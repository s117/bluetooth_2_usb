#!/usr/bin/env bash
# bluetooth_2_usb — Production-grade uninstaller (no dry-run)
set -Eeuo pipefail
IFS=$'\n\t'

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info(){ printf "${BLUE}ℹ %s${NC}\n" "$*"; }
ok(){ printf "${GREEN}✓ %s${NC}\n" "$*"; }
warn(){ printf "${YELLOW}⚠ %s${NC}\n" "$*"; }
fail(){ printf "${RED}✖ %s${NC}\n" "$*"; exit 1; }

INSTALL_DIR="/opt/bluetooth_2_usb"
SERVICE_NAME="bluetooth_2_usb"
NO_REBOOT=0
PURGE=0
REVERT_BOOT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_DIR="$2"; shift 2;;
    --service) SERVICE_NAME="$2"; shift 2;;
    --purge) PURGE=1; shift;;
    --revert-boot) REVERT_BOOT=1; shift;;
    --no-reboot) NO_REBOOT=1; shift;;
    -h|--help)
      cat <<'EOF'
Usage: sudo ./uninstall.sh [options]
  --dir </path>        Install dir (default: /opt/bluetooth_2_usb)
  --service <name>     systemd service name (default: bluetooth_2_usb)
  --purge              Remove install directory after unbinding
  --revert-boot        Remove dwc2 overlay and modules-load entries
  --no-reboot          Do not offer reboot
EOF
      exit 0;;
    *) fail "Unknown option: $1";;
  esac
done

[[ $EUID -eq 0 ]] || fail "Run as root (sudo)."
LOG_DIR="/var/log/bluetooth_2_usb"; mkdir -p "$LOG_DIR"
exec > >(tee -a "${LOG_DIR}/uninstall_$(date +%Y%m%d_%H%M%S).log") 2>&1

BOOT_DIR="/boot/firmware"; [[ -d "$BOOT_DIR" ]] || BOOT_DIR="/boot"
CONFIG_TXT="${BOOT_DIR}/config.txt"; CMDLINE_TXT="${BOOT_DIR}/cmdline.txt"
backup(){ [[ -f "$1" ]] && cp -a "$1" "$1.bak.$(date +%Y%m%d_%H%M%S)"; }
inplace_subst(){ python3 - "$@" <<'PY'
import io,re,sys
fn,pat,rep=sys.argv[1:4]
data=open(fn,'r',encoding='utf-8',errors='ignore').read()
new,n=re.subn(pat,rep,data,flags=re.M|re.S)
if n: open(fn,'w',encoding='utf-8').write(new)
print(n)
PY
}

# Stop/disable service
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
  info "Stopping ${SERVICE_NAME}.service…"
  systemctl stop "${SERVICE_NAME}.service" || true
  systemctl disable "${SERVICE_NAME}.service" || true
  systemctl daemon-reload || true
else info "No systemd service ${SERVICE_NAME}.service"; fi

# Unbind gadgets
if [[ -d /sys/kernel/config/usb_gadget ]]; then
  for g in /sys/kernel/config/usb_gadget/*; do
    [[ -d "$g" ]] || continue
    if [[ -f "$g/UDC" ]]; then UDC="$(cat "$g/UDC" || true)"; [[ -n "$UDC" ]] && echo > "$g/UDC" || true; fi
    find "$g/configs" -type l -exec rm -f {} + 2>/dev/null || true
    rm -rf "$g/functions/"* 2>/dev/null || true
    rmdir "$g/configs/"* 2>/dev/null || true
    rmdir "$g" 2>/dev/null || true
  done
else info "No configfs gadget directory present."; fi

# Purge install dir
if [[ $PURGE -eq 1 && -d "$INSTALL_DIR" ]]; then
  info "Purging ${INSTALL_DIR}"; rm -rf "$INSTALL_DIR"
fi

# Revert boot config
if [[ $REVERT_BOOT -eq 1 ]]; then
  info "Reverting boot configuration…"
  backup "$CONFIG_TXT"; backup "$CMDLINE_TXT"
  [[ -f "$CONFIG_TXT" ]] && inplace_subst "$CONFIG_TXT" '^[[:space:]]*dtoverlay=dwc2.*$' ''
  [[ -f "$CMDLINE_TXT" ]] && inplace_subst "$CMDLINE_TXT" '(^| )modules-load=[^ ]+' ' '
  ok "Boot config reverted."
fi

if [[ $NO_REBOOT -eq 0 ]]; then read -rp "Reboot now? [y/N] " ans; [[ "${ans,,}" == "y" ]] && { sync; reboot; }; fi
ok "Uninstall complete."
