import Foundation

/// Wingman’s settings in user defaults. MenuBarBridge applies edits from the AppKit panel.
enum Settings {
    static let advertiseKey = "advertise"
    static let portKey = "port"
    static let allowChangesKey = "allowChanges"
    static let allowSecurityKey = "allowSecurity"
    static let allowStructureKey = "allowStructure"
    static let demoModeKey = "demoMode"

    static func register() {
        UserDefaults.standard.register(defaults: [advertiseKey: true, portKey: Int(LocalServer.defaultPort), allowChangesKey: true, allowSecurityKey: false,
                                                  allowStructureKey: false, demoModeKey: false])
    }

    /// Serve the synthetic demo home instead of HomeKit's homes, for App Review and evaluation.
    static var demoMode: Bool { UserDefaults.standard.bool(forKey: demoModeKey) }

    /// Advertise `_homeswift-wingman._tcp` over Bonjour; off, a bridge needs the address by hand.
    static var advertise: Bool { UserDefaults.standard.bool(forKey: advertiseKey) }

    /// `WINGMAN_PORT` wins over the setting, for tests.
    static var port: UInt16 {
        if let port = UInt16(ProcessInfo.processInfo.environment["WINGMAN_PORT"] ?? "") { return port }
        return UInt16(exactly: UserDefaults.standard.integer(forKey: portKey)).flatMap { $0 > 0 ? $0 : nil } ?? LocalServer.defaultPort
    }

    /// Let paired bridges write values (`POST /write`); off, they only read.
    static var allowChanges: Bool { UserDefaults.standard.bool(forKey: allowChangesKey) }

    /// Also let them write lock, garage door and alarm targets. Off by default: the bridge asks its user to confirm
    /// each one, but Wingman cannot see that, so the owner of this Mac opts in.
    static var allowSecurity: Bool { UserDefaults.standard.bool(forKey: allowSecurityKey) }

    /// Let them rename rooms, move accessories between rooms and edit scenes and automations. Off by default: an edit
    /// reaches every device of the home through iCloud, and Wingman cannot see the bridge's user confirm it.
    static var allowStructure: Bool { UserDefaults.standard.bool(forKey: allowStructureKey) }
}
