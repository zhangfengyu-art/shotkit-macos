# Contributing

Issues and pull requests are welcome, in Chinese or English.

For a bug report, include macOS version, CPU architecture, Hammerspoon version, steps, expected behavior and actual behavior. Use a synthetic screenshot when possible; remove private content from logs and images before posting. Permissions, language downloads and multiple displays can change behavior.

Keep screen capture and document content on the device. Preserve the original PNG resolution, keyboard accessibility, reduced-motion behavior, and existing Hammerspoon configuration. Prefer native controls; avoid adding work to the mouse-move loop or making the main thread wait for OCR or translation.

Run `python3 -m unittest discover -s tests -v` and the Lua tests (`scripts/test.sh`). Build and manually verify native UI changes on a Mac. Native compilation currently requires the macOS 27 SDK; the runtime deployment target is macOS 15.

Do not commit screenshot history, personal configuration, local backups, credentials, generated binaries or diagnostic dumps. Preview images should contain synthetic content only.

By contributing, you agree that your contributions may be distributed under the repository's MIT license.
