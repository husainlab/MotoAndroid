# Cockpit OS & Companion App (Motorola Moto G52 // rhode)

[![Build & Release OS](https://github.com/husainlab/MotoAndroid/actions/workflows/build-cockpit.yml/badge.svg)](https://github.com/husainlab/MotoAndroid/actions/workflows/build-cockpit.yml)
[![Build Cockpit App](https://github.com/husainlab/MotoAndroid/actions/workflows/build-app.yml/badge.svg)](https://github.com/husainlab/MotoAndroid/actions/workflows/build-app.yml)
[![Target Device](https://img.shields.io/badge/Device-Moto%20G52%20(rhode)-FF5A1F)](https://wiki.lineageos.org/devices/rhode/)
[![Base](https://img.shields.io/badge/Base-LineageOS%2021-00E575)](https://github.com/LineageOS/android)

A unified repository containing both:
1. **MotoCockpit OS:** An automated, ultra-lean Android cockpit appliance operating system designed specifically for the **Motorola Moto G52 (`rhode`)** motorcycle handlebar mount, powered by **Cockpit** and live navigation.
2. **Cockpit Companion App (`cockpit/`):** The primary pocket phone Android application that relays media, notifications, call controls, battery/thermal watchdog alerts, and **automatic Bluetooth Internet (PAN tethering)** to the handlebar bike OS.

---

## Repository Structure

```
.
├── cockpit/                 # Primary phone Android companion app (Expo CNG / React Native)
│   ├── app/                 # Expo Router routes (Tabs, Phone, Alerts, Setup)
│   ├── modules/             # Native Kotlin modules (Bluetooth PAN, SPP server, Call/Notif)
│   ├── plugins/             # Continuous Native Generation (CNG) Android config plugins
│   └── src/                 # AMOLED-optimized UI, state, and test suites
├── config/                  # OS configs (debloat blacklist, privapp permissions, system props)
├── device/                  # LineageOS 21 device trees (rhode & sm6225-common)
├── scripts/                 # ROM image reshaper pipeline (payload extraction, debloat, repack)
└── .github/workflows/       # Automated CI/CD pipelines (OS image & signed release APK)
```

---

## Key Hardware & OS Optimizations (Moto G52)

* **AMOLED 60Hz Lock:** Hardcoded in framework overlay and SurfaceFlinger (`config_defaultPeakRefreshRate = 60`). Eliminates 90Hz display controller thermal spikes and saves ~18–22% battery in direct sunlight.
* **3GB `zstd` ZRAM:** Replaced standard `lz4` with `zstd` (3.2:1 compression ratio) and set ZRAM disk size to 75% in `fstab.qcom` and `init.mmi.rc`. Over 2.8 GB of clean, free physical RAM for Google Maps and Cockpit.
* **Embedded Cockpit System Appliance:** Automatically injects the latest signed release of Cockpit into `/system/priv-app/Cockpit/` with platform permissions pre-whitelisted (`privapp-permissions-cockpit.xml`).
* **Wi-Fi & Bluetooth-Only Appliance:** Disabled cellular baseband searching (`ro.radio.noril=yes`, `ro.carrier=wifi-only`). Radio modem DSP sleeps permanently, eliminating cell tower polling battery drain.
* **Aggressive Debloat:** Stripped Aperture camera, Eleven music, Jelly browser, Calculator, Calendar, DeskClock, PrintSpooler, SIM Toolkit, and CellBroadcastReceiver.

---

## Primary Phone Companion Features (`cockpit/`)

* **Bluetooth Internet Relay (PAN):** Automatically triggers Bluetooth PAN tethering when the bike's Cockpit OS connects over SPP, streaming mobile data for live traffic maps without overheating your pocket phone.
* **Media Deck:** Remote media player observation and asymmetric glove-friendly controls with real-time seeking.
* **Call HUD:** Real-time telephony listener, caller ID HUD, active call mute, and synced contacts / recent calls.
* **Pocket Guardian:** Real-time battery and thermal monitoring with overheating/low-battery HUD alerts.
* **Lightweight:** Completely stripped of receiver floating overlays, minimizing battery and CPU usage in your pocket.

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

