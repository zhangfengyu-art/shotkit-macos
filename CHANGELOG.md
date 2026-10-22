# Changelog

## 5.0.4 — Scroll range sensitivity and smooth transitions

- Separate scroll range switching from automatic hover recognition, with independent persistent settings.
- Accumulate wheel ticks and precise trackpad distances, ignore momentum and discard cooldown surplus to prevent accidental multi-level jumps.
- Restore responsive hover recognition by default; keep manual dragging and keyboard hierarchy changes immediate.
- Animate selection borders, dim mask and label with coordinated 160 ms easing, retargeting from the current presentation.
- Cover bursts, direction changes, device changes, gesture boundaries and event packetization in deterministic regression checks.

## 5.0.3 — Adjustable automatic selection

- Add a persistent native sensitivity slider, with a steadier 180 ms default, from 60 to 220 ms.
- Tune border hysteresis together with hover dwell while retaining small control selection.
- Cancel queued switches when the pointer returns to the current target or leaves the pending target.
- Keep manual selection immediate and settings actions reachable on smaller screens.

## 5.0.2 — Calmer selection, reliable cancellation, app icon

- Hold hover selection for 100 ms and widen border stability before switching small targets.
- Match button hit regions and highlight layers to their visible rounded bounds.
- Register Escape for capture, toolbar, delay and long-capture lifetimes; cancel open tool menus as well.
- Keep frozen selection through screen-state notifications unless display geometry actually changes.
- Add a custom vector-rendered application icon with all macOS icon sizes.
- Cover Escape dispatch, hover settling and actual button hit boundaries in native regression checks.

## 5.0.1 — Selection and frozen capture fixes

- Preserve typed AX geometry inside the app so images, buttons and smaller content remain selectable.
- Center the toolbar below the selection, clamp it to the relevant display, and place it above when needed.
- Detach captured pixels from their provider and draw an opaque frozen desktop during selection.
- Use one continuous glass toolbar and keep feedback animations inside stable button geometry.
- Add regression checks for nested controls, actual toolbar coordinates, and changing source pixels.

## 5.0.0 — Standalone native app

- Replace Hammerspoon/Lua orchestration with a native menu bar application.
- Carbon global shortcuts and AppKit selection gestures, resize handles, keyboard adjustment and selection hierarchy.
- ScreenCaptureKit snapshots, own-window exclusion, in-memory mixed-Retina cropping; no screenshot subprocess or hide delay.
- Core Animation selection feedback with no idle 60 Hz selection poll.
- Reuse annotation, OCR, QR, translation, pins, segmented capture and searchable history inside one process.
- Open translation directly from the selected memory image while storing history asynchronously.
- Native setup, optional Accessibility, launch-at-login preference and recoverable local history cleanup.
- Scoped migration with backup/restore; preserve other Hammerspoon automation and read legacy history without changing it.

## 4.2.0

First public Hammerspoon-based release. Available under tag `v4.2.0`.
