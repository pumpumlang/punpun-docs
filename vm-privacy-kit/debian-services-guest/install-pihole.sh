#!/usr/bin/env bash
# install-pihole.sh -- install genuine Pi-hole (v6) on this Debian VM with the
# official installer, then pin its DNS settings for the privacy LAN.
#
# Pi-hole does not support OpenBSD (official list: Alpine, Armbian, Debian,
# CentOS Stream, Fedora, Raspberry Pi OS, Ubuntu), which is why it lives here.
#
# The official installer is interactive. When it asks:
#   * interface  -> the one this script prints (internal LAN, 10.77.0.2)
#   * upstream   -> anything; this script sets it afterwards
#   * blocklist  -> Yes (StevenBlack)      * query logging / privacy: your choice
# Safe to rerun: an existing Pi-hole is not reinstalled, only reconfigured.
set -Eeuo pipefail
cd "$(dirname "$0")"
# shellcheck source=common.sh
source ./common.sh
require_root
require_debian

lan_has_addr || die "run ./setup-lan.sh first ($LAN_ADDR missing)"
ifn="$(lan_if)"

if command -v pihole >/dev/null 2>&1 && command -v pihole-FTL >/dev/null 2>&1; then
  ok "Pi-hole already installed: $(pihole version 2>/dev/null | tr '\n' ' ')"
else
  info "Installing Pi-hole with the official installer (github.com/pi-hole/pi-hole)"
  say  "    When asked for the interface, choose: $ifn"
  apt-get update
  apt-get install -y git curl ca-certificates bind9-dnsutils
  src=/root/pi-hole-installer
  rm -rf "$src"
  git clone --depth 1 https://github.com/pi-hole/pi-hole.git "$src"
  bash "$src/automated install/basic-install.sh"
fi

command -v pihole-FTL >/dev/null 2>&1 || die "pihole-FTL not found after installation"

info "Pinning Pi-hole settings for the privacy LAN"
set_ftl() { pihole-FTL --config "$1" "$2" >/dev/null && ok "$1 = $2"; }
set_ftl dns.interface "$ifn"
set_ftl dns.listeningMode "LOCAL"      # answers only local subnets: 10.77.0.0/24, loopback
mode="$(current_mode)"
say "    applying mode: $mode"
./services-mode.sh "$mode"

sleep 2
if command -v dig >/dev/null 2>&1; then
  dig @"$LAN_ADDR" +time=3 +tries=1 +short pi-hole.net >/dev/null && ok "Pi-hole answers on $LAN_ADDR:53"
else
  getent hosts pi-hole.net >/dev/null && ok "name resolution works"
fi

cat <<EOF

Pi-hole is installed (mode: $mode).
  Web UI (from the host, through the OpenBSD VM):
      ssh -p 2221 -L 8081:$LAN_ADDR:80 <openbsd-user>@127.0.0.1
      then open http://127.0.0.1:8081/admin
  Set your own admin password:  sudo pihole setpassword
  OpenBSD uses this Pi-hole ($LAN_ADDR) automatically in tunnel mode.
EOF
