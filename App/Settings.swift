import Foundation

/// Wingman's settings, in the app's user defaults: the window writes them (`@AppStorage`) and says "settings", and
/// the server applies them.
enum Settings {
    static let advertiseKey = "advertise"
    static let portKey = "port"
    static let allowChangesKey = "allowChanges"

    static func register() {
        UserDefaults.standard.register(defaults: [advertiseKey: true, portKey: Int(LocalServer.defaultPort), allowChangesKey: true])
    }

    /// Advertise `_homeswift-wingman._tcp` over Bonjour; off, a bridge needs the address by hand.
    static var advertise: Bool { UserDefaults.standard.bool(forKey: advertiseKey) }

    /// `WINGMAN_PORT` wins over the setting, for tests.
    static var port: UInt16 {
        if let port = UInt16(ProcessInfo.processInfo.environment["WINGMAN_PORT"] ?? "") { return port }
        return UInt16(exactly: UserDefaults.standard.integer(forKey: portKey)).flatMap { $0 > 0 ? $0 : nil } ?? LocalServer.defaultPort
    }

    /// Let paired bridges write values (`POST /write`); off, they only read.
    static var allowChanges: Bool { UserDefaults.standard.bool(forKey: allowChangesKey) }
}
