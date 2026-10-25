# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

The first version, 0.2.0 in `project.yml`, not released yet.

### Added

- A Mac Catalyst menu bar app that reads the Home app's homes, rooms, zones, scenes and accessories through HomeKit,
  follows their value changes, and writes values, refusing lock, garage door and alarm targets.
- A JSON API over TLS on every interface (port 8619): `/info`, `/pair`, `/status`, `/homes` (ids, HomeKit's ranges,
  each accessory's bridge and room, which ones are Matter), `/events` (numbered, with a long-poll: `?since=&wait=`),
  `/read`, `/write` (by characteristic id).
- Bonjour: `_homeswift-wingman._tcp`, with the API version, Wingman's id and a hash of its homes in the TXT record.
- TLS with a self-signed P-256 certificate made at the first launch and kept in the keychain; bridges pin it.
- Pairing: a six-digit code for ten minutes from the menu or the window; a token per bridge, kept only as its
  SHA-256; five wrong codes close the pairing; the window removes a bridge.
- A window with Liquid Glass on macOS 26, after apple-mail-mcp's panel: Home, Bridges and Settings (Bonjour, the port,
  whether bridges may change accessories, open at login). `--snapshot DIR` draws it to PNG.
- `Scripts/release.sh` and `Scripts/make-dmg.sh`: a development-signed disk image and its GitHub release, for the
  Homebrew cask `mp-consulting/tap/homeswift-wingman`.
- CI: Debug and Release built unsigned on every push, the window's snapshots kept as an artifact.

### Changed

- Named Homeswift Wingman; it began as a spike called Homeswift Sidecar, which served plain JSON on 127.0.0.1.
