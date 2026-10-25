import HomeKit
import UIKit

/// Loads `MenuBar.bundle` (AppKit, in Contents/PlugIns) and hands it a plain dictionary to draw: the two sides share
/// no types, only the principal class's `model` and `actionHandler` properties.
@MainActor
final class MenuBarBridge {
    private let store: HomeStore
    private let port: UInt16
    private var menu: NSObject?

    init(store: HomeStore, port: UInt16) {
        self.store = store
        self.port = port
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("MenuBar.bundle"),
              let bundle = Bundle(url: url), bundle.load(),
              let type = bundle.principalClass as? NSObject.Type
        else {
            NSLog("Sidecar: MenuBar.bundle did not load")
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
        menu?.setValue(model(), forKey: "model")
    }

    private func perform(_ action: String) {
        switch action {
        case "read": Task { _ = await store.readAll() }
        case "open": UIApplication.shared.open(URL(string: "http://127.0.0.1:\(port)/homes")!)
        case "quit": exit(0)
        default: break
        }
    }

    private func model() -> [String: Any] {
        var lines = [store.summary, "\(store.eventCount) value changes received"]
        if let read = store.lastRefresh {
            let failures = (read["failures"] as? [String: Int])?.values.reduce(0, +) ?? 0
            lines.append("Last read: \(read["succeeded"] ?? 0) values, \(failures) failed, app \(read["appState"] ?? "?")")
        }
        return [
            "lines": lines,
            "address": "http://127.0.0.1:\(port)",
            "homes": store.homes.map { home in
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
            },
        ]
    }
}
