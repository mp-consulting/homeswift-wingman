import AppKit

/// Synthetic data only: snapshots never create a HomeKit manager, open Keychain, or start a server.
@MainActor enum PanelFixtures {
    static let model: [String: Any] = [
        "headline": "Serving 1 bridge on port 8619", "level": "ok", "summary": "1 home, 2 rooms, 3 accessories",
        "port": 8619, "listening": true, "serving": true, "advertise": true, "allowChanges": true, "allowSecurity": false, "allowStructure": false,
        "updateEnabled": true, "automaticUpdateChecks": true, "updateStatus": "Wingman is up to date.",
        "launchAtLogin": false, "version": "0.2.0", "fingerprint": String(repeating: "3f9a0c71", count: 8),
        "bridges": [["id": "demo-bridge", "name": "Demo Bridge"]],
        "homes": [["id": "demo-home", "name": "Demo Home", "rooms": [
            ["id": "living", "name": "Living Room", "accessories": [
                ["id": "lamp", "name": "Floor Lamp", "detail": "Light", "symbol": "lightbulb", "reachable": true],
                ["id": "sensor", "name": "Room Sensor", "detail": "Sensor", "symbol": "sensor", "reachable": false],
            ]],
            ["id": "office", "name": "Office", "accessories": [
                ["id": "desk", "name": "Desk Light", "detail": "Light", "symbol": "lightbulb", "reachable": true],
            ]],
        ]]],
    ]

    static var demoModel: [String: Any] {
        var model = Self.model
        model["demo"] = true
        model["headline"] = "Demo mode: synthetic home, not your HomeKit data"
        model["level"] = "warning"
        model["summary"] = "Demo: 1 home, 4 rooms, 7 accessories"
        model["bridges"] = [["id": "demo", "name": "Demo Bridge (Synthetic)"]]
        model["demoPaired"] = true
        model["demoLog"] = [
            "Paired over TLS with code 482 913, pinning Wingman’s certificate.",
            "Read Demo Home (Synthetic): 7 accessories.",
            "Turned Demo Floor Lamp off. See it in the Home tab.",
            "Unlock refused: Lock Mechanism Target State is a security control; not written through Wingman.",
        ]
        model["homes"] = [["id": "demo-home", "name": "Demo Home (Synthetic)", "rooms": [
            ["id": "demo-living", "name": "Living Room", "accessories": [
                ["id": "lamp", "name": "Demo Floor Lamp", "detail": "Lightbulb · Off", "symbol": "lamp.floor", "reachable": true],
            ]],
            ["id": "demo-entrance", "name": "Entrance", "accessories": [
                ["id": "lock", "name": "Demo Front Door Lock", "detail": "Door Lock · Locked", "symbol": "lock", "reachable": true],
            ]],
        ]]]
        return model
    }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    static func click(_ identifier: String, in controller: WingmanPopoverController) throws {
        guard let button = descendants(controller.view).compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == identifier || $0.title == identifier }) else {
            throw NSError(domain: "PanelFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing button: \(identifier)"])
        }
        button.performClick(nil)
    }

    static func snapshot(_ controller: WingmanPopoverController, at url: URL) throws {
        controller.view.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 760, pixelsHigh: 1040,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { throw NSError(domain: "Snapshot", code: 1) }
        bitmap.size = NSSize(width: 380, height: 520)
        controller.view.effectiveAppearance.performAsCurrentDrawingAppearance {
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw NSError(domain: "Snapshot", code: 2) }
        try png.write(to: url)
    }
}
