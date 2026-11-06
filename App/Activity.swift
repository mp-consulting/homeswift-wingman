import Foundation

/// What paired bridges asked Wingman to do, newest first, for the panel's Activity section: pairing, Read All,
/// accessory changes, scene runs and edits to the home, with Wingman's refusals. The reads a bridge makes all the time
/// (`/homes`, `/events`, `/scenes`) are left out, or they would bury the rest. Saved beside the pairings
/// (`activity.jsonl`, one entry a line), so a relaunch keeps it.
@MainActor
final class ActivityFeed {
    struct Entry: Codable {
        enum Outcome: String, Codable {
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
    /// Nil keeps the feed in memory (tests).
    private let file: URL?
    /// The file's lines, one entry each, oldest first. Each entry is appended; past twice the limit, the file is
    /// written again with the entries kept, so it stays small.
    private var lines = 0
    /// Saves run here, in order, so a bridge's answer never waits for the disk.
    private let saves = DispatchQueue(label: "Wingman.activity", qos: .utility)

    /// Where the app keeps it: beside `bridges.json`.
    static var appFile: URL { Pairing.defaultDirectory.appendingPathComponent("activity.jsonl") }

    init(file: URL? = nil, limit: Int = 100) {
        self.file = file
        self.limit = limit
        // A missing file starts an empty feed, and an unreadable line (one a crash cut short) is skipped: the feed is a
        // record, not state anything depends on.
        if let file, let data = try? Data(contentsOf: file) {
            let saved = data.split(separator: 0x0A)
            lines = saved.count
            // From the end, only as far back as the feed keeps.
            for line in saved.reversed() where entries.count < limit {
                if let entry = try? Self.decoder.decode(Entry.self, from: Data(line)) { entries.append(entry) }
            }
        }
    }

    func record(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        if let file {
            lines += 1
            if lines > 2 * limit {
                let kept = Data(entries.reversed().compactMap(Self.line).joined())
                lines = entries.count
                saves.async { Self.save { try Pairing.write(kept, to: file) } }
            } else if let line = Self.line(entry) {
                saves.async { Self.save { try Self.append(line, to: file) } }
            }
        }
        onChange?()
    }

    /// Waits for the saves made so far to reach the file.
    func flush() { saves.sync {} }

    private static func line(_ entry: Entry) -> Data? {
        guard var line = try? encoder.encode(entry) else { return nil }
        line.append(0x0A)
        return line
    }

    nonisolated private static func save(_ write: () throws -> Void) {
        do { try write() } catch { NSLog("Wingman: could not save the activity: \(error)") }
    }

    /// One line at the end, owner-only like the pairings: an `O_APPEND` write of one line is never interleaved.
    nonisolated private static func append(_ line: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        try Pairing.writeAll(line, to: fd)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // The same key order on every line, for a person reading the file.
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Values `readAll()` could not read.
    static func failures(inRead result: [String: Any]) -> Int {
        (result["failures"] as? [String: Int])?.values.reduce(0, +) ?? 0
    }

    /// A refusal names the switch that refused it (`StoreAnswer.setting`); any other error is HomeKit's or the request's.
    static func outcome(_ body: [String: Any]) -> Entry.Outcome {
        body["setting"] != nil ? .refused : body["error"] != nil ? .failed : .changed
    }

    /// A written value as the panel shows it: switches read on or off.
    static func describe(_ value: Any) -> String {
        // JSON numbers are NSNumbers, and 1 casts to Bool too: only a JSON true or false is a switch.
        if let number = value as? NSNumber {
            return StructureValue.isBool(number) ? (number.boolValue ? "on" : "off") : number.stringValue
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
