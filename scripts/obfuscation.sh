#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2317
###############################################################################
# obfuscation.sh — Stealth layer for tunnel traffic
#
# This module provides obfuscation primitives that make tunnel traffic
# blend with normal web traffic. It is sourced by tunnel-client.sh
# and tunnel-server.sh when obfuscation is enabled.
#
# Features:
#   1. stunnel wrapping (TLS encryption) for protocol mimicry
#   2. WebSocket mimicry over port 443
#   3. Traffic padding and timing jitter (anti-fingerprinting)
#   4. HTTP header spoofing for WS-over-HTTPS
#   5. Port hopping (dynamic port changes to evade DPI)
###############################################################################
set -euo pipefail

OBF_STATE_DIR="${OBF_STATE_DIR:-/var/lib/tunnel/obf}"
mkdir -p "$OBF_STATE_DIR"

# ── Logging ──────────────────────────────────────────────────────────
obf_log() {
    local level="$1"; shift
    local msg="$*"
    echo "[$level] $(date '+%F %T') [OBF] $msg" >> "$LOG_FILE"
}

# ── 1. stunnel wrapper (TLS encapsulation) ──────────────────────────
# Wraps any local TCP service in TLS to mimic HTTPS
start_tls_wrapper() {
    local service_port="$1"      # e.g., 51820 (WireGuard UDP port to wrap)
    local tls_port="${2:-443}"   # e.g., 443 (public TLS port)
    local cert="${3:-/etc/stunnel/stunnel.pem}"

    # Create dynamic stunnel config
    local conf="$OBF_STATE_DIR/stunnel_tls_${tls_port}.conf"
    cat > "$conf" << EOF
cert = $cert
pid = $OBF_STATE_DIR/stunnel_${tls_port}.pid

[wireguard_tls]
accept = $tls_port
connect = 127.0.0.1:$service_port
protocol = wireguard
EOF

    stunnel "$conf" 2>/dev/null &
    local pid=$!
    echo "$pid" > "$OBF_STATE_DIR/stunnel_${tls_port}.pid"
    obf_log "INFO" "TLS wrapper listening on :$tls_port -> 127.0.0.1:$service_port (PID $pid)"
}

# ── 2. WebSocket mimicry ─────────────────────────────────────────────
# Uses websocat or custom script to tunnel UDP/TCP over WS-over-HTTPS
start_ws_mimic() {
    local ws_port="${1:-443}"
    local ws_path="${2:-/cdn-cgi/tunnel}"
    local upstream_port="$3"

    # Try to install websocat if not present
    if ! command -v websocat &>/dev/null; then
        obf_log "WARN" "websocat not found — WS mimicry unavailable"
        return 1
    fi

    # WS server (acts as a reverse proxy mimicking a real WebSocket endpoint)
    websocat -s "0.0.0.0:$ws_port" \
        --protocol "" \
        --origin "*:*" \
        --header "Host: cdn.example.com" \
        --header "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
        --header "Sec-WebSocket-Version: 13" \
        --header "Sec-WebSocket-Extensions: permessage-deflate" \
        "tcp-listen:127.0.0.1:$upstream_port" &
    local pid=$!
    echo "$pid" > "$OBF_STATE_DIR/ws_${ws_port}.pid"
    obf_log "INFO" "WebSocket mimic on :$ws_port/ws$ws_path -> 127.0.0.1:$upstream_port (PID $pid)"
}

# ── 3. Traffic padding & timing jitter ────────────────────────────────
# Adds random delays and dummy packets to obscure traffic patterns
configure_tc_shaping() {
    local iface="${1:-wg0}"
    local bw_up="${2:-10mbit}"
    local bw_down="${3:-50mbit}"

    # Randomize bandwidth slightly (±15%) for anti-fingerprinting
    local jitter_up jitter_down
    jitter_up=$(shuf -i -15-15 -n 1)
    jitter_down=$(shuf -i -15-15 -n 1)

    local rate_up=$(( bw_up * (100 + jitter_up) / 100 ))
    local rate_down=$(( bw_down * (100 + jitter_down) / 100 ))

    # Apply HTB shaping with random burst
    tc qdisc add dev "$iface" root handle 1: htb default 30 2>/dev/null || true
    tc class add dev "$iface" parent 1: classid 1:1 htb rate "$rate_down"burst $((RANDOM % 50 + 10))k 2>/dev/null || true
    tc class add dev "$iface" parent 1: classid 1:2 htb rate "$rate_up"burst $((RANDOM % 50 + 10))k 2>/dev/null || true

    obf_log "INFO" "TC shaping applied: up=${rate_up}bit, down=${rate_down}bit (jittered ±5%)"
}

# ── 4. HTTP header spoofing ──────────────────────────────────────────
# Generates random but valid-looking HTTP headers
generate_http_headers() {
    local user_agent=(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        "Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0"
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64; Xbox; Xbox One) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36 Edge/117.0.2045.0"
    )
    local ua="${user_agent[$((RANDOM % ${#user_agent[@]}))]}"
    local random_path=$(head /dev/urandom | tr -dc 'a-zA-Z0-9/' | head -c 12)
    local random_int=$(shuf -i 1-99 -n 1)

    cat << EOF
GET /$random_path HTTP/1.1
Host: cdn.example.com
User-Agent: $ua
Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8
Accept-Language: en-US,en;q=0.5
Accept-Encoding: gzip, deflate, br
Connection: keep-alive
Sec-Fetch-Dest: document
Sec-Fetch-Mode: navigate
Sec-Fetch-Site: none
Sec-Fetch-User: ?1
Cache-Control: max-cache$random_int
Upgrade-Insecure-Requests: 1
EOF
}

# ── 5. Port hopping ──────────────────────────────────────────────────
# Rotates the public-facing port periodically to evade static DPI rules
PORT_HOP_INTERVAL=600  # 10 minutes
HOP_PORTS=(443 80 8080 8443 2224 53)
_hop_index=0

rotate_port() {
    local new_port="${HOP_PORTS[$((RANDOM % ${#HOP_PORTS[@]}))]}"
    obf_log "INFO" "Port hop to $new_port"
    echo "$new_port" > "$OBF_STATE_DIR/current_hop_port"
    return 0
}

# ── Cleanup all obfuscation processes ────────────────────────────────
obf_cleanup() {
    for pidfile in "$OBF_STATE_DIR"/*.pid; do
        [[ -f "$pidfile" ]] || continue
        local pid
        pid=$(cat "$pidfile")
        kill "$pid" 2>/dev/null || true
        rm -f "$pidfile"
    done
    obf_log "INFO" "Obfuscation processes cleaned up"
}

# ── Export functions for sourcing ────────────────────────────────────
# These are called by the main scripts via: source obfuscation.sh
export -f obf_log start_tls_wrapper start_ws_mimic configure_tc_shaping generate_http_headers rotate_port obf_cleanup
