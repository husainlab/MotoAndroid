# Cockpit OS (Motorola Moto G52 // rhode)

[![Build & Release OS](https://github.com/husainlab/MotoAndroid/actions/workflows/build-cockpit.yml/badge.svg)](https://github.com/husainlab/MotoAndroid/actions/workflows/build-cockpit.yml)
[![Target Device](https://img.shields.io/badge/Device-Moto%20G52%20(rhode)-FF5A1F)](https://wiki.lineageos.org/devices/rhode/)
[![Base](https://img.shields.io/badge/Base-LineageOS%2021-00E575)](https://github.com/LineageOS/android)

An automated, ultra-lean, single-purpose Android cockpit appliance operating system designed specifically for the **Motorola Moto G52 (`rhode`)** motorcycle handlebar mount, powered by **Cockpit** and live navigation.

---

## Key Hardware & OS Optimizations

* **AMOLED 60Hz Lock:** Hardcoded in framework overlay and SurfaceFlinger (`config_defaultPeakRefreshRate = 60`). Eliminates 90Hz display controller thermal spikes and saves ~18–22% battery in direct sunlight.
* **3GB `zstd` ZRAM:** Replaced standard `lz4` with `zstd` (3.2:1 compression ratio) and set ZRAM disk size to 75% in `fstab.qcom` and `init.mmi.rc`. Over 2.8 GB of clean, free physical RAM for Google Maps and Cockpit.
* **Embedded Cockpit System Appliance:** Automatically injects the latest signed release of Cockpit into `/system/priv-app/Cockpit/` with platform permissions pre-whitelisted (`privapp-permissions-cockpit.xml`). No manual "Draw over other apps" or background location prompts on first boot.
* **Wi-Fi & Bluetooth-Only Appliance:** Disabled cellular baseband searching (`ro.radio.noril=yes`, `ro.carrier=wifi-only`). Radio modem DSP sleeps permanently, eliminating cell tower polling battery drain.
* **Aggressive Debloat:** Stripped Aperture camera, Eleven music, Jelly browser, Calculator, Calendar, DeskClock, PrintSpooler, SIM Toolkit, and CellBroadcastReceiver.

---

## Flashing Instructions

### 1. Download Latest Release
Download the latest `MotoCockpit-OS-*.zip` from [GitHub Releases](https://github.com/husainlab/MotoAndroid/releases).

### 2. Flash via Fastboot
1. Extract the downloaded archive.
2. Put your Motorola Moto G52 into Fastboot mode:
   ```bash
   adb reboot bootloader
   ```
3. Run the one-click installer:
   * **Mac / Linux:**
     ```bash
     chmod +x flash-all.sh && ./flash-all.sh
     ```
   * **Windows:**
     Double click `flash-all.bat`.

---

## Automated GitHub Actions Pipeline

This repository uses automated **ROM Image Reshaping** inside `.github/workflows/build-cockpit.yml`:
1. Fetches the latest signed base LineageOS build for `rhode`.
2. Extracts partition images via `payload-dumper-go`.
3. Prunes blacklisted bloatware from `system`, `product`, and `system_ext`.
4. Injects Cockpit, permissions whitelist, 60Hz overrides, and ZRAM properties.
5. Repacks partitions, packages the fastboot installer, and publishes a new GitHub Release in under 5 minutes.

