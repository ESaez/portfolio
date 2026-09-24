# Process Monitor

A small native macOS app (SwiftUI, Apple Silicon) that shows what is using your
**CPU, memory and GPU** and lets you quit it in a click — but only things **you**
started. macOS system processes are always shown with a lock and can never be
quit from the app.

> Status: work in progress. The package, CI and build script are in place; the
> monitor and the UI are being built milestone by milestone.

## Build and run

Requirements: an Apple Silicon Mac with macOS 14 or later and Xcode 16 (or its
Command Line Tools).

```sh
cd process-monitor
./scripts/build-app.sh
open "dist/Process Monitor.app"
```

The script builds a release binary, wraps it in `dist/Process Monitor.app`, signs
it ad hoc and also writes `dist/ProcessMonitor.zip`. A build made on your own Mac
is not quarantined, so Gatekeeper lets it open normally.

For development you can also run `swift run ProcessMonitor` or open
`Package.swift` in Xcode, and run the tests with `swift test`.

## Why it is not in the Mac App Store

App Store apps must be sandboxed, and the sandbox forbids listing or quitting
other processes. Process Monitor therefore runs unsandboxed — but it never asks
for administrator rights, so macOS itself stops it from touching anything owned
by root or another user.
