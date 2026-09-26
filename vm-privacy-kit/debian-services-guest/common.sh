# common.sh -- shared settings/helpers for the Debian services VM kit (sourced).
# shellcheck shell=bash

LAN_MAC="${LAN_MAC:-08:00:27:77:00:02}"   # set by vbox-privacy-setup.sh on adapter 2
LAN_ADDR="${LAN_ADDR:-10.77.0.2}"
LAN_PREFIX="${LAN_PREFIX:-24}"
OPENBSD_ADDR="${OPENBSD_ADDR:-10.77.0.1}"  # Hysteria listeners live here
SEARXNG_PORT="${SEARXNG_PORT:-8888}"
# Pi-hole upstreams in DIRECT mode (before the tunnel exists). Quad9's public
# resolvers; replace with any you prefer. In TUNNEL mode the upstream is always
# the Hysteria DNS forwarder ${OPENBSD_ADDR}#5353.
PIHOLE_DIRECT_UPSTREAMS="${PIHOLE_DIRECT_UPSTREAMS:-9.9.9.9 149.112.112.112}"
# Mullvad's in-tunnel resolver, taken from the DNS= line of your Mullvad
# WireGuard configs. Reached through the OpenBSD VM (gateway 10.77.0.1 -> wg0).
MULLVAD_DNS="${MULLVAD_DNS:-10.64.0.1}"

# shellcheck disable=SC2034  # used by the scripts that source this file
STATE_DIR=/var/lib/privacykit

say()  { printf '%s\n' "$*"; }
info() { printf '==> %s\n' "$*"; }
ok()   { printf ' ok  %s\n' "$*"; }
warn() { printf 'warn %s\n' "$*" >&2; }
die()  { printf 'FAIL %s\n' "$*" >&2; exit 1; }

require_root() { [[ $(id -u) -eq 0 ]] || die "run with sudo"; }

require_debian() {
  [[ -r /etc/os-release ]] || die "not a Debian system"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == debian ]] || die "this kit targets Debian (found ${ID:-unknown})"
  case ${VERSION_ID:-} in 12|13) ;; *) warn "written for Debian 12/13; this is ${VERSION_ID:-unknown}" ;; esac
}

lan_if() {
  ip -o link | awk -v mac="${LAN_MAC,,}" '{ for (i=1;i<=NF;i++) if ($i=="link/ether" && tolower($(i+1))==mac) { sub(/:$/,"",$2); sub(/@.*/,"",$2); print $2; exit } }'
}

lan_has_addr() {
  local ifn; ifn="$(lan_if)"
  [[ -n $ifn ]] && ip -o -4 addr show dev "$ifn" | grep -q " $LAN_ADDR/"
}

# direct | mullvad | tunnel. Without a saved choice: mullvad if the default
# route already points at the OpenBSD VM (installed that way), else direct.
current_mode() {
  if [[ -s $STATE_DIR/mode ]]; then cat "$STATE_DIR/mode"
  elif ip -4 route show default | grep -q "via $OPENBSD_ADDR "; then echo mullvad
  else echo direct; fi
}
