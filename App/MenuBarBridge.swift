import HomeKit
import UIKit

/// Loads `MenuBar.bundle` (AppKit, in Contents/PlugIns) and hands it a plain dictionary to draw: the two sides share
/// no types, only the principal class's `model` and `actionHandler` properties.
@MainActor
final class MenuBarBridge {
    private let store: HomeStore
    private let pairing: Pairing
    private let server: LocalServer?
    private let panel: PanelModel
    private let problem: String?
    private var menu: NSObject?

    init(store: HomeStore, pairing: Pairing, server: LocalServer?, panel: PanelModel, problem: String?) {
        self.store = store
        self.pairing = pairing
        self.server = server
        self.panel = panel
        self.problem = problem
        panel.perform = { [weak self] action in self?.perform(action) }
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("MenuBar.bundle"),
              let bundle = Bundle(url: url), bundle.load(),
              let type = bundle.principalClass as? NSObject.Type
        else {
            NSLog("Wingman: MenuBar.bundle did not load")
            refresh()
            return
        }
        let menu = type.init()
        let handler: @convention(block) (String) -> Void = { [weak self] action in
            MainActor.assumeIsolated { self?.perform(action) }
        }
        menu.setValue(handler, forKey: "actionHandler")
        self.menu = menu
        refresh()
    }

    func refresh() {
        let model = model()
        menu?.setValue(model, forKey: "model")
        panel.data = model
    }

    /// Brings Wingman's window forward, or opens it.
    func openWindow() {
        let existing = UIApplication.shared.openSessions.first { $0.scene?.delegate.flatMap { ($0 as? SceneDelegate)?.window } != nil }
        let activity = NSUserActivity(activityType: SceneDelegate.windowActivity)
        UIApplication.shared.requestSceneSessionActivation(existing, userActivity: existing == nil ? activity : nil, options: nil) { error in
            NSLog("Wingman: cannot open the window: \(error)")
        }
    }

    private func perform(_ action: String) {
        switch action {
        case "read": Task { _ = await store.readAll() }
        case "pair":
            pairing.openPairing()
            panel.tab = .bridges
            openWindow()
        case "open": openWindow()
        case "cancelPairing": pairing.closePairing()
        case "settings":
            server?.applySettings()
            refresh()
        case "quit": exit(0)
        case let action where action.hasPrefix("unpair:"): pairing.remove(String(action.dropFirst("unpair:".count)))
        default: break
        }
    }

    /// What the panel draws. Dates are seconds since 1970; `level` is ok, warning or error.
    private func model() -> [String: Any] {
        var model: [String: Any] = [
            "summary": store.summary,
            "events": store.eventCount,
            "serving": server != nil,
            "fingerprint": server?.fingerprint ?? "",
            "port": Int(server?.port ?? Settings.port),
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "bridges": pairing.bridges.map { bridge in
                var json: [String: Any] = ["id": bridge.id, "name": bridge.name, "pairedAt": bridge.pairedAt.timeIntervalSince1970]
                if let seen = bridge.lastSeenAt { json["lastSeenAt"] = seen.timeIntervalSince1970 }
                return json
            },
        ]
        if let at = store.lastEventAt { model["lastEventAt"] = at.timeIntervalSince1970 }
        if let read = store.lastRefresh {
            let failures = (read["failures"] as? [String: Int])?.values.reduce(0, +) ?? 0
            model["lastRead"] = "\(read["succeeded"] ?? 0) values read, \(failures) failed"
        }
        let (headline, level) = headline()
        model["headline"] = headline
        model["level"] = level
        model["homes"] = store.homes.map { home in
            let rooms = home.rooms + [home.roomForEntireHome()]
            return [
                "name": home.name,
                "rooms": rooms.compactMap { room -> [String: Any]? in
                    let accessories = home.accessories.filter { $0.room?.uniqueIdentifier == room.uniqueIdentifier }
                    guard !accessories.isEmpty else { return nil }
                    return [
                        "name": room.name,
                        "accessories": accessories.map { accessory in
                            [
                                "name": accessory.name,
                                "detail": accessory.category.localizedDescription,
                                "reachable": accessory.isReachable,
                            ] as [String: Any]
                        },
                    ]
                },
            ] as [String: Any]
        }
        if let open = pairing.open {
            model["pairingCode"] = open.code
            model["pairingUntil"] = open.until.timeIntervalSince1970
        }
        return model
    }

    private func headline() -> (String, String) {
        if let problem { return (problem, "error") }
        if let server, server.state != "listening" { return ("Server \(server.state)", "error") }
        if store.authorization != "authorized" { return ("HomeKit access: \(store.authorization)", "warning") }
        let count = pairing.bridges.count
        if count == 0 { return ("Ready to pair with a bridge", "warning") }
        return ("Serving \(count) bridge\(count == 1 ? "" : "s") on port \(server?.port ?? Settings.port)", "ok")
    }
}
