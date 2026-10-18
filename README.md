# edgetx-flight-wingman

![edgetx-flight-wingman: EdgeTX Lua widget for battery, link and GPS on one screen](docs/banner.png)

Flight Wingman brings **battery, radio link and the way home together on one screen**: a full-screen EdgeTX widget that shows the right page for each phase of a flight, from plugging in the battery to finding the model after a crash. It builds on [Lipo Nanny](https://github.com/Mariator-pro/edgetx-lipo-nanny), [Link Sentinel](https://github.com/Mariator-pro/elrs-link-sentinel) and [GPS Homer](https://github.com/Mariator-pro/edgetx-gps-homer) and ships with all three.

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE)
[![EdgeTX](https://img.shields.io/badge/EdgeTX-%E2%89%A5%202.11-brightgreen)](https://edgetx.org)
[![ExpressLRS](https://img.shields.io/badge/ExpressLRS-%E2%89%A5%204.0-orange)](https://www.expresslrs.org)
[![GitHub issues](https://img.shields.io/github/issues/Mariator-pro/edgetx-flight-wingman)](../../issues)
[![GitHub last commit](https://img.shields.io/github/last-commit/Mariator-pro/edgetx-flight-wingman)](../../commits/main)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-support-yellow?logo=buy-me-a-coffee&logoColor=white)](https://www.buymeacoffee.com/mariatorpro)

---

## 📑 Table of Contents

- [📋 Compatibility](#-compatibility)
- [🎯 What is it for?](#-what-is-it-for)
- [🧰 Requirements](#-requirements)
- [📥 Installation](#-installation)
- [⚙️ Customizing](#️-customizing)
- [🛠️ Troubleshooting](#️-troubleshooting)
- [🤝 Contributing](#-contributing)
- [⚠️ Disclaimer](#️-disclaimer)
- [📄 License](#-license)

---

## 📋 Compatibility

> [!CAUTION]
> **Testing is not finished yet.** The project is in an early stage and has not been through all real-flight tests. Feedback on how the individual functions behave on your setup is very welcome, please [open an issue](../../issues).

| Component | Minimum Version | Tested On | Test Hardware |
|-----------|-----------------|-----------|---------------|
| EdgeTX    | v2.11           | v2.12.4   | Radiomaster TX15, Radiomaster TX16S MK3 |
| ExpressLRS| v4.0.0          | v4.1.0    | Radiomaster RP1 V2, RP3 V2, RP4TD |

> Battery, link and GPS work exactly as in the three single projects, so their compatibility notes apply here too: [Lipo Nanny](https://github.com/Mariator-pro/edgetx-lipo-nanny/blob/main/docs/compatibility.md), [Link Sentinel](https://github.com/Mariator-pro/elrs-link-sentinel/blob/main/docs/compatibility.md), [GPS Homer](https://github.com/Mariator-pro/edgetx-gps-homer/blob/main/docs/compatibility.md).
>
> Flight Wingman itself reads the flight mode (`FM`) from the flight controller to tell when the model is armed. Betaflight and INAV also report arming blocks and board info over MSP; ArduPilot works without them.

---

## 🎯 What is it for?

Three widgets side by side share a small screen, yet each phase of a flight needs different values. Flight Wingman sorts by phase instead of by topic: before take-off it answers *"Am I ready to go?"*, in flight *"Do I have to react now?"*, after landing *"Did everything go well?"* and after a crash *"Where is the model?"*.

<p align="center">
  <img src="docs/img/widget-carousel.gif" width="800" alt="Flight Wingman pages one after another: waiting, preflight, flight with compass, flight with horizon, post-flight, search and switches">
  <br>
  <a href="docs/img/widget-waiting.png">Waiting</a> · <a href="docs/img/widget-preflight.png">Preflight</a> · <a href="docs/img/widget-flight.png">Flight, compass</a> · <a href="docs/img/widget-flight-horizon.png">Flight, horizon</a> · <a href="docs/img/widget-end.png">Post-flight</a> · <a href="docs/img/widget-search.png">Search</a> · <a href="docs/img/widget-switches.png">Switches</a>
</p>

- **One screen, three columns:** battery from Lipo Nanny, home arrow from GPS Homer, link from Link Sentinel, each with the same colors and thresholds as the single widget.
- **Pages switch on their own**, no button needed: waiting, preflight, flight, post-flight and search.
- **All warnings stay as they are:** the voice announcements and vibration of the three projects keep running, even when the widget is not on screen. Flight Wingman adds no warnings of its own.
- **One ready check before take-off:** `GO` when battery, link and GPS are fine and the flight controller allows arming, otherwise `CHECK` with the reason (Betaflight and INAV name the arming block in plain text).
- **Setup errors show up before you fly:** a missing core, an unconfigured model or a missing sensor keeps the waiting page with a hint, instead of warnings silently not playing.
- **See what each switch does:** on the waiting page, aileron held right opens a page with every switch, its channel, the flight controller's modes and the sounds for each position (can be turned off in Flight Bag under Display).
- **Not every model has GPS:** battery, link and GPS can be switched off per model; the remaining columns share the width.

See the pages in motion, from the ready check to warnings and the search for a crashed model: [Flight Wingman in action](docs/in-action.md).

The two fields in the header show the flight controller's state on every page:

| Header field | Meaning |
|---|---|
| <img src="docs/img/header-mode.png" width="56" alt="ACRO on a grey field"> | Flight mode as the flight controller sends it (any mode, e.g. `ANGL`, `HOR`, `AIR`) |
| <img src="docs/img/header-mode-blocked.png" width="56" alt="ACRO on a yellow field"> | Arming blocked, the reasons are on the preflight page (Betaflight: the mode, INAV: `!ERR`) |
| <img src="docs/img/header-mode-rth.png" width="56" alt="RTH on a yellow field"> <img src="docs/img/header-mode-land.png" width="56" alt="LAND on a yellow field"> | Return to home or automatic landing in progress (also `WRTH`, `RTL`, `SRTL`, `ARTL`, `QRTL` and `ALND`, `QLND`, `L2QL` from INAV and ArduPilot) |
| <img src="docs/img/header-mode-failsafe.png" width="56" alt="!FS! on a red field"> | Failsafe |
| <img src="docs/img/header-armed.png" width="55" alt="ARMED on a red field"> | Armed |

---

## 🧰 Requirements

- A **color-display radio** running **EdgeTX 2.11 or newer** (800×480 and 480×272/320 screens).
- A **flight controller** (Betaflight; INAV and ArduPilot untested) with telemetry enabled, so the radio gets the `FM` sensor. GPS is optional.
- An **ExpressLRS receiver (4.0 or newer)** with telemetry enabled. Set the telemetry ratio faster than `Std` (for example 1:16): with `Std` the flight mode arrives only every 6 to 8 s, so the flight page appears late after arming.
- The telemetry sensors of the three projects, found by a **telemetry discovery** (Model Settings → Telemetry → "Discover new sensors"). Which ones are needed: see the requirements of [Lipo Nanny](https://github.com/Mariator-pro/edgetx-lipo-nanny#-requirements), [Link Sentinel](https://github.com/Mariator-pro/elrs-link-sentinel#-requirements) and [GPS Homer](https://github.com/Mariator-pro/edgetx-gps-homer#-requirements).

---

## 📥 Installation

### 1. Copy the files to the SD card

Copy the folders below 1:1 into the root of the SD card. Flight Wingman brings the cores of the three single projects along, so you don't need to install them separately.

```
SCRIPTS/
├── WINGMAN/                ← Wingman logic and Flight Bag settings
├── LIPONY/                 ← battery logic (Lipo Nanny)
├── SNTNL/                  ← link logic (Link Sentinel)
├── GPSHOMER/               ← GPS logic (GPS Homer)
├── FLIGHTBAG/              ← Flight Bag pages
└── TOOLS/
    └── FLIGHTBAG.lua       ← Tools menu entry
WIDGETS/
└── WINGMAN/
    └── main.lua            ← widget
SOUNDS/
└── en/
    └── SCRIPTS/            ← all .wav files of the three projects
```

The sound files always live under `/SOUNDS/en/SCRIPTS/`, no matter which language your radio is set to. `config.lua` files are written by the radio once you save settings, nothing you copy.

> **Already using one of the single projects?** Its files are the same; a newer version on the card is fine as long as it fits (otherwise Flight Bag shows `core too old` in the Wingman popup).

### 2. Set up the widget

1. Open the model's **Telemetry / Display** setup (the page where you arrange the widget screens).
2. Choose the **App mode** layout (one zone over the whole screen, no EdgeTX top bar). Flight Wingman draws its own header with model name, flight mode, `ARMED`, radio battery and time.
3. Add a widget to the zone and choose **Wingman** from the list.
4. *(Optional)* Open the widget settings to adjust the look:
   - **Theme**: `Dark` or `Light`.
   - **Compass**: `NoseUp` (default): flight direction on top, the arrow points home. `NorthUp`: north on top like a map, a house on the ring marks home.
   - **Transparency**: how much of the radio theme shows through the milky background (light theme only): `0%` opaque, `100%` no overlay.
   - **Accent**: color of the heading text: `Default` (green), `Theme` (the focus color of your EdgeTX theme) or `Custom` (pick any color under **AccentColor**).

> ⚠️ **Don't combine Flight Wingman with the single widgets or function scripts** of Lipo Nanny, Link Sentinel or GPS Homer on the same model, otherwise every announcement plays twice. Place Flight Wingman on **one screen only**.

### 3. Set up the projects

Open **SYS → Tools → Apps → Flight Bag** and set up battery, link and GPS (at least one battery profile and the model settings). An icon with a warning sign tells you what is still missing. All pages and rows, including Wingman's own settings (**Models → Show in Wingman**, **Display**), are described in the [Flight Bag guide](docs/flightbag.md).

### 4. Try it out

- Plug in the battery: the preflight page shows battery, GPS and link. Pick the pack if several fit, the same way as in [Lipo Nanny](https://github.com/Mariator-pro/edgetx-lipo-nanny/blob/main/docs/usage.md). Once everything is ready, the field shows `GO` and a bar counts down 15 s to the flight page; arming switches at once.
- Unplug the battery after the flight: the post-flight page shows flight time, used capacity, distance, each column's extremes and the flight's alerts for 30 s.
- Landed or crashed far from home (more than 15 m)? The search page shows where the model is, with a QR code for your phone's map app. While the link is still up, the radio beeps like a Geiger counter (higher and faster the stronger the signal), so you can walk towards the model without looking at the screen.

### Stick controls

Touch and keys don't reach a widget in App mode, so Flight Wingman uses the sticks, and only while disarmed:

- **Pack selection:** elevator moves the cursor, aileron held right for 1 s confirms.
- **Close the search page:** aileron held right for 1 s.
- **Mute the finder beeps:** on the search page, aileron held left for 1 s (again to unmute); each new search starts with sound.
- **Show the last post-flight page again:** on the waiting page, aileron held left for 1 s.
- **Open the switch page:** on the waiting page, aileron held right for 1 s; aileron held left goes back.

---

## ⚙️ Customizing

All settings are made in **Flight Bag**, the settings tool shared by Lipo Nanny, Link Sentinel, GPS Homer and Flight Wingman (**SYS → Tools → Apps → Flight Bag**). Thresholds, sounds, vibration and display options are set there; after **Save** they apply within a few seconds, no restart needed. Every page and row is described in the [Flight Bag guide](https://github.com/Mariator-pro/edgetx-flight-wingman/blob/main/docs/flightbag.md).

---

## 🛠️ Troubleshooting

- **Waiting page with a sad mascot and "Configuration error / Please check Tool Flight Bag":** Something is not set up yet. Open **SYS → Tools → Apps → Flight Bag**; the icon with the warning sign names the problem in its popup.
- **"Core missing / Reinstall Flight Wingman":** `/SCRIPTS/WINGMAN/core.lua` is not on the card. Copy the folders again.
- **The flight page comes several seconds after arming:** The telemetry ratio is set to `Std`. Set it faster, for example 1:16.
- **Every announcement plays twice:** A single widget or function script of the three projects is still active on this model. Remove it.
- Problems in one column: see the troubleshooting of [Lipo Nanny](https://github.com/Mariator-pro/edgetx-lipo-nanny/blob/main/docs/troubleshooting.md), [Link Sentinel](https://github.com/Mariator-pro/elrs-link-sentinel#️-troubleshooting) or [GPS Homer](https://github.com/Mariator-pro/edgetx-gps-homer#️-troubleshooting).

---

## 🤝 Contributing

Found a bug or have an idea for an improvement? Please [open an issue](../../issues) on GitHub. Pull requests are welcome too. Changes to battery, link or GPS logic belong in the matching single project.

---

## ⚠️ Disclaimer

This project is provided **as is** and is meant as an additional aid only. It does **not** replace careful flying within visual range, your own judgement, your own battery management, GPS rescue on the flight controller, or the safety mechanisms of your transmitter and receiver. Always be ready to react manually. Use at your own risk.

---

## 📄 License

Released under the [GNU General Public License v2.0](LICENSE).
