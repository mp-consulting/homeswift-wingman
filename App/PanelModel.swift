import Observation
import ServiceManagement
import UIKit

/// The window's view of `MenuBarBridge.model()` (the dictionary the menu bar draws too), with types. Actions go back
/// as strings through `perform`, as the menu's do: read, pair, cancelPairing, unpair:<id>, settings (after a setting
/// changed), quit.
@MainActor
@Observable
final class PanelModel {
    struct Accessory: Identifiable {
        let id: Int
        let name: String
        let detail: String
        let reachable: Bool
    }

    struct Room: Identifiable {
        let id: String
        let name: String
        let accessories: [Accessory]
        var unreachable: Int { accessories.filter { !$0.reachable }.count }
    }

    struct Home: Identifiable {
        let id: String
        let name: String
        let rooms: [Room]
    }

    struct Bridge: Identifiable {
        let id: String
        let name: String
        let pairedAt: Date
        let lastSeenAt: Date?
    }

    enum Level { case ok, warning, error }

    var data: [String: Any] = [:]
    var tab: PanelTab = .home
    @ObservationIgnored var perform: (String) -> Void = { _ in }

    var headline: String { data["headline"] as? String ?? "Starting…" }
    var level: Level {
        switch data["level"] as? String {
        case "ok": .ok
        case "error": .error
        default: .warning
        }
    }
    var summary: String { data["summary"] as? String ?? "Loading homes…" }
    var events: Int { data["events"] as? Int ?? 0 }
    var lastEventAt: Date? { date("lastEventAt") }
    var lastRead: String? { data["lastRead"] as? String }
    var serving: Bool { data["serving"] as? Bool ?? false }
    var port: Int { data["port"] as? Int ?? 8619 }
    var version: String { data["version"] as? String ?? "" }
    /// Lowercase hex; `AB:CD:…` for people.
    var fingerprint: String { data["fingerprint"] as? String ?? "" }
    var pairingCode: String? { data["pairingCode"] as? String }
    var pairingUntil: Date? { date("pairingUntil") }

    func formattedFingerprint(bytes: Int = 32) -> String {
        let hex = Array(fingerprint.uppercased())
        return stride(from: 0, to: min(hex.count, bytes * 2), by: 2).map { String(hex[$0..<min($0 + 2, hex.count)]) }.joined(separator: ":")
    }

    var homes: [Home] {
        (data["homes"] as? [[String: Any]] ?? []).enumerated().map { index, home in
            let name = home["name"] as? String ?? "Home"
            let rooms = (home["rooms"] as? [[String: Any]] ?? []).enumerated().map { roomIndex, room in
                Room(
                    id: "\(index)/\(roomIndex)", name: room["name"] as? String ?? "Room",
                    accessories: (room["accessories"] as? [[String: Any]] ?? []).enumerated().map { accessoryIndex, accessory in
                        Accessory(id: accessoryIndex, name: accessory["name"] as? String ?? "", detail: accessory["detail"] as? String ?? "",
                                  reachable: accessory["reachable"] as? Bool ?? true)
                    })
            }
            return Home(id: "\(index)", name: name, rooms: rooms)
        }
    }

    var bridges: [Bridge] {
        (data["bridges"] as? [[String: Any]] ?? []).map { bridge in
            Bridge(id: bridge["id"] as? String ?? "", name: bridge["name"] as? String ?? "Bridge",
                   pairedAt: Date(timeIntervalSince1970: bridge["pairedAt"] as? Double ?? 0),
                   lastSeenAt: (bridge["lastSeenAt"] as? Double).map(Date.init(timeIntervalSince1970:)))
        }
    }

    private func date(_ key: String) -> Date? { (data[key] as? Double).map(Date.init(timeIntervalSince1970:)) }

    func copy(_ text: String) { UIPasteboard.general.string = text }

    // MARK: Open at login

    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    var launchAtLoginError: String?

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

