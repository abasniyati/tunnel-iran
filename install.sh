#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ $EUID -eq 0 ]] || { echo 'Run with sudo: sudo ./install.sh' >&2; exit 1; }
mkdir -p /etc/tunnel
if [[ ! -e /etc/tunnel/tunnel.conf ]]; then install -m 600 "$ROOT_DIR/config/tunnel.conf" /etc/tunnel/tunnel.conf; else echo 'Keeping existing /etc/tunnel/tunnel.conf'; fi
install -d -m 755 /usr/local/lib/tunnel-iran/scripts
install -m 755 "$ROOT_DIR/scripts/tunnel-server.sh" /usr/local/lib/tunnel-iran/scripts/tunnel-server.sh
install -m 755 "$ROOT_DIR/scripts/tunnel-client.sh" /usr/local/lib/tunnel-iran/scripts/tunnel-client.sh
install -m 644 "$ROOT_DIR/scripts/obfuscation.sh" /usr/local/lib/tunnel-iran/scripts/obfuscation.sh
install -m 755 "$ROOT_DIR/test-harness.sh" /usr/local/lib/tunnel-iran/test-harness.sh
cat <<'MSG'
Files installed. Choose the role explicitly:
  Foreign server: SERVER_PUBLIC_ENDPOINT=your.public.ip sudo -E /usr/local/lib/tunnel-iran/scripts/tunnel-server.sh
  Iran server:    sudo /usr/local/lib/tunnel-iran/scripts/tunnel-client.sh /path/to/client.conf

The client.conf is generated on the foreign server at:
  /etc/tunnel/client-configs/client.conf
and packaged in client-config.tar.gz. Transfer it securely; it contains a private key.
MSG
#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────
# install.sh — One-line installer
# Usage:
# curl -sSL https://raw.githubusercontent.com/abasniyati/tunnel-iran/main/install.sh | sudo bash -s -- iran
# curl -sSL https://raw.githubusercontent.com/abasniyati/tunnel-iran/main/install.sh | sudo bash -s -- foreign
# ─────────────────────────────────────────────────────────────

ROLE="${1:-iran}"
REPO="https://raw.githubusercontent.com/abasniyati/tunnel-iran/main"

if [[ "$ROLE" == "foreign" ]]; then
 curl -sSL "$REPO/scripts/tunnel-server.sh" | sudo bash
elif [[ "$ROLE" == "iran" ]]; then
 curl -sSL "$REPO/scripts/tunnel-client.sh" | sudo bash
else
 echo "Usage: install.sh [foreign|iran]" >&2
 exit 1
fi
