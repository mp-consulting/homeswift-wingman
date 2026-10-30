# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

- Fix bridges on the network failing with "cannot reach Wingman (uncleanShutdown)" right after pairing. Wingman closed each connection as soon as its response was queued, which stalled larger responses such as the homes and dropped them after about 10 seconds; it now ends the response cleanly and waits for the bridge to hang up.
- Add a clearly labelled demo mode (Settings › Demo, or Try Demo Mode when there is no home) that serves a synthetic home, and a built-in demo bridge that pairs over TLS, switches a light and is refused a lock change, so Wingman can be evaluated without HomeKit devices or a Homeswift bridge.
- Hide the empty Catalyst window that appeared at launch and after granting Home access. It stays on screen, transparent and click-through: HomeKit refuses accessory changes from an app without a window on screen, which made 0.2.0 builds 5 and 6 fail every write with `HMErrorDomain 80`.
- Every build, App Store and TestFlight ones included, installs as "Homeswift Wingman.app" (it was "HomeswiftWingman.app"); the process is now "Homeswift Wingman". The bundle identifier, Home permission and paired bridges are unchanged.
- Prepare a sandboxed macOS 27.0.1+ App Store configuration with Apple-managed updates, privacy manifest, archive/export tooling, and regression coverage.

## [0.2.0] - 2026-10-25

- Report HomeKit identification support and forward Identify writes to its native identification action.
- Copy the pairing code on click, with a copy icon and visible confirmation.
- Add spacing between the menu-bar icon and the panel.

### Fixed

- Reject non-finite event wait durations and malformed or oversized HTTP requests; bound connection counts and request lifetimes.
- Persist pairing and removal transactionally, report storage failures, and cancel a removed bridge's pending requests.
- Save last-seen timestamps periodically even when bridges poll frequently; allow retrying a failed listener on the same port.
- Preserve room expansion by HomeKit UUID across renames and sorting changes.
- Test and snapshot the actual AppKit panel with synthetic data; remove the obsolete standalone SwiftUI interface.
- First launch no longer waits for hostname resolution when creating the TLS certificate.
- Build installation selects the requested Debug or Release product when both exist.

### Changed

- Add daily update checks, release notes, download progress and signature-verified installation with relaunch. Sign release disk images for the updater.

- Adopt the winged-house icon for the app, menu bar and panel header.

- Open Home, Bridges and Settings in a borderless panel beneath the menu-bar icon, matching apple-mail-mcp’s layout.
- Check port availability while editing, with inline validation and Apply blocked for invalid or occupied ports.
- Use native Liquid Glass for the panel and action buttons on macOS 26+, with a material fallback on older systems.
- Refine the panel with a compact layout, pill navigation, clearer section hierarchy and accessible contrast.
- Named Homeswift Wingman; it began as a spike called Homeswift Sidecar, which served plain JSON on 127.0.0.1.

### Added

- `bin/dev` commands for local builds, provisioning, launch, restart, status, logs and tool checks, using a source
  copy outside Documents to avoid Xcode file-coordination stalls.
- A Mac Catalyst menu bar app that reads the Home app's homes, rooms, zones, scenes and accessories through HomeKit,
  follows their value changes, and writes values, refusing lock, garage door and alarm targets.
- A JSON API over TLS on every interface (port 8619): `/info`, `/pair`, `/status`, `/homes` (ids, HomeKit's ranges,
  each accessory's bridge and room, which ones are Matter), `/events` (numbered, with a long-poll: `?since=&wait=`),
  `/read`, `/write` (by characteristic id).
- Bonjour: `_homeswift-wingman._tcp`, with the API version, Wingman's id and a hash of its homes in the TXT record.
- TLS with a self-signed P-256 certificate made at the first launch and kept in the keychain; bridges pin it.
- Pairing: a six-digit code for ten minutes from the panel; a token per bridge, kept only as its
  SHA-256; five wrong codes close the pairing; the panel removes a bridge.
- A menu-bar panel with Liquid Glass on macOS 26: Home, Bridges and Settings (Bonjour, the port,
  whether bridges may change accessories, open at login). `Scripts/test.sh` renders synthetic panel snapshots.
- `Scripts/release.sh` and `Scripts/make-dmg.sh`: a development-signed disk image and its GitHub release, for the
  Homebrew cask `mp-consulting/tap/homeswift-wingman`.
- CI: Debug and Release built unsigned on every push, regression tests and actual panel snapshots required, with images kept as artifacts.
