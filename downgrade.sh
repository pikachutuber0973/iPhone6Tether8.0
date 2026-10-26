#!/usr/bin/env bash
# iPhone6Tether8.0 - Linux edition
# Tethered (seprmvr64) downgrade strictly for iPhone 6 (iPhone7,2 / n61ap / A8) -> iOS 8.3 (12F70)
CURRENT_VERSION="v1.4.0-linux-8.3"

set -Eeuo pipefail

cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
ROOT="$PWD"
export LD_LIBRARY_PATH="$ROOT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------
IDENTIFIER="iPhone7,2"
BOARD="n61ap"
CPID="0x7000"                 # A8
TARGET_DEFAULT="8.3"          # iPhone_4.7_8.3_12F70_Restore.ipsw
LATEST_VERSION="12.5.8"       # signed base used for the restore
MAX_PWN_TRIES=5
RESTORE_BOOTARGS="rd=md0 debug=0x2014e -v wdt=-1 nand-enable-reformat=1 -restore amfi=0xff cs_enforcement_disable=1"
BOOT_BOOTARGS="-v rd=disk0s1s1${EXTRA_BOOTARGS:+ $EXTRA_BOOTARGS}"
SSH_PORT=6414                 # SSH ramdisk (iproxy 6414 22)

ECID_DEC=""; SERIAL=""; MODE_NOW=""
KEY_IBSS=""; KEY_IBEC=""; KEY_DTRE=""; KEY_RDSK=""; KEY_KRNL=""; KEY_FSTM=""

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '[*] %s\n' "$*"; }
ok()   { printf '[+] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

on_err() {
  local rc=$?
  warn "Script failed (exit $rc) at line ${BASH_LINENO[0]}: $BASH_COMMAND"
  exit "$rc"
}
trap on_err ERR

as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo env "LD_LIBRARY_PATH=$LD_LIBRARY_PATH" "$@"; fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing '$1'. Install it with your package manager."; }

to_dec() {
  local v="${1//[[:space:]]/}"
  if [[ $v == 0x* || $v == 0X* ]]; then printf '%d' "$v"; else printf '%s' "$v"; fi
}

usage() {
  cat <<EOF
Usage: $0 <command>

  --ipsw TARGET.ipsw BASE_12.5.8.ipsw [VERSION] [--stitch-activation]
  --seprmvr64-ipsw ...        (same as --ipsw)
      Build a custom IPSW (default VERSION: $TARGET_DEFAULT). Activation records are
      always stitched in, Setup.app is deleted and auto-lock is set to Never.
      Example: $0 --ipsw iPhone_4.7_8.3_12F70_Restore.ipsw iPhone_4.7_12.5.8_Restore.ipsw 8.3

  --restore [VERSION]         (alias: --seprmvr64-restore)
      Put the phone in DFU, pwn it (with retries) and restore the custom IPSW.

  --fix-ios8                  Patch dyld over the SSH ramdisk (fixes "Slide to Upgrade"),
                              delete Setup.app and disable auto-lock/sleep. Run after restoring.

  boot [VERSION] [IPSW]       (alias: --boot, --seprmvr64-boot)
      Tethered boot. Needed after every reboot / power off.

Env: EXTRA_BOOTARGS="..." adds boot-args to the tethered boot, SKIP_GO=1 skips 'irecovery -c go'.
EOF
}

# ----------------------------------------------------------------------------
# Environment checks
# ----------------------------------------------------------------------------
check_env() {
  [[ "$(uname -s)" == "Linux" ]] || die "This is the Linux edition."
  for c in unzip zip curl perl awk find df; do need_cmd "$c"; done
  [[ -d bin ]] || die "No ./bin folder. Run this from the repo root."
  local b missing=()
  for b in irecovery gaster img4 img4tool hfsplus dmg asr64_patcher ldid restoredpatcher \
           ipatcher Kernel64Patcher2 kerneldiff tsschecker idevicerestore sshpass dsc64patcher; do
    [[ -f bin/$b ]] || missing+=("$b")
  done
  ((${#missing[@]} == 0)) || die "Missing binaries in ./bin: ${missing[*]}"
  chmod +x bin/* 2>/dev/null || true
}

# ----------------------------------------------------------------------------
# Device / DFU handling
# ----------------------------------------------------------------------------
stop_usbmuxd()  { as_root systemctl stop usbmuxd >/dev/null 2>&1 || true; as_root pkill -x usbmuxd >/dev/null 2>&1 || true; }
start_usbmuxd() {
  as_root systemctl start usbmuxd >/dev/null 2>&1 || (as_root usbmuxd -pf >/dev/null 2>&1 &)
  sleep 2
}

irq()          { as_root "$ROOT/bin/irecovery" -q 2>/dev/null || true; }
current_mode() { irq | awk -F': *' '/^MODE:/{gsub(/\r/,"",$2); print $2; exit}'; }

wait_for_mode() {
  local want="$1" timeout="${2:-30}" i m
  for ((i = 0; i < timeout; i++)); do
    m="$(current_mode)"
    [[ "$m" == "$want" ]] && return 0
    sleep 1
  done
  return 1
}

detect_device() {
  local info=""
  # normal mode
  if command -v ideviceinfo >/dev/null 2>&1 && info="$(ideviceinfo 2>/dev/null)" && [[ -n "$info" ]]; then
    MODE_NOW="normal"
    IDENT_FOUND="$(awk -F': ' '/^ProductType:/{print $2}' <<<"$info" | tr -d '\r ')"
    ECID_DEC="$(awk -F': ' '/^UniqueChipID:/{print $2}' <<<"$info" | tr -d '\r ')"
    SERIAL="$(awk -F': ' '/^SerialNumber:/{print $2}' <<<"$info" | tr -d '\r ')"
  # recovery / DFU
  elif info="$(irq)" && [[ -n "$info" ]]; then
    MODE_NOW="$(awk -F': *' '/^MODE:/{gsub(/\r/,"",$2); print $2; exit}' <<<"$info")"
    IDENT_FOUND="$(awk -F': *' '/^PRODUCT:/{gsub(/\r/,"",$2); print $2; exit}' <<<"$info")"
    ECID_DEC="$(to_dec "$(awk -F': *' '/^ECID:/{gsub(/\r/,"",$2); print $2; exit}' <<<"$info")")"
  else
    die "No device found. Check the cable (try a USB 2.0 port) and that the phone is on or in DFU."
  fi
  [[ "$IDENT_FOUND" == "$IDENTIFIER" ]] || die "This script is for the iPhone 6 ($IDENTIFIER) only. Found: ${IDENT_FOUND:-unknown}"
  [[ -n "$ECID_DEC" ]] || die "Could not read the ECID."
  ok "Device: $IDENT_FOUND  ECID: $ECID_DEC  Mode: ${MODE_NOW:-unknown}"
}

dfu_instructions() {
  cat <<'EOF'
    Enter DFU on the iPhone 6:
      1. Plug in the cable. Turn the phone off or leave it on.
      2. Hold Power + Home together for 8-10 seconds.
      3. Release Power, KEEP holding Home for another ~8 seconds.
      4. Screen must stay completely black (no logo, no "connect to iTunes").
EOF
}

pwn_device() {
  local try info
  stop_usbmuxd                     # usbmuxd grabbing the USB device is the #1 cause of failed pwns on Linux
  for ((try = 1; try <= MAX_PWN_TRIES; try++)); do
    log "PWNDFU attempt $try/$MAX_PWN_TRIES"
    if [[ "$(current_mode)" != "DFU" ]]; then
      dfu_instructions
      read -r -p "    Press Enter once the phone is in DFU... " _
      if ! wait_for_mode DFU 15; then warn "Phone not seen in DFU mode."; continue; fi
    fi

    info="$(irq)"
    grep -q "PRODUCT: $IDENTIFIER" <<<"$info" || die "DFU device is not an $IDENTIFIER. Aborting."
    grep -qi "CPID: $CPID" <<<"$info" || warn "CPID is not $CPID (A8) - continuing anyway."

    if grep -q 'PWND' <<<"$info"; then ok "Already in PWNDFU."; return 0; fi

    as_root "$ROOT/bin/gaster" pwn || warn "gaster pwn returned an error."
    sleep 1
    as_root "$ROOT/bin/gaster" reset || warn "gaster reset returned an error."
    sleep 1

    if irq | grep -q 'PWND'; then ok "PWNDFU verified."; return 0; fi
    warn "Not pwned. Re-enter DFU (unplug, power off, redo the button combo) and retry."
    as_root "$ROOT/bin/irecovery" -n >/dev/null 2>&1 || true   # leave the device out of a half-state if possible
    sleep 2
  done
  die "Could not get PWNDFU after $MAX_PWN_TRIES attempts. Try another USB port/cable (USB-A 2.0 works best)."
}

irec_try() {
  local n
  for n in 1 2 3; do
    as_root "$ROOT/bin/irecovery" "$@" && return 0
    sleep 2
  done
  die "'irecovery $*' failed 3 times. Re-enter DFU and run the command again."
}

# ----------------------------------------------------------------------------
# Key / IPSW helpers
# ----------------------------------------------------------------------------
load_keys() {
  local ver="$1"; shift
  local keyfile="keys/$IDENTIFIER.txt" k v missing=()
  [[ -f "$keyfile" ]] || die "Missing $keyfile"
  for k in "$@"; do
    v="$(grep -m1 "^$k-$ver:" "$keyfile" | cut -d: -f2- | tr -d ' \r' || true)"
    [[ -n "$v" ]] || missing+=("$k-$ver")
    printf -v "KEY_${k^^}" '%s' "$v"
  done
  if ((${#missing[@]})); then
    warn "No keys for iOS $ver in $keyfile: ${missing[*]}"
    warn "Easiest: run 'python3 downgrade_gui.py' and use 'Import keys...' with the copied wiki page"
    warn "(theapplewiki: Keys:Stowe_12F70_(iPhone7,2)). Or add lines like 'ibss-$ver:<IV+KEY hex>' by hand;"
    warn "ibss/ibec/dtre/rdsk/krnl = IV+Key (96 hex), fstm = rootfs key only (72 hex)."
    exit 1
  fi
}

stat_size() { stat -c %s "$1"; }

find_dmg() { # dir smallest|largest
  find "$1" -type f -name '*.dmg' ! -name '._*' -print0 |
    while IFS= read -r -d '' f; do printf '%s %s\n' "$(stat_size "$f")" "$f"; done |
    { if [[ "$2" == smallest ]]; then sort -n; else sort -nr; fi; } |
    head -n 1 | cut -d' ' -f2-
}

manifest_path() { # BuildManifest.plist component
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import plistlib, sys
m = plistlib.load(open(sys.argv[1], 'rb'))
for ident in m.get('BuildIdentities', []):
    if ident.get('Info', {}).get('RestoreBehavior') == 'Erase':
        e = ident.get('Manifest', {}).get(sys.argv[2])
        if e:
            print(e['Info']['Path'])
            break
PY
}

pick_dmg() { # dir component fallback-mode
  local p
  p="$(manifest_path "$1/BuildManifest.plist" "$2")"
  if [[ -n "$p" && -f "$1/$p" ]]; then printf '%s\n' "$1/$p"; else find_dmg "$1" "$3"; fi
}

find_one() { find "$1" -type f -name "$2" ! -name '._*' 2>/dev/null | head -n 1 || true; }

pick_ipsw() { # optional preset
  local p="${1:-${IPSW:-}}"
  if [[ -z "$p" ]] && command -v zenity >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    p="$(zenity --file-selection --title="Select the iOS $2 IPSW" 2>/dev/null || true)"
  fi
  if [[ -z "$p" ]]; then read -r -e -p "Path to the iOS $2 IPSW: " p; fi
  [[ -f "$p" ]] || die "IPSW not found: $p"
  printf '%s\n' "$p"
}

# ----------------------------------------------------------------------------
# Activation records
# ----------------------------------------------------------------------------
SSH_OPTS=(-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR)

scp_get() { # pw ip remote local
  "$ROOT/bin/sshpass" -p "$1" scp -O "${SSH_OPTS[@]}" "root@$2:$3" "$4" 2>/dev/null ||
  "$ROOT/bin/sshpass" -p "$1" scp    "${SSH_OPTS[@]}" "root@$2:$3" "$4"
}

fetch_activation() {
  local dir="activation_records/$ECID_DEC"
  if [[ -s "$dir/activation_record.plist" && -s "$dir/IC-Info.sisv" && -s "$dir/com.apple.commcenter.device_specific_nobackup.plist" ]]; then
    ok "Using stored activation records ($dir)"; return 0
  fi
  if [[ -n "$SERIAL" && -s "activation_records/$SERIAL/activation_record.plist" ]]; then
    mkdir -p "$dir"; cp -r "activation_records/$SERIAL/." "$dir/"; ok "Migrated records from serial folder"; return 0
  fi
  [[ "$MODE_NOW" == "normal" ]] || die "Activation records are missing. Boot the phone normally (activated, jailbroken, OpenSSH installed) and rerun."
  warn "Activation records REQUIRED. Phone must be on its latest iOS, activated, jailbroken, with OpenSSH."
  local ip pw
  read -r -p "Device IP: " ip
  read -r -s -p "SSH password for root (usually 'alpine'): " pw; echo
  mkdir -p "$dir"
  scp_get "$pw" "$ip" "/private/var/containers/Data/System/*/Library/activation_records/activation_record.plist" "$dir/activation_record.plist"
  scp_get "$pw" "$ip" "/private/var/mobile/Library/FairPlay/iTunes_Control/iTunes/IC-Info.sisv" "$dir/IC-Info.sisv"
  scp_get "$pw" "$ip" "/private/var/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist" "$dir/com.apple.commcenter.device_specific_nobackup.plist"
  ok "Activation records saved."
}

# ----------------------------------------------------------------------------
# springboard prefs: auto-lock = Never  (screen lock/sleep is what panics a SEP-less boot)
# ----------------------------------------------------------------------------
write_nosleep_plist() { # output path
  cat >"$1" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>SBAutoLockTime</key>
	<integer>-1</integer>
</dict>
</plist>
EOF
}

# ----------------------------------------------------------------------------
# Command: build custom IPSW
# ----------------------------------------------------------------------------
cmd_ipsw() {
  local target_ipsw="${1:-}" base_ipsw="${2:-}" ver="${3:-$TARGET_DEFAULT}"
  [[ "$ver" == --* ]] && ver="$TARGET_DEFAULT"
  [[ -f "$target_ipsw" ]] || die "Target IPSW not found: '$target_ipsw'"
  [[ -f "$base_ipsw"   ]] || die "Base IPSW not found: '$base_ipsw'"
  [[ "$ver" == "8.3" ]] || warn "This build is tuned for 8.3 - proceeding with $ver."

  detect_device
  fetch_activation
  load_keys "$ver" ibss ibec dtre rdsk krnl fstm

  local avail; avail="$(df --output=avail -k . | tail -n 1 | tr -d ' ')"
  (( avail > 14 * 1024 * 1024 )) || die "Need ~14 GB free in $(pwd)."

  local savedir="noseprestore/$IDENTIFIER/$ver" act="activation_records/$ECID_DEC"
  rm -rf tmp1 tmp2 work
  mkdir -p "$savedir" work cache
  log "Unpacking IPSWs..."
  unzip -q "$target_ipsw" -d tmp1
  unzip -q "$base_ipsw"   -d tmp2

  local t_rd t_root b_rd b_root
  t_rd="$(pick_dmg tmp1 RestoreRamDisk smallest)"; t_root="$(pick_dmg tmp1 OS largest)"
  b_rd="$(pick_dmg tmp2 RestoreRamDisk smallest)"; b_root="$(pick_dmg tmp2 OS largest)"
  [[ -n "$t_rd" && -n "$t_root" && -n "$b_rd" && -n "$b_root" ]] || die "Could not locate ramdisk/rootfs DMGs."

  # ---- ramdisk: patch ASR + restored_external ----
  log "Patching ASR and restored_external..."
  ./bin/img4 -i "$t_rd" -o work/ramdisk.raw -k "$KEY_RDSK"
  ./bin/hfsplus work/ramdisk.raw grow 30000000
  ./bin/hfsplus work/ramdisk.raw extract usr/sbin/asr
  ./bin/asr64_patcher asr asr_patch
  ./bin/ldid -e asr > ents.plist
  ./bin/ldid -Sents.plist asr_patch
  ./bin/hfsplus work/ramdisk.raw rm usr/sbin/asr
  ./bin/hfsplus work/ramdisk.raw add asr_patch usr/sbin/asr
  ./bin/hfsplus work/ramdisk.raw chmod 100755 usr/sbin/asr
  ./bin/hfsplus work/ramdisk.raw extract usr/local/bin/restored_external
  ./bin/restoredpatcher restored_external restored_patch -b
  ./bin/ldid -e restored_external > ents.plist
  ./bin/ldid -Sents.plist restored_patch
  ./bin/hfsplus work/ramdisk.raw rm usr/local/bin/restored_external
  ./bin/hfsplus work/ramdisk.raw add restored_patch usr/local/bin/restored_external
  ./bin/hfsplus work/ramdisk.raw chmod 100755 usr/local/bin/restored_external
  [[ -s cache/options.n61.plist ]] || curl -fL -o cache/options.n61.plist \
    https://github.com/pwnerblu/surrealra1n/raw/refs/heads/development/dualboot/options.n61.plist
  ./bin/hfsplus work/ramdisk.raw rm usr/local/share/restore/options.n61.plist || true
  ./bin/hfsplus work/ramdisk.raw add cache/options.n61.plist usr/local/share/restore/options.n61.plist
  ./bin/img4 -i work/ramdisk.raw -o "$b_rd" -A -T rdsk

  # ---- rootfs ----
  log "Extracting rootfs ($ver)..."
  ./bin/dmg extract "$t_root" tmp1/rootfs.raw -k "$KEY_FSTM"
  ./bin/hfsplus tmp1/rootfs.raw grow 3500000000
  local R=tmp1/rootfs.raw
  hfs() { ./bin/hfsplus "$R" "$@"; }

  log "Stitching activation files..."
  local d
  for d in private/var/root/Library/Lockdown private/var/root/Library/Lockdown/activation_records \
           private/var/mobile/Library/mad private/var/mobile/Library/mad/activation_records \
           private/var/mobile/Library/FairPlay private/var/mobile/Library/FairPlay/iTunes_Control \
           private/var/mobile/Library/FairPlay/iTunes_Control/iTunes \
           private/var/wireless private/var/wireless/Library private/var/wireless/Library/Preferences; do
    hfs mkdir "$d" >/dev/null 2>&1 || true
  done
  hfs add "$act/activation_record.plist" private/var/root/Library/Lockdown/activation_records/activation_record.plist
  hfs add "$act/activation_record.plist" private/var/mobile/Library/mad/activation_records/activation_record.plist
  hfs add "$act/IC-Info.sisv" private/var/mobile/Library/FairPlay/iTunes_Control/iTunes/IC-Info.sisv
  hfs add "$act/com.apple.commcenter.device_specific_nobackup.plist" private/var/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist
  hfs chmod 666 private/var/root/Library/Lockdown/activation_records/activation_record.plist
  hfs chmod 666 private/var/mobile/Library/mad/activation_records/activation_record.plist
  hfs chmod 664 private/var/mobile/Library/FairPlay/iTunes_Control/iTunes/IC-Info.sisv
  hfs chmod 600 private/var/wireless/Library/Preferences/com.apple.commcenter.device_specific_nobackup.plist

  log "Deleting Setup.app..."
  if ! hfs rmall Applications/Setup.app >/dev/null 2>&1; then hfs rm Applications/Setup.app >/dev/null 2>&1 || true; fi
  if hfs ls Applications 2>/dev/null | grep -q 'Setup.app'; then
    warn "Setup.app is still present (your hfsplus build may lack 'rmall'). Run --fix-ios8 afterwards, it deletes it over SSH."
  else
    ok "Setup.app removed."
  fi

  log "Disabling auto-lock (prevents the lock-screen sleep panic)..."
  write_nosleep_plist work/com.apple.springboard.plist
  hfs mkdir private/var/mobile/Library/Preferences >/dev/null 2>&1 || true
  hfs rm private/var/mobile/Library/Preferences/com.apple.springboard.plist >/dev/null 2>&1 || true
  hfs add work/com.apple.springboard.plist private/var/mobile/Library/Preferences/com.apple.springboard.plist
  hfs chmod 644 private/var/mobile/Library/Preferences/com.apple.springboard.plist
  hfs chown 501 501 private/var/mobile/Library/Preferences/com.apple.springboard.plist >/dev/null 2>&1 || true

  rm -f "$b_root"
  ./bin/dmg build "$R" "$b_root"

  # ---- DeviceTree ----
  log "Patching DeviceTree..."
  local t_dt b_dt
  t_dt="$(find_one tmp1/Firmware/all_flash "DeviceTree.$BOARD.im4p")"
  b_dt="$(find_one tmp2/Firmware/all_flash "DeviceTree.$BOARD.im4p")"
  [[ -n "$t_dt" && -n "$b_dt" ]] || die "DeviceTree not found in one of the IPSWs."
  ./bin/img4 -i "$t_dt" -o work/dtre.raw -k "$KEY_DTRE"
  perl -pi -e 's/content-protect/content-protecV/g' work/dtre.raw
  ./bin/img4 -i work/dtre.raw -o "$b_dt" -A -T rdtr

  # ---- iBSS / iBEC (file names differ between 8.x and 12.x, so resolve them) ----
  log "Patching iBSS/iBEC..."
  local t_ibss t_ibec b_ibss b_ibec
  t_ibss="$(find_one tmp1/Firmware/dfu 'iBSS.n61*')"; t_ibec="$(find_one tmp1/Firmware/dfu 'iBEC.n61*')"
  b_ibss="$(find_one tmp2/Firmware/dfu 'iBSS.n61*')"; b_ibec="$(find_one tmp2/Firmware/dfu 'iBEC.n61*')"
  [[ -n "$t_ibss" && -n "$t_ibec" && -n "$b_ibss" && -n "$b_ibec" ]] || die "iBSS/iBEC not found in Firmware/dfu."
  ./bin/img4 -i "$t_ibss" -o work/iBSS.dec -k "$KEY_IBSS"
  ./bin/img4 -i "$t_ibec" -o work/iBEC.dec -k "$KEY_IBEC"
  ./bin/ipatcher work/iBSS.dec work/iBSS.patched
  ./bin/ipatcher work/iBEC.dec work/iBEC.patched -b "$RESTORE_BOOTARGS"
  ./bin/img4 -i work/iBSS.patched -o "$b_ibss" -A -T ibss
  ./bin/img4 -i work/iBEC.patched -o "$b_ibec" -A -T ibec

  # ---- kernelcache ----
  log "Patching kernelcache..."
  local t_kc b_kc
  t_kc="$(find_one tmp1 'kernelcache.release.n61*')"; b_kc="$(find_one tmp2 'kernelcache.release.n61*')"
  [[ -n "$t_kc" && -n "$b_kc" ]] || die "kernelcache not found."
  ./bin/img4 -i "$t_kc" -o work/kcache.raw -k "$KEY_KRNL"
  ./bin/img4 -i "$t_kc" -o work/kcache.im4p -k "$KEY_KRNL" -D
  ./bin/Kernel64Patcher2 work/kcache.raw work/kcache.patched -u 8 -t -p -e 8 -f 8 -a -m 8 -g -s -d
  ./bin/kerneldiff work/kcache.raw work/kcache.patched work/kcache.bpatch
  ./bin/img4 -i work/kcache.im4p -o "$b_kc" -T rkrn -P work/kcache.bpatch -J || true

  log "Packaging IPSW..."
  rm -f "$savedir/custom.ipsw"
  ( cd tmp2 && zip -0 -r -q "$ROOT/$savedir/custom.ipsw" . )
  rm -rf work tmp1 tmp2 asr asr_patch restored_external restored_patch ents.plist
  ok "IPSW ready: $savedir/custom.ipsw"
  log "Next: $0 --restore $ver"
}

# ----------------------------------------------------------------------------
# Command: restore
# ----------------------------------------------------------------------------
cmd_restore() {
  local ver="${1:-$TARGET_DEFAULT}" savedir
  savedir="noseprestore/$IDENTIFIER/$ver"
  [[ -f "$savedir/custom.ipsw" ]] || die "No $savedir/custom.ipsw - run --ipsw first."
  detect_device

  log "Saving SHSH blobs for $LATEST_VERSION (used for tethered boot)..."
  rm -rf shsh; mkdir -p shsh
  as_root "$ROOT/bin/tsschecker" -d "$IDENTIFIER" -B "$BOARD" -s -e "$ECID_DEC" -i "$LATEST_VERSION" --save-path shsh || true
  [[ -n "$(find shsh -type f -name '*.shsh2' 2>/dev/null | head -n 1)" ]] ||
    die "No SHSH saved. Is $LATEST_VERSION still signed for iPhone 6 and are you online?"

  pwn_device
  start_usbmuxd                     # restore mode needs usbmuxd again
  log "Restoring (do not unplug)..."
  as_root "$ROOT/bin/idevicerestore" -e "$savedir/custom.ipsw" -y
  ok "Restore finished. NEXT: $0 --fix-ios8   then   $0 boot $ver"
}

# ----------------------------------------------------------------------------
# Command: fix-ios8 (dyld + Setup.app + no sleep) over SSH ramdisk
# ----------------------------------------------------------------------------
cmd_fix_ios8() {
  warn "Boot an SSH ramdisk first (e.g. Legacy iOS Kit) and expose it on localhost:$SSH_PORT."
  if command -v iproxy >/dev/null 2>&1 && ! (exec 3<>"/dev/tcp/127.0.0.1/$SSH_PORT") 2>/dev/null; then
    log "Starting iproxy $SSH_PORT 22..."
    (iproxy "$SSH_PORT" 22 >/dev/null 2>&1 &)
    sleep 2
  fi
  read -r -p "Press Enter when the ramdisk is booted and ready... " _

  local sshc=("$ROOT/bin/sshpass" -p alpine ssh -p "$SSH_PORT" "${SSH_OPTS[@]}" root@127.0.0.1)
  local scpc=("$ROOT/bin/sshpass" -p alpine scp -P "$SSH_PORT" "${SSH_OPTS[@]}")

  "${sshc[@]}" "/sbin/mount_hfs /dev/disk0s1s1 /mnt1 || true"
  "${sshc[@]}" "/sbin/mount_hfs /dev/disk0s1s2 /mnt2 || true"

  log "Patching dyld shared cache..."
  "${scpc[@]}" "root@127.0.0.1:/mnt1/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64" dyld.raw
  ./bin/dsc64patcher dyld.raw dyld.patched -8
  "${scpc[@]}" dyld.patched "root@127.0.0.1:/mnt1/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64"
  rm -f dyld.raw dyld.patched

  log "Deleting Setup.app..."
  "${sshc[@]}" "rm -rf /mnt1/Applications/Setup.app" || warn "Could not delete Setup.app."

  log "Disabling auto-lock/sleep..."
  local tmp; tmp="$(mktemp)"; write_nosleep_plist "$tmp"
  "${sshc[@]}" "mkdir -p /mnt2/mobile/Library/Preferences /mnt1/private/var/mobile/Library/Preferences" || true
  "${scpc[@]}" "$tmp" "root@127.0.0.1:/mnt2/mobile/Library/Preferences/com.apple.springboard.plist" || warn "Could not write prefs to /mnt2."
  "${scpc[@]}" "$tmp" "root@127.0.0.1:/mnt1/private/var/mobile/Library/Preferences/com.apple.springboard.plist" || true
  "${sshc[@]}" "chown 501:501 /mnt2/mobile/Library/Preferences/com.apple.springboard.plist; chmod 644 /mnt2/mobile/Library/Preferences/com.apple.springboard.plist" || true
  rm -f "$tmp"

  "${sshc[@]}" "/sbin/reboot || true" || true
  ok "Done. Now tethered boot: $0 boot"
}

# ----------------------------------------------------------------------------
# Command: tethered boot
# ----------------------------------------------------------------------------
cmd_boot() {
  local ver="${1:-$TARGET_DEFAULT}" ipsw_arg="${2:-}" savedir
  savedir="seprmvr64boot/$IDENTIFIER/$ver"
  local shsh; shsh="$(find shsh -type f -name '*.shsh2' 2>/dev/null | head -n 1 || true)"
  [[ -n "$shsh" ]] || die "No SHSH in ./shsh - run --restore once first (it saves them)."

  if [[ ! -f "$savedir/iBSS.img4" || ! -f "$savedir/iBEC.img4" || ! -f "$savedir/DeviceTree.img4" || ! -f "$savedir/Kernelcache.img4" ]]; then
    local ipsw; ipsw="$(pick_ipsw "$ipsw_arg" "$ver")"
    load_keys "$ver" ibss ibec dtre krnl
    rm -rf "$savedir" work tmp1
    mkdir -p "$savedir" work tmp1
    log "Building boot files from the IPSW..."
    unzip -q "$ipsw" -d tmp1
    ./bin/img4tool -s "$shsh" -e -m work/im4m

    local dt ibss ibec kc
    dt="$(find_one tmp1/Firmware/all_flash "DeviceTree.$BOARD.im4p")"
    ibss="$(find_one tmp1/Firmware/dfu 'iBSS.n61*')"; ibec="$(find_one tmp1/Firmware/dfu 'iBEC.n61*')"
    kc="$(find_one tmp1 'kernelcache.release.n61*')"
    [[ -n "$dt" && -n "$ibss" && -n "$ibec" && -n "$kc" ]] || die "Boot components not found in that IPSW (is it the iPhone 6 $ver IPSW?)."

    ./bin/img4 -i "$dt" -o work/dtre.raw -k "$KEY_DTRE"
    ./bin/img4 -i work/dtre.raw -o "$savedir/DeviceTree.img4" -A -T rdtr -M work/im4m
    ./bin/img4 -i "$ibss" -o work/iBSS.dec -k "$KEY_IBSS"
    ./bin/img4 -i "$ibec" -o work/iBEC.dec -k "$KEY_IBEC"
    ./bin/ipatcher work/iBSS.dec work/iBSS.patched
    ./bin/ipatcher work/iBEC.dec work/iBEC.patched -b "$BOOT_BOOTARGS"
    ./bin/img4 -i work/iBSS.patched -o "$savedir/iBSS.img4" -A -T ibss -M work/im4m
    ./bin/img4 -i work/iBEC.patched -o "$savedir/iBEC.img4" -A -T ibec -M work/im4m
    ./bin/img4 -i "$kc" -o work/kcache.raw -k "$KEY_KRNL"
    ./bin/img4 -i "$kc" -o work/kcache.im4p -k "$KEY_KRNL" -D
    ./bin/Kernel64Patcher2 work/kcache.raw work/kcache.patched -u 8 -t -p -e 8 -f 8 -a -m 8 -g -s -d
    ./bin/kerneldiff work/kcache.raw work/kcache.patched work/kcache.bpatch
    ./bin/img4 -i work/kcache.im4p -o "$savedir/Kernelcache.img4" -T rkrn -P work/kcache.bpatch -J -M work/im4m || true
    rm -rf work tmp1
  fi

  pwn_device
  log "Sending boot chain..."
  irec_try -f "$savedir/iBSS.img4";        sleep 2
  irec_try -f "$savedir/iBEC.img4";        sleep 1
  if [[ -z "${SKIP_GO:-}" ]]; then irec_try -c go; fi
  sleep 3
  irec_try -f "$savedir/DeviceTree.img4"
  irec_try -c devicetree
  irec_try -f "$savedir/Kernelcache.img4"
  irec_try -c bootx
  ok "Booting. Do NOT lock the phone (auto-lock is already set to Never)."
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
  [[ $# -gt 0 ]] || { usage; exit 1; }
  echo "iPhone6Tether8.0 - $CURRENT_VERSION"
  echo "Tethered downgrader strictly for the iPhone 6 ($IDENTIFIER) -> iOS $TARGET_DEFAULT"
  echo
  case "$1" in -h|--help) usage; exit 0 ;; esac
  check_env
  log "sudo is needed for USB access."
  sudo -v || die "sudo required."

  local cmd="$1"; shift
  case "$cmd" in
    --ipsw|--seprmvr64-ipsw)        cmd_ipsw "$@" ;;
    --restore|--seprmvr64-restore)  cmd_restore "$@" ;;
    --fix-ios8)                     cmd_fix_ios8 ;;
    boot|--boot|--seprmvr64-boot)   cmd_boot "$@" ;;
    *) warn "Unknown command: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
