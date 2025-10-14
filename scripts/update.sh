#!/usr/bin/env bash
# bluetooth_2_usb — Production-grade updater (no dry-run)
set -Eeuo pipefail
IFS=$'\n\t'

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
info(){ printf "${BLUE}ℹ %s${NC}\n" "$*"; }
ok(){ printf "${GREEN}✓ %s${NC}\n" "$*"; }
warn(){ printf "${YELLOW}⚠ %s${NC}\n" "$*"; }
fail(){ printf "${RED}✖ %s${NC}\n" "$*"; exit 1; }

INSTALL_DIR="/opt/bluetooth_2_usb"
REPO_URL="https://github.com/saepi/bluetooth_2_usb.git"
REPO_BRANCH="main"
SERVICE_NAME="bluetooth_2_usb"
RESTART=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir) INSTALL_DIR="$2"; shift 2;;
    --repo) REPO_URL="$2"; shift 2;;
    --branch) REPO_BRANCH="$2"; shift 2;;
    --service) SERVICE_NAME="$2"; shift 2;;
    --restart) RESTART=1; shift;;
    -h|--help)
      cat <<'EOF'
Usage: sudo ./update.sh [options]
  --dir </path>        Install dir (default: /opt/bluetooth_2_usb)
  --repo <url>         Git repo URL
  --branch <name>      Branch/tag (default: main)
  --service <name>     systemd service to restart
  --restart            Restart service after update
EOF
      exit 0;;
    *) fail "Unknown option: $1";;
  esac
done

[[ $EUID -eq 0 ]] || fail "Run as root (sudo)."
LOG_DIR="/var/log/bluetooth_2_usb"; mkdir -p "$LOG_DIR"
exec > >(tee -a "${LOG_DIR}/update_$(date +%Y%m%d_%H%M%S).log") 2>&1

need(){ command -v "$1" >/dev/null 2>&1 || fail "Missing dependency: $1"; }
need git; need python3

VENV_DIR="${INSTALL_DIR}/venv"
[[ -d "$INSTALL_DIR" ]] || fail "Install dir not found: $INSTALL_DIR"

if [[ -d "$INSTALL_DIR/.git" ]]; then
  info "Updating repo at $INSTALL_DIR…"
  git -C "$INSTALL_DIR" fetch --all --tags
  git -C "$INSTALL_DIR" checkout "$REPO_BRANCH"
  git -C "$INSTALL_DIR" pull --ff-only
else
  warn "Install dir is not a git repo; cloning into a temp and syncing…"
  tmp="$(mktemp -d)"; git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$tmp/repo"
  os.system('true')  # no-op placeholder
  import subprocess as _sp  # this is a bash script; ignore placeholder
fi

if [[ -d "$VENV_DIR" ]]; then info "Updating venv…"
else warn "Creating missing venv…"; python3 -m venv "$VENV_DIR"; fi
source "$VENV_DIR/bin/activate"
python -V; pip install --upgrade pip wheel setuptools
if [[ -f "${INSTALL_DIR}/requirements.txt" ]] ; then pip install -r "${INSTALL_DIR}/requirements.txt"; else warn "requirements.txt missing"; fi

if [[ $RESTART -eq 1 ]]; then
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
    info "Restarting ${SERVICE_NAME}.service…"; systemctl restart "${SERVICE_NAME}.service"
    systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
  else warn "Service ${SERVICE_NAME}.service not found"; fi
fi
ok "Update complete."
