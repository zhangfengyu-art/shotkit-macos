# ShotKit macOS

A native screenshot toolkit for Apple Silicon Macs, powered by **Hammerspoon + Swift / AppKit / SwiftUI**. [中文说明](../README.md) · [MIT license](../LICENSE)

![Native capture toolbar and pressed feedback](images/toolbar.png)

## Features

- Stabilized window/element selection and manual region selection.
- Arrows, shapes, pen, text, opaque redaction, mosaic, cropping, undo and redo.
- On-device OCR, editable text, TXT export and separate QR/barcode scanning.
- Apple system translation with fast/high-fidelity modes, cancellation, retries and bounded memory caches.
- Floating image pins, searchable local history and **manual segmented** scrolling captures.
- Native glass on supported systems; hover, press, spring release and contextual long-press menus.
- System appearance, reduced motion, keyboard controls and native save dialogs.

This version **requires Hammerspoon**. It is not a standalone screenshot app.

## Requirements

Apple Silicon, macOS 15+, Hammerspoon and Python 3. Liquid Glass requires macOS 26+; enhanced interactive glass requires macOS 27. Earlier systems use a native material fallback. Fast/high-fidelity translation selection requires macOS 26.4+. Language resources may need an initial system download.

Building from source requires Apple development tools with the **macOS 27 SDK**. The release binary targets arm64/macOS 15; Intel builds are not provided or validated.

## Install

Download and extract `shotkit-macos-v4.2.0-arm64.zip` from this repository's Releases. Check the archive against the accompanying `SHA256SUMS.txt`. Install and launch [Hammerspoon](https://www.hammerspoon.org/), close active capture/edit sessions, then run from the extracted folder:

```sh
python3 scripts/install.py --dry-run
python3 scripts/install.py
```

Choose **Hammerspoon → Reload Config**. Grant Hammerspoon **Accessibility** and **Screen Recording** in macOS when prompted; a restart may be needed.

The installer updates only ShotKit's four Lua modules and native helper. It appends a marked startup block to an existing `init.lua` when necessary, backs up affected files under `.shotkit-backups/` and does not automatically reload Hammerspoon. Existing unrelated configuration is preserved.

For a linked or manually managed `init.lua`, use `--no-init`, then add `require("screenshot").start()` yourself. `--config PATH` selects a custom Hammerspoon configuration directory.

The helper is **ad-hoc signed and not Apple notarized**. macOS may require explicit user approval for a downloaded binary. Follow the normal macOS security flow, or build locally. The installer does not remove quarantine flags or disable security controls.

To build locally instead of using a release binary:

```sh
zsh build.sh
python3 scripts/install.py
```

The output is `build/ShotKit.app`. Compiled binaries are excluded from Git and distributed only as release assets.

## Usage

Press **Control + Command + A** to capture; **Shift + Control + Command + A** opens history or finishes a segmented long capture. Return or double-click copies the selection; Esc cancels.

In the selection UI: E annotates, O extracts text, T translates, P pins, S saves, L starts a long capture and D starts a three-second delay. Arrow keys move; Shift + arrows resizes; Option increases the step. Long-press (~0.45 seconds) or right-click a tool for related options. Translation's long-press menu selects a target language directly.

In the translation window, **Command + Return** translates, **Esc** stops ongoing work, and **Shift + Command + C** copies the completed translation. Editing the source disables copying an outdated result.

Long capture requires manual scrolling and roughly one-third overlap between segments. It is not automatic full-page capture. Up to 20 segments are stitched and opened in the editor for inspection.

![Translation window with synthetic sample text](images/translation.png)

## Privacy and performance

Images, thumbnails, recognized text and history metadata remain in `screenshot-data/` under the Hammerspoon configuration directory. The default retention is 60 images, 30 days or 300 MB; temporary long-capture segments expire after about 24 hours. Redacting an export **does not delete the original image from history**.

Translation uses Apple's system Translation framework. The project has no translation API key, analytics, server or account system. Language downloads are managed by macOS. “Copy and open ChatGPT” only copies the image and opens the local app; it does not paste or send automatically. Repository preview images are synthetic.

The resident service prepares OCR in the background and separates text recognition from barcode scanning. In one Apple Silicon test after preparation, an 800 × 160 English sample opened its window in about 114 ms and completed OCR plus translation in about 730 ms; cached repeats took 9–13 ms. This excludes screen capture and is not a performance guarantee. Cold initialization, content and language preparation affect timing. OCR and translation caches are memory-only, limited to about 2 MB each (24/48 entries), and cleared when the service exits.

## Restore the previous installation

Close capture/editor windows, then run:

```sh
python3 scripts/install.py --uninstall --dry-run
python3 scripts/install.py --uninstall
```

Reload Hammerspoon afterward. History and backups remain. Restoration refuses to overwrite modules edited after installation and preserves later unrelated additions to `init.lua` when possible.

## Development

Run `python3 -m unittest discover -s tests -v`. With Lua 5.4+ available, `scripts/test.sh` also checks selection geometry, border stability and idle canvas updates. After building, run the native synthetic image tests:

```sh
build/ShotKit.app/Contents/MacOS/ShotKit selftest /tmp/shotkit-selftest
```

Native tests cover OCR, QR, stitching, duplicate segment rejection, opaque redaction and cropping. Permissions, real pointer interactions, multiple displays and language downloads require manual Mac validation. See [CONTRIBUTING](../CONTRIBUTING.md) and [SECURITY](../SECURITY.md).

MIT licensed. Thanks to Hammerspoon. This independent community project is not affiliated with Apple, QQ or the Hammerspoon project.
