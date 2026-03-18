# Changelog

## v1.5 — Performance Optimization

### Fixes
- Metering timer no longer runs when the popover is closed or meters are collapsed — was the primary source of ~15% idle CPU usage
- Removed unconditional `startMetering()` calls from power, try-again, and permission buttons
- App list polling now does a cheap PID-only check before rebuilding the full list with icons

---

## v1.4 — App Exclusion & Customizable Keyboard Shortcut

### New Features
- **App Exclusion** — Exclude specific apps from loudness equalization; their audio bypasses processing entirely
- **Customizable Keyboard Shortcut** — Replace the default ⌃⌥E with any modifier+key combo via an inline recorder
- **Auto-refreshing app list** — Excluded Apps dropdown polls for newly launched apps every 3 seconds

### Improvements
- HAL process object enumeration with prefix matching catches child/helper processes (e.g. browser audio renderers)
- Full pipeline rebuild on exclusion change ensures the tap is recreated with the correct process list
- Shortcut recorder with live key capture inside NSPopover
- New localized strings for exclusion and shortcut features in all 10 languages

---

## v1.3 — Custom Presets, Lookahead, Auto-Start & Distribution

### New Features
- **Custom Preset Management** — Save, rename, and delete your own presets with full persistence across launches
- **Auto-start on launch** — Optionally start loudness equalization automatically when the app opens; gracefully handles permission re-confirmation with an in-app banner
- **Lookahead buffer** — 2-block (~1.3ms) predictive envelope tracking for smoother transient handling with no perceptible latency
- **Right-click menu** — Right-click the menu bar icon for quick access to Start/Stop, Reset to Defaults, and Quit
- **Distribution script** — `distribute.sh` automates archive, notarize, and DMG creation

### Improvements
- Replaced SwiftUI `MenuBarExtra` with manual `NSStatusItem` + `NSPopover` for full programmatic control (popover auto-opens when permission is needed)
- Menu bar icon dims when the engine is off
- Preset picker with inline save/rename/delete controls (no alerts that dismiss the popover)
- Auto-start permission banner with glowing red/orange button to draw attention
- Migrated old preset system to new `BuiltInPreset` / `CustomPreset` / `PresetSelection` architecture
- Added localized strings for preset management in all 10 languages

### Audio
- Lookahead ring buffer is pre-allocated and real-time safe (no heap allocations during processing)
- Ring buffer properly deallocated on device pipeline cleanup

---

## v1.2 — Device Switching, Output Picker & UI Polish

### New Features
- Output device picker — choose any audio output device
- Device hot-switching with automatic recovery
- System default device tracking

### Improvements
- Level meters behind disclosure group to reduce rendering cost
- GPU-interpolated meter animations at 10fps
- `@ObservationIgnored` optimizations for non-UI audio state
- Switching status with pulsing animation

---

## v1.1 — Performance and Reliability Improvements

### Improvements
- Reduced CPU usage from ~35% to near-zero with block-based DSP
- vDSP SIMD operations for RMS calculation, gain application, and peak detection
- Soft-clip limiter for overdrive protection
- Fixed observation chain for real-time meter updates

---

## v1.0 — macOS Loudness Equalization

### New Features
- Real-time loudness equalization for all system audio
- Global process tap with aggregate device architecture
- Built-in presets: Light, Medium, Heavy
- Adjustable release time, boost, and threshold
- Input/output level meters
- Launch at login support
- Global keyboard shortcut (⌃⌥E)
- 10-language localization
- First-launch welcome screen with permission flow
