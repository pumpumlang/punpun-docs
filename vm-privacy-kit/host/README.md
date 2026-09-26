# vbox-privacy-host

`vbox-privacy-setup.sh` creates the OpenBSD privacy VM and the Debian
Pi-hole/SearXNG companion VM in VirtualBox 7.x on a Linux host. Defaults live
in `vbox-privacy.conf`, and every value can be overridden from the environment.

```sh
./vbox-privacy-setup.sh check                 # changes nothing
./vbox-privacy-setup.sh --dry-run create-openbsd
./vbox-privacy-setup.sh create-openbsd
./vbox-privacy-setup.sh create-services
./vbox-privacy-setup.sh status
./vbox-privacy-setup.sh eject-installer openbsd|services
./vbox-privacy-setup.sh cable openbsd|services on|off
./vbox-privacy-setup.sh isolate-services | connect-services
./vbox-privacy-setup.sh pack-mullvad ~/Downloads/mullvad_wireguard_linux_all_all.zip
./vbox-privacy-setup.sh rollback-openbsd [--yes] [--purge-cache]
./vbox-privacy-setup.sh rollback-services [--yes] [--purge-cache]
```

Requirements: VirtualBox ≥ 7.0 (`VBoxManage`), `curl`, coreutils, and `unzip`
for `pack-mullvad`. `gpg`, `signify-openbsd`, and `signify-openbsd-keys` are
optional, for extra signature checks.

The script is safe to rerun. The VMs it creates carry extradata
`privacykit/managed=1`, and it never changes or deletes anything without that
marker. Before any change it checks for name, folder, disk, MAC,
internal-network, and host-port collisions. Paths under `PROTECTED_PATHS` (your
Parrot VM folder) are never used. See `../README.md` for the full walkthrough
and the privacy limits.
