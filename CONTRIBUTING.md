# Contributing

Bug reports and fixes are welcome. For anything larger than a fix, open an issue first so we can agree on the
approach before you spend time on it.

## Building

You need a Mac with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
Scripts/build.sh --unsigned          # compiles; this is what CI runs, Debug and Release
```

An unsigned build has no HomeKit and no keychain, so it reads no home and serves nothing: enough to work on the panel
(`Scripts/test.sh /tmp/wingman-snapshots` draws it with synthetic data) and the code that does not need HomeKit. To run it
for real you need a signed build:

- **Your own team.** HomeKit is an Apple Developer Program capability that Developer ID cannot carry, so Wingman is
  signed for development. Set `DEVELOPMENT_TEAM` in `project.yml` to your team, and change the bundle identifiers
  under `com.mpconsulting` to yours; do not commit those changes.
- **The first signed build:** `PROVISION=1 Scripts/build.sh` lets Xcode register the App ID, this Mac and a
  development profile. If it reports "Entitlement com.apple.developer.homekit not found", open the generated project
  in Xcode once (Signing & Capabilities) and build again.
- `Scripts/build.sh --install` copies it to `~/Applications` and launches it with `open` (launched from a shell, macOS
  kills it for want of the shell's HomeKit usage text).

Builds live outside the repository (`~/Library/Caches/HomeswiftWingman`): files under `~/Documents` carry Finder
metadata that codesign refuses.

## Changes

- **The API is shared with Homeswift's Wingman plugin** (`Plugins/Wingman` in
  [homeswift](https://github.com/mp-consulting/homeswift)). Keep it compatible: add fields rather than rename them,
  and bump `apiVersion` (and the TXT record's `v`) for a change an older plugin cannot read. A change the plugin needs
  goes to both repositories, and its fake (`Plugins/Wingman/Tests/FakeWingman.swift`) follows.
- **Security:** never log a pairing code, a token or a key; keep tokens only as their SHA-256; keep lock, garage door
  and alarm targets refused; every route but `/info` and `/pair` needs a token.
- **The menu bar bundle** (`MenuBar/`) is AppKit only and shares no types with the app: it draws the dictionary
  `MenuBarBridge` gives it and sends actions back as strings. The app (`App/`) owns HomeKit and the server; it does not render a separate window.
- Changes that users notice get a line in the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md), and the README
  follows the API and menu-bar panel.
- Panel changes: look at the tabs in dark and light (`Scripts/test.sh /tmp/wingman-snapshots`, or the CI artifact) before proposing them.

The pull request template has the checklist.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
