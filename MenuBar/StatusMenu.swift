import AppKit

/// The menu bar item, drawn from the dictionary the Catalyst side sets on `model` (`MenuBarBridge.model()`): the
/// headline, the homes → rooms → accessories, the pairing code while pairing is open, and the window. SwiftUI cannot
/// run here (a Catalyst process loads the iOS SwiftUI), so the window is the Catalyst side's; this menu opens it.
@MainActor
@objc(WingmanStatusMenu)
public final class WingmanStatusMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    @objc public var actionHandler: ((String) -> Void)?
    @objc public var model: [String: Any] = [:] {
        didSet { rebuild() }
    }

    override public init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "bird", accessibilityDescription: "Homeswift Wingman")
        rebuild()
    }

    private func rebuild() {
        let menu = NSMenu()
        let headline = menu.addItem(withTitle: model["headline"] as? String ?? "Starting…", action: nil, keyEquivalent: "")
        headline.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [color(model["level"] as? String)]).applying(.init(scale: .small)))
        headline.isEnabled = false
        menu.addItem(withTitle: model["summary"] as? String ?? "", action: nil, keyEquivalent: "").isEnabled = false
        let homes = model["homes"] as? [[String: Any]] ?? []
        if !homes.isEmpty { menu.addItem(.separator()) }
        for home in homes {
            let homeItem = menu.addItem(withTitle: home["name"] as? String ?? "Home", action: nil, keyEquivalent: "")
            homeItem.image = NSImage(systemSymbolName: "house", accessibilityDescription: nil)
            let rooms = NSMenu()
            for room in home["rooms"] as? [[String: Any]] ?? [] {
                let accessories = room["accessories"] as? [[String: Any]] ?? []
                let roomItem = rooms.addItem(withTitle: "\(room["name"] as? String ?? "Room") (\(accessories.count))", action: nil, keyEquivalent: "")
                let list = NSMenu()
                for accessory in accessories {
                    let reachable = accessory["reachable"] as? Bool ?? true
                    let title = "\(accessory["name"] as? String ?? "")  ·  \(accessory["detail"] as? String ?? "")"
                    let entry = list.addItem(withTitle: reachable ? title : "\(title)  ·  No Response", action: nil, keyEquivalent: "")
                    entry.image = NSImage(systemSymbolName: reachable ? "circle.fill" : "exclamationmark.circle", accessibilityDescription: nil)
                    entry.isEnabled = false
                }
                roomItem.submenu = list
            }
            homeItem.submenu = rooms
        }
        menu.addItem(.separator())
        if model["serving"] as? Bool ?? false {
            if let code = model["pairingCode"] as? String {
                let entry = menu.addItem(withTitle: "Pairing code \(code.prefix(3)) \(code.suffix(3))", action: nil, keyEquivalent: "")
                entry.image = NSImage(systemSymbolName: "key", accessibilityDescription: nil)
                entry.isEnabled = false
                add("Cancel Pairing", "cancelPairing", to: menu)
            } else {
                add("Pair a Homeswift Bridge…", "pair", to: menu)
            }
        }
        add("Open Wingman…", "open", key: ",", to: menu)
        menu.addItem(.separator())
        add("Quit Homeswift Wingman", "quit", key: "q", to: menu)
        item.menu = menu
    }

    private func color(_ level: String?) -> NSColor {
        switch level {
        case "ok": .systemGreen
        case "error": .systemRed
        default: .systemOrange
        }
    }

    private func add(_ title: String, _ action: String, key: String = "", to menu: NSMenu) {
        let entry = menu.addItem(withTitle: title, action: #selector(run(_:)), keyEquivalent: key)
        entry.target = self
        entry.representedObject = action
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? String else { return }
        actionHandler?(action)
        // An LSUIElement app is never frontmost by itself: bring the window forward.
        if action == "open" || action == "pair" { NSApp.activate() }
    }
}
