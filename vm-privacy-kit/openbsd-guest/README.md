# OpenBSD guest kit — Mullvad WireGuard + Hysteria 2 + fail-closed pf

For OpenBSD 7.9/amd64 inside the VM created by `vbox-privacy-setup.sh`.
Everything runs as root (`doas`). Nothing here contains keys or addresses.
Your Mullvad configs are imported from your own file, and the Hysteria
server settings are placeholders you fill in.

## Files

| Path in kit | Installed to | Purpose |
|---|---|---|
| `install.sh` | — | one-time setup (Mullvad first, then everything else) |
| `privctl` | `/usr/local/sbin/privctl` | Mullvad, Hysteria, locks, status |
| `etc/privkit.conf` | `/etc/privkit.conf` | addresses, ports, timeouts |
| `etc/rc.d/hysteria` | `/etc/rc.d/hysteria` | rc.d service (runs as `_hysteria`) |
| `etc/hysteria/config.yaml.template` | `/etc/hysteria/config.yaml` | Hysteria client config (placeholders) |

## Install (Mullvad first)

OpenBSD's base system has no `unzip`. On the **Linux host**, unzip this kit,
repack the Mullvad ZIP, and copy both into the VM:

```sh
./vbox-privacy-setup.sh pack-mullvad ~/Downloads/mullvad_wireguard_linux_all_all.zip
unzip openbsd-guest-setup.zip
scp -P 2221 -r openbsd-guest ~/.cache/vbox-privacy-kit/mullvad-configs.tgz YOURUSER@127.0.0.1:
```

In the VM (SSH `ssh -p 2221 YOURUSER@127.0.0.1`, or the VirtualBox console):

```sh
doas ksh ~/openbsd-guest/install.sh --mullvad ~/mullvad-configs.tgz --server se
rm ~/mullvad-configs.tgz          # the configs now live root-only in /etc/mullvad
doas privctl status
```

`--server` takes an exact name (`se-sto-wg-001`) or a prefix (`se`, `de-fra`,
`us-nyc`). A prefix picks a random match. `install.sh` stops if the
"You are connected to Mullvad" check fails, so `pkg_add`, `git` and the Go
module downloads never run outside Mullvad.

## Kill switch for Mullvad

```sh
doas privctl lock mullvad     # pf: only WireGuard may leave em0; IPv6 blocked
# open a SECOND ssh session now to prove you still get in, then:
doas privctl confirm          # otherwise it reverts by itself after 180 s
doas privctl persist          # optional: keep the lock across reboots
```

`lock mullvad` also NATs the Debian services VM (10.77.0.2) into Mullvad, so
that VM can be installed and updated through Mullvad as well.

## Hysteria 2 (later, when you have a server)

1. `doas vi /etc/hysteria/config.yaml` and fill every `__PLACEHOLDER__`:
   server IP:port, auth, SNI, the certificate option (a/b/c in the file), and
   a remote DNS resolver.
2. Run these:
   ```sh
   doas privctl hy2 check-config
   doas privctl hy2 start && doas privctl hy2 test
   doas privctl unlock && doas privctl lock tunnel && doas privctl confirm
   doas privctl persist            # optional
   ```
3. Apps use the proxies (`privctl proxy-env` prints the settings):
   HTTP `10.77.0.1:8080` and SOCKS5 `10.77.0.1:1080`. The DNS forwarder is
   `10.77.0.1:5353`.

With Mullvad up, Hysteria's QUIC runs inside `wg0`. The chain is:
VM → Mullvad → Hysteria server → website.

OpenBSD has no Hysteria TUN mode (upstream lists BSD TUN as unsupported), so
programs must use the proxies. In `lock tunnel` anything that ignores the
proxies simply has no connection.

## Commands

```
privctl status
privctl mullvad import|list|use|test|down
privctl hy2 check-config|start|stop|restart|enable|disable|test
privctl lock mullvad|tunnel ; privctl confirm ; privctl persist ; privctl unlock
privctl proxy-env
```

## Recovery

* Locked out of SSH: log in on the VirtualBox console and run `doas privctl unlock`.
  An unconfirmed lock also reverts by itself after 180 s.
* Tunnel down: with a lock on, traffic stops (fail closed). `privctl status`
  shows why. Fix it, or `privctl unlock`. `privctl hy2 enable` adds a watchdog
  that restarts Hysteria within 2 minutes.
* Bad Mullvad server: `privctl unlock; privctl mullvad use de; privctl mullvad test`,
  then lock again.
* Remove Mullvad completely: `privctl unlock; privctl mullvad down`.
