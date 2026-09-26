# vm-privacy-kit — OpenBSD + Mullvad + Hysteria 2, with a Pi-hole/SearXNG companion VM

$0 setup (all components are free and open source; Mullvad and any Hysteria
server are what you already pay for). Built for Oracle VirtualBox 7.x on a Linux host.
Your existing Parrot VM and its disk are listed as **protected**: the host
script refuses to create, attach, change or delete anything inside that folder.

| Download | What |
|---|---|
| `dist/vbox-privacy-host.zip` | host script + config (creates the VMs) |
| `dist/openbsd-guest-setup.zip` | OpenBSD guest kit (Mullvad, Hysteria 2, pf locks) |
| `dist/debian-services-setup.zip` | Debian companion VM kit (Pi-hole, SearXNG) |
| `dist/SHA256SUMS` | checksums of the three ZIPs |

Your Mullvad ZIP is **not** included anywhere. It holds your WireGuard
private key, and it stays on your host and inside the OpenBSD VM (root-only).

## Layout

```
 Linux host (VirtualBox)
 ├─ OpenBSD-7.9-Privacy        em0 NAT (Internet, ssh 127.0.0.1:2221 -> 22)
 │    wg0  Mullvad WireGuard   em1 10.77.0.1 ──┐  internal network "privacykit-lan"
 │    Hysteria 2 client (proxies on 10.77.0.1) │  (only these two VMs; host not on it)
 └─ Debian-PiHole-SearXNG      em(2) 10.77.0.2 ┘  gateway 10.77.0.1, NAT cable unplugged
      Pi-hole :53/:80, SearXNG :8888
```

Traffic paths:

* `lock mullvad`: OpenBSD and the Debian VM → wg0 → Mullvad → Internet.
* `lock tunnel`: apps → Hysteria proxies → (wg0 → Mullvad) → Hysteria server → Internet.

Anything else is blocked by pf on OpenBSD. IPv4 and IPv6 are both covered;
IPv6 is dropped because your Mullvad configs are IPv4-only. DNS goes to
Pi-hole (upstream: Mullvad DNS, or the Hysteria DNS forwarder), never to the
VirtualBox NAT resolver.

## Step by step

### 1. Host — create the OpenBSD VM

```sh
unzip vbox-privacy-host.zip && cd vbox-privacy-host
./vbox-privacy-setup.sh check                  # read-only: prerequisites + collisions
./vbox-privacy-setup.sh --dry-run create-openbsd   # optional: see every command first
./vbox-privacy-setup.sh create-openbsd
VBoxManage startvm "OpenBSD-7.9-Privacy"
```

The script downloads `install79.iso` from cdn.openbsd.org and requires the
SHA256 from cdn.openbsd.org and ftp.openbsd.org to be identical. It also checks
the signify signature if `signify-openbsd` and the 7.9 key are installed. It
creates a 24 GB dynamic VDI, 2 CPUs, 2 GB RAM, audio/USB/clipboard/drag-and-drop
off, NIC1 NAT (SSH on 127.0.0.1:2221 only, guest cannot reach host localhost),
and NIC2 on the internal network (MAC 08:00:27:77:00:01).

OpenBSD installer answers: em0 `dhcp`, IPv6 `none`; em1 `none`; sshd yes;
create a user; auto layout; sets from `cd0`. The installer downloads nothing.

**Strict first boot (recommended).** OpenBSD's first boot runs `fw_update`,
and `ntpd` starts contacting time servers. Both would go out directly, before
Mullvad exists. To prevent that:

```sh
./vbox-privacy-setup.sh eject-installer openbsd
./vbox-privacy-setup.sh cable openbsd off      # boot the new system unplugged
VBoxManage startvm "OpenBSD-7.9-Privacy"
#   console login -> doas rcctl stop ntpd
./vbox-privacy-setup.sh cable openbsd on
```

### 2. Host → OpenBSD — Mullvad first, then the kit

```sh
./vbox-privacy-setup.sh pack-mullvad ~/Downloads/mullvad_wireguard_linux_all_all.zip
unzip openbsd-guest-setup.zip
scp -P 2221 -r openbsd-guest ~/.cache/vbox-privacy-kit/mullvad-configs.tgz YOURUSER@127.0.0.1:
ssh -p 2221 YOURUSER@127.0.0.1
```

In OpenBSD:

```sh
doas ksh ~/openbsd-guest/install.sh --mullvad ~/mullvad-configs.tgz --server se
rm ~/mullvad-configs.tgz
doas rcctl start ntpd                          # if you stopped it: time sync now via Mullvad
doas privctl lock mullvad
#   from the host, open a second session to prove access: ssh -p 2221 YOURUSER@127.0.0.1
doas privctl confirm
doas privctl persist
```

`install.sh` imports all 533 configs. It brings up `wg0` (all IPv4 via Mullvad,
DNS 10.64.0.1 from your configs) and verifies *"You are connected to Mullvad"*.
Only then does it install `go` and `git` with `pkg_add`, and build Hysteria
2.12.3 from the pinned tag (commit `e1366b17…` verified). See
`openbsd-guest/README.md`.

### 3. Host — create the Pi-hole/SearXNG VM (installs through Mullvad)

```sh
./vbox-privacy-setup.sh create-services
VBoxManage startvm "Debian-PiHole-SearXNG"
```

The newest Debian stable netinst is chosen from the official `SHA512SUMS` and
checked against it. The GPG signature is also checked if the Debian CD key is
in your keyring. The VM starts with its NAT cable unplugged, so the Debian
installer can only reach the Internet through the OpenBSD VM and Mullvad.

Installer network: second NIC, manual `10.77.0.2/24`, gateway `10.77.0.1`,
DNS `10.64.0.1`. Then:

```sh
./vbox-privacy-setup.sh eject-installer services
unzip debian-services-setup.zip
scp -o ProxyJump=YOURUSER@127.0.0.1:2221 -r debian-services-guest DEBUSER@10.77.0.2:
ssh -J YOURUSER@127.0.0.1:2221 DEBUSER@10.77.0.2
cd ~/debian-services-guest && sudo ./setup-lan.sh && sudo ./install-pihole.sh \
  && sudo pihole setpassword && sudo ./install-searxng.sh && sudo ./services-mode.sh status
```

Then run `doas privctl unlock && doas privctl lock mullvad && doas privctl confirm`
on OpenBSD. This makes OpenBSD pick up Pi-hole as its resolver.

### 4. Later — Hysteria 2

Fill `/etc/hysteria/config.yaml` on OpenBSD, then run
`privctl hy2 start`, `privctl hy2 test`, `privctl unlock`, `privctl lock tunnel`,
and `privctl confirm`. On Debian, run `sudo ./services-mode.sh tunnel`.

## Rollback

```sh
./vbox-privacy-setup.sh rollback-openbsd      # only the VM + disk this kit created
./vbox-privacy-setup.sh rollback-services
./vbox-privacy-setup.sh rollback-openbsd --purge-cache   # also delete the cached ISO
```

Rollback refuses VMs without the kit's marker, running VMs, and any path under
`PROTECTED_PATHS`. The Parrot VM is never passed to a changing command.

## What this does NOT do — privacy limits

* **Mullvad hides your IP from websites, not from Mullvad.** Mullvad sees your
  real IP (or your ISP's) and when you connect. Every config in your ZIP uses
  one device key (Mullvad device "Good Goose"), so all servers see the same
  account device.
* **Hysteria moves trust to the server's operator.** Websites see the Hysteria
  server's IP. Whoever runs or rents that server can see where the traffic
  goes, and the hosting account may carry your identity. A server you rent in
  your own name links your traffic to you.
* **Pi-hole is DNS filtering, not anonymity.** It blocks ad/tracker domains
  and logs queries locally (you can disable logging). The upstream resolver
  (Mullvad DNS, or the resolver behind Hysteria) still sees every name looked
  up.
* **VM isolation limits damage; it does not hide identity.** Browser
  fingerprinting, logins, cookies, writing style, timing, and anything the
  host itself leaks still identify you. A compromised host sees everything in
  its VMs.
* **The host is outside this setup.** ISO downloads, and anything the host OS
  does, use your normal connection unless you run Mullvad on the host too.
* **Kill switches cover these VMs only.** They drop traffic when the tunnel
  fails. They cannot protect other programs on the host.

Nothing here makes your public IP "untraceable". It reduces what each party
can see, and it fails closed instead of leaking when a tunnel breaks.

## How this was verified

* Official sources checked for this build (2026-09-26):
  * OpenBSD 7.9 is current (released 2026-05-19, packages include Go 1.26.2).
    The OpenBSD ports tree has no Hysteria and no SearXNG port.
  * The official client config docs and the app/v2.12.3 source (latest,
    2026-09-13) were checked; Hysteria ships no OpenBSD binary, and TUN is
    unsupported on BSD.
  * Pi-hole's prerequisites page (official OS list, no BSD) and its v6
    installer and `pihole-FTL --config` keys.
  * SearXNG's step-by-step install, `utils/searxng.sh` Debian packages, and
    the outgoing-proxy settings.
  * VBoxManage man pages (createvm, modifyvm, storagectl, storageattach,
    createmedium, unregistervm), and the OS type IDs `OpenBSD_64` and
    `Debian13_64`.
  * The OpenBSD sources for `dhcpleased.conf`, `netstart`, `hostname.if`,
    pf `user` matching, and base `dig`/`host`.
* Hysteria 2.12.3 was cross-compiled for `openbsd/amd64` with the exact flags
  `install.sh` uses; the result is an ELF with OSABI OpenBSD. The client
  template ran against a real Hysteria server: the HTTP and SOCKS5 proxies and
  the UDP+TCP DNS forwarders all worked, and a wrong certificate pin was
  rejected.
* ShellCheck is clean for every script. The ksh scripts pass a mksh syntax
  check.
* `privctl` ran end to end with mocked OpenBSD commands: import, use, test,
  lock, auto-revert, persist, unlock, and `mullvad down`.
* The host script ran against a stateful fake `VBoxManage`. That covered
  dry-run, create, rerun, name/folder/MAC/intnet/port collisions, bad
  checksum, mirror mismatch, and rollback. The Parrot files were unchanged
  after every scenario.
* Not run for real: VirtualBox on your computer and an actual OpenBSD/Debian
  install. Those steps run on your machine.
