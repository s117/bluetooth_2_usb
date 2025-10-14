#!/usr/bin/env bash
# bluetooth_2_usb — Debug Info Collector (GitHub Markdown)
set -Eeuo pipefail
IFS=$'\n\t'

SERVICE_NAME="bluetooth_2_usb"; INSTALL_DIR="/opt/bluetooth_2_usb"; VENV_DIR="/opt/bluetooth_2_usb/venv"; DURATION=10
LOG_DIR="/var/log/bluetooth_2_usb"; OUT="${LOG_DIR}/debug_$(date +%Y%m%d_%H%M%S).md"
while [[ $# -gt 0 ]]; do case "$1" in --service) SERVICE_NAME="$2"; shift 2;; --dir) INSTALL_DIR="$2"; shift 2;; --venv) VENV_DIR="$2"; shift 2;; --duration) DURATION="$2"; shift 2;; -h|--help) cat <<EOF
Usage: sudo bash debug.sh [--service bluetooth_2_usb] [--dir /opt/bluetooth_2_usb] [--venv /opt/bluetooth_2_usb/venv] [--duration 10]
EOF
exit 0;; *) echo "Unknown option: $1" >&2; exit 2;; esac; done
mkdir -p "$LOG_DIR"; BOOT_DIR="/boot/firmware"; [[ -d "$BOOT_DIR" ]] || BOOT_DIR="/boot"; CONFIG_TXT="${BOOT_DIR}/config.txt"; CMDLINE_TXT="${BOOT_DIR}/cmdline.txt"
has(){ command -v "$1" >/dev/null 2>&1; }; section(){ printf "\n## %s\n\n" "$1"; }; code(){ echo '```'; cat; echo '```'; }

{
echo "# bluetooth_2_usb — Debug Report"
echo; echo "_Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")_"; echo; echo "> _Attach this file to your GitHub issue._"

section "System"
echo "- **Model**:"; tr -d '\0' </proc/device-tree/model 2>/dev/null | sed 's/^/  /' | code
echo "- **Kernel**:"; uname -a | code
echo "- **Raspberry Pi OS release**:"; [[ -f /etc/os-release ]] && grep -E '^(PRETTY_NAME|VERSION|ID|VERSION_CODENAME)=' /etc/os-release | code || echo "_/etc/os-release not found_" | code

section "Boot configuration (relevant excerpts)"
echo "### config.txt (dwc2 overlay):"; [[ -f "$CONFIG_TXT" ]] && grep -E '^\s*(\[all\]|dtoverlay=dwc2.*)' -n "$CONFIG_TXT" | code || echo "_Missing: ${CONFIG_TXT}_" | code
echo "### cmdline.txt (modules-load):"; [[ -f "$CMDLINE_TXT" ]] && cat "$CMDLINE_TXT" | sed 's/$/\n/' | code || echo "_Missing: ${CMDLINE_TXT}_" | code

section "USB Gadget readiness"
echo "### UDC presence:"; (ls /sys/class/udc 2>/dev/null || true) | code
echo "### configfs path:"; [[ -d /sys/kernel/config/usb_gadget ]] && echo "/sys/kernel/config/usb_gadget exists" | code || echo "/sys/kernel/config/usb_gadget MISSING" | code

section "Kernel modules (filtered)"; (lsmod | egrep '^(dwc2|libcomposite|g_[a-z]+)\b' || true) | code

section "Service status"
if has systemctl && systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
  echo "### systemctl is-active:"; (systemctl is-active "${SERVICE_NAME}.service" || true) | code
  echo "### systemctl status:"; (systemctl --no-pager --full status "${SERVICE_NAME}.service" || true) | code
  echo "### Recent journal (last 200 lines):"; has journalctl && (journalctl -u "${SERVICE_NAME}.service" -n 200 --no-pager || true) | code || echo "_journalctl not available_" | code
else echo "_Service ${SERVICE_NAME}.service not installed_" | code; fi

section "dmesg (filtered)"; (dmesg | egrep -i 'dwc2|gadget|udc' | tail -200 || true) | code

section "Python environment"
if [[ -x "${VENV_DIR}/bin/python" ]]; then
  echo "### Interpreter & pip"; ("${VENV_DIR}/bin/python" -V && "${VENV_DIR}/bin/pip" -V) | code
  echo "### Package import check"
  if "${VENV_DIR}/bin/python" - <<'PY' >/dev/null 2>&1; then
import importlib; print(bool(importlib.util.find_spec("bluetooth_2_usb")))
PY
  then echo "bluetooth_2_usb importable: true" | code; else echo "bluetooth_2_usb importable: false" | code; fi
else echo "_Venv not found at ${VENV_DIR}_" | code; fi

section "App debug output (timed)"
TMP="$(mktemp)"
if [[ -x "${VENV_DIR}/bin/python" && -d "$INSTALL_DIR" ]]; then
  timeout "${DURATION}" "${VENV_DIR}/bin/python" -m bluetooth_2_usb --debug --no_bind >/dev/null 2>"${TMP}" || true
  [[ -s "${TMP}" ]] || timeout "${DURATION}" "${VENV_DIR}/bin/python" -m bluetooth_2_usb --debug --dry-run >/dev/null 2>"${TMP}" || true
  [[ -s "${TMP}" ]] || timeout "${DURATION}" "${VENV_DIR}/bin/python" -m bluetooth_2_usb --debug >/dev/null 2>"${TMP}" || true
  (echo "_Captured for ${DURATION}s (stderr)_" && cat "${TMP}") | code
  rm -f "${TMP}"
else echo "_Skipped (venv or install dir missing)_" | code; fi

section "How to reproduce"
cat <<'REPRO' | code
Please describe:
1) Exact board model and target host
2) Cable/port used (USB-C data? separate power?)
3) Steps to reproduce
4) What you expected to happen
5) What actually happened
REPRO

} | tee "$OUT" >/dev/null

echo "Wrote: $OUT"
echo "Attach this file to your GitHub issue."
