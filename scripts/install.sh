#!/usr/bin/env bash
# bluetooth_2_usb — Production-grade installer (no dry-run)
set -Eeu
IFS=$'\n\t'

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info(){ printf "${BLUE}ℹ %s${NC}\n" "$*"; }
ok(){ printf "${GREEN}✓ %s${NC}\n" "$*"; }
warn(){ printf "${YELLOW}⚠ %s${NC}\n" "$*"; }
fail(){ printf "${RED}✖ %s${NC}\n" "$*"; exit 1; }

REPO_URL="https://github.com/quaxalber/bluetooth_2_usb.git"
REPO_BRANCH="main"
INSTALL_DIR="/opt/bluetooth_2_usb"
LOG_DIR="/var/log/bluetooth_2_usb"
VENV_DIR="${INSTALL_DIR}/venv"
NO_REBOOT=0
SKIP_CLONE=0
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO_URL="$2"; shift 2;;
    --branch) REPO_BRANCH="$2"; shift 2;;
    --dir) INSTALL_DIR="$2"; VENV_DIR="${INSTALL_DIR}/venv"; shift 2;;
    --no-reboot) NO_REBOOT=1; shift;;
    --skip-clone) SKIP_CLONE=1; shift;;
    --force) FORCE=1; shift;;
    -h|--help)
      cat <<'EOF'
Usage: sudo ./install.sh [options]
  --repo <url>     Git repository (default: https://github.com/quaxalber/bluetooth_2_usb.git)
  --branch <name>  Branch/tag (default: main)
  --dir </path>    Install dir (default: /opt/bluetooth_2_usb)
  --no-reboot      Do not prompt to reboot
  --skip-clone     Only prepare system (no clone/venv)
  --force          Continue past soft warnings
EOF
      exit 0;;
    *) fail "Unknown option: $1";;
  esac
done

[[ $EUID -eq 0 ]] || fail "Run as root (sudo)."
mkdir -p "${LOG_DIR}"
exec > >(tee -a "${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log") 2>&1

need(){ command -v "$1" >/dev/null 2>&1 || fail "Missing dependency: $1"; }
need awk; need sed; need grep; need tr; need python3; need git

BOOT_DIR="/boot/firmware"; [[ -d "$BOOT_DIR" ]] || BOOT_DIR="/boot"
CONFIG_TXT="${BOOT_DIR}/config.txt"; CMDLINE_TXT="${BOOT_DIR}/cmdline.txt"

BOARD_MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || true)"
info "Detected model: ${BOLD}${BOARD_MODEL:-unknown}${NC}"

KC1="/boot/config-$(uname -r)"; KC2="/proc/config.gz"
CONFIG_STR=""
if [[ -f "$KC1" ]]; then CONFIG_STR="$(grep -E '^(CONFIG_USB_DWC2|CONFIG_USB_DWC3|CONFIG_USB_LIBCOMPOSITE)=' "$KC1" || true)"
elif [[ -f "$KC2" ]]; then CONFIG_STR="$(zcat "$KC2" 2>/dev/null | grep -E '^(CONFIG_USB_DWC2|CONFIG_USB_DWC3|CONFIG_USB_LIBCOMPOSITE)=' || true)"; fi
echo "$CONFIG_STR" | sed 's/^/  /'

has_dwc2_builtin=0; has_dwc2_module=0
grep -q '^CONFIG_USB_DWC2=y' <<<"$CONFIG_STR" && has_dwc2_builtin=1
grep -q '^CONFIG_USB_DWC2=m' <<<"$CONFIG_STR" && has_dwc2_module=1

UDC_NOW="$(ls /sys/class/udc 2>/dev/null || true)"
[[ -n "$UDC_NOW" ]] && ok "UDC present: $(echo "$UDC_NOW" | tr '\n' ' ')" || warn "No UDC visible yet (expected pre-reboot)."

needs_dr_mode=0
case "$BOARD_MODEL" in *"Raspberry Pi 4"*|*"Raspberry Pi 5"*) needs_dr_mode=1;; esac
OVERLAY_LINE="dtoverlay=dwc2"; [[ $needs_dr_mode -eq 1 ]] && OVERLAY_LINE="dtoverlay=dwc2,dr_mode=peripheral"

backup(){ [[ -f "$1" ]] && cp -a "$1" "$1.bak.$(date +%Y%m%d_%H%M%S)" && info "Backup: $1 -> $1.bak.*"; }

inplace_subst(){ python3 - "$@" <<'PY'
import io,re,sys
fn,pat,rep=sys.argv[1:4]
data=open(fn,'r',encoding='utf-8',errors='ignore').read()
new,n=re.subn(pat,rep,data,flags=re.M|re.S)
open(fn,'w',encoding='utf-8').write(new) if n else None
print(f"replaced={n}")
PY
}

info "Updating ${CONFIG_TXT} and ${CMDLINE_TXT}…"
[[ -f "$CONFIG_TXT" ]] || fail "Missing $CONFIG_TXT"; [[ -f "$CMDLINE_TXT" ]] || fail "Missing $CMDLINE_TXT"; backup "$CONFIG_TXT"; backup "$CMDLINE_TXT";

if grep -qE '^\s*dtoverlay=dwc2' "$CONFIG_TXT"; then
  inplace_subst "$CONFIG_TXT" '^[[:space:]]*dtoverlay=dwc2.*$' "$OVERLAY_LINE"
  ok "Normalized existing dwc2 overlay"
else
  if grep -q '^\[all\]' "$CONFIG_TXT"; then
    awk -v line="$OVERLAY_LINE" 'BEGIN{d=0}{print} /^\[all\]$/ && !d {print line; d=1} END{if(!d) print line}' "$CONFIG_TXT" > "${CONFIG_TXT}.tmp" && mv "${CONFIG_TXT}.tmp" "$CONFIG_TXT"
  else echo "$OVERLAY_LINE" >> "$CONFIG_TXT"; fi
  ok "Inserted overlay"
fi

modules_to_add="libcomposite"; [[ $has_dwc2_module -eq 1 ]] && modules_to_add="dwc2,libcomposite"
if grep -q 'modules-load=' "$CMDLINE_TXT"; then
  inplace_subst "$CMDLINE_TXT" 'modules-load=[^ ]+' "modules-load=${modules_to_add}"; ok "Normalized modules-load"
else
  cmd="$(cat "$CMDLINE_TXT")"; new="$(sed -E 's@\broot=[^ ]+@& modules-load='"${modules_to_add}"'@' <<<"$cmd")"
  [[ "$new" == "$cmd" ]] && new="$cmd modules-load=${modules_to_add}"
  echo "$new" > "$CMDLINE_TXT"; ok "Inserted modules-load"
fi

[[ $needs_dr_mode -eq 1 ]] && { warn "Pi 4/5: use USB-C DATA cable; power separately."; }

if [[ $SKIP_CLONE -eq 0 ]]; then
  info "Setting up repo at ${INSTALL_DIR}…"
  apt-get update -y
  apt-get install -y --no-install-recommends python3-venv python3-pip git
  mkdir -p "$(dirname "$INSTALL_DIR")"
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    git -C "$INSTALL_DIR" fetch --all --tags
    git -C "$INSTALL_DIR" checkout "$REPO_BRANCH"
    git -C "$INSTALL_DIR" pull --ff-only
  else
    rm -rf "$INSTALL_DIR"
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"
  fi
  python3 -m venv "$VENV_DIR"
  source "$VENV_DIR/bin/activate"
  pip install --upgrade pip wheel setuptools
  if [[ -f "$INSTALL_DIR/requirements.txt" ]]; then pip install -r "$INSTALL_DIR/requirements.txt"; else warn "requirements.txt missing"; fi
  ok "Virtualenv ready at $VENV_DIR"
else info "Skip clone as requested."; fi

cat <<EOF

${BOLD}Next steps${NC}
1) Reboot to activate bootloader changes.
2) After reboot, verify:
     ls /sys/class/udc
     systemctl status bluetooth_2_usb.service --no-pager || true
3) For Ethernet gadgets, you may need:
     sudo ip link set usb0 up
EOF

if [[ $NO_REBOOT -eq 0 ]]; then
  read -rp "Reboot now? [y/N] " ans; [[ "${ans,,}" == "y" ]] && { sync; reboot; } || warn "Reboot manually to apply changes."
fi

ok "Installation completed."
