# Audit notes for the supplied draft

This file distinguishes changes made in the cleaned-up project from features that were only claimed by the original draft.

## Critical issues found in the supplied scripts

1. **Mismatched config contracts:** server settings used Bash arrays such as `FOREIGN_ENDPOINTS`; the client expected JSON-like `WG_ENDPOINTS`. The generated config therefore did not match what the client parsed.
2. **WireGuard/stunnel protocol mismatch:** the draft configured stunnel TCP to connect to a WireGuard UDP listener and set `protocol = wireguard`. This does not make WireGuard work over TCP.
3. **Different interface names:** server config used `WG_INTERFACE=wg-tunnel`, while client hard-coded `wg0` and `/etc/wireguard/wg0.conf`.
4. **Invalid DNAT target:** rules used `10.200.200.2:0`, which is not a valid target for forwarding an arbitrary range while preserving destination ports.
5. **SSH endpoint inconsistency:** server hard-coded port 2224, and the client overwrote the SSH port variable while constructing forwards, risking a connection to the wrong port.
6. **Incorrect SSH service test:** checking whether both `ssh` and `sshd` are inactive with an OR condition does not correctly detect the service name used by a distribution.
7. **Misleading health checks:** sending UDP data to a port is not a WireGuard handshake; a TCP connect does not verify a working stunnel tunnel.
8. **Broken traffic shaping arithmetic:** bandwidth strings such as `10mbit` were used as Bash arithmetic operands, and the generated `tc` syntax was malformed.
9. **Port hopping was not implemented:** the draft wrote a chosen port to a state file but did not reconfigure listeners/firewalls/client endpoints.
10. **Test harness path and counter bugs:** it expected `configs/tunnel.conf` and scripts at the repository root, while the intended layout used `config/` and `scripts/`; `((PASS++))` can return a failing status under `set -e` when the initial value is zero.
11. **Unsafe install pattern:** the draft recommended piping remote content directly to a root shell without an inspect/review step.

## Changes in this version

- Standardized on one supported transport: WireGuard.
- Made server and client use `wg0` and the `10.200.200.1/24` / `10.200.200.2/32` addressing plan consistently.
- Generated a proper WireGuard peer config and packaged it in a root-readable bundle.
- Validated essential settings before attempting to start the client.
- Added idempotent NAT rules that preserve destination ports and SNAT return traffic to the tunnel client address.
- Fixed repository paths and test counter handling.
- Kept the old obfuscation script as a reference only; it is not started by `install.sh` or the supported server/client scripts.

## Remaining deployment checks

- Confirm your target service listens on the foreign host's WireGuard-reachable address or wildcard address.
- Confirm the selected port range is correct and as narrow as possible.
- Configure provider-level firewall/security-group rules.
- Test actual service connectivity and reboot persistence on both distributions before production use.
- Consider using your distribution's persistent firewall manager instead of relying on transient iptables rules.
