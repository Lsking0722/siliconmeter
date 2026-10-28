# SiliconMeter — Developer notes

SiliconMeter is a menu bar app that shows an Apple Silicon Mac's live resource usage as a **drawing of the chip die**.

- **Menu bar:** a plain chip icon with the chip's name engraved. Its shape follows the chip: base chips are square; Pro, Max and Ultra are one tall rectangle with the chip number on top and P, M or U below.
- **Popover:** a keynote-style spec list on the left, the live die animation on the right. Every core glows as hard as it's working, and the unified memory packages under the die fill with usage.
- **Sizes:** die size (100% · 75% · 50%) and a numbers-only Simple mode, picked from the bottom-left of the popover.
- **Efficiency:** sampling and animation run only while the popover is open (sampling once a second, drawing at 30 or 60 fps, chosen in the popover or the right-click menu) and stop when it closes. The parts of the die that never move (silicon plate, block outlines, chip name, wiring, interposer metal, memory package frames) and the gradients are rendered once per size into images; each frame only computes what changes with load. The menu bar icon is a static image, so it costs nothing while idle.
- **Permissions:** no sudo, no network access.

## Requirements

- An Apple Silicon Mac (M1 or later, including the A18 Pro MacBook Neo), macOS 13 or later
- Xcode or the Command Line Tools (`xcode-select --install`)
- The deployment target is macOS 13, so APIs missing on 13 fail at compile time. The app has not yet been run on a real macOS 13 machine.

## Build and run

```bash
./scripts/build_app.sh          # creates build/SiliconMeter.app
open build/SiliconMeter.app     # run it
cp -R build/SiliconMeter.app /Applications/   # install (optional)
```

Click the menu bar icon to open the popover; right-click it for the menu (frame rate, quit). "Open at login" at the bottom of the popover starts the app at login (best after installing to `/Applications`).

## Release packages

```bash
bash scripts/package.sh         # creates dist/SiliconMeter-<version>.zip, .dmg and .sha256
```

The app is ad-hoc signed and not notarized (no Apple Developer ID), so macOS blocks a downloaded copy the first time it's opened. Allow it once, either way:

1. **System Settings:** move the app to `/Applications`, open it once and dismiss the warning, then go to **System Settings → Privacy & Security** and click **Open Anyway** next to "SiliconMeter was blocked…". (On macOS 14 and earlier, right-click the app in Finder → **Open** also works.)
2. **Terminal:** `xattr -dr com.apple.quarantine /Applications/SiliconMeter.app`

A copy you build yourself carries no quarantine flag and needs neither.

## App icon

```bash
python3 scripts/make_icon.py Resources/AppIcon-1024.png          # full detail
python3 scripts/make_icon.py Resources/AppIcon-small.png small   # 16–32 px variant
python3 scripts/pack_icns.py Resources                           # → Resources/AppIcon.icns
```

Needs Pillow. The name plate text uses Inter Display SemiBold (or the font in `$SM_ICON_FONT`).

## Diagnostic dump

```bash
swift run -c release SiliconMeter --dump
```

Prints the detected chip, its performance levels, the CPU cluster map from the device tree, one second of live readings, and every IOReport channel that mentions the Neural Engine.

```bash
build/SiliconMeter.app/Contents/MacOS/SiliconMeter --ane-load 20         # sustained load
build/SiliconMeter.app/Contents/MacOS/SiliconMeter --ane-load 20 light   # light load
```

Runs Vision (text recognition and image classification) for 20 seconds to load the Neural Engine, so you can check that the popover's Neural Engine reading actually responds. When a layout looks wrong on another chip, this output is what to ask for.

## Running as another chip (debug)

```bash
open build/SiliconMeter.app --args --debug                     # pick a chip from the panel
open build/SiliconMeter.app --args --debug m5-ultra-36c-80g    # start as a specific chip
```

Runs the real menu bar app as any of the 41 configurations (M1–M6, A18 Pro). The icon, popover and size switching are the shipping code; only the chip info and the load are simulated. A floating panel lets you switch chips and load (Idle / Sample / Busy / Full).

```bash
build/SiliconMeter.app/Contents/MacOS/SiliconMeter --simulate sim
```

Writes every configuration's detected layout (`chips.json`), menu bar icons at 1x, 2x and 4x, and popover snapshots to `sim/`, and checks the cached render against a full redraw.

## What's measured and what's for show

| Element | Data | Source |
|---|---|---|
| Per-core CPU load | **Measured**, one value per core | `host_processor_info` (public API) |
| Core → cluster → tier mapping | **Measured** | IORegistry `cpuN` nodes' `cluster-type`, `hw.perflevelN.*` |
| GPU utilization and clock | **Measured**, one value for the whole GPU | Utilization: IOAccelerator `Device Utilization %` (same as Activity Monitor). Clock: IOReport `GPU Stats` (private) |
| Per-core GPU lighting | **For show**: overall utilization plus a fixed per-core offset, lit in a set order | macOS reports no per-core values |
| Neural Engine | Activity: measured on chips that report residency; otherwise estimated from the ANE bandwidth-floor residency, marked "(est.)" (on M4: 0% idle, ~94% under a sustained Vision load). Power is shown in W only once the energy counter has proved it works; on chips where it stays at zero (M4), memory traffic in GB/s is shown instead | IOReport `SoC Stats › Cluster Power States`, `PMP › DCS/SOC Floor`, `AMC Stats › Perf Counters`, `Energy Model` |
| Memory breakdown, pressure, swap | **Measured** (same calculation as Activity Monitor) | `host_statistics64`, sysctl |
| Flow along wiring and bridges | **For show**: speed proportional to overall activity | Bandwidth is not measured |

## Per-chip layout and colors

Each generation and variant has its own floorplan (`Floorplans` in `ChipLayout.swift`) and palette (`ChipCatalog.swift`). A floorplan defines where the CPU clusters, GPU, Neural Engine and caches sit and the die's proportions; the detected cluster and core counts are then filled into those regions. Binned models need no extra work, and models with GPU cores disabled (e.g. 8-core M3, 30-core M3 Max, 5-core A18 Pro) draw the full grid and leave the disabled cores dark.

| Chip | Based on | Colors |
|---|---|---|
| M1, M1 Pro, M1 Max | Block layout of Apple's official line art | Peach→blue / blue / violet |
| M2, M2 Pro, M2 Max | Same | Amber→violet / blue / violet |
| M3, M3 Pro, M3 Max | Official line art (M3, M3 Max); M3 Pro from the same generation's rules and die proportions | Mint / blue / purple·pink |
| M4, M4 Pro, M4 Max | Official line art | Lime→cyan→blue→indigo (keynote die shot) / blue / violet |
| M5, M5 Pro, M5 Max | Official line art (M5); fused CPU-die + GPU-die structure (Pro/Max) | Aqua / blue / purple |
| M6 | No line art published: three core tiers, two Neural Engines | Green→blue |
| A18 Pro (MacBook Neo) | Official line art: 2 performance + 4 efficiency cores, 16-core NE (8×2), 6 GPU columns with 5 enabled, one memory package | Rose gold |
| Ultra (M1–M3, M5) | Two Max dies joined by UltraFusion | Per-chip badge colors |

- **UltraFusion:** drawn as gold wiring across the whole seam between the two dies, with pulses (white and amber) running both ways.
- **Memory traffic:** the number of memory lanes, pulses per lane and pulse speed scale with each chip's published memory bandwidth (e.g. M1 68.25 GB/s, M4 Max 546 GB/s, M5 Ultra 1228.8 GB/s).
- The fine lines inside each block are the app's own patterns and don't copy Apple's illustrations. No Apple logo is drawn.

## Credits and license

The data layer borrows proven techniques from these MIT-licensed projects. Full notices are in `THIRD_PARTY_NOTICES.md`.

- [SiliconScope](https://github.com/kennss/SiliconScope): IOReport declarations, CPU cluster map, GPU / Neural Engine / memory sampling approach
- [Stats](https://github.com/exelban/stats): M5-generation cluster letters (P = Super, M = Performance, E = Efficiency)

Because it uses a private API (IOReport), the app can't ship on the Mac App Store; it's for personal use and GitHub distribution.

SiliconMeter is released under the MIT License (`LICENSE`).

Apple, Apple Silicon, Mac, MacBook, M1–M6 and A18 Pro are trademarks of Apple Inc. SiliconMeter is an independent project and is not affiliated with, sponsored by, or endorsed by Apple.
