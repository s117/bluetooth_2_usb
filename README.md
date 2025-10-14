<!-- omit in toc -->
<p align="center">
  <img src="https://raw.githubusercontent.com/quaxalber/bluetooth_2_usb/main/assets/overview.png" alt="Bluetooth to USB overview" width="720">
</p>

<h1 align="center">Bluetooth → USB (HID Relay for Raspberry&nbsp;Pi)</h1>

<p align="center">
  Translate Bluetooth keyboard/mouse input to USB HID, so any host sees a wired keyboard/mouse — even in BIOS, boot menus, and pre‑OS environments.
</p>

<p align="center">
  <a href="#-features">Features</a> ·
  <a href="#-supported-hardware--os">Support Matrix</a> ·
  <a href="#-quick-start">Quick Start</a> ·
  <a href="#-usage">Usage</a> ·
  <a href="#-smoke-test">Smoke Test</a> ·
  <a href="#-troubleshooting">Troubleshooting</a> ·
  <a href="#-reporting-issues">Reporting Issues</a> ·
  <a href="#-systemd-service">Systemd</a>
</p>

---

## ✨ Features

- **One‑command setup** with a production‑grade installer (Bookworm paths, OTG on Pi 4/5, `dwc2` built‑in vs. module, safe backups).
- **Works before the OS** on the target: BIOS/UEFI, boot menus, password prompts — the host sees a standard USB HID.
- **Multiple devices** (keyboard + mouse, multimedia keys), auto‑discover, auto‑reconnect.
- **Service‑first**: systemd unit, structured logs in `/var/log/bluetooth_2_usb/`, Python 3.11+ venv.
- **Idempotent & robust**: re‑runs cleanly, won’t duplicate config, explains what it changed.

## ✅ Supported Hardware & OS

| Board | OTG Port | Notes |
|---|---|---|
| Raspberry Pi Zero / Zero W / Zero 2 W | micro‑USB **USB/OTG** | Power via the second port |
| Raspberry Pi 4B / 5 | **USB‑C (data)** only | Use a **data** cable; **power separately** while acting as device |
| Compute Module 4 | Depends on carrier | Carrier must expose USB2 OTG |
| Raspberry Pi 3A+ | micro‑USB | Limited but usable |

> Not supported: Pi 3B/3B+ (no device mode on available ports), older non‑OTG boards.  
> **OS:** Raspberry Pi OS **Bookworm** (32‑/64‑bit) • **Python:** 3.11+

---

## 🚀 Quick Start

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/quaxalber/bluetooth_2_usb.git
cd bluetooth_2_usb/scripts
sudo bash install.sh
sudo reboot
```

### Verify after reboot (or run the Smoke Test below)
```bash
ls /sys/class/udc
systemctl status bluetooth_2_usb.service --no-pager
```

Pair your Bluetooth keyboard/mouse on the Pi (Desktop GUI or `bluetoothctl`).

---

## 🧭 Usage

### Connect the Pi to the target host
- **Pi 4/5**: connect the **USB‑C** port to the host using a **data‑capable** cable. **Power the Pi separately** (GPIO/PoE/USB‑C splitter).  
- **Pi Zero / Zero 2 W**: use the **USB/OTG** port for data; power via the second port.

You should hear a USB connect chime on the host and be able to control it with your Bluetooth devices.

### Common CLI options
Run `bluetooth_2_usb -h` for the full list. Frequently used:

- `--auto_discover` — relay all readable input devices automatically.  
- `--grab_devices` — prevent the Pi from handling events locally.  
- `--interrupt_shortcut CTRL+SHIFT+F12` — toggle relaying on/off (useful to type locally on the Pi).

### Service management
```bash
# Logs
journalctl -u bluetooth_2_usb.service -f -n 100 --no-pager

# Restart / enable at boot
sudo systemctl restart bluetooth_2_usb.service
sudo systemctl enable bluetooth_2_usb.service
```

---

## 🔄 Update
```bash
cd bluetooth_2_usb/scripts
sudo bash update.sh --restart
```
- Pulls the latest code (or refreshes a non‑git tree atomically), updates the venv, and restarts the service (optional).

## 🧹 Uninstall
```bash
cd bluetooth_2_usb/scripts
sudo bash uninstall.sh --purge --revert-boot
```
- Stops & disables the service, unbinds the gadget from configfs, optionally removes the install dir (`--purge`) and reverts boot config (`--revert-boot`).

---

## ✅ Smoke Test

After a reboot, validate your setup end‑to‑end:
```bash
cd bluetooth_2_usb/scripts
sudo bash smoke_test.sh --verbose
```
- Verifies **overlay** and **modules‑load** in the correct boot files.
- Checks for a **UDC**, presence of **configfs**, and **service** health.
- Confirms the **Python venv** exists and the package is **importable**.
- Writes a detailed report to `/var/log/bluetooth_2_usb/smoke_*.txt` and exits non‑zero on failures.

---

## 🛠 Troubleshooting

If the **Smoke Test** reports failures, use the quick checks below to pinpoint the issue.

### 1) Quick manual checks (if the Smoke Test failed)
```bash
ls /sys/class/udc                          # → controller name (e.g. fe980000.usb)
systemctl status bluetooth_2_usb.service   # → active (running)
grep -E '^\s*dtoverlay=dwc2' /boot/firmware/config.txt 2>/dev/null || grep -E '^\s*dtoverlay=dwc2' /boot/config.txt
cat /proc/cmdline                          # → modules-load=libcomposite (and dwc2 if it’s a module)
dmesg | egrep -i 'dwc2|gadget|udc' | tail -200
```

### 2) Pi 4/5 specifics
- Gadget mode works **only** on **USB‑C**. Use a **data** cable.  
- **Power separately** while the Pi acts as a device on the host.

### 3) `ls /sys/class/udc` is empty
- Reboot; ensure `dtoverlay=dwc2` (Pi 4/5: `dtoverlay=dwc2,dr_mode=peripheral`) in the correct `config.txt` (`/boot/firmware` on Bookworm).  
- Ensure `cmdline.txt` contains **one line**, with `modules-load=libcomposite` (and `dwc2` **only** if it’s a module).  
- Confirm `/boot` is writable; look for installer backups (`*.bak.*`).

### 4) Service runs, host doesn’t react
- Try another cable/host port; check host `dmesg`/Device Manager.  
- Remove legacy `g_*` modules: `sudo rmmod g_hid g_ether …`.  
- Confirm the service creates HID via configfs and **binds** to the UDC (see logs).

### 5) Bluetooth (pairing/connection)
```bash
bluetoothctl devices
bluetoothctl info <MAC>      # Connected: yes, Paired: yes, Trusted: yes
```
- If events are duplicated/missing: try `--grab_devices`.  
- For flaky links: trust devices and use `--auto_discover`.

### 6) configfs / libcomposite
```bash
ls /sys/kernel/config/usb_gadget || echo "configfs/gadget missing"
sudo modprobe libcomposite     # test only; installer handles this persistently
```

### 7) dwc2 module vs built‑in (this is **not** an error)
- Built‑in (`CONFIG_USB_DWC2=y`): no `/sys/module/dwc2`, `modprobe dwc2` fails — **expected**. A UDC must still appear.  
- Module (`=m`): the installer sets `modules-load=dwc2,libcomposite`; a UDC appears after reboot.

### 8) Power
Undervoltage causes reboots/disconnects. Use a proper PSU; do **not** power solely from a weak host port.

### 9) Known conflicts
- Old gadget services or udev rules creating devices concurrently.  
- Desktop environments grabbing input. → Run in **multi-user.target** or use `--grab_devices`.

---

## 🐞 Reporting Issues

**Recommended path:**
```bash
cd bluetooth_2_usb/scripts
sudo bash smoke_test.sh --verbose
sudo bash debug.sh --duration 10
# Attach the printed Markdown file (e.g. /var/log/bluetooth_2_usb/debug_YYYYMMDD_HHMMSS.md)
```

### Copying the debug report off the Pi (headless)

If your Pi has no GUI, you can copy the debug report to your computer via an SSH pipe:

```bash
# On your computer (macOS/Linux/Windows PowerShell with OpenSSH):
ssh pi@<PI-IP> 'sudo cat /var/log/bluetooth_2_usb/debug_*.md' > debug.md
```
- Replace `<PI-IP>` with the Pi’s address (e.g. `raspberrypi.local` or the IP from `hostname -I`).
- The wildcard (`debug_*.md`) expands **on the Pi**, so keep the command inside **single quotes**.
- The output is saved as `debug.md` on your computer, ready to attach to a GitHub issue.
- If the script printed a specific path (e.g. `/var/log/bluetooth_2_usb/debug_2025...md`), you can paste that exact path instead of the wildcard.

> If SSH isn’t enabled yet, run `sudo raspi-config nonint do_ssh 0` on the Pi (or place an empty file named `ssh` onto the boot partition and reboot).

### Alternative: Manual Diagnostic Bundle

If you prefer, or if the scripts aren’t available in your environment, you can share a short manual bundle. Each command echoes itself first so the output is self‑describing when pasted into an issue.

```bash
echo '$ uname -a'; uname -a
echo "$ tr -d '\0' </proc/device-tree/model"; tr -d ' ' </proc/device-tree/model

echo '$ grep -E "dwc2" /boot/firmware/config.txt || grep -E "dwc2" /boot/config.txt'
grep -E 'dwc2' /boot/firmware/config.txt 2>/dev/null || grep -E 'dwc2' /boot/config.txt

echo '$ cat /proc/cmdline'; cat /proc/cmdline

echo '$ ls /sys/class/udc'; ls /sys/class/udc

echo "$ lsmod | egrep 'dwc2|libcomposite|^g_'"
lsmod | egrep 'dwc2|libcomposite|^g_'

echo '$ journalctl -u bluetooth_2_usb.service -n 200 --no-pager'
journalctl -u bluetooth_2_usb.service -n 200 --no-pager

echo "$ dmesg | egrep -i 'dwc2|gadget|udc' | tail -200"
dmesg | egrep -i 'dwc2|gadget|udc' | tail -200
```

---

## 🧩 Systemd service

A ready‑to‑use service file is provided. Install it like this:

```bash
sudo cp bluetooth_2_usb.service /etc/systemd/system/bluetooth_2_usb.service
sudo systemctl daemon-reload
sudo systemctl enable --now bluetooth_2_usb.service
systemctl status bluetooth_2_usb.service --no-pager
```

Default command:
```bash
ExecStart=/opt/bluetooth_2_usb/venv/bin/python -m bluetooth_2_usb --auto_discover --grab_devices --interrupt_shortcut CTRL+SHIFT+F12
```

---

## 🤝 Contributing

PRs and issues welcome — please include the **debug report** from `scripts/debug.sh` where possible.  
Guidelines: **[CONTRIBUTING.md](CONTRIBUTING.md)**

---

## 🙏 Acknowledgments

- **heuristicperson** — this project was originally forked from their repository (only little of that code remains today, but the starting point was invaluable).  
  GitHub: https://github.com/heuristicperson
- **mikerr/pihidproxy** — for the seminal idea and early HID gadget logic.  
  Repo: https://github.com/mikerr/pihidproxy
- **gvalkov/python-evdev** — input event handling.  
  Repo: https://github.com/gvalkov/python-evdev
- **Adafruit** — CircuitPython HID and Blinka’s `usb_hid` port.  
  Org: https://github.com/adafruit

---

## 🧾 License

MIT. See `LICENSE`.
