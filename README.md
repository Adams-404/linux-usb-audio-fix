# Linux USB Audio "Sticky Mixer" Fixer 🎧

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux-blue.svg)](https://kernel.org)
[![Shell: Bash](https://img.shields.io/badge/Language-Bash-green.svg)](https://www.gnu.org/software/bash/)

A lightweight, automated diagnostic and fix tool for a frustrating and notorious Linux audio bug: **USB Type-C earphones or DAC dongles are recognized and connected, media players show audio playing, but there is complete silence in the earphones.**

Tested on Fedora, Ubuntu, Debian, Arch Linux, openSUSE, and other modern distributions with PipeWire or PulseAudio.

---

## The Problem

You connect wired USB Type-C earphones (e.g. Huawei, Realtek, Samsung, KT0210, Yichip DAC) to your Linux laptop:
1. The desktop recognizes them immediately and switches output to the earphones.
2. Spotify, YouTube, or browser videos play normally (sound waves and progress bars moving).
3. **You hear absolute silence.**
4. You test the earphones on an Android phone or another device, and they work perfectly.

### Why Does This Happen?
Many USB Type-C audio DAC chips power on with their internal hardware volume register set to minimum (`-32513` or `-32768`, which represents **-128 dB / hardware silence**).

During initial connection, the Linux ALSA driver (`snd-usb-audio`) probes the volume control. Because the earphone firmware returns a constant initial read value, the Linux kernel's automatic heuristic mistakenly assumes the hardware mixer is broken and logs:
```text
usb 1-5: 9:0: sticky mixer values (-32768/-32513/1 => -32513), disabling
usb 1-5: check MIXER_GET_CUR_BROKEN if you believe the mixer is non-sticky
```
As a safety measure, ALSA disables the hardware volume mixer entirely. This traps the physical DAC chip in a permanent -128 dB hardware mute, even though digital audio is streaming over the USB cable!

---

## ⚡ Quick Start (One Command)

You can run the interactive fixer directly via curl:

```bash
curl -fsSL https://raw.githubusercontent.com/Adams-404/linux-usb-audio-fix/main/fix.sh | bash
```

Or clone the repository locally:

```bash
git clone https://github.com/Adams-404/linux-usb-audio-fix.git
cd linux-usb-audio-fix
chmod +x fix.sh
./fix.sh
```

---

## 🛠️ Usage & Options

```text
Usage:
  ./fix.sh [options]

Options:
  -c, --check          Inspect and diagnose USB audio devices without making changes
  -y, --yes            Automatically apply fixes without prompting for confirmation
  -r, --revert         Remove applied audio quirks and restore system default settings
  -d, --device VID:PID Manually specify target USB device VID:PID (e.g. 12d1:3a06)
      --install        Install 'usb-audio-fix' globally into /usr/local/bin
  -v, --verbose        Show detailed diagnostic and debugging output
  -h, --help           Display help message and exit
```

### 1. Diagnose without changing anything
```bash
./fix.sh --check
```
Scans all connected USB sound cards, checks kernel logs, and examines ALSA hardware mixer capabilities. If your device is suffering from the bug, it reports it clearly.

### 2. Auto-fix non-interactively
```bash
./fix.sh -y
```
Detects the affected device, saves the permanent `/etc/modprobe.d/` quirk, resets the USB device via sysfs (no reboot required), sets the volume to 70%, and plays a test sound.

### 3. Target a specific device
```bash
./fix.sh --device 12d1:3a06
```

### 4. Revert / Uninstall
```bash
./fix.sh --revert
```
Completely removes any generated configuration files and restores default Linux driver behavior.

---

## 🔒 Is The Fix Permanent?

**Yes.**
- **Survives Reboots:** The configuration is saved to `/etc/modprobe.d/usb-audio-quirk.conf`. Whenever your machine boots or a USB device is plugged in, `systemd-udevd` automatically loads the quirk before the DAC initializes.
- **Survives Kernel Updates:** `/etc/` contains system-level configuration managed by the system administrator. Package managers (`dnf`, `apt`, `pacman`) do not touch these files during kernel upgrades.
- **Hardware-Specific:** The quirk strictly binds to the exact `VID:PID` (Vendor and Product ID) of the affected device, leaving your laptop speakers, Bluetooth headsets, and other audio interfaces completely unaffected.

---

## 📋 Manual Fix Steps

If you prefer applying the fix manually without running the script:

1. Identify your device's Vendor ID and Product ID:
   ```bash
   lsusb | grep -i audio
   # Example output: Bus 001 Device 010: ID 12d1:3a06 Huawei Technologies Co., Ltd. USB-Audio
   ```
2. Create `/etc/modprobe.d/usb-audio-quirk.conf`:
   ```bash
   sudo sh -c 'echo "options snd-usb-audio quirk_flags=12d1:3a06:0x40000000" > /etc/modprobe.d/usb-audio-quirk.conf'
   ```
   *(Replace `12d1:3a06` with your actual device IDs; `0x40000000` is the hex bitmask for `MIXER_GET_CUR_BROKEN`).*
3. Unplug and replug your earphones (or re-authorize the USB port via sysfs).
4. Unmute and set your volume in your audio mixer settings.

---

## License

This project is licensed under the [MIT License](LICENSE).
