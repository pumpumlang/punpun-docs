# Debian services VM kit — Pi-hole + SearXNG

**Why a separate VM:** Pi-hole's official supported OS list is Alpine, Armbian,
Debian, CentOS Stream, Fedora, Raspberry Pi OS and Ubuntu. OpenBSD is not on
it, so Pi-hole runs here, on Debian. SearXNG is not packaged for OpenBSD, and
its official installer covers Debian/Ubuntu, Arch and Fedora, so it runs here
too.

| | |
|---|---|
| Address | `10.77.0.2/24` on the internal VirtualBox network `privacykit-lan` |
| Gateway | OpenBSD VM `10.77.0.1` (Mullvad), no NAT cable by default |
| Pi-hole | DNS `10.77.0.2:53`, web UI `http://10.77.0.2/admin` |
| SearXNG | `http://10.77.0.2:8888/` |

## Install

1. OpenBSD first: `doas privctl lock mullvad && doas privctl confirm`
   (this VM reaches the Internet only through it).
2. Debian installer: pick the **second** NIC (MAC `08:00:27:77:00:02`). DHCP
   fails, so choose manual: IP `10.77.0.2/24`, gateway `10.77.0.1`, DNS
   `10.64.0.1`. No root password. Software: only "SSH server" and "standard
   system utilities".
3. From the host, through OpenBSD:
   ```sh
   unzip debian-services-setup.zip
   scp -o ProxyJump=OBSDUSER@127.0.0.1:2221 -r debian-services-guest DEBUSER@10.77.0.2:
   ssh -J OBSDUSER@127.0.0.1:2221 DEBUSER@10.77.0.2
   ```
4. In the VM:
   ```sh
   cd ~/debian-services-guest
   sudo ./setup-lan.sh              # no-op if the installer already set 10.77.0.2
   sudo ./install-pihole.sh         # official interactive installer; choose the LAN NIC
   sudo pihole setpassword
   sudo ./install-searxng.sh
   sudo ./services-mode.sh status
   ```

## Modes (`sudo ./services-mode.sh <mode>`)

| Mode | Internet path | Pi-hole upstream | Needs on OpenBSD |
|---|---|---|---|
| `mullvad` (default) | default route → OpenBSD → Mullvad | `10.64.0.1` (Mullvad DNS) | `privctl lock mullvad` |
| `tunnel` | none; only the Hysteria proxies | `10.77.0.1#5353` | `privctl lock tunnel` |
| `direct` | own NAT adapter (not private) | Quad9 `9.9.9.9`, `149.112.112.112` | host: `connect-services` |

In `mullvad` and `tunnel` mode, keep this VM's NAT cable unplugged
(`vbox-privacy-setup.sh isolate-services`, the default for a new VM).

## Web UIs from the Linux host

```sh
ssh -p 2221 -L 8081:10.77.0.2:80 -L 8888:10.77.0.2:8888 OBSDUSER@127.0.0.1
# Pi-hole: http://127.0.0.1:8081/admin     SearXNG: http://127.0.0.1:8888/
```
