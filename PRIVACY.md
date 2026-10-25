# Homeswift Wingman privacy

Last updated: 25 October 2026.

Homeswift Wingman is developed by Mickael Palma. The App Store version does not
include advertising, tracking, analytics SDKs, or a developer-operated cloud service.
It does not send your Home data to its developer.

## Apple Home access

With your permission, Wingman reads the homes, rooms, accessories, identifiers,
capabilities and states available through Apple's HomeKit framework. It displays
that information on your Mac and shares it with Homeswift bridges you explicitly
pair. When accessory changes are enabled, paired bridges can request supported
device changes. Lock, garage-door and security-alarm writes are blocked.

Apple manages your Home data and HomeKit authorization. You can revoke Wingman's
HomeKit permission in macOS System Settings.

## Paired bridges and local storage

Wingman serves a TLS-protected API from your Mac. Pairing requires a short-lived
code; each paired bridge receives a revocable credential. The app stores its
identity and pairing information on your Mac using the app's storage and Keychain.
Settings and bridge names are stored locally. Recent accessory events are held in
memory to deliver updates to paired bridges. Network discovery announces the
Wingman service and identifiers on your local network.

You can remove a bridge in Wingman's Bridges tab to revoke its access, disable
accessory changes in Settings, or quit Wingman to stop serving data. Removing a
pairing does not erase data already received by that bridge. Manage retained data
and integrations in the bridge itself. A bridge may transmit data to other services
you configure, including AI providers; those services have their own privacy policies.

## Apple distribution and support

App Store and TestFlight delivery, purchase records, and any diagnostic information
you choose to share through Apple's services are governed by Apple's privacy
settings and policies. Wingman does not include its own analytics or crash uploader.

If you open a GitHub issue or otherwise contact support, the information you submit
is processed by that service and may be visible publicly. Do not include pairing
codes, tokens, private home details, or other secrets in public issues.

For questions, use [Wingman support](https://github.com/mp-consulting/homeswift-wingman/issues).
