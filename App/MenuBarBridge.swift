import HomeKit
import UIKit

/// Loads `MenuBar.bundle` (AppKit, in Contents/PlugIns) and hands it a plain dictionary to draw: the two sides share
/// no types, only the principal class's `model` and `actionHandler` properties.
@MainActor
final class MenuBarBridge {
    private let store: HomeStore
    private let demo: DemoStore
    private let demoBridge: DemoBridge?
    private let pairing: Pairing
    private let server: LocalServer?
    private let panel: LoginSettings
    private let problem: String?
    private var menu: NSObject?

    init(store: HomeStore, demo: DemoStore, demoBridge: DemoBridge?, pairing: Pairing, server: LocalServer?, panel: LoginSettings, problem: String?) {
        self.store = store
        self.demo = demo
        self.demoBridge = demoBridge
        self.pairing = pairing
        self.server = server
        self.panel = panel
        self.problem = problem
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
    }

    private func perform(_ action: String) {
        switch action {
        case "read": Task { _ = Settings.demoMode ? await demo.readAll() : await store.readAll() }
        case "demoBridge": Task { await demoBridge?.run() }
        case "pair":
            pairing.openPairing()
            refresh()
        case "open":
            menu?.perform(NSSelectorFromString("showPanel"))
        case "cancelPairing": pairing.closePairing()
        case "settings":
            server?.applySettings()
            refresh()
        case let action where action.hasPrefix("setting:"):
            let parts = action.split(separator: ":")
            guard parts.count == 3 else { return }
            let enabled = parts[2] == "1"
            switch parts[1] {
            case "advertise", "allowChanges":
                UserDefaults.standard.set(enabled, forKey: String(parts[1]))
                server?.applySettings()
            case "launchAtLogin": panel.setLaunchAtLogin(enabled)
            case "demoMode":
                guard enabled != Settings.demoMode else { return }
                UserDefaults.standard.set(enabled, forKey: Settings.demoModeKey)
                if !enabled { demoBridge?.forget() }
                // Paired bridges reconnect and see the other homes; Bonjour advertises the new home.
                server?.start()
            default: return
            }
            refresh()
        case let action where action.hasPrefix("port:"):
            guard let value = UInt16(action.dropFirst(5)), value > 0 else { return }
            UserDefaults.standard.set(Int(value), forKey: Settings.portKey)
            server?.applySettings()
            refresh()
        case "quit": exit(0)
        case let action where action.hasPrefix("unpair:"): pairing.remove(String(action.dropFirst("unpair:".count)))
        default: break
        }
    }

    /// What the panel draws. Dates are seconds since 1970; `level` is ok, warning or error.
    private func model() -> [String: Any] {
        let demoMode = Settings.demoMode
        var model: [String: Any] = [
            "summary": demoMode ? demo.summary : store.summary,
            "demo": demoMode,
            "advertise": Settings.advertise,
            "allowChanges": Settings.allowChanges,
            "launchAtLogin": panel.launchAtLogin,
            "events": demoMode ? demo.eventCount : store.eventCount,
            "serving": server != nil,
            "listening": server?.state == "listening",
            "fingerprint": server?.fingerprint ?? "",
            "port": Int(server?.port ?? Settings.port),
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "bridges": pairing.bridges.map { bridge in
                var json: [String: Any] = ["id": bridge.id, "name": bridge.name, "pairedAt": bridge.pairedAt.timeIntervalSince1970]
                if let seen = bridge.lastSeenAt { json["lastSeenAt"] = seen.timeIntervalSince1970 }
                return json
            },
        ]
        if let error = pairing.persistenceError { model["pairingError"] = error }
        if let error = panel.launchAtLoginError { model["settingsError"] = error }
        if let at = demoMode ? demo.lastEventAt : store.lastEventAt { model["lastEventAt"] = at.timeIntervalSince1970 }
        if let read = demoMode ? demo.lastRefresh : store.lastRefresh {
            let failures = (read["failures"] as? [String: Int])?.values.reduce(0, +) ?? 0
            model["lastRead"] = "\(read["succeeded"] ?? 0) values read, \(failures) failed"
        }
        let (headline, level) = headline()
        model["headline"] = headline
        model["level"] = level
        if let demoBridge, demoMode {
            model["demoLog"] = demoBridge.log
            model["demoBusy"] = demoBridge.busy
            model["demoPaired"] = demoBridge.isPaired
        }
        // Without HomeKit access or homes there is nothing to show, so offer the synthetic home instead.
        model["offerDemo"] = !demoMode && (store.authorization != "authorized" || (store.homesLoaded && store.homes.isEmpty))
        model["homes"] = demoMode ? demo.panelHomes() : store.homes.map { home in
            let rooms = (home.rooms + [home.roomForEntireHome()]).sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame
                    ? $0.uniqueIdentifier.uuidString < $1.uniqueIdentifier.uuidString
                    : order == .orderedAscending
            }
            return [
                "id": home.uniqueIdentifier.uuidString,
                "name": home.name,
                "rooms": rooms.compactMap { room -> [String: Any]? in
                    let accessories = home.accessories
                        .filter { $0.room?.uniqueIdentifier == room.uniqueIdentifier }
                        .sorted {
                            let typeOrder = $0.category.localizedDescription.localizedStandardCompare($1.category.localizedDescription)
                            if typeOrder != .orderedSame { return typeOrder == .orderedAscending }
                            let nameOrder = $0.name.localizedStandardCompare($1.name)
                            return nameOrder == .orderedSame
                                ? $0.uniqueIdentifier.uuidString < $1.uniqueIdentifier.uuidString
                                : nameOrder == .orderedAscending
                        }
                    guard !accessories.isEmpty else { return nil }
                    return [
                        "id": room.uniqueIdentifier.uuidString,
                        "name": room.name,
                        "accessories": accessories.map { accessory in
                            [
                                "id": accessory.uniqueIdentifier.uuidString,
                                "name": accessory.name,
                                "detail": accessory.category.localizedDescription,
                                "symbol": DeviceSymbol.name(for: accessory),
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
        if Settings.demoMode { return ("Demo mode: synthetic home, not your HomeKit data", "warning") }
        if store.authorization != "authorized" { return ("HomeKit access: \(store.authorization)", "warning") }
        let count = pairing.bridges.count
        if count == 0 { return ("Ready to pair with a bridge", "warning") }
        return ("Serving \(count) bridge\(count == 1 ? "" : "s") on port \(server?.port ?? Settings.port)", "ok")
    }
}
