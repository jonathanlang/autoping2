# Autoping 2

Menu bar app (Swift 6, SwiftPM, macOS 14+, Apple Silicon) that rebuilds the Intel-only
autoping 1.02 by Memset Ltd. (2013), which dies with Rosetta 2 in macOS 28.
README.md (English, public facing) has the overview and the reconstructed algorithm;
build quirks and diagnostics live only here.

Jon writes in German: answer in German. Code, comments and commit messages are English.

## Build and test

Only through the scripts, never plain `swift build` / `swift test`:

- `Scripts/test.sh` – unit tests (Swift Testing)
- `Scripts/build.sh` – release build, assembles and ad-hoc signs `dist/Autoping.app`
- `Scripts/build.sh --install` – also quits the running copy, installs and launches it.
  Target is /Applications, or ~/Applications while the old `/Applications/autoping.app`
  exists (the names clash on the case-insensitive file system).

The app is only ad-hoc signed, so on another Mac build it there instead of copying the
.app (Gatekeeper blocks a copied one).

Toolchain constraints, found on a Mac with Command Line Tools only (no Xcode, SDK 27):

- `--build-system native` everywhere: SwiftPM's default build system fails to start
  ("Unknown error parsing property list") because of an empty leftover
  `CommandLineTools/SDKs/MacOSX12.3.sdk`. It is root-owned; don't delete it without asking.
- No SwiftUI `@State` (nor `@Entry` and other SwiftUI macros): their plugin ships only
  with Xcode. View state lives in small `@Observable` models (`PopoverState`,
  `SettingsModel`); `@Bindable` and `@FocusState` work.
- Swift Testing needs the extra `-F`/rpath/plugin-path flags that `Scripts/test.sh` adds.
- Swift 6 strict concurrency: closures passed to `DispatchSource` handlers from
  `@MainActor` code must be marked `@Sendable`, otherwise they trap at run time on the
  source's queue.

## Layout

- `Sources/AutopingCore` – pure, unit-tested logic
  - `ConnectionScorer` – the original's scoring, reverse-engineered from its binary.
    Keep it 1:1 with the original and covered by tests.
  - `ICMPPacket` – echo request building, reply parsing (IPv4 replies include the IP header)
  - `StatCounter` – sent/replied/lost/avg/min/max
- `Sources/Autoping` – the app
  - `ICMPPinger` – unprivileged ICMP sockets (`SOCK_DGRAM`) for IPv4/IPv6, address
    fallback, reads on a background queue and hops to the main actor
  - `ConnectionMonitor` – `@Observable` state: 1 s ping and housekeeping, watchdog, grace
    periods after start, wake and network changes, 5 min history, session and all-time stats
  - `StatusItemController` – NSStatusItem, popover, right-click menu; re-renders through
    `withObservationTracking`
  - `PopoverView`, `SettingsView` – SwiftUI
  - `Preferences` – UserDefaults, key names taken from the original app
  - `StatsStore` – JSON per host in Application Support
  - `SystemServices` – SMAppService login item, notifications
  - `Snapshot` – diagnostics, see below
- `Resources/*.lproj` – the English text is the key; every new user-facing string needs a
  German entry in `de.lproj/Localizable.strings`.
- `Support/Info.plist` – `__VERSION__` / `__BUILD__` are filled in by build.sh;
  `Support/AppIcon.icns` comes from `Scripts/make-icon.swift`.

## Checking UI changes

Claude has no screen-recording access here, so check UI changes with the snapshot mode:

```bash
dist/Autoping.app/Contents/MacOS/Autoping -SnapshotDirectory <scratch dir> -SnapshotDelay 8
```

It renders the menu bar item, popover and settings (light and dark) to PNG and prints a
short report to stderr (menu bar title, settings window position), then keeps running –
kill it afterwards. Any preference can be overridden by argument, e.g. `-Hostname 192.0.2.1`
(dead host), `-AddressPreference 2` (force IPv6), `-AppleLanguages '(en)'`.
These runs share the real app's preferences domain and `stats.json`.

Logs: `log stream --predicate 'subsystem == "de.jonathanlang.Autoping"'`

## Status

Verified by Claude: pinging over IPv4 and IPv6, automatic address choice, DNS failure,
dead host, missing route, German/English, light/dark rendering, settings window centering.
Jon has the app installed and running. Not verified by Claude (needs a real session): popover
and right-click interaction, notifications, launch at login, sleep/wake, network changes.
