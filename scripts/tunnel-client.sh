#!/usr/bin/env bash
set -Eeuo pipefail
VERSION="2.0.0"
WG_IF="wg0"
WG_DIR="/etc/wireguard"
CONFIG_DIR="/etc/tunnel"
SETTINGS="$CONFIG_DIR/tunnel.conf"
WG_CONFIG="$WG_DIR/$WG_IF.conf"
LOG_FILE="/var/log/tunnel-client.log"

log(){ printf '[%s] %-5s %s\n' "$(date '+%F %T')" "$1" "$2" | tee -a "$LOG_FILE"; }
die(){ log ERROR "$*"; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run as root: sudo ./scripts/tunnel-client.sh /path/to/client.conf'
mkdir -p "$CONFIG_DIR" "$WG_DIR" /var/lib/tunnel "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"

install_packages(){
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wireguard-tools iptables
  elif command -v dnf >/dev/null 2>&1; then dnf install -y wireguard-tools iptables
  elif command -v yum >/dev/null 2>&1; then yum install -y epel-release || true; yum install -y wireguard-tools iptables
  else die 'Unsupported package manager. Install wireguard-tools and iptables manually.'; fi
}

if ! command -v wg >/dev/null 2>&1 || ! command -v wg-quick >/dev/null 2>&1; then
  log INFO 'Installing WireGuard dependencies'; install_packages
fi
command -v systemctl >/dev/null || die 'systemd is required by this installer.'

CLIENT_SOURCE="${1:-}"
if [[ -n "$CLIENT_SOURCE" ]]; then
  [[ -f "$CLIENT_SOURCE" ]] || die "Client config file not found: $CLIENT_SOURCE"
  install -m 600 "$CLIENT_SOURCE" "$WG_CONFIG"
elif [[ ! -f "$WG_CONFIG" ]]; then
  die "Missing $WG_CONFIG. Provide the client.conf extracted from the foreign server bundle."
fi

# Validate essential WireGuard fields before enabling a service.
grep -Eq '^PrivateKey[[:space:]]*=' "$WG_CONFIG" || die 'PrivateKey missing from client config.'
grep -Eq '^Address[[:space:]]*=' "$WG_CONFIG" || die 'Address missing from client config.'
grep -Eq '^PublicKey[[:space:]]*=' "$WG_CONFIG" || die 'Peer PublicKey missing from client config.'
grep -Eq '^Endpoint[[:space:]]*=' "$WG_CONFIG" || die 'Peer Endpoint missing from client config.'
chmod 600 "$WG_CONFIG"
systemctl enable "wg-quick@$WG_IF"
if ! systemctl restart "wg-quick@$WG_IF"; then
  log WARN 'Service restart failed; trying a clean start'
  systemctl stop "wg-quick@$WG_IF" 2>/dev/null || true
  systemctl start "wg-quick@$WG_IF" || die 'WireGuard could not start. Check endpoint, firewall and keys.'
fi

# Load forwarding settings, not the peer's WireGuard config.
if [[ -f "$SETTINGS" ]]; then
  # shellcheck disable=SC1090
  source "$SETTINGS"
fi
START="${FORWARD_PORT_START:-10000}"
END="${FORWARD_PORT_END:-20000}"
[[ "$START" =~ ^[0-9]+$ && "$END" =~ ^[0-9]+$ ]] && (( START >= 1 && END <= 65535 && START <= END )) || die 'Invalid forwarding port range in /etc/tunnel/tunnel.conf.'

# Forward incoming TCP and UDP service ports from the Iran host to services on
# the foreign host through the WireGuard peer. SNAT ensures replies return via WG.
for proto in tcp udp; do
  iptables -t nat -C PREROUTING -p "$proto" --dport "$START:$END" -j DNAT --to-destination 10.200.200.1 2>/dev/null || \
    iptables -t nat -A PREROUTING -p "$proto" --dport "$START:$END" -j DNAT --to-destination 10.200.200.1
  iptables -t nat -C POSTROUTING -p "$proto" -d 10.200.200.1 --dport "$START:$END" -j SNAT --to-source 10.200.200.2 2>/dev/null || \
    iptables -t nat -A POSTROUTING -p "$proto" -d 10.200.200.1 --dport "$START:$END" -j SNAT --to-source 10.200.200.2
done
# Permit only the selected forwarded port range through the host firewall.
iptables -C FORWARD -o "$WG_IF" -d 10.200.200.1 -p tcp --dport "$START:$END" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -o "$WG_IF" -d 10.200.200.1 -p tcp --dport "$START:$END" -j ACCEPT
iptables -C FORWARD -o "$WG_IF" -d 10.200.200.1 -p udp --dport "$START:$END" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -o "$WG_IF" -d 10.200.200.1 -p udp --dport "$START:$END" -j ACCEPT
iptables -C FORWARD -i "$WG_IF" -s 10.200.200.1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "$WG_IF" -s 10.200.200.1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
cat > /etc/sysctl.d/90-tunnel-iran.conf <<'SYSEOF'
net.ipv4.ip_forward=1
SYSEOF
sysctl --system >/dev/null

log INFO "WireGuard client started on $WG_IF"
log INFO "Forwarding TCP/UDP ports $START-$END to foreign tunnel IP 10.200.200.1"
log INFO 'Verify the handshake with: wg show wg0'
wg show "$WG_IF" || true
