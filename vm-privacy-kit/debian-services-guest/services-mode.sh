#!/usr/bin/env bash
# services-mode.sh -- how this VM (Pi-hole + SearXNG) reaches the Internet.
#
#   sudo ./services-mode.sh status
#   sudo ./services-mode.sh mullvad  default route -> OpenBSD 10.77.0.1, which NATs it
#                                    into Mullvad (needs `privctl lock mullvad` there)
#                                    Pi-hole upstream -> Mullvad DNS (10.64.0.1)
#   sudo ./services-mode.sh tunnel   no forwarding; only the Hysteria services on OpenBSD:
#                                    Pi-hole upstream -> 10.77.0.1#5353 (DNS forwarder)
#                                    SearXNG + apt + gravity -> Hysteria proxies
#                                    (needs `privctl lock tunnel` there)
#   sudo ./services-mode.sh direct   the VM's own NAT adapter + public upstreams
#                                    (needs `vbox-privacy-setup.sh connect-services` on the host)
#
# In mullvad and tunnel mode the NAT cable must stay unplugged on the host
# (`vbox-privacy-setup.sh isolate-services`, the default for a new VM). Then the
# only path out is through the OpenBSD VM, whose pf lock fails closed.
set -Eeuo pipefail
cd "$(dirname "$0")"
# shellcheck source=common.sh
source ./common.sh

SETTINGS=/etc/searxng/settings.yml
APT_PROXY=/etc/apt/apt.conf.d/90privacykit-proxy
DHCLIENT_HOOK=/etc/dhcp/dhclient-enter-hooks.d/privacykit-keep-resolv
ROUTE_HELPER=/usr/local/sbin/privacykit-route
ROUTE_UNIT=/etc/systemd/system/privacykit-route.service
ENV_BEGIN="# >>> privacykit proxy"
ENV_END="# <<< privacykit proxy"
BLK_BEGIN="# >>> privacykit outgoing"
BLK_END="# <<< privacykit outgoing"

replace_block() {  # replace_block FILE BEGIN END NEWCONTENT_FILE  (appends the block if missing)
  local f=$1 b=$2 e=$3 new=$4 tmp
  tmp="$(mktemp)"
  if grep -qxF "$b" "$f" 2>/dev/null; then
    awk -v b="$b" -v e="$e" -v nf="$new" '
      $0==b { print; while ((getline l < nf) > 0) print l; skip=1; next }
      $0==e { skip=0 } !skip' "$f" >"$tmp"
  else
    { cat "$f" 2>/dev/null || true; echo "$b"; cat "$new"; echo "$e"; } >"$tmp"
  fi
  cat "$tmp" >"$f"; rm -f "$tmp"
}

remove_block() {  # remove_block FILE BEGIN END
  local f=$1 tmp
  grep -qxF "$2" "$f" 2>/dev/null || return 0
  tmp="$(mktemp)"
  awk -v b="$2" -v e="$3" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$f" >"$tmp"
  cat "$tmp" >"$f"; rm -f "$tmp"
}

searxng_outgoing() {  # direct|mullvad|tunnel
  [[ -f $SETTINGS ]] || return 0
  local blk; blk="$(mktemp)"
  if [[ $1 == tunnel ]]; then
    printf 'outgoing:\n  request_timeout: 6.0\n  extra_proxy_timeout: 4.0\n  proxies:\n    all://:\n      - socks5h://%s:1080\n' "$OPENBSD_ADDR" >"$blk"
  else
    printf 'outgoing:\n  request_timeout: 5.0\n' >"$blk"
  fi
  replace_block "$SETTINGS" "$BLK_BEGIN" "$BLK_END" "$blk"; rm -f "$blk"
  systemctl try-restart searxng.service || true
  ok "SearXNG outgoing: $([[ $1 == tunnel ]] && echo "socks5h://$OPENBSD_ADDR:1080 (Hysteria)" || echo "default route ($1)")"
}

pihole_upstream() {  # direct|mullvad|tunnel
  command -v pihole-FTL >/dev/null 2>&1 || return 0
  local ups=""
  case $1 in
    tunnel)  ups="\"$OPENBSD_ADDR#5353\"" ;;
    mullvad) ups="\"$MULLVAD_DNS\"" ;;
    *)       for u in $PIHOLE_DIRECT_UPSTREAMS; do ups+="${ups:+, }\"$u\""; done ;;
  esac
  pihole-FTL --config dns.upstreams "[ $ups ]" >/dev/null
  systemctl restart pihole-FTL
  ok "Pi-hole upstream: [ $ups ]"
}

gateway() {  # on|off -- default route via the OpenBSD VM, re-applied at boot
  local ifn; ifn="$(lan_if)"
  if [[ $1 == on ]]; then
    cat >"$ROUTE_HELPER" <<EOF
#!/bin/sh
# privacykit: default route via the OpenBSD VM (mullvad/tunnel mode)
exec ip -4 route replace default via $OPENBSD_ADDR dev $ifn
EOF
    chmod 0755 "$ROUTE_HELPER"
    cat >"$ROUTE_UNIT" <<EOF
[Unit]
Description=privacykit default route via the OpenBSD VM
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$ROUTE_HELPER
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now privacykit-route.service >/dev/null
    "$ROUTE_HELPER"
    ok "default route via $OPENBSD_ADDR ($ifn), persistent"
  else
    systemctl disable --now privacykit-route.service >/dev/null 2>&1 || true
    rm -f "$ROUTE_UNIT" "$ROUTE_HELPER"; systemctl daemon-reload
    ip -4 route del default via "$OPENBSD_ADDR" 2>/dev/null || true
    ok "default route via $OPENBSD_ADDR removed (the NAT adapter's DHCP route takes over)"
  fi
}

resolver_pihole() {  # on|off -- this VM's own resolver = Pi-hole (127.0.0.1)
  if [[ $1 == on ]]; then
    mkdir -p "$(dirname "$DHCLIENT_HOOK")"
    printf '# privacykit: keep /etc/resolv.conf pointing at Pi-hole\nmake_resolv_conf() { :; }\n' >"$DHCLIENT_HOOK"
    [[ -f $STATE_DIR/resolv.conf.direct ]] || cp -p /etc/resolv.conf "$STATE_DIR/resolv.conf.direct"
    printf '# privacykit (%s mode)\nnameserver 127.0.0.1\n' "$2" >/etc/resolv.conf
  else
    rm -f "$DHCLIENT_HOOK"
    if [[ -f $STATE_DIR/resolv.conf.direct ]]; then
      cp -p "$STATE_DIR/resolv.conf.direct" /etc/resolv.conf; rm -f "$STATE_DIR/resolv.conf.direct"
    fi
  fi
}

system_proxy() {  # on|off -- apt, cron jobs (Pi-hole gravity) and shells use Hysteria's HTTP proxy
  local tmp
  if [[ $1 == on ]]; then
    printf 'Acquire::http::Proxy "http://%s:8080";\nAcquire::https::Proxy "http://%s:8080";\n' \
      "$OPENBSD_ADDR" "$OPENBSD_ADDR" >"$APT_PROXY"
    tmp="$(mktemp)"
    printf 'http_proxy=http://%s:8080\nhttps_proxy=http://%s:8080\nno_proxy=localhost,127.0.0.1,%s,%s\n' \
      "$OPENBSD_ADDR" "$OPENBSD_ADDR" "$OPENBSD_ADDR" "$LAN_ADDR" >"$tmp"
    replace_block /etc/environment "$ENV_BEGIN" "$ENV_END" "$tmp"; rm -f "$tmp"
    ok "apt / cron / login shells use http://$OPENBSD_ADDR:8080"
  else
    rm -f "$APT_PROXY"
    remove_block /etc/environment "$ENV_BEGIN" "$ENV_END"
  fi
}

cmd_status() {
  say "mode            : $(current_mode)"
  say "default route   : $(ip -4 route show default | head -n 1 || true)"
  command -v pihole-FTL >/dev/null 2>&1 && say "Pi-hole upstream: $(pihole-FTL --config dns.upstreams 2>/dev/null | tr '\n' ' ')"
  [[ -f $SETTINGS ]] && say "SearXNG proxy   : $(grep -A1 'all://:' "$SETTINGS" | tail -n 1 | tr -d ' -' || true)"
  say "apt proxy       : $([[ -f $APT_PROXY ]] && echo on || echo off)"
  say "resolv.conf     : $(awk '/^nameserver/{printf "%s ",$2}' /etc/resolv.conf)"
}

require_root
mkdir -p "$STATE_DIR"
only_searxng=0; [[ ${2:-} == --searxng-only ]] && only_searxng=1
mode=${1:-status}

case $mode in
  status) cmd_status; exit 0 ;;
  mullvad|tunnel|direct) ;;
  *) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac

if [[ $only_searxng -eq 0 ]]; then
  lan_has_addr || die "LAN not configured (./setup-lan.sh)"
  case $mode in
    mullvad)
      gateway on
      ping -c 1 -W 3 "$MULLVAD_DNS" >/dev/null 2>&1 || dig @"$MULLVAD_DNS" +time=3 +tries=1 +short pi-hole.net >/dev/null 2>&1 \
        || warn "Mullvad DNS $MULLVAD_DNS not reachable through $OPENBSD_ADDR -- on OpenBSD: doas privctl lock mullvad"
      pihole_upstream mullvad; system_proxy off; resolver_pihole on mullvad ;;
    tunnel)
      if command -v dig >/dev/null 2>&1; then
        dig @"$OPENBSD_ADDR" -p 5353 +time=4 +tries=1 +short pi-hole.net A | grep -q . \
          || die "Hysteria DNS forwarder $OPENBSD_ADDR:5353 does not answer -- on OpenBSD: doas privctl hy2 start && doas privctl hy2 test"
        ok "Hysteria DNS forwarder answers"
      fi
      gateway on; pihole_upstream tunnel; system_proxy on; resolver_pihole on tunnel ;;
    direct)
      gateway off; pihole_upstream direct; system_proxy off; resolver_pihole off ;;
  esac
  echo "$mode" >"$STATE_DIR/mode"
fi
searxng_outgoing "$mode"

if [[ $only_searxng -eq 0 ]]; then
  case $mode in
    direct) say "
Direct mode needs the NAT cable (Linux host): ./vbox-privacy-setup.sh connect-services" ;;
    *) say "
Keep the NAT cable unplugged (Linux host): ./vbox-privacy-setup.sh isolate-services" ;;
  esac
fi
exit 0
