# Process Monitor

A small native macOS app (SwiftUI, Apple Silicon) that shows what is using your
**CPU, memory and GPU**, and lets you quit it in a click, but only things **you**
started. macOS's own processes are shown with a lock and can never be quit from
the app.

- **Tabs for CPU, Memory and GPU.** Each tab is a list ranked by that resource,
  with usage bars and live totals at the top.
- **Apps grouped with their helpers.** Chrome's 20 helper processes show as one
  "Google Chrome (21)" row. Expand it to see or quit single helpers.
- **My processes / All processes.** "My processes" lists only what you can quit.
  "All processes" also shows macOS processes, each locked with the reason.
- **Safe quitting.** Apps are asked to quit the way the Dock does it, so they can
  save first. Force Quit is always confirmed.
- **Menu bar icon.** A popover shows the top five things you can quit, with an
  optional live CPU % in the menu bar.
- **Rows never jump under the pointer.** While you hover over the list its order
  stays put.

## Build and run

You need an Apple Silicon Mac with macOS 14 or later and Xcode 16 (or its Command
Line Tools).

```sh
cd process-monitor
./scripts/build-app.sh
open "dist/Process Monitor.app"
```

The script builds a release binary, wraps it in `dist/Process Monitor.app`, signs
it ad hoc and also writes `dist/ProcessMonitor.zip`. A build made on your own Mac
isn't quarantined, so it opens normally. Copy the app to `/Applications` if you
want to keep it.

If you download the zip from a CI run instead, macOS will block it because it's
ad-hoc signed. Right-click the app, choose **Open** (or use **Open Anyway** in
System Settings → Privacy & Security), or run
`xattr -dr com.apple.quarantine "Process Monitor.app"`.

For development, you can also run `swift run ProcessMonitor` or open
`Package.swift` in Xcode, and run the tests with `swift test`.

## What can be quit

The app never asks for administrator rights. That alone means macOS won't let it
signal anything owned by root or another user. On top of that, a safety policy
(`Sources/MonitorCore/SafetyPolicy.swift`) decides row by row. It denies by default
and checks these rules in order:

1. If Process Monitor itself runs with admin rights, nothing can be quit.
2. `kernel_task`, `launchd` and Process Monitor itself are locked.
3. The effective, real and saved user IDs must all be yours. This also locks a
   `sudo` you started.
4. The program's path must be readable.
5. Anything in `/System/Library/CoreServices` (Finder, Dock, the login window,
   Control Center, …) and a short list of critical names and bundle IDs are
   locked.
6. macOS code (anything in `/System`, `/usr`, `/bin`, `/sbin`, `/Library/Apple`,
   or signed as part of macOS) can be quit only in two cases. The first is when
   it's a Dock app (Safari, Mail, Terminal, …). The second is when something you
   launched started it, like a `python3` or `sleep` run from Terminal. The app
   checks this by walking up the parent processes.
7. Everything else you own can be quit: apps in `/Applications`, Homebrew and
   developer tools, apps run from a disk image, and so on.

Just before sending anything, the app reads the process again. It must have the
same pid, start time, path and owner, and it must still pass the policy. Only then
does the app send the signal. Apps get the normal "quit" request first. If one
doesn't exit within 5 s, the row offers **Force Quit**.

## Where the numbers come from

| Column | Source |
|---|---|
| CPU % | `proc_pid_rusage` CPU time, converted from Mach ticks. 100% = one core, as in Activity Monitor |
| Memory | `ri_phys_footprint`, the same "Memory" figure Activity Monitor shows |
| GPU % | GPU time of each process's clients under the GPU driver in the IORegistry |
| Totals | Mach host statistics, `hw.memsize` and the kernel's memory-pressure level |

macOS only gives CPU and memory figures to the process's owner. For other users'
processes, "All processes" shows approximate values from `/bin/ps`, marked with
"≈". Per-process GPU memory isn't exposed by macOS, so it isn't shown.

## Why it isn't in the Mac App Store

App Store apps must be sandboxed, and the sandbox forbids listing or quitting
other processes. Process Monitor runs unsandboxed instead. It still never asks for
administrator rights.

## Layout

```
Sources/MonitorCore/     platform-independent logic: safety policy, rates, grouping,
                         list building, quitting (tested on Linux and macOS)
Sources/MonitorDarwin/   macOS system access: sysctl/libproc, IOKit, Security, kill(2)
Sources/ProcessMonitor/  the SwiftUI app
Tests/                   unit tests (Swift Testing) and macOS integration tests
scripts/build-app.sh     builds and signs the .app bundle
```

CI (`.github/workflows/process-monitor.yml`) runs the core tests on Linux. On an
Apple Silicon macOS runner it builds everything, runs all tests, bundles the app,
checks the signature and launches the app.

## Known limitations

- A system tool orphaned to launchd, such as a disowned `/bin/sleep` whose
  terminal was closed, stays locked. Quit it from Terminal instead.
- Background agents that macOS keeps alive restart after you quit them. The app
  tells you when that happens.
- Under Rosetta, CPU times can't be converted, so the app is built for arm64 only
  and hides CPU numbers if it's ever run translated.
