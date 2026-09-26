#!/usr/bin/env bash
# vbox-privacy-setup.sh -- create the OpenBSD privacy VM (and, optionally, a
# Debian companion VM for Pi-hole + SearXNG) in Oracle VirtualBox on a Linux host.
#
# Safe to rerun: every command checks the current state first, never touches a
# VM or disk it did not create (VMs it creates carry the extradata marker
# "privacykit/managed"), and refuses to run on name, disk, MAC, port or
# internal-network collisions.  Nothing here reads, attaches or modifies the
# paths listed in PROTECTED_PATHS (your Parrot VM).
#
# Usage: ./vbox-privacy-setup.sh [--dry-run] [--yes] [--purge-cache] <command>
#   check               prerequisites + collision checks, changes nothing
#   create-openbsd      download/verify OpenBSD ISO, create + register the VM
#   create-services     download/verify Debian netinst, create the Pi-hole/SearXNG VM
#   status              show both VMs as this kit sees them
#   eject-installer <openbsd|services>   remove the installer ISO after the OS is installed
#   isolate-services    unplug the services VM's NAT cable (only the internal LAN remains)
#   connect-services    plug the services VM's NAT cable back in (direct mode)
#   cable <openbsd|services> <on|off>   plug/unplug a kit VM's NAT cable
#   pack-mullvad ZIP    repack Mullvad's WireGuard ZIP as a 0600 .tgz for OpenBSD (no unzip there)
#   rollback-openbsd    delete ONLY the OpenBSD VM + disk created by this script
#   rollback-services   delete ONLY the services VM + disk created by this script
#
# Options:
#   --dry-run      print every VBoxManage/download step without executing it
#   --yes          do not ask for confirmation before rollback
#   --purge-cache  with rollback-*: also delete the cached, verified ISO
set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${VBOX_PRIVACY_CONF:-$SCRIPT_DIR/vbox-privacy.conf}"
MARKER_KEY="privacykit/managed"
COMPLETE_KEY="privacykit/complete"
DRY_RUN=0
ASSUME_YES=0
PURGE_CACHE=0
CURRENT_VM=""          # set while creating, for the failure hint

# ------------------------------------------------------------------ output
if [[ -t 1 ]]; then B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'; else B='' R='' G='' Y='' N=''; fi
say()  { printf '%s\n' "$*"; }
info() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s ok%s  %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%sFAIL%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# Run a state-changing command (or just print it in --dry-run mode).
run() {
  local shown=("$@"); [[ ${shown[0]} == vbm ]] && shown[0]=VBoxManage
  printf '   + %s\n' "$(printf '%q ' "${shown[@]}")"
  [[ $DRY_RUN -eq 1 ]] && return 0
  "$@"
}

on_error() {
  local rc=$? line=$1
  warn "stopped at line $line (exit $rc)."
  if [[ -n $CURRENT_VM ]]; then
    warn "The VM may be half-created. Rerun the same command to resume, or remove it with:"
    warn "    $0 rollback-$CURRENT_VM"
  fi
  exit "$rc"
}
trap 'on_error $LINENO' ERR

usage() { sed -n '2,/^set -Eeuo/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

# ------------------------------------------------------------------ config
[[ -r $CONF_FILE ]] || die "config file not found: $CONF_FILE"
# shellcheck source=vbox-privacy.conf
source "$CONF_FILE"
OPENBSD_SHORT="${OPENBSD_VERSION//./}"                 # 7.9 -> 79
OPENBSD_ISO_NAME="install${OPENBSD_SHORT}.iso"
OPENBSD_URL_DIR="$OPENBSD_MIRROR/$OPENBSD_VERSION/$OPENBSD_ARCH"
OPENBSD_URL_DIR2="$OPENBSD_MIRROR2/$OPENBSD_VERSION/$OPENBSD_ARCH"

# ------------------------------------------------------------------ helpers
# stdin from /dev/null: VBoxManage must never eat the input of a surrounding read loop.
vbm() { VBoxManage "$@" </dev/null; }

abspath() { realpath -m -- "$1"; }

# Refuse any path inside PROTECTED_PATHS.
assert_not_protected() {
  local p prot
  p="$(abspath "$1")"
  for prot in "${PROTECTED_PATHS[@]}"; do
    prot="$(abspath "$prot")"
    if [[ $p == "$prot" || $p == "$prot"/* ]]; then
      die "refusing to use protected path: $p (inside $prot)"
    fi
  done
}

vm_exists() { vbm showvminfo "$1" --machinereadable >/dev/null 2>&1; }

# Cached machine-readable info for one VM.
# Call mr_load in the current shell first; $(mr ...) subshells then reuse the cache.
declare -A MR_CACHE=()
mr_load() {
  [[ -n ${MR_CACHE[$1]+x} ]] && return 0
  MR_CACHE[$1]="$(vbm showvminfo "$1" --machinereadable 2>/dev/null || true)"
}
mr() {  # mr VM KEY
  local vm=$1 key=$2
  mr_load "$vm"
  printf '%s\n' "${MR_CACHE[$vm]}" | awk -v k="$key" '
    { line=$0; eq=index(line,"="); if (!eq) next
      lhs=substr(line,1,eq-1); rhs=substr(line,eq+1)
      gsub(/^"|"$/,"",lhs); if (lhs!=k) next
      gsub(/^"|"$/,"",rhs); if (!done) print rhs; done=1 }'
}
mr_flush() { MR_CACHE=(); }

is_managed() {
  [[ "$(vbm getextradata "$1" "$MARKER_KEY" 2>/dev/null || true)" == "Value: 1" ]]
}
is_complete() {
  [[ "$(vbm getextradata "$1" "$COMPLETE_KEY" 2>/dev/null || true)" == "Value: 1" ]]
}

vm_state() { mr "$1" VMState; }

# All registered VMs as "uuid<TAB>name".
list_vms() {
  vbm list vms | sed -nE 's/^"(.*)" \{([0-9a-fA-F-]+)\}$/\2\t\1/p'
}

# Registered media locations of a kind (hdds|dvds).
list_media() {
  vbm list "$1" | sed -nE 's/^Location:[[:space:]]+//p'
}

confirm() {
  [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]] && return 0
  local ans
  read -r -p "$1 [type yes]: " ans
  [[ $ans == yes ]]
}

mac_fmt() { local m=${1^^}; printf '%s:%s:%s:%s:%s:%s' "${m:0:2}" "${m:2:2}" "${m:4:2}" "${m:6:2}" "${m:8:2}" "${m:10:2}"; }

# ------------------------------------------------------------------ prerequisites
check_prereqs() {
  info "Checking host prerequisites"
  [[ $(uname -s) == Linux ]] || die "this script is for a Linux host"
  local c missing=()
  for c in VBoxManage curl sha256sum sha512sum awk sed grep realpath df; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  ((${#missing[@]} == 0)) || die "missing commands: ${missing[*]}"
  ok "required commands present"

  local ver major
  ver="$(vbm --version 2>/dev/null | tr -d '\r')" || die "VBoxManage --version failed"
  major="${ver%%.*}"
  if ! [[ $major =~ ^[0-9]+$ ]] || ((major < 7)); then
    die "VirtualBox $ver found; this script needs VirtualBox 7.0 or newer"
  fi
  ok "VirtualBox $ver"

  vbm list vms >/dev/null 2>&1 || die "VBoxManage cannot talk to VirtualBox (is the vboxdrv service running?)"
  if [[ -e /dev/vboxdrv ]]; then ok "/dev/vboxdrv present"; else
    warn "/dev/vboxdrv missing -- VMs will not start until the kernel module is loaded (sudo /sbin/vboxconfig)"; fi

  if grep -Eqw 'vmx|svm' /proc/cpuinfo; then ok "CPU virtualization extensions visible"
  else warn "no vmx/svm flag in /proc/cpuinfo -- enable VT-x/AMD-V in firmware for 64-bit guests"; fi

  has_ostype OpenBSD_64 || die "this VirtualBox does not know the OS type OpenBSD_64 (see: VBoxManage list ostypes)"
  ok "OS type OpenBSD_64 available"

  local p
  for p in "${PROTECTED_PATHS[@]}"; do
    if [[ -e $p ]]; then ok "protected (will not be touched): $p"; fi
  done
}

check_space() {  # check_space DIR NEED_MB   (read-only: measures the nearest existing parent)
  local dir=$1 need=$2 avail
  while [[ ! -d $dir && $dir != / ]]; do dir="$(dirname -- "$dir")"; done
  avail=$(( $(df -Pk -- "$dir" | awk 'NR==2{print $4}') / 1024 ))
  if ((avail < need)); then die "only ${avail} MB free in $dir, need about ${need} MB"; fi
  ok "${avail} MB free in $dir"
}

# VirtualBox 7.0 prints "ID:   OpenBSD_64"; 7.1+ prints
# "ID / Description: OpenBSD_64 -- OpenBSD (64-bit)". Accept both.
has_ostype() {
  # Capture first: with pipefail, `... | grep -q` can fail on SIGPIPE even when it matches.
  local types; types="$(vbm list ostypes)" || return 1
  grep -Eq "^ID( / Description)?:[[:space:]]+$1([[:space:]]|\$)" <<<"$types"
}

debian_ostype() {
  local t
  for t in Debian13_64 Debian12_64 Debian_64; do
    if has_ostype "$t"; then printf '%s' "$t"; return; fi
  done
  die "no 64-bit Debian OS type known to this VirtualBox"
}

# ------------------------------------------------------------------ collision checks
# check_collisions ROLE VMNAME DISKPATH LANMAC SSHPORT
# Exits non-zero on any conflict. Returns quietly if VMNAME is already ours.
check_collisions() {
  local role=$1 name=$2 disk=$3 mac=$4 port=$5
  local vmdir="$VM_BASEFOLDER/$name" our_uuid="" uuid vname

  info "Collision checks for '$name'"
  assert_not_protected "$vmdir"
  assert_not_protected "$disk"
  assert_not_protected "$CACHE_DIR"

  if vm_exists "$name"; then
    is_managed "$name" || die "a VM named '$name' already exists and was NOT created by this kit. Choose another name (set ${role^^}_VM_NAME) -- it will not be touched."
    our_uuid="$(mr "$name" UUID)"
    ok "VM '$name' exists and is managed by this kit (uuid $our_uuid) -- will resume/verify"
  else
    [[ -e $vmdir ]] && die "folder already exists but no VM '$name' is registered: $vmdir -- move it away or pick another name"
    [[ -e $disk ]] && die "disk file already exists: $disk"
    ok "name '$name' and folder are free"
  fi

  # Disk registered in the media registry by someone else?
  local loc
  while IFS= read -r loc; do
    if [[ $(abspath "$loc") == "$(abspath "$disk")" && -z $our_uuid ]]; then
      die "disk $disk is already registered in VirtualBox's media registry"
    fi
  done < <(list_media hdds)
  ok "disk path not used by another VM"

  # Other VMs: MAC, internal network, host port.
  local want_mac=${mac^^} i v
  while IFS=$'\t' read -r uuid vname; do
    [[ -n $our_uuid && $uuid == "$our_uuid" ]] && continue
    mr_load "$uuid"
    for i in 1 2 3 4 5 6 7 8; do
      v="$(mr "$uuid" "macaddress$i")"
      [[ -n $v && ${v^^} == "$want_mac" ]] && die "MAC $(mac_fmt "$mac") already used by VM '$vname' (adapter $i)"
      v="$(mr "$uuid" "intnet$i")"
      if [[ -n $v && $v == "$LAN_INTNET" ]] && ! is_managed "$uuid"; then
        die "internal network '$LAN_INTNET' is already used by VM '$vname' -- set LAN_INTNET to another name"
      fi
    done
    if grep -Eq "^\"?Forwarding\([0-9]+\)\"?=\"[^,]*,tcp,[^,]*,$port," <<<"$(mr_all "$uuid")"; then
      die "host port $port is already forwarded by VM '$vname' -- set ${role^^}_SSH_HOST_PORT"
    fi
  done < <(list_vms)
  ok "MAC $(mac_fmt "$mac"), internal network '$LAN_INTNET' and host port $port are free"

  if [[ -z $our_uuid ]] && command -v ss >/dev/null 2>&1 && [[ -n "$(ss -Hltn "sport = :$port" 2>/dev/null)" ]]; then
    die "something on the host already listens on TCP port $port -- set ${role^^}_SSH_HOST_PORT"
  fi
}
mr_all() { mr_load "$1"; printf '%s\n' "${MR_CACHE[$1]}"; }

# ------------------------------------------------------------------ downloads
fetch() {  # fetch URL DEST  (TLS verified by curl, https only)
  run curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --output "$2" "$1"
}

# fetch_verified URL DEST SUMTOOL WANT -- resumes a partial download, verifies, then moves into place
fetch_verified() {
  local url=$1 dest=$2 tool=$3 want=$4 got=""
  [[ -f $dest.part ]] && got="$("$tool" -- "$dest.part" | awk '{print $1}')"
  if [[ $got != "$want" ]]; then
    run curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --continue-at - \
      --output "$dest.part" "$url" || { rm -f -- "$dest.part"; fetch "$url" "$dest.part"; }
    got="$("$tool" -- "$dest.part" | awk '{print $1}')"
  fi
  if [[ $got != "$want" ]]; then
    rm -f -- "$dest.part"
    die "checksum mismatch for $(basename -- "$dest") (got $got) -- partial file deleted, rerun to retry"
  fi
  mv -f -- "$dest.part" "$dest"
  ok "downloaded and verified: $dest"
}

fetch_openbsd_iso() {
  local dir="$CACHE_DIR/openbsd-$OPENBSD_VERSION" iso sums1 sums2 line1 line2 want
  iso="$dir/$OPENBSD_ISO_NAME"
  info "OpenBSD $OPENBSD_VERSION installer ($OPENBSD_ISO_NAME)"
  run mkdir -p -- "$dir"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "   (dry-run) would fetch $OPENBSD_URL_DIR/SHA256 and $OPENBSD_URL_DIR2/SHA256, compare them,"
    say "   (dry-run) download $OPENBSD_URL_DIR/$OPENBSD_ISO_NAME and verify its SHA-256"
    ISO_PATH="$iso"; return
  fi
  sums1="$dir/SHA256"; sums2="$dir/SHA256.mirror2"
  rm -f -- "$sums1" "$sums2"
  fetch "$OPENBSD_URL_DIR/SHA256" "$sums1"
  fetch "$OPENBSD_URL_DIR2/SHA256" "$sums2"
  line1="$(grep -F "($OPENBSD_ISO_NAME) =" "$sums1" || true)"
  line2="$(grep -F "($OPENBSD_ISO_NAME) =" "$sums2" || true)"
  [[ -n $line1 ]] || die "$OPENBSD_ISO_NAME not listed in $OPENBSD_URL_DIR/SHA256 (wrong OPENBSD_VERSION?)"
  [[ $line1 == "$line2" ]] || die "SHA256 for $OPENBSD_ISO_NAME differs between $OPENBSD_MIRROR and $OPENBSD_MIRROR2 -- not using it"
  want="${line1##* = }"
  ok "official SHA256 (identical on both hosts): $want"

  if [[ -f $iso ]] && [[ "$(sha256sum -- "$iso" | awk '{print $1}')" == "$want" ]]; then
    ok "cached ISO already verified: $iso"
  else
    fetch_verified "$OPENBSD_URL_DIR/$OPENBSD_ISO_NAME" "$iso" sha256sum "$want"
  fi

  # Optional: signify signature over the SHA256 list.
  local sig="$dir/SHA256.sig" key="$OPENBSD_SIGNIFY_PUBKEY" sbin=""
  command -v signify-openbsd >/dev/null 2>&1 && sbin=signify-openbsd
  command -v signify >/dev/null 2>&1 && sbin=signify
  if [[ -z $key ]]; then
    for key in "/usr/share/signify-openbsd-keys/openbsd-${OPENBSD_SHORT}-base.pub" \
               "/etc/signify/openbsd-${OPENBSD_SHORT}-base.pub" ""; do
      [[ -z $key || -r $key ]] && break
    done
  fi
  if [[ -n $sbin && -n $key && -r $key ]]; then
    fetch "$OPENBSD_URL_DIR/SHA256.sig" "$sig"
    (cd -- "$dir" && "$sbin" -C -p "$key" -x SHA256.sig "$OPENBSD_ISO_NAME") \
      || die "signify verification FAILED for $OPENBSD_ISO_NAME"
    ok "signify signature verified with $key"
  else
    warn "signify check skipped (no signify binary or openbsd-${OPENBSD_SHORT}-base.pub key found)."
    warn "Integrity rests on HTTPS + matching SHA256 from two official hosts. For the extra check:"
    warn "  sudo apt install signify-openbsd signify-openbsd-keys   (if your distro ships a key for ${OPENBSD_VERSION})"
  fi
  ISO_PATH="$iso"
}

fetch_debian_iso() {
  local dir="$CACHE_DIR/debian" sums line name want iso
  info "Debian stable netinst (for the Pi-hole/SearXNG VM)"
  run mkdir -p -- "$dir"
  if [[ $DRY_RUN -eq 1 ]]; then
    say "   (dry-run) would fetch $DEBIAN_ISO_BASE/SHA512SUMS, pick debian-*-amd64-netinst.iso,"
    say "   (dry-run) download it and verify SHA-512 (+ GPG signature if the Debian CD key is in your keyring)"
    ISO_PATH="$dir/debian-netinst.iso"; return
  fi
  sums="$dir/SHA512SUMS"
  rm -f -- "$sums" "$sums.sign"
  fetch "$DEBIAN_ISO_BASE/SHA512SUMS" "$sums"
  line="$(grep -E '  debian-[0-9.]+-amd64-netinst\.iso$' "$sums" | tail -n 1 || true)"
  [[ -n $line ]] || die "no amd64 netinst ISO listed in $DEBIAN_ISO_BASE/SHA512SUMS"
  want="${line%% *}"; name="${line##* }"
  ok "latest netinst: $name"

  if command -v gpg >/dev/null 2>&1; then
    fetch "$DEBIAN_ISO_BASE/SHA512SUMS.sign" "$sums.sign" || warn "could not fetch SHA512SUMS.sign"
    if [[ -s $sums.sign ]] && gpg --batch --status-fd 1 --verify "$sums.sign" "$sums" 2>/dev/null \
        | grep -E "^\[GNUPG:\] VALIDSIG .*$DEBIAN_CD_KEY_FPR( |\$)" >/dev/null; then
      ok "SHA512SUMS signed by Debian CD signing key $DEBIAN_CD_KEY_FPR"
    else
      warn "GPG signature not verified (Debian CD key not in your keyring?). To add it:"
      warn "  gpg --keyserver keyring.debian.org --recv-keys $DEBIAN_CD_KEY_FPR"
      warn "Continuing with HTTPS + SHA-512 only."
    fi
  fi

  iso="$dir/$name"
  if [[ -f $iso ]] && [[ "$(sha512sum -- "$iso" | awk '{print $1}')" == "$want" ]]; then
    ok "cached ISO already verified: $iso"
  else
    fetch_verified "$DEBIAN_ISO_BASE/$name" "$iso" sha512sum "$want"
  fi
  ISO_PATH="$iso"
}

# ------------------------------------------------------------------ VM creation
# create_vm ROLE NAME OSTYPE MEM CPUS DISK_MB SSHPORT LANMAC ISO NATCABLE
create_vm() {
  local role=$1 name=$2 ostype=$3 mem=$4 cpus=$5 disk_mb=$6 port=$7 mac=$8 iso=$9 cable=${10}
  local vmdir="$VM_BASEFOLDER/$name" disk state
  disk="$vmdir/$name.vdi"
  CURRENT_VM=$role

  if ! vm_exists "$name"; then
    info "Registering VM '$name'"
    run vbm createvm --name "$name" --ostype "$ostype" --basefolder "$VM_BASEFOLDER" --register
    run vbm setextradata "$name" "$MARKER_KEY" 1
    mr_flush
  fi
  if [[ $DRY_RUN -eq 0 ]]; then
    state="$(vm_state "$name")"
    case $state in
      poweroff|aborted) ;;
      *) if is_complete "$name"; then ok "VM '$name' is complete (state: $state) -- nothing to do"; CURRENT_VM=""; return; fi
         die "VM '$name' is $state; power it off, then rerun" ;;
    esac
  fi

  info "Applying settings (idempotent)"
  run vbm modifyvm "$name" \
    --description "Created by vbox-privacy-kit ($role). Safe to remove with: vbox-privacy-setup.sh rollback-$role" \
    --memory "$mem" --cpus "$cpus" --ioapic on --rtc-use-utc on \
    --audio-enabled off --usb-ohci off --usb-ehci off --usb-xhci off \
    --clipboard-mode disabled --drag-and-drop disabled --vrde off \
    --boot1 disk --boot2 dvd --boot3 none --boot4 none
  # NIC1: NAT (Internet + SSH admin via host loopback only). Guest cannot reach host's 127.0.0.1.
  run vbm modifyvm "$name" --nic1 nat --nic-type1 82540EM --nat-localhostreachable1 off
  if [[ $DRY_RUN -eq 1 ]] || ! is_complete "$name"; then   # cable state is yours to change later
    run vbm modifyvm "$name" --cable-connected1 "$cable"
  fi
  if [[ $DRY_RUN -eq 1 ]] || [[ "$(mr "$name" "Forwarding(0)")" != ssh,* ]]; then
    run vbm modifyvm "$name" --nat-pf1 "ssh,tcp,127.0.0.1,$port,,22"
  fi
  # NIC2: internal network shared only with the other kit VM.
  run vbm modifyvm "$name" --nic2 intnet --intnet2 "$LAN_INTNET" --nic-type2 82540EM \
    --mac-address2 "$mac" --cable-connected2 on --nic-promisc2 deny
  mr_flush

  if [[ $DRY_RUN -eq 1 ]] || [[ -z "$(mr "$name" storagecontrollername0)" ]]; then
    run vbm storagectl "$name" --name SATA --add sata --controller IntelAhci --portcount 2 --bootable on
    mr_flush
  fi

  local attached
  attached="$(mr "$name" SATA-0-0)"
  if [[ $DRY_RUN -eq 1 ]] || [[ -z $attached || $attached == none ]]; then
    if [[ ! -e $disk ]]; then
      info "Creating disk $disk (${disk_mb} MB, dynamically allocated)"
      run vbm createmedium disk --filename "$disk" --size "$disk_mb" --format VDI --variant Standard
    fi
    run vbm storageattach "$name" --storagectl SATA --port 0 --device 0 --type hdd --medium "$disk"
  else
    ok "disk already attached: $attached"
  fi

  if [[ $DRY_RUN -eq 1 ]] || ! is_complete "$name"; then
    run vbm storageattach "$name" --storagectl SATA --port 1 --device 0 --type dvddrive --medium "$iso"
    # First boot must reach the installer: disk is empty so BIOS falls through to DVD.
    run vbm setextradata "$name" "$COMPLETE_KEY" 1
  fi
  CURRENT_VM=""
  ok "VM '$name' is ready"
}

cmd_create_openbsd() {
  check_prereqs
  check_space "$CACHE_DIR" 1200
  check_space "$VM_BASEFOLDER" 4096
  check_collisions openbsd "$OPENBSD_VM_NAME" "$VM_BASEFOLDER/$OPENBSD_VM_NAME/$OPENBSD_VM_NAME.vdi" \
    "$OPENBSD_LAN_MAC" "$OPENBSD_SSH_HOST_PORT"
  local ISO_PATH=""
  fetch_openbsd_iso
  create_vm openbsd "$OPENBSD_VM_NAME" OpenBSD_64 "$OPENBSD_MEMORY_MB" "$OPENBSD_CPUS" \
    "$OPENBSD_DISK_MB" "$OPENBSD_SSH_HOST_PORT" "$OPENBSD_LAN_MAC" "$ISO_PATH" on
  cat <<EOF

${B}Next steps (OpenBSD)${N}
  1. Start the installer:   VBoxManage startvm "$OPENBSD_VM_NAME"
  2. In the installer: (I)nstall; em0 = dhcp, IPv6 for em0 = none; em1 = none
     (the guest kit sets em1 = 10.77.0.1); start sshd = yes; X = your choice;
     create a normal user; disk: whole disk, (A)uto layout; sets: defaults from cd0.
     Installing from cd0 downloads nothing.
  3. After the install halts/reboots:  $0 eject-installer openbsd
  4. Prepare Mullvad + the kit, copy both in (see README):
         $0 pack-mullvad ~/Downloads/mullvad_wireguard_linux_all_all.zip
         scp -P $OPENBSD_SSH_HOST_PORT -r openbsd-guest "$CACHE_DIR/mullvad-configs.tgz" <user>@127.0.0.1:
  5. In the VM:  doas ksh ~/openbsd-guest/install.sh --mullvad ~/mullvad-configs.tgz --server se
  Rollback at any time:      $0 rollback-openbsd
EOF
}

cmd_create_services() {
  check_prereqs
  check_space "$CACHE_DIR" 1000
  check_space "$VM_BASEFOLDER" 3072
  check_collisions services "$SERVICES_VM_NAME" "$VM_BASEFOLDER/$SERVICES_VM_NAME/$SERVICES_VM_NAME.vdi" \
    "$SERVICES_LAN_MAC" "$SERVICES_SSH_HOST_PORT"
  local ISO_PATH="" ostype
  ostype="$(debian_ostype)"
  fetch_debian_iso
  create_vm services "$SERVICES_VM_NAME" "$ostype" "$SERVICES_MEMORY_MB" "$SERVICES_CPUS" \
    "$SERVICES_DISK_MB" "$SERVICES_SSH_HOST_PORT" "$SERVICES_LAN_MAC" "$ISO_PATH" "$SERVICES_NAT_CABLE"
  cat <<EOF

${B}Next steps (Debian services VM: Pi-hole + SearXNG)${N}
  NAT cable: $SERVICES_NAT_CABLE. With "off" the installer reaches the Internet ONLY via the
  OpenBSD VM -> Mullvad, so first, on OpenBSD:  doas privctl lock mullvad && doas privctl confirm
  1. VBoxManage startvm "$SERVICES_VM_NAME"
  2. Debian installer: primary network interface = the SECOND one (MAC 08:00:27:77:00:02);
     DHCP fails -> "Configure network manually": IP 10.77.0.2/24, gateway 10.77.0.1,
     name server 10.64.0.1 (Mullvad DNS from your configs); no root password (your
     user gets sudo); software: ONLY "SSH server" + "standard system utilities".
  3. $0 eject-installer services
  4. From the host, through OpenBSD:  ssh -J <openbsd-user>@127.0.0.1:$OPENBSD_SSH_HOST_PORT <user>@10.77.0.2
     then run the debian-services kit (README).
  Rollback at any time:      $0 rollback-services
EOF
}

# ------------------------------------------------------------------ other commands
role_vm() {
  case $1 in
    openbsd) printf '%s' "$OPENBSD_VM_NAME" ;;
    services) printf '%s' "$SERVICES_VM_NAME" ;;
    *) die "unknown role '$1' (use openbsd or services)" ;;
  esac
}

require_managed() {
  vm_exists "$1" || die "no VM named '$1' is registered"
  is_managed "$1" || die "VM '$1' was not created by this kit -- refusing to change it"
}

cmd_eject() {
  local name; name="$(role_vm "${1:-}")"
  require_managed "$name"
  info "Ejecting installer from '$name'"
  run vbm storageattach "$name" --storagectl SATA --port 1 --device 0 --type dvddrive \
    --medium emptydrive --forceunmount
  ok "installer ejected; the VM now boots from its disk"
}

cmd_cable() {  # cmd_cable on|off [ROLE]
  local want=$1 name state
  name="$(role_vm "${2:-services}")"
  [[ $want == on || $want == off ]] || die "usage: $0 cable <openbsd|services> <on|off>"
  require_managed "$name"
  state="$(vm_state "$name")"
  if [[ $state == running ]]; then
    run vbm controlvm "$name" setlinkstate1 "$want"
  else
    run vbm modifyvm "$name" --cable-connected1 "$want"
  fi
  mr_flush
  ok "'$name' NAT adapter cable: $want (now: $(mr "$name" cableconnected1))"
  [[ $want == off && $name == "$SERVICES_VM_NAME" ]] && say "   The services VM can now reach ONLY the internal LAN (OpenBSD 10.77.0.1).
   Administer it through OpenBSD:  ssh -J <user>@127.0.0.1:$OPENBSD_SSH_HOST_PORT <user>@10.77.0.2"
  return 0
}

show_vm() {
  local role=$1 name=$2
  if ! vm_exists "$name"; then say "  $role: '$name' not created"; return; fi
  local m="no"; is_managed "$name" && m="yes"
  say "  $role: '$name'  managed=$m  state=$(vm_state "$name")  complete=$(is_complete "$name" && echo yes || echo no)"
  say "      memory=$(mr "$name" memory)MB cpus=$(mr "$name" cpus) disk=$(mr "$name" SATA-0-0)"
  say "      dvd=$(mr "$name" SATA-1-0)"
  say "      nic1=$(mr "$name" nic1) cable1=$(mr "$name" cableconnected1) fwd=$(mr "$name" 'Forwarding(0)')"
  say "      nic2=$(mr "$name" nic2) intnet2=$(mr "$name" intnet2) mac2=$(mr "$name" macaddress2)"
}

cmd_status() {
  info "vbox-privacy-kit VMs"
  show_vm openbsd "$OPENBSD_VM_NAME"
  show_vm services "$SERVICES_VM_NAME"
  local p
  for p in "${PROTECTED_PATHS[@]}"; do say "  protected, untouched: $p"; done
}

cmd_rollback() {  # cmd_rollback ROLE
  local role=$1 name uuid cfg state loc
  name="$(role_vm "$role")"
  info "Rollback of '$name'"
  if ! vm_exists "$name"; then
    ok "no VM '$name' registered -- nothing to remove"
  else
    is_managed "$name" || die "VM '$name' was NOT created by this kit; refusing to delete it"
    uuid="$(mr "$name" UUID)"; cfg="$(mr "$name" CfgFile)"; state="$(vm_state "$name")"
    assert_not_protected "$cfg"
    for loc in "$(mr "$name" SATA-0-0)" "$(mr "$name" SATA-1-0)"; do
      [[ -n $loc && $loc != none && $loc != emptydrive ]] && assert_not_protected "$loc"
    done
    case $state in poweroff|aborted|saved) ;; *) die "VM is $state -- run: VBoxManage controlvm \"$name\" poweroff" ;; esac
    say "   will delete VM '$name' ($uuid), its settings and its disk: $(mr "$name" SATA-0-0)"
    confirm "Delete this VM and its disk?" || die "aborted"
    [[ $state == saved ]] && run vbm discardstate "$uuid"
    if [[ -n "$(mr "$name" storagecontrollername0)" ]]; then
      run vbm storageattach "$uuid" --storagectl SATA --port 1 --device 0 --type dvddrive --medium none || true
    fi
    run vbm unregistervm "$uuid" --delete
    ok "VM '$name' and its disk removed"
  fi
  # Forget installer ISOs in VirtualBox's media registry (does not delete files).
  while IFS= read -r loc; do
    [[ $(abspath "$loc") == "$(abspath "$CACHE_DIR")"/* ]] && { run vbm closemedium dvd "$loc" 2>/dev/null || true; }
  done < <(list_media dvds)
  if [[ $PURGE_CACHE -eq 1 ]]; then
    local sub; [[ $role == openbsd ]] && sub="openbsd-$OPENBSD_VERSION" || sub="debian"
    run rm -rf -- "${CACHE_DIR:?}/$sub"
    ok "cached ISO removed"
  else
    say "   verified ISO kept in $CACHE_DIR (add --purge-cache to delete it)"
  fi
}

cmd_pack_mullvad() {  # cmd_pack_mullvad ZIP -- no keys leave this host except to your VM
  local zip=${1:-} tmp out n
  [[ -f $zip ]] || die "usage: $0 pack-mullvad /path/to/mullvad_wireguard_*.zip"
  command -v unzip >/dev/null 2>&1 || die "unzip is needed on the host (sudo apt install unzip)"
  out="$CACHE_DIR/mullvad-configs.tgz"
  info "Repacking Mullvad WireGuard configs"
  if [[ $DRY_RUN -eq 1 ]]; then say "   (dry-run) would unzip $zip and write $out (mode 0600)"; return 0; fi
  tmp="$(mktemp -d)"
  (umask 077; unzip -q -o "$zip" '*.conf' -d "$tmp") || { rm -rf "$tmp"; die "cannot read $zip"; }
  n=$(grep -l '^PrivateKey' "$tmp"/*.conf 2>/dev/null | xargs -r grep -l '^Endpoint' | wc -l)
  ((n > 0)) || { rm -rf "$tmp"; die "no WireGuard configs with PrivateKey/Endpoint in $zip"; }
  mkdir -p -- "$CACHE_DIR"
  (umask 077; tar -czf "$out" -C "$tmp" .)
  chmod 600 "$out"; rm -rf "$tmp"
  ok "$n configs -> $out (0600; contains your Mullvad private key -- do not share it)"
  say "   copy into the OpenBSD VM:  scp -P $OPENBSD_SSH_HOST_PORT \"$out\" <user>@127.0.0.1:"
}

cmd_check() {
  check_prereqs
  check_collisions openbsd "$OPENBSD_VM_NAME" "$VM_BASEFOLDER/$OPENBSD_VM_NAME/$OPENBSD_VM_NAME.vdi" \
    "$OPENBSD_LAN_MAC" "$OPENBSD_SSH_HOST_PORT"
  check_collisions services "$SERVICES_VM_NAME" "$VM_BASEFOLDER/$SERVICES_VM_NAME/$SERVICES_VM_NAME.vdi" \
    "$SERVICES_LAN_MAC" "$SERVICES_SSH_HOST_PORT"
  debian_ostype >/dev/null && ok "Debian OS type: $(debian_ostype)"
  ok "all checks passed -- nothing was changed"
}

# ------------------------------------------------------------------ main
ARGS=()
while (($#)); do
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    --purge-cache) PURGE_CACHE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
set -- "${ARGS[@]+"${ARGS[@]}"}"
[[ $DRY_RUN -eq 1 ]] && info "DRY RUN: nothing will be changed or downloaded"

case ${1:-} in
  check) cmd_check ;;
  create-openbsd) cmd_create_openbsd ;;
  create-services) cmd_create_services ;;
  status) cmd_status ;;
  eject-installer) cmd_eject "${2:-}" ;;
  isolate-services) cmd_cable off ;;
  connect-services) cmd_cable on ;;
  pack-mullvad) cmd_pack_mullvad "${2:-}" ;;
  cable) cmd_cable "${3:-}" "${2:-}" ;;
  rollback-openbsd) cmd_rollback openbsd ;;
  rollback-services) cmd_rollback services ;;
  ""|help) usage ;;
  *) usage; die "unknown command: $1" ;;
esac
