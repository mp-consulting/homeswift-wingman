import AppKit

@main struct PanelTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            do { try run(); exit(0) }
            catch { fputs("Panel tests failed: \(error)\n", stderr); exit(1) }
        }
        NSApp.run()
    }

    @MainActor static func run() throws {
        let panel = WingmanPopoverController()
        panel.model = PanelFixtures.model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 520), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentViewController = panel
        window.setContentSize(NSSize(width: 380, height: 520))
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "PanelTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func text(_ value: String) -> Bool {
            PanelFixtures.descendants(panel.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == value }
        }
        try PanelFixtures.click("room:living", in: panel)
        try expect(text("Floor Lamp") && !text("Desk Light"), "room expands")
        var homes = panel.model["homes"] as! [[String: Any]]
        var rooms = homes[0]["rooms"] as! [[String: Any]]
        rooms[0]["name"] = "Z Living Room"
        homes[0]["rooms"] = Array(rooms.reversed())
        panel.model["homes"] = homes
        try expect(text("Floor Lamp") && !text("Desk Light"), "expanded room survives reorder and rename")
        homes[0]["rooms"] = [rooms[1]]
        panel.model["homes"] = homes
        try expect(!text("Desk Light"), "removed room does not expand its replacement")
        panel.model = PanelFixtures.model
        let before = PanelFixtures.descendants(panel.view).first { $0.identifier?.rawValue == "room:living" }
        for count in 1...20 { panel.model["events"] = count }
        let after = PanelFixtures.descendants(panel.view).first { $0.identifier?.rawValue == "room:living" }
        try expect(before === after, "value updates preserve row identity")
        var actions: [String] = []
        panel.perform = { actions.append($0) }
        try PanelFixtures.click("Bridges", in: panel)
        try PanelFixtures.click("unpair:demo-bridge", in: panel)
        try expect(actions.isEmpty, "removal requires confirmation")
        try PanelFixtures.click("cancelRemoval", in: panel)
        try expect(actions.isEmpty, "cancel is nonmutating")
        try PanelFixtures.click("unpair:demo-bridge", in: panel)
        try PanelFixtures.click("confirmRemoval:demo-bridge", in: panel)
        try expect(actions == ["unpair:demo-bridge"], "confirm emits one removal")
        panel.model["pairingError"] = "Cannot save paired bridges. Retry removal."
        try expect(text("Cannot save paired bridges. Retry removal."), "storage error visible")
        try PanelFixtures.click("unpair:demo-bridge", in: panel)
        panel.cancelRemoval()
        try expect(!PanelFixtures.descendants(panel.view).contains { $0.identifier?.rawValue == "confirmRemoval:demo-bridge" }, "closing cancels confirmation")
        try PanelFixtures.click("Settings", in: panel)
        var update = PanelFixtures.model
        update["updateAvailable"] = true
        update["updateStatus"] = "Version 0.3.0 is available."
        panel.model = update
        #if APP_STORE
        try expect(text("Updates are delivered by the App Store or TestFlight."), "Apple-managed updates are explained")
        try expect(!PanelFixtures.descendants(panel.view).contains {
            ["installUpdate", "checkUpdate", "automaticUpdateChecks"].contains($0.identifier?.rawValue ?? "")
        }, "App Store build has no external updater controls even with an available update")
        #else
        try expect(text("Version 0.3.0 is available."), "available update is visible")
        try PanelFixtures.click("installUpdate", in: panel)
        try expect(actions.last == "installUpdate", "install requires an explicit click")
        update["updateBlocker"] = "Copy the app to Applications first."
        panel.model = update
        let install = PanelFixtures.descendants(panel.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "installUpdate" }
        try expect(install?.isEnabled == false, "blocked install is disabled")
        update.removeValue(forKey: "updateAvailable")
        update["updateBusy"] = true
        update["updateProgress"] = 0.5
        update["updateStatus"] = "Downloading…"
        panel.model = update
        let check = PanelFixtures.descendants(panel.view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "checkUpdate" }
        try expect(check?.isEnabled == false && text("Downloading…"), "download disables duplicate checks")
        #endif
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (style, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: style)
            window.appearance = NSApp.appearance
            panel.view.appearance = window.appearance
            panel.model = PanelFixtures.model
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            for tab in ["Home", "Bridges", "Settings"] {
                try PanelFixtures.click(tab, in: panel)
                try PanelFixtures.snapshot(panel, at: directory.appendingPathComponent("panel-\(tab.lowercased())-\(name).png"))
            }
            panel.model["pairingCode"] = "482913"
            panel.model["pairingUntil"] = Date().addingTimeInterval(600).timeIntervalSince1970
            try PanelFixtures.click("Bridges", in: panel)
            try PanelFixtures.snapshot(panel, at: directory.appendingPathComponent("panel-pairing-\(name).png"))
        }
        try expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".png") }.count == 8, "all actual panel screenshots rendered")
        print("PASS: stable room identities, row reuse, removal confirmation, storage errors and 8 AppKit panel snapshots")
    }
}
