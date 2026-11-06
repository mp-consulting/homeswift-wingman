import Foundation

/// What paired bridges asked Wingman to do, newest first, for the panel's Activity section: pairing, Read All,
/// accessory changes, scene runs and edits to the home, with Wingman's refusals. The reads a bridge makes all the time
/// (`/homes`, `/events`, `/scenes`) are left out, or they would bury the rest. Kept in memory: it is what happened
/// since Wingman started.
@MainActor
final class ActivityFeed {
    struct Entry {
        enum Outcome: String {
            /// Read the home without changing it.
            case read
            case changed
            /// Wingman's settings, or its pairing rules, said no.
            case refused
            /// HomeKit, or the request, failed.
            case failed
        }

        var date: Date
        var bridge: String
        /// What was asked, in a few words: "Renamed room".
        var title: String
        /// What it was about ("Office → Study"), or why it did not happen.
        var summary: String
        var outcome: Outcome
        var milliseconds: Int

        var panel: [String: Any] {
            ["date": date.timeIntervalSince1970, "bridge": bridge, "title": title, "summary": summary,
             "outcome": outcome.rawValue, "milliseconds": milliseconds]
        }
    }

    private(set) var entries: [Entry] = []
    let limit: Int
    var onChange: (() -> Void)?

    init(limit: Int = 100) {
        self.limit = limit
    }

    func record(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        onChange?()
    }

    /// The outcome an answer's status line means: 403 is Wingman's settings, any other failure HomeKit's or the request's.
    static func outcome(status: String, success: Entry.Outcome = .changed) -> Entry.Outcome {
        status.hasPrefix("2") ? success : status.hasPrefix("403") ? .refused : .failed
    }

    /// A written value as the panel shows it: switches read on or off.
    static func describe(_ value: Any) -> String {
        // JSON numbers are NSNumbers, and 1 casts to Bool too: only a JSON true or false is a switch.
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "on" : "off") : number.stringValue
        }
        return "\(value)"
    }
}

extension StructureEdit {
    /// The feed's title and summary for this edit, with names looked up before it runs (a renamed room by its old
    /// name, a deleted one while it still exists).
    func activity(name lookup: (String) -> String?) -> (title: String, summary: String) {
        func name(_ id: String) -> String { lookup(id) ?? id }
        func renamed(_ id: String, _ new: String) -> String { "\(name(id)) → \(new)" }
        func changes(_ id: String, add: [String], remove: [String]) -> String {
            let parts = [add.isEmpty ? nil : "added " + add.map(name).joined(separator: ", "),
                         remove.isEmpty ? nil : "removed " + remove.map(name).joined(separator: ", ")].compactMap { $0 }
            return parts.isEmpty ? name(id) : "\(name(id)): " + parts.joined(separator: "; ")
        }
        func actions(_ count: Int) -> String { count == 1 ? "1 action" : "\(count) actions" }
        switch self {
        case .renameRoom(let room, let new): return ("Renamed room", renamed(room, new))
        case .moveAccessory(let accessory, let room): return ("Moved accessory", "\(name(accessory)) → \(room)")
        case .createRoom(_, let new): return ("Created room", new)
        case .deleteRoom(let room): return ("Deleted room", name(room))
        case .assignAccessory(let accessory, let room): return ("Moved accessory", "\(name(accessory)) → \(room.map(name) ?? "Default Room")")
        case .createZone(_, let new): return ("Created zone", new)
        case .renameZone(let zone, let new): return ("Renamed zone", renamed(zone, new))
        case .deleteZone(let zone): return ("Deleted zone", name(zone))
        case .zoneRooms(let zone, let add, let remove): return ("Changed zone", changes(zone, add: add, remove: remove))
        case .createGroup(_, let new, let services): return ("Created group", "\(new): " + services.map(name).joined(separator: ", "))
        case .renameGroup(let group, let new): return ("Renamed group", renamed(group, new))
        case .deleteGroup(let group): return ("Deleted group", name(group))
        case .groupServices(let group, let add, let remove): return ("Changed group", changes(group, add: add, remove: remove))
        case .runScene(let scene): return ("Ran scene", name(scene))
        case .renameScene(let scene, let new): return ("Renamed scene", renamed(scene, new))
        case .sceneActions(let scene, let list): return ("Changed scene", "\(name(scene)), \(actions(list.count))")
        case .createScene(_, let new, let list): return ("Created scene", "\(new), \(actions(list.count))")
        case .deleteScene(let scene): return ("Deleted scene", name(scene))
        case .enableAutomation(let automation, let enabled): return (enabled ? "Turned on automation" : "Turned off automation", name(automation))
        case .renameAutomation(let automation, let new): return ("Renamed automation", renamed(automation, new))
        case .automationTime(let automation, _): return ("Retimed automation", name(automation))
        case .automationScenes(let automation, let scenes): return ("Changed automation", "\(name(automation)): " + (scenes.isEmpty ? "no scenes" : scenes.map(name).joined(separator: ", ")))
        case .automationActions(let automation, let list): return ("Changed automation", "\(name(automation)), \(actions(list.count))")
        case .deleteAutomation(let automation): return ("Deleted automation", name(automation))
        }
    }
}
