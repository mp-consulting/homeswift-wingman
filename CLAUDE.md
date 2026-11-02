# Homeswift Wingman

A Mac Catalyst menu bar app that reads Apple Home through HomeKit and serves it over TLS to paired Homeswift bridges.
README.md covers the product and API; CONTRIBUTING.md covers building, API compatibility and security rules. Read both
before larger changes.

## Layout

- `App/`: Catalyst side. HomeKit (`HomeStore`), the TLS API (`LocalServer`), pairing, settings, and the demo mode
  (`DemoStore`, `DemoBridge`). `MenuBarBridge` turns state into a plain dictionary for the panel.
- `MenuBar/`: AppKit bundle loaded at runtime. It draws that dictionary and sends actions back as strings. It shares
  no types with `App/`.
- `Tests/`: plain executables compiled by `Scripts/test.sh` against the real sources, with synthetic data only.
- `project.yml`: XcodeGen. The `.xcodeproj` is generated; edit `project.yml` instead.

## Commands

```sh
Scripts/test.sh /tmp/wingman-snapshots   # all tests, plus panel PNGs in light and dark
bin/dev run                              # signed Debug build, installed to ~/Applications and launched
bin/dev info                             # query the running app (WINGMAN_PORT=8620 bin/dev info for another port)
BUILD_NUMBER=<n> Scripts/app-store.sh            # App Store archive
BUILD_NUMBER=<n> PROVISION=1 Scripts/app-store.sh export   # signed .pkg for Transporter
```

Builds run from a copy in `~/Library/Caches/HomeswiftWingman/source`; edit the checkout, not that copy.

## Gotchas

- The iOS deployment target must stay at the Catalyst iOS-support version (27.0 for macOS 27.0.1). A higher value
  stops the app building or running on this Mac. The macOS minimum (`LSMinimumSystemVersion`) is separate.
- Catalyst creates an empty host window at launch and on reactivation. Never order it out: HomeKit refuses accessory
  writes (`HMErrorDomain 80: Missing entitlement for API`) from an app with no window on screen, while reads keep
  working. `HostWindow` in `MenuBar/StatusMenu.swift` makes it transparent and click-through just before AppKit first
  shows it. The scene delegate cannot do this, because no UIWindow exists.
- Only one copy of the app should be installed. macOS relaunches whichever copy Launch Services prefers (for
  example after a Home permission change), so a stale `/Applications` copy hides fixes in `~/Applications`.
- Lock, garage door and alarm writes are refused unless `Settings.allowSecurity` (off by default), in `HomeStore` and
  `DemoStore`. Keep the two in step.
- Structural edits (rooms, scenes, automations: `StructureEdit` in `App/Structure.swift`) need `Settings.allowStructure`
  (off by default), checked in `LocalServer`; `HomeStore+Structure.swift` and `DemoStore` apply them with the same
  administrator, security and value checks. HomeKit tells this app's delegate only of changes made elsewhere, so an
  edit Wingman makes adds its own event.
- Demo mode (Settings › Demo) serves a synthetic home labelled "Demo" and "(Synthetic)" everywhere. It exists so
  App Review can assess the app without a home or bridge. Keep every demo name, status field and banner clearly marked.
- The app is "Homeswift Wingman.app" with the executable "Homeswift Wingman" (`PRODUCT_NAME`); the Swift module stays
  `HomeswiftWingman`. Its process name is longer than the 16 characters `pgrep -x` sees, so match the path instead.
- `APP_STORE` builds exclude the GitHub updater. Check both variants when touching `MenuBar/`; `Scripts/test.sh`
  builds the panel both ways.

## Conventions

- Match the surrounding style: short doc comments explaining why, no extra abstraction.
- User-visible changes get a line under `[Unreleased]` in CHANGELOG.md.
- Commit messages: imperative subject, wrapped body explaining why. Do not add `Co-Authored-By` trailers.
