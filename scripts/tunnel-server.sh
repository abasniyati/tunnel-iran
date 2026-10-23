#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="2.0.0"
CONFIG_FILE="/etc/tunnel/tunnel.conf"
CONFIG_DIR="/etc/tunnel"
BUNDLE_DIR="/etc/tunnel/client-configs"
WG_DIR="/etc/wireguard"
WG_IF="wg0"
WG_PORT="51820"
SERVER_ADDR="10.200.200.1/24"
CLIENT_ADDR="10.200.200.2/32"
LOG_FILE="/var/log/tunnel-server.log"

log(){ printf '[%s] %-5s %s\n' "$(date '+%F %T')" "$1" "$2" | tee -a "$LOG_FILE"; }
die(){ log ERROR "$*"; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run as root: sudo ./scripts/tunnel-server.sh'
mkdir -p "$CONFIG_DIR" "$BUNDLE_DIR" "$WG_DIR" /var/lib/tunnel "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"; chmod 600 "$LOG_FILE"

PUBLIC_ENDPOINT_ENV="${SERVER_PUBLIC_ENDPOINT:-}"
if [[ -f "$CONFIG_FILE" ]]; then
  # This is an administrator-owned Bash config file; only use trusted files.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi
SERVER_PUBLIC_ENDPOINT="${PUBLIC_ENDPOINT_ENV:-${SERVER_PUBLIC_ENDPOINT:-}}"
WG_PORT="${WG_LISTEN_PORT:-$WG_PORT}"
FORWARD_START="${FORWARD_PORT_START:-10000}"
FORWARD_END="${FORWARD_PORT_END:-20000}"

install_packages(){
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y wireguard-tools iptables curl ca-certificates
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y wireguard-tools iptables curl ca-certificates
  elif command -v yum >/dev/null 2>&1; then
    yum install -y epel-release || true
    yum install -y wireguard-tools iptables curl ca-certificates
  else die 'Unsupported package manager. Install wireguard-tools and iptables manually.'; fi
}

if ! command -v wg >/dev/null 2>&1 || ! command -v wg-quick >/dev/null 2>&1; then
  log INFO 'Installing WireGuard dependencies'; install_packages
fi
command -v systemctl >/dev/null || die 'systemd is required by this installer.'

if [[ -z "${SERVER_PUBLIC_ENDPOINT:-}" ]]; then
  read -r -p 'Foreign server public IPv4 address or DNS name: ' SERVER_PUBLIC_ENDPOINT
fi
[[ -n "$SERVER_PUBLIC_ENDPOINT" && "$SERVER_PUBLIC_ENDPOINT" != *' '* && "$SERVER_PUBLIC_ENDPOINT" != *'/'* ]] || die 'Invalid public endpoint.'
[[ "$WG_PORT" =~ ^[0-9]+$ ]] && (( WG_PORT >= 1 && WG_PORT <= 65535 )) || die 'WG_LISTEN_PORT must be 1..65535.'
[[ "$FORWARD_START" =~ ^[0-9]+$ && "$FORWARD_END" =~ ^[0-9]+$ ]] && (( FORWARD_START >= 1 && FORWARD_END <= 65535 && FORWARD_START <= FORWARD_END )) || die 'Invalid forwarding port range.'

umask 077
if [[ ! -s "$WG_DIR/server_private.key" ]]; then wg genkey > "$WG_DIR/server_private.key"; fi
if [[ ! -s "$WG_DIR/client_private.key" ]]; then wg genkey > "$WG_DIR/client_private.key"; fi
chmod 600 "$WG_DIR"/*_private.key
SERVER_PRIV=$(cat "$WG_DIR/server_private.key")
SERVER_PUB=$(printf '%s' "$SERVER_PRIV" | wg pubkey)
CLIENT_PRIV=$(cat "$WG_DIR/client_private.key")
CLIENT_PUB=$(printf '%s' "$CLIENT_PRIV" | wg pubkey)
printf '%s\n' "$SERVER_PUB" > "$WG_DIR/server_public.key"
chmod 644 "$WG_DIR/server_public.key"

# Pick a likely outbound interface for NAT. Forwarding is only needed if the
# server itself routes client traffic onward; port forwarding targets local services.
cat > "$WG_DIR/$WG_IF.conf" <<WGEOF
[Interface]
Address = $SERVER_ADDR
ListenPort = $WG_PORT
PrivateKey = $SERVER_PRIV
SaveConfig = false

[Peer]
# Iran-side forwarding gateway
PublicKey = $CLIENT_PUB
AllowedIPs = 10.200.200.2/32
WGEOF
chmod 600 "$WG_DIR/$WG_IF.conf"

# Enable IPv4 forwarding persistently for deployments that later route through WG.
cat > /etc/sysctl.d/90-tunnel-iran.conf <<'SYSEOF'
net.ipv4.ip_forward=1
SYSEOF
sysctl --system >/dev/null
systemctl enable --now "wg-quick@$WG_IF"

# Open the WireGuard UDP port where UFW is present. Other firewalls/cloud ACLs
# must be updated separately by the administrator.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw allow "$WG_PORT/udp" || true
fi

CLIENT_CONFIG="$BUNDLE_DIR/client.conf"
cat > "$CLIENT_CONFIG" <<WGEOF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.200.200.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = $SERVER_PUB
Endpoint = $SERVER_PUBLIC_ENDPOINT:$WG_PORT
AllowedIPs = 10.200.200.1/32
PersistentKeepalive = 25
WGEOF
chmod 600 "$CLIENT_CONFIG"
# Also export the non-secret server public key for diagnostics.
printf '%s\n' "$SERVER_PUB" > "$BUNDLE_DIR/server_public.key"
chmod 644 "$BUNDLE_DIR/server_public.key"
BUNDLE="$BUNDLE_DIR/client-config.tar.gz"
tar -czf "$BUNDLE" -C "$BUNDLE_DIR" client.conf server_public.key
chmod 600 "$BUNDLE"

log INFO "WireGuard server configured: $SERVER_PUBLIC_ENDPOINT:$WG_PORT"
log INFO "Client bundle created: $BUNDLE"
log INFO "Copy the bundle securely to the Iran server; it contains a private key."
log INFO 'Check status with: wg show wg0'
printf '\nClient bundle: %s\nServer public key: %s\n' "$BUNDLE" "$SERVER_PUB"
