#!/usr/bin/env bash
# bluetooth_2_usb — Smoke Test
set -Eeu
IFS=$'\n\t'

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
pass(){ printf "${GREEN}✓ %s${NC}\n" "$*"; }
fail(){ printf "${RED}✖ %s${NC}\n" "$*"; exit 1; }
info(){ printf "${BLUE}ℹ %s${NC}\n" "$*"; }
warn(){ printf "${YELLOW}⚠ %s${NC}\n" "$*"; }

SERVICE_NAME="bluetooth_2_usb";
INSTALL_DIR="/opt/bluetooth_2_usb";
VENV_DIR="/opt/bluetooth_2_usb/venv";
VERBOSE=0;
EXIT_CODE=0

while [[ $# -gt 0 ]]; do
case "$1" in
    --service) SERVICE_NAME="$2"; shift 2;;
    --dir) INSTALL_DIR="$2"; shift 2;;
    --venv) VENV_DIR="$2"; shift 2;;
    --verbose) VERBOSE=1; shift;;
    -h|--help)
    cat <<EOF
Usage: sudo bash smoke_test.sh [--service bluetooth_2_usb] [--dir /opt/bluetooth_2_usb] [--venv /opt/bluetooth_2_usb/venv] [--verbose]
EOF
      exit 0;;
    *) fail "Unknown option: $1";;
  esac
done

BOOT_DIR="/boot/firmware";
[[ -d "$BOOT_DIR" ]] || BOOT_DIR="/boot"; CONFIG_TXT="${BOOT_DIR}/config.txt"; CMDLINE_TXT="${BOOT_DIR}/cmdline.txt"
LOG_DIR="/var/log/bluetooth_2_usb";
mkdir -p "$LOG_DIR"; REPORT="${LOG_DIR}/smoke_$(date +%Y%m%d_%H%M%S).txt"
exec > >(tee -a "$REPORT") 2>&1

MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"; KERNEL="$(uname -a)"
info "Model: ${MODEL:-unknown}"; info "Kernel: $KERNEL"

if [[ -f "$CONFIG_TXT" ]] && grep -qE '^\s*dtoverlay=dwc2' "$CONFIG_TXT"; then pass "config.txt: dtoverlay=dwc2 present"; else warn "config.txt: dwc2 overlay missing"; EXIT_CODE=1; fi
if [[ -f "$CMDLINE_TXT" ]]; then
  if grep -q 'modules-load=' "$CMDLINE_TXT"; then ML="$(grep -o 'modules-load=[^ ]*' "$CMDLINE_TXT" | head -1)"; info "cmdline: ${ML}"; pass "cmdline.txt: modules-load present"
  else warn "cmdline.txt: modules-load missing"; EXIT_CODE=1; fi
else fail "Missing ${CMDLINE_TXT}"; EXIT_CODE=1; fi

UDC="$(ls /sys/class/udc 2>/dev/null || true)"; [[ -n "$UDC" ]] && pass "UDC present: $(echo "$UDC" | tr '\n' ' ')" || { warn "No UDC visible"; EXIT_CODE=1; }
[[ -d /sys/kernel/config/usb_gadget ]] && pass "configfs gadget path exists" || { warn "configfs gadget path missing"; EXIT_CODE=1; }

if systemctl list-unit-files --type=service | grep -Fq "${SERVICE_NAME}.service"; then
  systemctl is-active --quiet "${SERVICE_NAME}.service" && pass "systemd: ${SERVICE_NAME}.service is active" || { warn "systemd: service not active"; EXIT_CODE=1; }
else warn "systemd: service not installed"; EXIT_CODE=1; fi

if [[ -d "$VENV_DIR" ]] && [[ -x "${VENV_DIR}/bin/python" ]]; then
  if "${VENV_DIR}/bin/python" -c "import bluetooth_2_usb" >/dev/null 2>&1; then pass "python: module importable"; else warn "python: module not importable"; EXIT_CODE=1; fi
else warn "venv missing or python missing"; EXIT_CODE=1; fi

if [[ $VERBOSE -eq 1 ]]; then
  info "----- Diagnostics (tail) -----"
  dmesg | egrep -i 'dwc2|gadget|udc' | tail -200 || true
  command -v systemctl >/dev/null 2>&1 && systemctl status "${SERVICE_NAME}.service" --no-pager || true
  command -v journalctl >/dev/null 2>&1 && journalctl -u "${SERVICE_NAME}.service" -n 100 --no-pager || true
fi

[[ $EXIT_CODE -eq 0 ]] && pass "Smoke test PASSED" || fail "Smoke test FAILED — see ${REPORT}"
exit $EXIT_CODE
