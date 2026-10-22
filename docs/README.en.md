# ShotKit macOS 5

A standalone native macOS screenshot app. **No Hammerspoon, Lua, or Python runtime is needed.** Apple Silicon, macOS 15+.

## Install

Extract the release and move **ShotKit.app** into Applications (or `~/Applications`). Open it, use its setup window to allow **Screen Recording** for ShotKit in System Settings, then return and choose **Recheck permissions** / Start Capture. Restart the app if macOS requests it.

Accessibility is optional for detecting individual UI elements; window selection and free selection do not require it. Global shortcuts do not require Input Monitoring. Enable launch at login explicitly in Settings if desired.

The build is ad-hoc signed and **not Apple notarized**. Use normal macOS approval or build from source; keep system security protections enabled.

Rebuilding an ad-hoc signed app may require renewed permission. If a system toggle is enabled but ShotKit reports otherwise, quit ShotKit, remove its stale entry from that permission list, add the newly installed app, allow it, and reopen. Accessibility and Screen Recording are managed separately; Hammerspoon needs no additional access.

For v4 users, the optional Python migration tool installs into `~/Applications/ShotKit.app`, backs up `init.lua`, disables only a standalone `require("screenshot").start()` statement, and stops only that module through Hammerspoon IPC. It never reloads unrelated automation. Unrecognized startup statements are refused. Existing screenshots remain in their original location and can be displayed read-only by the new app.

```sh
python3 scripts/install.py --dry-run --migrate-hammerspoon
python3 scripts/install.py --migrate-hammerspoon
```

If IPC is unavailable, reload Hammerspoon yourself when no capture is active to release the old hotkeys. Recheck permissions in ShotKit afterward. Do not run both capture shortcut handlers at once.

## Use

**Control–Command–A** captures; **Shift–Control–Command–A** opens history. Hover to select a window or accessible content, or drag a rectangle. Click to lock it and show the toolbar; drag its interior or eight handles to adjust it. Scroll / Tab / arrow keys cycle targets before locking. Arrow keys nudge; Shift resizes; Option accelerates.

Return/C copies; E annotates; O extracts text; T translates; P pins; S saves; L starts segmented capture; Q reads barcodes; D delays three seconds; A copies and opens the local AI app. Escape is registered globally only during capture, toolbar, delay and segmented-capture sessions; it cancels without depending on which panel has keyboard focus. Right-click reselects. Long-press or right-click toolbar buttons for additional actions.

Annotation includes arrows, rectangles, pen, text, opaque redaction, mosaic, crop, undo and redo. OCR text is editable and exportable. Barcode contents never open automatically. Translation uses Apple's system framework with cancellation, retry, target languages and bounded memory caches. Language resources may require a first-time system download.

Liquid Glass needs macOS 26+, enhanced interaction uses macOS 27, and older versions use system materials. Translation quality strategies require macOS 26.4+.

Long capture is **manual segmented capture**, not automatic scrolling: scroll down while retaining at least one-third overlap, take the next segment, then stitch and inspect. At most 20 segments. Cancelled/failed segments remain recoverable in a local `long-…` directory.

Settings separately control scroll range switching and automatic hover recognition. Scrolling defaults to deliberate accumulated input, ignores trackpad momentum, and limits burst repeats. Hover recognition defaults to a responsive 76 ms dwell. Changes apply to the next capture; manual dragging and Tab/arrow stepping remain immediate. Interrupted range animations continue from their current presentation with a shared 160 ms easing.

## Native architecture and data

Carbon hotkeys, AppKit selection windows, ScreenCaptureKit snapshots and in-memory cropping all run inside one app. Capture pixels are copied into a detached frozen bitmap, and the opaque selection background displays that same frame. Typed AX coordinates preserve fine targets; a continuous glass toolbar is centered under the selection, or above it near the screen edge. There is no screenshot command subprocess, hide-and-wait delay or Lua/native message bridge. Core Animation animates selection changes; there is no idle 60 Hz selection poll. Background queues handle PNG/history work. Translation opens directly from the selected image in memory.

New data lives in `~/Library/Application Support/ShotKit/Screenshots/`. Nothing is uploaded to a project server. New history defaults to 60 entries (12/60/100 configurable), 30 days and 300 MB; expired files are moved to Trash. Legacy history is read-only and excluded from cleanup. Original history images remain after exporting redactions. The local `status.json` contains only version, permission flags, counts and timings.

Copy-and-open AI only copies the image and opens an installed app; it never pastes or sends it.

## Develop / restore

Build with Apple's command line tools and macOS 27 SDK:

```sh
zsh build.sh
sh scripts/test.sh
python3 scripts/package.py
```

Tests use synthetic images, covering selection stability, negative and mixed-Retina displays, pixel orientation, cancellation, OCR/barcodes, stitching, opaque redaction and crop. Crop microbenchmarks are not end-to-end screenshot or translation latency measurements.

Quit native ShotKit before restoring a migration:

```sh
python3 scripts/install.py --restore --dry-run
python3 scripts/install.py --restore
```

Backups are retained under `.shotkit-native-backups/` beside the install target. Restore refuses to overwrite a configuration edited after migration. Screenshot history is retained.

MIT licensed. Not affiliated with Apple. [Chinese documentation](../README.md)
