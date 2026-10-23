#!/usr/bin/env bash
set -uo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ok(){ printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail(){ printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }
check_syntax(){ local f="$1"; if bash -n "$f"; then ok "bash syntax: ${f#"$ROOT_DIR"/}"; else fail "bash syntax: ${f#"$ROOT_DIR"/}"; fi; }
for f in "$ROOT_DIR/install.sh" "$ROOT_DIR/scripts/tunnel-server.sh" "$ROOT_DIR/scripts/tunnel-client.sh" "$ROOT_DIR/scripts/obfuscation.sh"; do check_syntax "$f"; done
if [[ -f "$ROOT_DIR/config/tunnel.conf" ]] && bash -c 'source "$1"' _ "$ROOT_DIR/config/tunnel.conf" 2>/dev/null; then ok 'config parses as Bash'; else fail 'config missing or invalid'; fi
for f in "$ROOT_DIR/install.sh" "$ROOT_DIR/scripts/tunnel-server.sh" "$ROOT_DIR/scripts/tunnel-client.sh" "$ROOT_DIR/test-harness.sh"; do [[ -x "$f" ]] && ok "executable bit: ${f#"$ROOT_DIR"/}" || fail "missing executable bit: ${f#"$ROOT_DIR"/}"; done
if grep -q '10.200.200.1' "$ROOT_DIR/scripts/tunnel-client.sh" && grep -q '10.200.200.2/32' "$ROOT_DIR/scripts/tunnel-server.sh"; then ok 'WireGuard peer addressing is consistent'; else fail 'WireGuard peer addressing mismatch'; fi
if [[ ! -e "$ROOT_DIR/configs" && -f "$ROOT_DIR/config/tunnel.conf" ]]; then ok 'test harness uses current config path'; else fail 'config directory layout mismatch'; fi
printf '\nSummary: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
