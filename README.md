# tunnel-iran

A small, auditable WireGuard-based tunnel for forwarding selected TCP/UDP ports from an Iran-side server to services listening on a foreign server. This repository is a cleaned-up, conservative implementation of the uploaded draft. The supported deployment path is **WireGuard only**; SSH/stunnel/WebSocket/traffic-shaping code from the original draft is retained only for reference and is not started by the installer.

> **Important:** This forwards matching ports to the foreign server's WireGuard address (`10.200.200.1`). The target service must be listening on that host/interface and the selected ports must match your actual service ports. Test on a maintenance window and keep console access to both servers. Configure your provider firewall/security group to allow the WireGuard UDP port.

## Repository layout

```text
tunnel-iran/
├── install.sh
├── README.md
├── .gitignore
├── config/
│   └── tunnel.conf
├── scripts/
│   ├── tunnel-server.sh
│   ├── tunnel-client.sh
│   └── obfuscation.sh       # legacy/experimental; not used by supported setup
├── docs/
│   └── AUDIT.md
└── test-harness.sh
```

## Requirements

- Two Linux servers with root/sudo access and systemd.
- A foreign server reachable from the Iran server.
- Ubuntu/Debian or RHEL-family system with `apt`, `dnf`, or `yum`.
- UDP reachability to the WireGuard port (default `51820`) on the foreign server.
- `wireguard-tools` and `iptables` (the scripts install them when possible).

## 1. Review and install the project

Do not pipe an unreviewed remote script directly into a root shell. Upload/clone this repository, inspect the scripts, then run:

```bash
cd tunnel-iran
sudo bash ./test-harness.sh
sudo bash ./install.sh
```

`install.sh` copies the supported scripts to `/usr/local/lib/tunnel-iran/` and installs the sample settings at `/etc/tunnel/tunnel.conf` only if that file does not already exist. Review/edit `/etc/tunnel/tunnel.conf` on both servers before deployment. The config is a Bash file and is sourced by the scripts; only use a file you control.

## 2. Configure the foreign server

On the foreign server, set the public endpoint in `/etc/tunnel/tunnel.conf` or provide it as an environment variable. Then run:

```bash
sudo nano /etc/tunnel/tunnel.conf
sudo SERVER_PUBLIC_ENDPOINT=YOUR_PUBLIC_IP_OR_DOMAIN /usr/local/lib/tunnel-iran/scripts/tunnel-server.sh
```

Replace `YOUR_PUBLIC_IP_OR_DOMAIN` with the actual public IP or DNS name. If the setting is left blank, the script asks interactively. It creates a WireGuard interface named `wg0`, listens on UDP `WG_LISTEN_PORT`, and creates a client config bundle at:

```text
/etc/tunnel/client-configs/client-config.tar.gz
```

The bundle contains a **private key**. Keep it secret and transfer it over a trusted channel, for example from your workstation:

```bash
scp root@FOREIGN_SERVER:/etc/tunnel/client-configs/client-config.tar.gz .
```

If root SSH is disabled, copy it through an administrator account with suitable permissions. Do not commit the bundle or `client.conf` to GitHub.

Also open the configured WireGuard UDP port in the hosting provider's firewall/security group. The script attempts to add a UFW rule if UFW is active, but it cannot change every cloud firewall.

## 3. Configure the Iran-side server

Copy the archive to the Iran server using SCP/SFTP. Then:

```bash
sudo mkdir -p /etc/tunnel/client-import
sudo tar -xzf client-config.tar.gz -C /etc/tunnel/client-import
sudo chmod 600 /etc/tunnel/client-import/client.conf
sudo nano /etc/tunnel/tunnel.conf
sudo /usr/local/lib/tunnel-iran/scripts/tunnel-client.sh /etc/tunnel/client-import/client.conf
```

Set `FORWARD_PORT_START` and `FORWARD_PORT_END` to the exact port range you intend to forward. Defaults are `10000`–`20000`; do not keep that broad range unless you really need it. The client script installs the config as `/etc/wireguard/wg0.conf`, enables `wg-quick@wg0`, and adds idempotent NAT rules for TCP and UDP in the selected range.

## 4. Verify

Run these on the Iran-side server:

```bash
sudo wg show wg0
sudo systemctl status wg-quick@wg0 --no-pager
sudo journalctl -u wg-quick@wg0 -n 100 --no-pager
sudo iptables -t nat -S PREROUTING
sudo iptables -t nat -S POSTROUTING
```

A successful WireGuard connection should show a recent `latest handshake` and increasing transfer counters in `wg show`. A UDP port probe alone is not proof of a WireGuard handshake. Confirm the target service is listening on the foreign server and test one known port before forwarding a wide range.

On the foreign server:

```bash
sudo wg show wg0
sudo systemctl status wg-quick@wg0 --no-pager
sudo ss -lntup
```

## 5. Stop / uninstall manually

To stop the client tunnel:

```bash
sudo systemctl disable --now wg-quick@wg0
```

To stop the foreign-side tunnel:

```bash
sudo systemctl disable --now wg-quick@wg0
```

The Iran-side NAT rules are managed by iptables and may remain after stopping WireGuard. Remove only the rules you added after checking `iptables -t nat -S`; do not flush the host's entire firewall. Back up `/etc/wireguard/` before removing keys/configs.

## What this project does not claim

- It does not provide automatic protocol selection or failover. The old draft's TCP/UDP probes could not reliably establish whether WireGuard or stunnel worked end-to-end.
- It does not wrap WireGuard UDP in stunnel. stunnel is a TCP proxy and cannot directly carry WireGuard UDP in the configuration used by the draft.
- The legacy WebSocket/header-spoofing/port-hopping functions are not enabled and should not be treated as a working tunnel implementation.
- It does not configure x-ui itself, change x-ui bind addresses, or open arbitrary cloud-provider firewalls.
- The current scripts do not persist iptables rules across a reboot on every distribution. Confirm persistence with your OS firewall tooling if you need it.

## Logs

- Foreign server: `/var/log/tunnel-server.log`
- Iran server: `/var/log/tunnel-client.log`

## License

MIT. Use at your own risk; review before deploying on production systems.
