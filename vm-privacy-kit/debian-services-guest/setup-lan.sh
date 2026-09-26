#!/usr/bin/env bash
# setup-lan.sh -- give the internal-network NIC (MAC 08:00:27:77:00:02) the
# static address 10.77.0.2/24, persistently, with no gateway and no IPv6.
# The NAT NIC (Internet during setup) is left exactly as the installer set it.
# Safe to rerun.
set -Eeuo pipefail
cd "$(dirname "$0")"
# shellcheck source=common.sh
source ./common.sh
require_root
require_debian

ifn="$(lan_if)"
[[ -n $ifn ]] || die "no NIC with MAC $LAN_MAC -- was this VM created by vbox-privacy-setup.sh?"
ok "internal LAN NIC: $ifn"

if lan_has_addr; then
  ok "$ifn already has $LAN_ADDR"
  exit 0
fi

if [[ -f /etc/network/interfaces ]] && command -v ifup >/dev/null 2>&1; then
  grep -Eq '^[[:space:]]*source(-directory)?[[:space:]]+/etc/network/interfaces\.d' /etc/network/interfaces \
    || die "/etc/network/interfaces does not include interfaces.d; add: source /etc/network/interfaces.d/*"
  f=/etc/network/interfaces.d/privacykit-lan
  cat >"$f" <<EOF
# privacykit: internal VirtualBox network to the OpenBSD VM (no gateway here)
auto $ifn
iface $ifn inet static
    address $LAN_ADDR/$LAN_PREFIX
EOF
  printf 'net.ipv6.conf.%s.disable_ipv6 = 1\n' "$ifn" >/etc/sysctl.d/90-privacykit-lan.conf
  sysctl -q -p /etc/sysctl.d/90-privacykit-lan.conf || true
  ifup "$ifn"
elif command -v nmcli >/dev/null 2>&1; then
  nmcli con add type ethernet ifname "$ifn" con-name privacykit-lan \
    ipv4.method manual ipv4.addresses "$LAN_ADDR/$LAN_PREFIX" ipv4.never-default yes ipv6.method disabled
  nmcli con up privacykit-lan
else
  die "neither ifupdown nor NetworkManager found; configure $ifn = $LAN_ADDR/$LAN_PREFIX manually"
fi

lan_has_addr || die "$ifn did not get $LAN_ADDR"
ok "$ifn = $LAN_ADDR/$LAN_PREFIX (persistent)"
if ping -c 1 -W 2 "$OPENBSD_ADDR" >/dev/null 2>&1; then ok "OpenBSD VM $OPENBSD_ADDR answers"
else warn "OpenBSD VM $OPENBSD_ADDR does not answer yet (fine if its kit is not installed yet)"; fi
