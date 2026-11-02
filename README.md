# Homeswift Wingman

The Home app's accessories for [Homeswift](https://github.com/mp-consulting/homeswift), from a Mac. Wingman is a menu
bar app that reads Apple Home through HomeKit (homes, rooms, accessories, their values as they change) and serves it
over TLS to the Homeswift bridges paired with it, wherever they run: the same Mac, a Synology, a Linux container. It
rides alongside the bridge, hence the name.

Homeswift's **Wingman** plugin finds it over Bonjour, pairs with the code it shows, and mirrors its accessories into the
web UI, moods, scenes and the MCP tools, Matter ones included (Hue, IKEA), without publishing them to HomeKit again.
HomeKit exists on the Mac only for Mac Catalyst apps (the Home app is one), so Wingman is one.

## Install

Requires macOS 27.0.1 or later on Apple Silicon.

```sh
brew install --cask mp-consulting/tap/homeswift-wingman
```

Open it, allow access to Home data, and a winged house appears in the menu bar. Wingman is signed for development (HomeKit is
not available to Developer ID apps, see [Signing](#signing-no-developer-id-no-notarization)): it runs only on the Macs
registered in its developer's team, and macOS asks once before opening it (System Settings › Privacy & Security › Open
Anyway). Releases are made on such a Mac with `Scripts/release.sh`, which builds the version in `project.yml` signed,
packs `HomeswiftWingman-<version>.dmg`, tags it and creates the GitHub release; the tap's cask follows within 6 hours.

## Updates

Settings includes **Check for Updates…**, automatic daily checks, release notes and **Install & Relaunch**.
Wingman downloads the latest GitHub release with progress, verifies the disk image and app against the
publisher’s Apple signing team and bundle identifier, checks the version, then replaces the app and relaunches.
The app must be installed on a writable disk and signed by Wingman’s developer. Development-signed releases
still require this Mac to be registered with the team. Older unsigned disk images cannot be installed by the updater.

The winged-house artwork is drawn by `MenuBar/WingmanIcon.swift`; regenerate app icon assets with:

```sh
swiftc MenuBar/WingmanIcon.swift Scripts/generate-icon.swift -o /tmp/wingman-icon
/tmp/wingman-icon
```

## Pair a Homeswift bridge

1. In Homeswift's web UI, open **Plugins › Wingman › On the network**: it lists the Wingman apps Bonjour finds.
2. In Wingman's menu, choose **Pair a Homeswift Bridge…**: it shows a six-digit code for ten minutes.
3. On the Homeswift page, choose **Pair**, check that the certificate starts as the one in Wingman's window (Bridges
   tab), and type the code.

The Home app's accessories then appear on Homeswift's Accessories page, in their rooms. Wingman's window lists the
paired bridges and removes one.

## The app

The menu bar item shows the headline, the homes and the pairing code. **Open Wingman…** (⌘,) opens its window, after
apple-mail-mcp's menu bar panel: SwiftUI with Liquid Glass on macOS 26, three tabs.

- **Home:** the rooms and their accessories, those not responding, the value changes received, **Read All**.
- **Bridges:** the pairing code with its countdown, the paired bridges (Remove), the certificate's fingerprint.
- **Settings:** advertise over Bonjour, the port (8619), whether paired bridges may change accessories, open at login.

The window is the Catalyst side's: SwiftUI cannot run in the AppKit bundle, because a Catalyst process loads the iOS
SwiftUI. The menu bar item lives in that bundle (`MenuBar/`, loaded from `Contents/PlugIns`), because a Catalyst app
cannot make an `NSStatusItem` itself. The settings live in the app's user defaults; `WINGMAN_PORT` wins over the port.

## Security: discovery, TLS and pairing

- **Bonjour:** `_homeswift-wingman._tcp` on every interface, named after the Mac. The TXT record has `v` (the API
  version, `1`), `id` (Wingman's, made once) and `home` (16 hex digits of the SHA-256 of the homes' identifiers), so
  a bridge that finds Wingman on two Macs of the same home keeps one. Nothing else: anyone on the network reads it.
- **TLS:** a P-256 key and a self-signed certificate made at the first launch and kept in the data protection
  keychain (label "Homeswift Wingman TLS"). It names nothing and lasts until 2049: the bridge pins its SHA-256 when it
  pairs (Homeswift's `HTTPClient` trust `.pinned`), and a new certificate would unpair every bridge. The menu shows the
  start of the fingerprint under Paired Bridges, to compare with what the bridge shows.
- **Pairing:** Pair a Homeswift Bridge… shows a six-digit code for ten minutes. `POST /pair` with it returns a token
  (32 random bytes); the code serves once and five wrong ones close the pairing. Every route but `/info` and `/pair`
  needs `Authorization: Bearer <token>`. Only each token's SHA-256 is kept, with the bridge's name and when it was
  last seen, in `~/Library/Application Support/com.mpconsulting.HomeswiftWingman/bridges.json` (owner only). The menu
  removes a bridge.
- **What pairing trusts:** the code goes over TLS to a certificate the bridge has not seen yet, so someone who sits
  between the two on the network during those ten minutes could pair in the bridge's place. After pairing the
  certificate is pinned. HAP closes that gap with SRP; a later version could too, or the bridge can show the
  fingerprint to compare with the menu.

- **What bridges can do:** read the homes and values, and write values unless **Let bridges change accessories** is
  off. Lock, garage door and alarm targets are refused before HomeKit is asked unless **Let bridges operate locks and
  doors** is on too (off by default). Homeswift asks its user to confirm each such change, but Wingman cannot see
  that confirmation, so the owner of this Mac opts in here. Renaming rooms, moving accessories between rooms and
  editing scenes and automations needs **Let bridges edit rooms, scenes and automations** (off by default) for the same
  reason, and an edit reaches every device of the home through iCloud. Running a scene needs only **Let bridges change
  accessories**, and a scene that operates a lock, garage door or alarm runs only while bridges may operate them.

## The API

JSON over HTTPS on port 8619, version 1. Every route but `/info` and `/pair` needs the token pairing gave.

```sh
dns-sd -B _homeswift-wingman._tcp    # Bonjour: the instance, with v, id and home in its TXT record
curl -sk https://127.0.0.1:8619/info # id, version, certificate fingerprint, whether pairing is open
# Menu → Pair a Homeswift Bridge… shows a six-digit code for ten minutes:
curl -sk https://127.0.0.1:8619/pair -d '{"code": "123456", "name": "My bridge"}'   # → {"token", …}
H="Authorization: Bearer <token>"
curl -sk -H "$H" https://127.0.0.1:8619/status        # authorization, counts, events received, last read
curl -sk -H "$H" https://127.0.0.1:8619/homes         # homes → rooms, zones, scenes, accessories → services → characteristics
curl -sk -H "$H" https://127.0.0.1:8619/events        # the latest value changes HomeKit pushed, newest first
curl -sk -H "$H" "https://127.0.0.1:8619/events?since=42&wait=25"   # those after seq 42, waiting up to 25 s for one
curl -sk -H "$H" -X POST https://127.0.0.1:8619/read  # reads every readable value; failures grouped by error
curl -sk -H "$H" https://127.0.0.1:8619/write -d '{"accessory": "<id>", "characteristic": "<id>", "value": true}'
```

Homeswift's Wingman plugin (`Plugins/Wingman` in the homeswift repository) uses it this way: `/homes` gives every
service and characteristic an `id` (HomeKit's `uniqueIdentifier`), HomeKit's ranges (`min`, `max`, `step`,
`validValues`) and, for a bridged accessory, its `bridge` (so a Homeswift bridge leaves out its own accessories);
`/events?since=&wait=` is a long-poll whose events carry `seq`, `kind`, `accessoryID`, `characteristicID` and `type`
(a `kind` of `homes`, with no characteristic, says accessories, rooms, names or reachability changed: the plugin reads
`/homes` again), whose `last` says when Wingman restarted (lower than `since`) and whose `first` is the oldest event
kept (500 at most: a `since` before `first - 1` missed some, and the plugin reads `/homes` again); `POST /write` takes
the characteristic's `id`.

## Rooms, scenes and automations

`GET /info` lists `"features": ["structure"]` and `"structure": true|false` (whether **Let bridges edit rooms, scenes
and automations** is on): additive, so `api` stays `1` and an older bridge ignores it. Each home in `/homes` has its
`id`, its `rooms` (`[{"id", "name", "accessories"}]`) and `editable` (whether this Mac's user administers it: HomeKit
refuses structural edits otherwise). Ids are HomeKit's `uniqueIdentifier`s.

```sh
curl -sk -H "$H" https://127.0.0.1:8619/scenes        # every home's scenes (action sets) and their actions
curl -sk -H "$H" https://127.0.0.1:8619/automations   # every home's automations (triggers)
curl -sk -H "$H" https://127.0.0.1:8619/rooms/rename -d '{"room": "<id>", "name": "Lounge"}'
```

| Method and path | Body | Does |
|---|---|---|
| `POST /rooms/rename` | `{"room", "name"}` | Renames the room |
| `POST /accessories/room` | `{"accessory", "room": name}` | Moves the accessory to its home's room of that name (case aside), added when there is none |
| `POST /scenes/run` | `{"scene"}` | Runs the scene (needs **Let bridges change accessories** only) |
| `POST /scenes/rename` | `{"scene", "name"}` | Renames a scene; built-in ones keep their names |
| `POST /scenes/actions` | `{"scene", "actions": [{"accessory", "characteristic", "value"}]}` | Makes the scene write exactly these characteristics: others removed, kept ones updated, new ones added |
| `POST /scenes/create` | `{"home", "name", "actions"}` | Adds a scene; answers `{"id"}` |
| `POST /scenes/delete` | `{"scene"}` | Removes a scene; built-in ones stay |
| `POST /automations/enable` | `{"automation", "enabled"}` | Turns it on or off |
| `POST /automations/rename` | `{"automation", "name"}` | Renames it |
| `POST /automations/time` | `{"automation", "time"}` | A new time for one that starts at a time |
| `POST /automations/scenes` | `{"automation", "scenes": [ids]}` | Makes it run exactly these scenes |
| `POST /automations/actions` | `{"automation", "actions"}` | As `/scenes/actions`, on its own actions |
| `POST /automations/delete` | `{"automation"}` | Removes it |

Errors are `{"error": "…"}` with `400` (a bad body, or an action naming an accessory the home lacks, a characteristic
it cannot set, a value outside its format or range, or one characteristic twice), `403` (the setting is off, the user
does not administer the home, or a lock, garage door or alarm without **Let bridges operate locks and doors**), `404`
(no such room, scene, automation or home) or `422` (HomeKit refused, with its `HMErrorDomain` code; `done` counts the
changes made before it: HomeKit has no transaction). Every action is checked before anything changes.

- **Scenes:** `{"id", "home", "name", "type", "builtIn", "executing", "actions", "unsupported"}`. `type` is `user`,
  `wakeUp`, `sleep`, `homeArrival` or `homeDeparture`; the four built-in ones can be run and their actions changed, not
  renamed or deleted. Each action is `{"accessory", "characteristic", "type", "value"}`. `unsupported` counts actions
  Wingman cannot show (shortcuts, media): they are never replaced. An automation's own actions are listed with it, not here.
- **Automations:** `{"id", "home", "name", "enabled", "trigger", "endEvents", "conditions", "executeOnce", "scenes",
  "actions", "unsupported"}`. `trigger.kind` is `time` (a timer, or an event trigger whose only event is a sunrise,
  sunset or time of day) with `trigger.time`, or `event` with `trigger.events`. A time is `{"hour", "minute"}` or
  `{"significant": "sunrise|sunset", "offsetMinutes"}`, with `weekdays` (1 is Sunday; none is every day). An event is
  `characteristic` (`accessory`, `characteristic`, `type`, `value`), `threshold` (`min`, `max`), `presence` (`who`:
  `me`, `anyone` or `everyone`, `arriving`), `location` (`arriving`; the region is left out), `duration` (`seconds`,
  as an end event), `time` or `other` (`text`). Conditions are `time` (`after`, `before`), `characteristic`
  (`comparison`, `value`), `presence` (`who`, `home`) or `other` (`text`, the predicate as HomeKit writes it): Wingman
  recognises a part of the predicate by building it again with HomeKit's own predicate builders.
- **Times:** a timer takes a clock time, every day or on one weekday; an event trigger takes a clock time or a sunrise
  or sunset with an offset, on any weekdays. An automation started by accessories or presence keeps its events: the
  Home app edits those, its end events and its conditions.
- **Own actions:** HomeKit's API cannot give an automation actions of its own; `/automations/actions` changes those it
  has, and refuses to add some to one that has none.
- **Events:** `scenes` and `automations` events say those changed (in the Home app or through Wingman), `homes`
  covers rooms and accessories' rooms, and `settings` says the owner turned the edits on or off: the bridge asks
  `/info` again. Like `homes`, they are coalesced over a second and name no characteristic.

## Building

For local development, run these from the checkout:

```sh
bin/dev run                        # build, install and launch
bin/dev provision                  # first build: allow Xcode provisioning updates
bin/dev status                     # running process and local API health
bin/dev logs                       # stream app logs
bin/dev restart                    # restart without rebuilding
bin/dev doctor                     # check tools and signing identities
bin/dev help                       # all commands, including build, unsigned, open and stop
CONFIGURATION=Release bin/dev run   # test a Release build
```

`bin/dev` builds a source copy in `~/Library/Caches/HomeswiftWingman/source` to avoid Xcode file-coordination
stalls in Documents. Edit this checkout, not the copy; each build refreshes it. App data and pairings are preserved.
`info` and `status` query port 8619 by default; set `WINGMAN_PORT` to query a different port configured in the app.
If provisioning reports a missing HomeKit entitlement, open the generated project in the source copy in Xcode
and check Signing & Capabilities once, then retry `bin/dev provision`.

The underlying build script is also available:

```sh
Scripts/build.sh --unsigned          # compile only (an unsigned build has no keychain, so it serves nothing)
PROVISION=1 Scripts/build.sh         # first signed build: Xcode registers the App ID, this Mac and a development profile
Scripts/build.sh --install           # ~/Applications/Homeswift Wingman.app, launched
Scripts/test.sh /tmp/wingman-snapshots   # isolated regression tests and actual panel PNGs, dark and light
```

`Scripts/build.sh` generates the Xcode project with XcodeGen (`project.yml`) and builds outside the repository. Launch
the app with `open` (or from Finder): started from a shell, macOS checks the shell's Info.plist for the HomeKit usage
text and kills the app. CI builds Debug and Release unsigned on every push and keeps the menu-bar panel's snapshots.

## Signing: no Developer ID, no notarization

Apple's "Supported capabilities (macOS)" table lists HomeKit for the Apple Developer Program (development and
App Store) only, not for Developer ID. So the apple-mail-mcp process (Developer ID, notarized DMG, Homebrew cask)
cannot ship this app with HomeKit. The ways out:

- **Development signing** (what Wingman does): runs on Macs registered in the team's account, with a development profile
  that expires every year. Fine for one's own bridge Mac, not for other people.
- **Mac App Store or TestFlight for Mac**: needs the App Sandbox (`com.apple.security.network.server` for the local
  server) and App Review.

## What HomeKit does on the Mac (2026-10-25, macOS 27, one home)

- **Provisioning:** `xcodebuild -allowProvisioningUpdates` registered this Mac and made a wildcard Mac Catalyst profile, but
  would not turn HomeKit on for the App ID ("Entitlement com.apple.developer.homekit not found"), even with
  `SystemCapabilities` in the project. Opening the project in Xcode once did it; command line builds work since.
- **Permission:** the prompt is per signature: the ad-hoc test copy and the development build each asked.
- **Homes:** 1 home, 19 rooms, 2 zones, 40 scenes, 120 accessories (114 bridged), 361 services, 1,523
  characteristics, all with their room. Bridged accessories report the category "Other"; their services say what
  they are. Homeswift's own accessories are there (manufacturer per plugin, bridged), so a plugin must skip them.
- **Reading every value** (`POST /read`): 1,383 readable characteristics in under a second; 1,107 read, 276 failed
  with `HMErrorDomain 74` ("Read/Write operation failed"). The failures are exactly the 66 **Matter** accessories
  (`"matter": true`: a service with a `matterEndpointID`): the Hue bridge and its lights and sensors, IKEA DIRIGERA
  and its devices, the Nuki lock, and 41 bridged ones reporting manufacturer "Unknown". All 54 HAP accessories read
  fine, Homeswift's included. Half of the Matter characteristics still have a cached value. `matterNodeID` is no
  test: every accessory has one, HAP ones too.
- **Events:** value changes arrive, from Matter accessories too (Hue lights and sensors): notifications work
  where reads fail. The app reports `active` the whole time, as a menu bar app: no background state so far.
- **Writing** (`POST /write`): a Matter ceiling light took hue 0 and saturation 100 in about 0.07 s, although every
  read of it fails. Two Matter lamps switched off at the wall refused with the same `HMErrorDomain 74` in 30–40 ms,
  while HomeKit still listed them as reachable: for Matter devices `reachable` lags, and error 74 on a write means
  the device did not answer. No event came back from the light after the write; HomeKit's value is the one written.
  Lock, garage door and alarm targets are refused before HomeKit is asked, unless bridges may operate locks and doors.
- **Writing needs a window on screen:** with Catalyst's host window ordered out, every write fails with
  `HMErrorDomain 80` ("Missing entitlement for API") while reads and events go on. Wingman keeps that window on
  screen, transparent and click-through.
- **Soak test:** `/status` has `startedAt`, `lastEventAt` and `eventsPerHour` (UTC hours); a gap across a night of
  screen lock and sleep would show HomeKit stopped sending.

## Not done yet

- A password-authenticated pairing (SRP, as HAP does), so the ten minutes of pairing no longer trust the network.
- A night-long soak test of the signed build: HomeKit's events across screen lock and sleep.
- The structural edits against a real home: they are built on HomeKit's public API and tested on the demo home only.
  Whether HomeKit takes them from a menu bar app as it takes writes, and how the Home app's automations on recent
  systems (event triggers with calendar events) take a new time, is still to be seen.
- Linux, which has no HomeKit.

## License

MIT, see [LICENSE](LICENSE). [CONTRIBUTING.md](CONTRIBUTING.md) says how to build and propose a change;
[CHANGELOG.md](CHANGELOG.md) lists what changed.

## Menu-bar panel

Click the Wingman winged house in the macOS menu bar to open its borderless panel directly beneath the icon, matching
apple-mail-mcp’s compact header, pill tabs, sectioned rows and footer. Home, Bridges and Settings stay in this panel, including pairing; click outside or press
Escape to dismiss it. Snapshots render this same AppKit panel with synthetic fixtures; they never load real homes, pairings or Keychain data.

## Regression tests

Run `Scripts/test.sh /tmp/wingman-snapshots` on macOS with Xcode installed. Tests compile the production parser,
server, pairing store and AppKit panel. Storage is temporary; the network server binds loopback with a fake
HomeKit store and no Bonjour. Production still requires its Keychain TLS identity. No real accessories or
pairings are changed. CI runs the tests and requires all eight light/dark panel snapshots to render. These
bitmap fixtures verify layout; macOS composites native glass separately, so inspect the installed panel
when reviewing its glass appearance.

Requests are limited to 64 connections, 16 KiB of headers and 64 KiB total. A connection has ten seconds to
complete its TLS handshake and request; responses are bounded to 90 seconds. Removing a paired bridge cancels
its pending requests. Pairing and removal report storage failures instead of claiming success.

### Identify

Accessory JSON includes HomeKit’s `supportsIdentify` flag. A paired bridge can send
`POST /write` with `{"accessory":"<id>","characteristic":"Identify","value":true}`
to invoke HomeKit’s native identification action. It requires “Let bridges change accessories”,
checks device support and returns HomeKit failures. Room assignments are unchanged.

## Demo mode

Settings › Demo (or **Try Demo Mode** when Wingman has no Home access or no homes) serves a synthetic
"Demo Home (Synthetic)" instead of HomeKit's homes: seven accessories named "Demo …", one not responding.
Every tab shows an orange DEMO MODE banner, the status line says so, and `/status` and `/homes` carry `"demo": true`.
Writes change only these in-memory values; lock, garage door and alarm targets follow the same setting as
real ones. Its rooms, three scenes ("Demo Evening (Synthetic)", the built-in "Good Night (Demo)", and "Demo Leave Home
(Synthetic)", which locks the door) and two automations ("Demo Sunset (Synthetic)", "Demo Motion Light (Synthetic)")
take every edit above in memory, with the same settings and checks.

In demo mode the Bridges tab adds a **demo bridge** that runs inside Wingman: it pairs with a fresh code over TLS,
pinning the certificate, reads the home, switches the demo floor lamp and is refused an unlock (or unlocks the demo lock while
**Let bridges operate locks and doors** is on). Remove it like any
bridge to see its token revoked on the next run. Turning demo mode off removes it. Bridges already paired see the
synthetic home while demo mode is on.

## Mac App Store preparation

The `AppStore` build configuration enables sandboxed networking, requires macOS 27.0.1+ on Apple Silicon,
and removes the GitHub updater in favor of Apple-managed updates. See
[App Store and TestFlight preparation](docs/app-store.md) for archive/export commands, signing,
privacy and review requirements. This configuration is not yet an approved App Store release.
