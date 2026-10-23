#!/usr/bin/env bash
set -Eeuo pipefail

REPO=""
BRANCH="main"
ROLE=""

while (($#)); do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --branch) BRANCH="${2:-}"; shift 2 ;;
    --role) ROLE="${2:-}"; shift 2 ;;
    -h|--help)
      echo "Usage: bootstrap.sh --repo OWNER/REPO --role server|client"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[[ $EUID -eq 0 ]] || {
  echo "Run as root." >&2
  exit 1
}

[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
  echo "Invalid repository. Use OWNER/REPO." >&2
  exit 2
}

[[ -z "$ROLE" || "$ROLE" == "server" || "$ROLE" == "client" ]] || {
  echo "Role must be server or client." >&2
  exit 2
}

command -v curl >/dev/null 2>&1 || {
  echo "curl is required." >&2
  exit 1
}

command -v tar >/dev/null 2>&1 || {
  echo "tar is required." >&2
  exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"

echo "Downloading project from GitHub..."

curl -fsSL "$ARCHIVE_URL" -o "$TMP_DIR/repo.tar.gz"
tar -xzf "$TMP_DIR/repo.tar.gz" -C "$TMP_DIR"

PROJECT_DIR="$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit)"

[[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/install.sh" ]] || {
  echo "Project files or install.sh not found." >&2
  exit 1
}

echo "Checking script syntax..."

for f in \
  "$PROJECT_DIR/install.sh" \
  "$PROJECT_DIR/scripts/tunnel-server.sh" \
  "$PROJECT_DIR/scripts/tunnel-client.sh"
do
  [[ -f "$f" ]] || {
    echo "Missing required file: $f" >&2
    exit 1
  }

  bash -n "$f"
done

echo "Installing project..."
bash "$PROJECT_DIR/install.sh"

if [[ -z "$ROLE" ]]; then
  echo "Select server role:"
  echo "1) Foreign server"
  echo "2) Iran client"
  read -r -p "Choose 1 or 2: " choice

  case "$choice" in
    1) ROLE="server" ;;
    2) ROLE="client" ;;
    *)
      echo "Invalid selection." >&2
      exit 2
      ;;
  esac
fi

if [[ "$ROLE" == "server" ]]; then
  read -r -p "Foreign server public IP or domain: " endpoint

  if [[ -n "$endpoint" ]]; then
    SERVER_PUBLIC_ENDPOINT="$endpoint" \
      /usr/local/lib/tunnel-iran/scripts/tunnel-server.sh
  else
    /usr/local/lib/tunnel-iran/scripts/tunnel-server.sh
  fi

  echo "Server setup finished."
  echo "Transfer the client configuration securely to the Iran server."
else
  read -r -p "Full path to client.conf: " client_config

  [[ -f "$client_config" ]] || {
    echo "Client configuration file not found." >&2
    exit 1
  }

  /usr/local/lib/tunnel-iran/scripts/tunnel-client.sh "$client_config"
fi
