# Contributing

Build on an Apple Silicon Mac with Apple command line tools and the macOS 27 SDK:

```sh
zsh build.sh
sh scripts/test.sh
```

The default executable is a standalone AppKit application. There is no Lua or Hammerspoon runtime. Keep selection coordinates in Quartz global points; convert to AppKit only at window boundaries. Never block the main thread with AX queries, PNG encoding or history scans. All async capture/recognition work must reject stale results on cancellation or replacement.

Synthetic fixtures and reports belong outside the public source tree. Never commit screenshot history, local installation manifests, private configuration, signing identities or diagnostics containing personal content. Public preview images must use synthetic data.

For changes to selection, verify border stability, offscreen and negative-origin displays, mixed Retina scales, drag/resize/keyboard behavior and cancellation releasing display buffers. For changes to controllers, closing one editor/result/pin must leave the resident app and other windows running.

Migration must touch only the screenshot startup statement and must preserve unrelated automation and all historical images. Do not auto-enable login startup, grant permissions, alter TCC databases or weaken Gatekeeper. Ad-hoc signing is local development, not notarization.
