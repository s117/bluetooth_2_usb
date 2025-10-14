---
name: Bug report
about: Create a report to help us improve
title: "[Bug] Short, descriptive title"
labels: bug
assignees: ""
---

<!-- Thanks for filing a bug! -->

## ✅ Quick checklist
- [ ] I ran the smoke test:
  ```bash
  cd bluetooth_2_usb/scripts
  sudo bash smoke_test.sh --verbose
  ```
- [ ] I ran the debug collector and attached the generated Markdown file:
  ```bash
  cd bluetooth_2_usb/scripts
  sudo bash debug.sh --duration 10
  # Attach the path printed at the end (e.g. /var/log/bluetooth_2_usb/debug_YYYYMMDD_HHMMSS.md)
  ```

## 🧩 Summary
**Expected:**  
**Actual:**  
**Reproducible:** always / sometimes / once

## 📋 Environment
- Board model:
- Raspberry Pi OS (Bookworm/bitness):
- Kernel (`uname -a`):
- Target host (make/model/OS):
- Connection (USB-C data cable? separate power?):

## 🚶 Steps to reproduce
1. 
2. 
3. 

## 📎 Attachments
- Debug Markdown from `scripts/debug.sh` (required)
- Optional: photos, additional logs

## 📝 Notes
Anything else that could help us understand or reproduce the issue.
