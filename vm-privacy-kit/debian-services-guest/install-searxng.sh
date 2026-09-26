#!/usr/bin/env bash
# install-searxng.sh -- install SearXNG on this Debian VM following the official
# "step by step" installation (docs.searxng.org/admin/installation-searxng.html):
# Debian packages, a 'searxng' system user, a Python virtualenv in
# /usr/local/searxng, /etc/searxng/settings.yml, served by uWSGI.
#
# Kept minimal on purpose: no nginx/apache and no Valkey (the bot limiter is
# for public instances; this one is private). uWSGI serves HTTP directly on
# 10.77.0.2:8888, reachable only from the internal LAN (OpenBSD) and via SSH
# port-forwarding. SearXNG is not packaged for OpenBSD and its install scripts
# cover Debian/Ubuntu, Arch and Fedora -- hence this companion VM.
# Safe to rerun (updates the checkout and dependencies; keeps settings.yml).
set -Eeuo pipefail
cd "$(dirname "$0")"
# shellcheck source=common.sh
source ./common.sh
require_root
require_debian
lan_has_addr || die "run ./setup-lan.sh first ($LAN_ADDR missing)"

S_USER=searxng
S_HOME=/usr/local/searxng
S_SRC=$S_HOME/searxng-src
S_ENV=$S_HOME/searx-pyenv
S_SETTINGS=/etc/searxng/settings.yml

info "Packages (list from SearXNG's utils/searxng.sh for Debian)"
apt-get update
apt-get install -y python3-dev python3-babel python3-venv python-is-python3 \
  uwsgi uwsgi-plugin-python3 git build-essential libxslt-dev zlib1g-dev libffi-dev libssl-dev

info "Service user"
if ! id "$S_USER" >/dev/null 2>&1; then
  useradd --shell /bin/bash --system --home-dir "$S_HOME" \
    --comment 'Privacy-respecting metasearch engine' "$S_USER"
fi
mkdir -p "$S_HOME"; chown -R "$S_USER:$S_USER" "$S_HOME"
ok "user $S_USER, home $S_HOME"

info "SearXNG source"
as_s() { runuser -u "$S_USER" -- "$@"; }
if [[ -d $S_SRC/.git ]]; then
  as_s git -C "$S_SRC" pull --ff-only
else
  as_s git clone --depth 1 https://github.com/searxng/searxng.git "$S_SRC"
fi
ok "$(as_s git -C "$S_SRC" log -1 --format='commit %h (%cs)')"

info "Python virtualenv + dependencies"
[[ -x $S_ENV/bin/python ]] || as_s python3 -m venv "$S_ENV"
as_s "$S_ENV/bin/pip" install -q -U pip setuptools wheel pyyaml msgspec typing-extensions pybind11
( cd "$S_SRC" && as_s "$S_ENV/bin/pip" install -q --use-pep517 --no-build-isolation -e . )
ok "installed into $S_ENV"

info "Configuration"
install -d -m 0755 /etc/searxng
if [[ ! -f $S_SETTINGS ]]; then
  secret="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  cat >"$S_SETTINGS" <<EOF
# /etc/searxng/settings.yml -- private instance on the privacy LAN.
# Only overrides are listed; everything else comes from SearXNG's defaults.
use_default_settings: true

general:
  debug: false
  instance_name: "SearXNG (private)"

search:
  safe_search: 0
  autocomplete: ""
  formats:
    - html

server:
  secret_key: "$secret"
  bind_address: "$LAN_ADDR"
  port: $SEARXNG_PORT
  limiter: false          # private instance, no Valkey needed
  image_proxy: true       # your browser fetches result images via SearXNG
  method: "POST"

valkey:
  url: false

# The block below is managed by services-mode.sh -- do not edit inside it.
# >>> privacykit outgoing
outgoing:
  request_timeout: 4.0
# <<< privacykit outgoing
EOF
  chmod 0640 "$S_SETTINGS"; chown root:"$S_USER" "$S_SETTINGS"
  ok "created $S_SETTINGS (random secret_key)"
else
  ok "kept existing $S_SETTINGS"
fi

cat >/etc/searxng/uwsgi.ini <<EOF
# uWSGI for SearXNG (from SearXNG's utils/templates/etc/uwsgi/apps-available/searxng.ini,
# reduced to what a private single-user instance needs; HTTP served directly).
[uwsgi]
env = LANG=C.UTF-8
env = LANGUAGE=C.UTF-8
env = LC_ALL=C.UTF-8
env = SEARXNG_SETTINGS_PATH=$S_SETTINGS
chdir = $S_SRC/searx
disable-logging = true
single-interpreter = true
master = true
lazy-apps = true
plugin = python3
enable-threads = true
workers = 2
threads = 4
module = searx.webapp
virtualenv = $S_ENV
pythonpath = $S_SRC
http-socket = $LAN_ADDR:$SEARXNG_PORT
buffer-size = 8192
offload-threads = 2
die-on-term = true
EOF

cat >/etc/systemd/system/searxng.service <<EOF
[Unit]
Description=SearXNG (private metasearch, uWSGI)
After=network-online.target
Wants=network-online.target

[Service]
User=$S_USER
Group=$S_USER
ExecStart=/usr/bin/uwsgi --ini /etc/searxng/uwsgi.ini
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable searxng.service >/dev/null
systemctl restart searxng.service

# Re-apply the current mode (direct/tunnel) to the managed outgoing block.
./services-mode.sh "$(current_mode)" --searxng-only

sleep 3
if curl -fsS -o /dev/null "http://$LAN_ADDR:$SEARXNG_PORT/healthz" 2>/dev/null \
   || curl -fsS -o /dev/null "http://$LAN_ADDR:$SEARXNG_PORT/"; then
  ok "SearXNG answers on http://$LAN_ADDR:$SEARXNG_PORT/"
else
  warn "SearXNG did not answer yet: journalctl -u searxng -n 50"
fi
cat <<EOF

From OpenBSD:        http://$LAN_ADDR:$SEARXNG_PORT/
From the Linux host: ssh -p 2221 -L 8888:$LAN_ADDR:$SEARXNG_PORT <openbsd-user>@127.0.0.1
                     then open http://127.0.0.1:8888/
Update later:        sudo ./install-searxng.sh   (pulls the latest SearXNG)
EOF
