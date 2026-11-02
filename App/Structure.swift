import Foundation

/// What a structural edit (or a scene run) answers: the status line and the JSON body `LocalServer` sends.
struct StoreAnswer {
    var status: String
    var body: [String: Any]

    static func ok(_ body: [String: Any]) -> StoreAnswer { StoreAnswer(status: "200 OK", body: body) }
    static func badRequest(_ message: String) -> StoreAnswer { StoreAnswer(status: "400 Bad Request", body: ["error": message]) }
    static func forbidden(_ message: String) -> StoreAnswer { StoreAnswer(status: "403 Forbidden", body: ["error": message]) }
    static func notFound(_ message: String) -> StoreAnswer { StoreAnswer(status: "404 Not Found", body: ["error": message]) }
    /// HomeKit refused, or cannot do it. `done` counts the changes made before the refusal: HomeKit has no transaction.
    static func refused(_ message: String, done: Int? = nil) -> StoreAnswer {
        var body: [String: Any] = ["error": message]
        if let done { body["done"] = done }
        return StoreAnswer(status: "422 Unprocessable Content", body: body)
    }

    static var notAdministrator: StoreAnswer { forbidden("only an administrator of the home can change it") }
    static var turnedOff: StoreAnswer { forbidden("structural edits are turned off in Wingman's settings") }
    static func security(_ name: String) -> StoreAnswer {
        forbidden("\(name) operates a lock, garage door or alarm; turn on Let bridges operate locks and doors in Wingman's settings")
    }
    static func builtIn(_ name: String) -> StoreAnswer {
        refused("\(name) is one of Apple Home's built-in scenes: HomeKit does not rename or delete it")
    }
}

/// A characteristic an action set (a scene, or an automation's own actions) should write, as a bridge sends it:
/// the accessory by id, the characteristic by id (or HAP UUID or HomeKit's description, as `/write` takes).
struct StructureAction {
    var accessory: String
    var characteristic: String
    var value: Any
}

/// A clock time, or a sunrise or sunset with an offset in minutes, on weekdays (1 is Sunday; none is every day).
struct StructureTime: Equatable {
    var hour: Int?
    var minute: Int?
    /// "sunrise" or "sunset".
    var significant: String?
    var offsetMinutes = 0
    var weekdays: [Int] = []

    var json: [String: Any] {
        var json: [String: Any] = [:]
        if let significant {
            json["significant"] = significant
            json["offsetMinutes"] = offsetMinutes
        } else {
            json["hour"] = hour ?? 0
            json["minute"] = minute ?? 0
        }
        if !weekdays.isEmpty { json["weekdays"] = weekdays }
        return json
    }

    static func parse(_ value: Any?) throws(StructureRequestError) -> StructureTime {
        guard let json = value as? [String: Any] else { throw StructureRequestError(#"expected a "time" object"#) }
        let weekdays = try integers(json["weekdays"], "weekdays")
        guard weekdays.allSatisfy((1...7).contains) else { throw StructureRequestError("weekdays go from 1 (Sunday) to 7") }
        let days = Array(Set(weekdays)).sorted()
        if let significant = json["significant"] {
            guard let significant = significant as? String, ["sunrise", "sunset"].contains(significant) else {
                throw StructureRequestError(#""significant" is "sunrise" or "sunset""#)
            }
            let offset = try integer(json["offsetMinutes"], "offsetMinutes") ?? 0
            guard (-720...720).contains(offset) else { throw StructureRequestError("offsetMinutes is within 12 hours") }
            return StructureTime(significant: significant, offsetMinutes: offset, weekdays: days)
        }
        guard let hour = try integer(json["hour"], "hour"), let minute = try integer(json["minute"], "minute") else {
            throw StructureRequestError(#"a time is {"hour", "minute"} or {"significant", "offsetMinutes"}"#)
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { throw StructureRequestError("no such time \(hour):\(minute)") }
        return StructureTime(hour: hour, minute: minute, weekdays: days)
    }

    private static func integer(_ value: Any?, _ key: String) throws(StructureRequestError) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber, !StructureValue.isBool(number), number.doubleValue == number.doubleValue.rounded() else {
            throw StructureRequestError("\(key) is a whole number")
        }
        return number.intValue
    }

    private static func integers(_ value: Any?, _ key: String) throws(StructureRequestError) -> [Int] {
        guard let value, !(value is NSNull) else { return [] }
        guard let array = value as? [Any] else { throw StructureRequestError("\(key) is a list of whole numbers") }
        var numbers: [Int] = []
        for item in array {
            guard let number = try integer(item, key) else { throw StructureRequestError("\(key) is a list of whole numbers") }
            numbers.append(number)
        }
        return numbers
    }
}

struct StructureRequestError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// A request to change Apple Home's rooms, scenes or automations (or to run a scene), parsed from `POST /<path>`.
/// `HomeStore` applies it through HomeKit, `DemoStore` to its synthetic home, with the same checks.
enum StructureEdit {
    case renameRoom(room: String, name: String)
    case moveAccessory(accessory: String, room: String)
    case runScene(String)
    case renameScene(String, name: String)
    case sceneActions(String, [StructureAction])
    case createScene(home: String, name: String, actions: [StructureAction])
    case deleteScene(String)
    case enableAutomation(String, enabled: Bool)
    case renameAutomation(String, name: String)
    case automationTime(String, StructureTime)
    case automationScenes(String, scenes: [String])
    case automationActions(String, [StructureAction])
    case deleteAutomation(String)

    static let paths: Set<String> = [
        "rooms/rename", "accessories/room", "scenes/run", "scenes/rename", "scenes/actions", "scenes/create", "scenes/delete",
        "automations/enable", "automations/rename", "automations/time", "automations/scenes", "automations/actions",
        "automations/delete",
    ]

    /// Running a scene changes accessories, as a write does; everything else changes the home itself.
    var isStructural: Bool {
        if case .runScene = self { return false }
        return true
    }

    /// The kind of event the change makes: what a bridge reads again.
    var eventKind: String? {
        switch self {
        case .renameRoom, .moveAccessory: "homes"
        case .runScene: nil
        case .renameScene, .sceneActions, .createScene, .deleteScene: "scenes"
        default: "automations"
        }
    }

    static func parse(path: String, body: Data) throws(StructureRequestError) -> StructureEdit {
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            throw StructureRequestError("expected a JSON object")
        }
        func id(_ key: String) throws(StructureRequestError) -> String {
            guard let value = json[key] as? String, !value.isEmpty else { throw StructureRequestError(#"expected "\#(key)", an id"#) }
            return value
        }
        func name(_ key: String = "name") throws(StructureRequestError) -> String {
            let value = (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { throw StructureRequestError(#"expected "\#(key)", a name"#) }
            return value
        }
        switch path {
        case "rooms/rename": return .renameRoom(room: try id("room"), name: try name())
        case "accessories/room": return .moveAccessory(accessory: try id("accessory"), room: try name("room"))
        case "scenes/run": return .runScene(try id("scene"))
        case "scenes/rename": return .renameScene(try id("scene"), name: try name())
        case "scenes/actions": return .sceneActions(try id("scene"), try actions(json["actions"]))
        case "scenes/create": return .createScene(home: try id("home"), name: try name(), actions: try actions(json["actions"]))
        case "scenes/delete": return .deleteScene(try id("scene"))
        case "automations/enable":
            guard let enabled = json["enabled"] as? NSNumber, StructureValue.isBool(enabled) else {
                throw StructureRequestError(#"expected "enabled", true or false"#)
            }
            return .enableAutomation(try id("automation"), enabled: enabled.boolValue)
        case "automations/rename": return .renameAutomation(try id("automation"), name: try name())
        case "automations/time": return .automationTime(try id("automation"), try StructureTime.parse(json["time"]))
        case "automations/scenes":
            guard let scenes = json["scenes"] as? [String] else { throw StructureRequestError(#"expected "scenes", a list of ids"#) }
            var seen: Set<String> = []
            return .automationScenes(try id("automation"), scenes: scenes.filter { seen.insert($0).inserted })
        case "automations/actions": return .automationActions(try id("automation"), try actions(json["actions"]))
        case "automations/delete": return .deleteAutomation(try id("automation"))
        default: throw StructureRequestError("not found")
        }
    }

    private static func actions(_ value: Any?) throws(StructureRequestError) -> [StructureAction] {
        guard let list = value as? [[String: Any]] else {
            throw StructureRequestError(#"expected "actions": [{"accessory", "characteristic", "value"}]"#)
        }
        var actions: [StructureAction] = []
        for item in list {
            guard let accessory = item["accessory"] as? String, let characteristic = item["characteristic"] as? String,
                  let value = item["value"], !(value is NSNull) else {
                throw StructureRequestError(#"each action is {"accessory", "characteristic", "value"}"#)
            }
            actions.append(StructureAction(accessory: accessory, characteristic: characteristic, value: value))
        }
        return actions
    }
}

/// How `/write` and actions name a characteristic: by its id, else by its HAP UUID or HomeKit's description. The
/// first writable match wins; `problem` says why there is none.
enum CharacteristicLookup {
    static func writable<C>(_ all: [C], named name: String, id: (C) -> String, type: (C) -> String, description: (C) -> String,
                            isWritable: (C) -> Bool) -> (match: C?, problem: String?) {
        let byID = all.filter { id($0).caseInsensitiveCompare(name) == .orderedSame }
        let candidates = byID.isEmpty ? all.filter { type($0).caseInsensitiveCompare(name) == .orderedSame || description($0) == name } : byID
        if let match = candidates.first(where: isWritable) { return (match, nil) }
        return (nil, candidates.isEmpty ? "no characteristic \(name)" : "\(name) is not writable")
    }
}

/// Room names as HomeKit compares them: "Entrée" is "entree".
func sameRoomName(_ a: String, _ b: String) -> Bool {
    a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
}

/// Checks a value an action would write against the characteristic's format and range, as HomeKit would.
enum StructureValue {
    static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    /// The value as the characteristic takes it (Bool, Int, Double, String, or Data from base64 as `/scenes` lists it),
    /// or nil when it does not fit.
    static func coerce(_ value: Any, format: String?, minimum: Double?, maximum: Double?, validValues: [Int]? = nil) -> Any? {
        let number = value as? NSNumber
        func inRange(_ double: Double) -> Bool {
            double >= (minimum ?? -.infinity) && double <= (maximum ?? .infinity)
        }
        switch format {
        case "bool":
            guard let number, isBool(number) || [0, 1].contains(number.doubleValue) else { return nil }
            return number.boolValue
        case "int", "uint8", "uint16", "uint32", "uint64":
            guard let number, !isBool(number), number.doubleValue == number.doubleValue.rounded(), inRange(number.doubleValue) else { return nil }
            if format != "int", number.doubleValue < 0 { return nil }
            if let validValues, !validValues.isEmpty, !validValues.contains(number.intValue) { return nil }
            return number.intValue
        case "float":
            guard let number, !isBool(number), number.doubleValue.isFinite, inRange(number.doubleValue) else { return nil }
            return number.doubleValue
        case "string":
            return value as? String
        case "data", "tlv8":
            return (value as? String).flatMap { Data(base64Encoded: $0) }
        default:
            if let number { return isBool(number) ? number.boolValue : number }
            return value as? String
        }
    }

    /// Whether two target values are the same, as JSON would show them.
    static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (let a as NSNumber, let b as NSNumber): a == b
        case (let a as String, let b as String): a == b
        case (let a as Data, let b as Data): a == b
        case (nil, nil): true
        default: false
        }
    }
}
