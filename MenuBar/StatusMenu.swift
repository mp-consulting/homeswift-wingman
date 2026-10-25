import AppKit

/// The menu bar item, drawn from the dictionary the Catalyst side sets on `model`:
/// `lines` (status text), `address`, and `homes` → `rooms` → `accessories` (`name`, `detail`, `reachable`).
@MainActor
@objc(SidecarStatusMenu)
public final class SidecarStatusMenu: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    @objc public var actionHandler: ((String) -> Void)?
    @objc public var model: [String: Any] = [:] {
        didSet { rebuild() }
    }

    override public init() {
        super.init()
        item.button?.image = NSImage(systemSymbolName: "house", accessibilityDescription: "Homeswift Sidecar")
        rebuild()
    }

    private func rebuild() {
        let menu = NSMenu()
        for line in model["lines"] as? [String] ?? ["Starting…"] {
            menu.addItem(withTitle: line, action: nil, keyEquivalent: "").isEnabled = false
        }
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
        add("Read All Values", "read", to: menu)
        add("Open \(model["address"] as? String ?? "")/homes", "open", to: menu)
        menu.addItem(.separator())
        add("Quit Homeswift Sidecar", "quit", key: "q", to: menu)
        item.menu = menu
    }

    private func add(_ title: String, _ action: String, key: String = "", to menu: NSMenu) {
        let entry = menu.addItem(withTitle: title, action: #selector(run(_:)), keyEquivalent: key)
        entry.target = self
        entry.representedObject = action
    }

    @objc private func run(_ sender: NSMenuItem) {
        if let action = sender.representedObject as? String { actionHandler?(action) }
    }
}
