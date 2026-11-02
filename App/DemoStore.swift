import Foundation

/// A synthetic home for App Review and evaluation, served through the same API as HomeKit's homes.
///
/// Nothing here touches HomeKit: names say "Demo" and "(Synthetic)", `/status` reports `"demo": true`, and writes only
/// change these in-memory values. Locks, garage doors and alarms follow the same security setting as real ones. Its
/// rooms, scenes and automations take the same edits as HomeKit's (`HomeStore+Structure.swift`), in memory.
@MainActor
final class DemoStore: WingmanStore {
    struct Characteristic {
        let id: String
        let type: String
        let description: String
        var properties: [String]
        var format: String
        var units: String?
        var minimum: Double?
        var maximum: Double?
        var value: Any
    }

    struct Accessory {
        let id: String
        let name: String
        var room: String
        let category: String
        let symbol: String
        let serviceType: String
        let serviceName: String
        var reachable = true
        var characteristics: [Characteristic]
    }

    static let homeID = "D3E0DE00-0000-4000-8000-000000000001"
    static let homeName = "Demo Home (Synthetic)"
    struct Room {
        let id: String
        var name: String
    }

    /// An action set: its characteristic writes by accessory and characteristic id.
    struct Scene {
        let id: String
        var name: String
        let type: String
        var actions: [StructureAction]
    }

    struct Automation {
        let id: String
        var name: String
        var enabled: Bool
        /// A time trigger's time; nil for one that starts on events.
        var time: StructureTime?
        var events: [[String: Any]] = []
        var endEvents: [[String: Any]] = []
        var conditions: [[String: Any]] = []
        var scenes: [String]
        var actions: [StructureAction]
    }

    var onChange: (() -> Void)?
    var onEvent: (() -> Void)?
    private(set) var accessories: [Accessory]
    private(set) var rooms: [Room] = ["Living Room", "Kitchen", "Office", "Entrance"].map { Room(id: DemoStore.roomID($0), name: $0) }
    private(set) var scenes: [Scene] = DemoStore.makeScenes()
    private(set) var automations: [Automation] = DemoStore.makeAutomations()
    private var created = 0
    private var addedRooms = 0
    private(set) var lastSeq = 0
    private(set) var lastEventAt: Date?
    private(set) var lastRefresh: [String: Any]?
    private var events: [[String: Any]] = []
    private let now: () -> Date

    var homeIdentifiers: [String] { [Self.homeID] }
    var firstSeq: Int { (events.first?["seq"] as? Int) ?? lastSeq + 1 }
    var eventCount: Int { lastSeq }

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        accessories = Self.makeAccessories()
    }

    var summary: String {
        let unreachable = accessories.filter { !$0.reachable }.count
        var text = "Demo: 1 home, \(rooms.count) rooms, \(accessories.count) accessories"
        if unreachable > 0 { text += " (\(unreachable) not responding)" }
        return text
    }

    // MARK: WingmanStore

    func statusJSON() -> [String: Any] {
        var status: [String: Any] = [
            "demo": true, "authorization": "demo", "homesLoaded": true, "homes": 1,
            "accessories": accessories.count, "events": lastSeq, "appState": "active",
        ]
        if let lastRefresh { status["lastRead"] = lastRefresh }
        if let lastEventAt { status["lastEventAt"] = ISO8601DateFormatter().string(from: lastEventAt) }
        return status
    }

    func homesJSON() -> [[String: Any]] {
        [[
            "id": Self.homeID, "name": Self.homeName, "primary": true, "demo": true, "editable": true,
            "rooms": rooms.map { room in
                ["id": room.id, "name": room.name, "accessories": accessories.filter { $0.room == room.name }.count] as [String: Any]
            },
            "zones": [] as [Any],
            "scenes": scenes.map { ["name": $0.name, "type": $0.type, "actions": $0.actions.count] as [String: Any] },
            "accessories": accessories.map(accessoryJSON),
        ]]
    }

    func eventsJSON(since: Int?) -> [[String: Any]] {
        since.map { since in events.filter { ($0["seq"] as? Int ?? 0) > since } } ?? events.reversed()
    }

    func readAll() async -> [String: Any] {
        let readable = accessories.filter(\.reachable).flatMap(\.characteristics).filter { $0.properties.contains("read") }
        let failed = accessories.filter { !$0.reachable }.flatMap(\.characteristics).filter { $0.properties.contains("read") }
        var result: [String: Any] = [
            "demo": true, "characteristics": readable.count + failed.count, "succeeded": readable.count,
            "seconds": 0.01, "appState": "active", "finishedAt": ISO8601DateFormatter().string(from: now()),
        ]
        result["failures"] = failed.isEmpty ? [:] as [String: Int] : ["Demo: accessory not responding": failed.count]
        result["failed"] = [:] as [String: Int]
        lastRefresh = result
        onChange?()
        return result
    }

    /// Accepts the same accessory and characteristic forms as `HomeStore.write`.
    func write(accessory: String, characteristic type: String, value: Any, allowSecurity: Bool) async -> [String: Any] {
        guard let index = accessories.firstIndex(where: { $0.id == accessory || $0.name == accessory })
        else { return ["error": "no accessory \(accessory)"] }
        let target = accessories[index]
        if type == "Identify" {
            guard let enabled = value as? Bool, enabled else { return ["error": "Identify requires true"] }
            return ["accessory": target.name, "characteristic": "Identify", "written": true, "demo": true]
        }
        guard target.reachable else { return ["error": "Demo: \(target.name) is not responding", "demo": true] }
        let found = Self.writableSlot(of: target, named: type)
        guard let slot = found.match else { return ["error": found.problem ?? "no characteristic \(type)"] }
        let characteristic = target.characteristics[slot]
        if !allowSecurity, Self.securityTypes.contains(characteristic.type) {
            return ["error": "\(characteristic.description) is a security control; turn on Let bridges operate locks and doors in Wingman's settings"]
        }
        guard let accepted = Self.coerce(value, to: characteristic) else {
            return ["error": "\(characteristic.description) expects a \(characteristic.format) value"]
        }
        accessories[index].characteristics[slot].value = accepted
        record(accessories[index], accessories[index].characteristics[slot])
        return [
            "accessory": target.name, "characteristic": characteristic.description,
            "written": accepted, "value": accepted, "seconds": 0.01, "appState": "active", "demo": true,
        ]
    }

    // MARK: Panel

    /// The rows the menu-bar panel draws, in its model's shape.
    func panelHomes() -> [[String: Any]] {
        [[
            "id": Self.homeID, "name": Self.homeName,
            "rooms": rooms.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.compactMap { room -> [String: Any]? in
                let members = accessories.filter { $0.room == room.name }
                    .sorted { ($0.category, $0.name) < ($1.category, $1.name) }
                guard !members.isEmpty else { return nil }
                return [
                    "id": room.id, "name": room.name,
                    "accessories": members.map { accessory in
                        [
                            "id": accessory.id, "name": accessory.name, "detail": detail(accessory),
                            "symbol": accessory.symbol, "reachable": accessory.reachable,
                        ] as [String: Any]
                    },
                ]
            },
        ]]
    }

    /// The category and the main state, so a change made through the API shows in the panel.
    private func detail(_ accessory: Accessory) -> String {
        func value(_ type: String) -> Any? { accessory.characteristics.first { $0.type == type }?.value }
        var parts = [accessory.category]
        if let on = value(Self.powerState) as? Bool {
            var state = on ? "On" : "Off"
            if on, let brightness = value(Self.brightness) as? Int { state += ", \(brightness)%" }
            parts.append(state)
        }
        if let temperature = value(Self.currentTemperature) as? Double {
            let target = (value(Self.targetTemperature) as? Double).map { String(format: ", set to %.1f °C", $0) } ?? ""
            parts.append(String(format: "%.1f °C", temperature) + target)
        }
        if let lock = value(Self.lockCurrentState) as? Int { parts.append(lock == 1 ? "Locked" : "Unlocked") }
        if let door = value(Self.currentDoorState) as? Int { parts.append(door == 1 ? "Closed" : "Open") }
        if let motion = value(Self.motionDetected) as? Bool { parts.append(motion ? "Motion" : "No motion") }
        return parts.joined(separator: " · ")
    }

    // MARK: Helpers

    private func record(_ accessory: Accessory, _ characteristic: Characteristic) {
        lastSeq += 1
        let time = now()
        lastEventAt = time
        events.append([
            "seq": lastSeq, "time": ISO8601DateFormatter().string(from: time), "home": Self.homeName, "kind": "value",
            "accessory": accessory.name, "accessoryID": accessory.id, "characteristic": characteristic.description,
            "characteristicID": characteristic.id, "type": characteristic.type, "value": characteristic.value,
            "appState": "active", "demo": true,
        ])
        if events.count > 500 { events.removeFirst(events.count - 500) }
        onChange?()
        onEvent?()
    }

    private func accessoryJSON(_ accessory: Accessory) -> [String: Any] {
        [
            "id": accessory.id, "name": accessory.name, "room": accessory.room, "category": accessory.category,
            "reachable": accessory.reachable, "supportsIdentify": true, "bridged": false, "blocked": false,
            "manufacturer": "Wingman Demo", "model": "Synthetic", "firmware": "1.0", "demo": true,
            "services": [[
                "id": accessory.id + "-service", "name": accessory.serviceName, "type": accessory.serviceType,
                "description": accessory.serviceName, "primary": true,
                "characteristics": accessory.characteristics.map { characteristic in
                    var json: [String: Any] = [
                        "id": characteristic.id, "type": characteristic.type, "description": characteristic.description,
                        "properties": characteristic.properties, "notifying": characteristic.properties.contains("events"),
                        "format": characteristic.format, "value": characteristic.value,
                    ]
                    if let units = characteristic.units { json["units"] = units }
                    if let minimum = characteristic.minimum { json["min"] = minimum }
                    if let maximum = characteristic.maximum { json["max"] = maximum }
                    return json
                },
            ] as [String: Any]],
        ]
    }

    private static func coerce(_ value: Any, to characteristic: Characteristic) -> Any? {
        let number = value as? NSNumber
        switch characteristic.format {
        case "bool":
            guard let number, CFGetTypeID(number) == CFBooleanGetTypeID() || [0, 1].contains(number.intValue) else { return nil }
            return number.boolValue
        case "int", "uint8":
            guard let number else { return nil }
            let clamped = min(max(number.doubleValue, characteristic.minimum ?? -.infinity), characteristic.maximum ?? .infinity)
            return Int(clamped.rounded())
        case "float":
            guard let number else { return nil }
            return min(max(number.doubleValue, characteristic.minimum ?? -.infinity), characteristic.maximum ?? .infinity)
        default: return nil
        }
    }

    fileprivate static func roomID(_ room: String) -> String {
        "demo-room-" + room.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    // HAP characteristic and service types, as HomeKit reports them.
    static let powerState = "00000025-0000-1000-8000-0026BB765291"
    static let brightness = "00000008-0000-1000-8000-0026BB765291"
    static let currentTemperature = "00000011-0000-1000-8000-0026BB765291"
    static let targetTemperature = "00000035-0000-1000-8000-0026BB765291"
    static let motionDetected = "00000022-0000-1000-8000-0026BB765291"
    static let lockCurrentState = "0000001D-0000-1000-8000-0026BB765291"
    static let lockTargetState = "0000001E-0000-1000-8000-0026BB765291"
    static let currentDoorState = "0000000E-0000-1000-8000-0026BB765291"
    static let targetDoorState = "00000032-0000-1000-8000-0026BB765291"
    static let securityTargetState = "00000067-0000-1000-8000-0026BB765291"
    /// The same set `HomeStore.securityTypes` names through HomeKit's constants.
    static let securityTypes: Set<String> = [lockTargetState, targetDoorState, securityTargetState]

    private static func makeAccessories() -> [Accessory] {
        func id(_ n: Int) -> String { String(format: "D3E0DE00-0000-4000-8000-%012d", n) }
        func power(_ n: Int, _ on: Bool) -> Characteristic {
            Characteristic(id: id(n), type: powerState, description: "Power State", properties: ["read", "write", "events"], format: "bool", value: on)
        }
        func level(_ n: Int, _ value: Int) -> Characteristic {
            Characteristic(id: id(n), type: brightness, description: "Brightness", properties: ["read", "write", "events"], format: "int",
                           units: "percentage", minimum: 0, maximum: 100, value: value)
        }
        return [
            Accessory(id: id(101), name: "Demo Floor Lamp", room: "Living Room", category: "Lightbulb", symbol: "lamp.floor",
                      serviceType: "00000043-0000-1000-8000-0026BB765291", serviceName: "Lightbulb",
                      characteristics: [power(1011, true), level(1012, 80)]),
            Accessory(id: id(102), name: "Demo Ceiling Light", room: "Kitchen", category: "Lightbulb", symbol: "lightbulb",
                      serviceType: "00000043-0000-1000-8000-0026BB765291", serviceName: "Lightbulb",
                      characteristics: [power(1021, false), level(1022, 100)]),
            Accessory(id: id(103), name: "Demo Coffee Plug", room: "Kitchen", category: "Outlet", symbol: "poweroutlet.type.b",
                      serviceType: "00000047-0000-1000-8000-0026BB765291", serviceName: "Outlet",
                      characteristics: [power(1031, false)]),
            Accessory(id: id(104), name: "Demo Thermostat", room: "Office", category: "Thermostat", symbol: "thermometer.medium",
                      serviceType: "0000004A-0000-1000-8000-0026BB765291", serviceName: "Thermostat", characteristics: [
                Characteristic(id: id(1041), type: currentTemperature, description: "Current Temperature", properties: ["read", "events"],
                               format: "float", units: "celsius", minimum: 0, maximum: 100, value: 21.5),
                Characteristic(id: id(1042), type: targetTemperature, description: "Target Temperature", properties: ["read", "write", "events"],
                               format: "float", units: "celsius", minimum: 10, maximum: 38, value: 21.0),
            ]),
            Accessory(id: id(105), name: "Demo Motion Sensor", room: "Office", category: "Sensor", symbol: "sensor",
                      serviceType: "00000085-0000-1000-8000-0026BB765291", serviceName: "Motion Sensor", reachable: false, characteristics: [
                Characteristic(id: id(1051), type: motionDetected, description: "Motion Detected", properties: ["read", "events"], format: "bool", value: false),
            ]),
            Accessory(id: id(106), name: "Demo Front Door Lock", room: "Entrance", category: "Door Lock", symbol: "lock",
                      serviceType: "00000045-0000-1000-8000-0026BB765291", serviceName: "Lock Mechanism", characteristics: [
                Characteristic(id: id(1061), type: lockCurrentState, description: "Lock Mechanism Current State", properties: ["read", "events"], format: "uint8", value: 1),
                Characteristic(id: id(1062), type: lockTargetState, description: "Lock Mechanism Target State", properties: ["read", "write", "events"],
                               format: "uint8", minimum: 0, maximum: 1, value: 1),
            ]),
            Accessory(id: id(107), name: "Demo Garage Door", room: "Entrance", category: "Garage Door Opener", symbol: "door.garage.closed",
                      serviceType: "00000041-0000-1000-8000-0026BB765291", serviceName: "Garage Door Opener", characteristics: [
                Characteristic(id: id(1071), type: currentDoorState, description: "Current Door State", properties: ["read", "events"], format: "uint8", value: 1),
                Characteristic(id: id(1072), type: targetDoorState, description: "Target Door State", properties: ["read", "write", "events"],
                               format: "uint8", minimum: 0, maximum: 1, value: 1),
            ]),
        ]
    }
}

// MARK: Rooms, scenes and automations

extension DemoStore {
    static let sceneEvening = "D3E0DE00-0000-4000-8000-000000002001"
    static let sceneNight = "D3E0DE00-0000-4000-8000-000000002002"
    static let sceneLeave = "D3E0DE00-0000-4000-8000-000000002003"
    static let automationSunset = "D3E0DE00-0000-4000-8000-000000003001"
    static let automationMotion = "D3E0DE00-0000-4000-8000-000000003002"

    func scenesJSON() -> [[String: Any]] {
        scenes.map { scene in
            [
                "id": scene.id, "home": Self.homeID, "name": scene.name, "type": scene.type, "builtIn": scene.type != "user",
                "executing": false, "actions": scene.actions.map(actionJSON), "unsupported": 0, "demo": true,
            ]
        }
    }

    func automationsJSON() -> [[String: Any]] {
        automations.map { automation in
            let trigger: [String: Any] = automation.time.map { ["kind": "time", "time": $0.json] } ?? ["kind": "event", "events": automation.events]
            return [
                "id": automation.id, "home": Self.homeID, "name": automation.name, "enabled": automation.enabled, "trigger": trigger,
                "endEvents": automation.endEvents, "conditions": automation.conditions, "executeOnce": false,
                "scenes": automation.scenes, "actions": automation.actions.map(actionJSON), "unsupported": 0, "demo": true,
            ]
        }
    }

    /// The same checks as `HomeStore`'s edits, applied to the synthetic home; the demo's user administers it.
    func edit(_ edit: StructureEdit, allowSecurity: Bool) async -> StoreAnswer {
        let answer = apply(edit, allowSecurity: allowSecurity)
        if answer.status.hasPrefix("200"), let kind = edit.eventKind { structureEvent(kind) }
        return answer
    }

    func settingsChanged() { structureEvent("settings") }

    private func apply(_ edit: StructureEdit, allowSecurity: Bool) -> StoreAnswer {
        switch edit {
        case .renameRoom(let id, let name):
            guard let index = rooms.firstIndex(where: { $0.id == id }) else { return .notFound("no room \(id)") }
            // Accessories keep their room by name: two rooms of one name would be one.
            if rooms.contains(where: { $0.id != id && sameRoomName($0.name, name) }) { return .refused("\(Self.homeName) already has a room named \(name)") }
            let old = rooms[index].name
            rooms[index].name = name
            for slot in accessories.indices where accessories[slot].room == old { accessories[slot].room = name }
            return .ok(["renamed": id, "name": name, "demo": true])

        case .moveAccessory(let id, let room):
            guard let index = accessories.firstIndex(where: { $0.id == id }) else { return .notFound("no accessory \(id)") }
            var added = false
            let target: Room
            if let existing = rooms.first(where: { sameRoomName($0.name, room) }) {
                target = existing
            } else {
                // Not from the name: a renamed room keeps the id its first name gave it.
                addedRooms += 1
                target = Room(id: "demo-room-added-\(addedRooms)", name: room)
                rooms.append(target)
                added = true
            }
            accessories[index].room = target.name
            return .ok(["accessory": id, "room": target.name, "roomID": target.id, "added": added, "demo": true])

        case .runScene(let id):
            guard let scene = scenes.first(where: { $0.id == id }) else { return .notFound("no scene \(id)") }
            if !allowSecurity, scene.actions.contains(where: { isSecurity($0) }) { return .security(scene.name) }
            for action in scene.actions { set(action) }
            return .ok(["ran": id, "demo": true])

        case .renameScene(let id, let name):
            guard let index = scenes.firstIndex(where: { $0.id == id }) else { return .notFound("no scene \(id)") }
            guard scenes[index].type == "user" else { return .builtIn(scenes[index].name) }
            scenes[index].name = name
            return .ok(["renamed": id, "name": name, "demo": true])

        case .sceneActions(let id, let actions):
            guard let index = scenes.firstIndex(where: { $0.id == id }) else { return .notFound("no scene \(id)") }
            let (resolved, refusal) = resolve(actions, keeping: scenes[index].actions, allowSecurity: allowSecurity)
            guard let resolved else { return refusal ?? .badRequest("invalid actions") }
            scenes[index].actions = resolved
            return .ok(["scene": id, "actions": actions.count, "demo": true])

        case .createScene(let home, let name, let actions):
            guard home == Self.homeID else { return .notFound("no home \(home)") }
            let (resolved, refusal) = resolve(actions, keeping: [], allowSecurity: allowSecurity)
            guard let resolved else { return refusal ?? .badRequest("invalid actions") }
            created += 1
            let id = String(format: "D3E0DE00-0000-4000-8000-%012d", 2100 + created)
            scenes.append(Scene(id: id, name: name, type: "user", actions: resolved))
            return .ok(["id": id, "name": name, "demo": true])

        case .deleteScene(let id):
            guard let index = scenes.firstIndex(where: { $0.id == id }) else { return .notFound("no scene \(id)") }
            guard scenes[index].type == "user" else { return .builtIn(scenes[index].name) }
            scenes.remove(at: index)
            for slot in automations.indices { automations[slot].scenes.removeAll { $0 == id } }
            return .ok(["deleted": id, "demo": true])

        case .enableAutomation(let id, let enabled):
            guard let index = automations.firstIndex(where: { $0.id == id }) else { return .notFound("no automation \(id)") }
            automations[index].enabled = enabled
            return .ok(["automation": id, "enabled": enabled, "demo": true])

        case .renameAutomation(let id, let name):
            guard let index = automations.firstIndex(where: { $0.id == id }) else { return .notFound("no automation \(id)") }
            automations[index].name = name
            return .ok(["renamed": id, "name": name, "demo": true])

        case .automationTime(let id, let time):
            guard let index = automations.firstIndex(where: { $0.id == id }) else { return .notFound("no automation \(id)") }
            guard automations[index].time != nil else {
                return .refused("\(automations[index].name) does not start at a time: change what starts it in the Home app")
            }
            automations[index].time = time
            return .ok(["automation": id, "time": time.json, "demo": true])

        case .automationScenes(let id, let sceneIDs):
            guard let index = automations.firstIndex(where: { $0.id == id }) else { return .notFound("no automation \(id)") }
            for sceneID in sceneIDs {
                guard let scene = scenes.first(where: { $0.id == sceneID }) else { return .notFound("no scene \(sceneID) in \(Self.homeName)") }
                if !allowSecurity, scene.actions.contains(where: { isSecurity($0) }) { return .security(scene.name) }
            }
            automations[index].scenes = sceneIDs
            return .ok(["automation": id, "scenes": sceneIDs, "demo": true])

        case .automationActions(let id, let actions):
            guard let index = automations.firstIndex(where: { $0.id == id }) else { return .notFound("no automation \(id)") }
            let (resolved, refusal) = resolve(actions, keeping: automations[index].actions, allowSecurity: allowSecurity)
            guard let resolved else { return refusal ?? .badRequest("invalid actions") }
            automations[index].actions = resolved
            return .ok(["automation": id, "actions": actions.count, "demo": true])

        case .deleteAutomation(let id):
            guard let index = automations.firstIndex(where: { $0.id == id }) else { return .notFound("no automation \(id)") }
            automations.remove(at: index)
            return .ok(["deleted": id, "demo": true])
        }
    }

    /// The accessory and characteristic slots an action names, as `write` finds them.
    private func locate(_ action: StructureAction) -> (accessory: Int, slot: Int)? {
        guard let index = accessories.firstIndex(where: { $0.id == action.accessory }) else { return nil }
        return Self.writableSlot(of: accessories[index], named: action.characteristic).match.map { (index, $0) }
    }

    /// The slot of the characteristic `/write` or an action names, as `HomeStore` finds it.
    fileprivate static func writableSlot(of accessory: Accessory, named name: String) -> (match: Int?, problem: String?) {
        let all = accessory.characteristics
        return CharacteristicLookup.writable(
            Array(all.indices), named: name, id: { all[$0].id }, type: { all[$0].type }, description: { all[$0].description },
            isWritable: { all[$0].properties.contains("write") })
    }

    private func isSecurity(_ action: StructureAction) -> Bool {
        guard let (index, slot) = locate(action) else { return false }
        return Self.securityTypes.contains(accessories[index].characteristics[slot].type)
    }

    /// Every action checked before anything changes, as `HomeStore.resolve` does, and kept by characteristic id with
    /// its value in the characteristic's format. A security action the set already has, unchanged, needs no setting.
    private func resolve(_ actions: [StructureAction], keeping existing: [StructureAction], allowSecurity: Bool) -> ([StructureAction]?, StoreAnswer?) {
        var resolved: [StructureAction] = []
        var seen: Set<String> = []
        for action in actions {
            guard let accessory = accessories.first(where: { $0.id == action.accessory }) else {
                return (nil, .badRequest("no accessory \(action.accessory) in \(Self.homeName)"))
            }
            guard let (index, slot) = locate(action) else { return (nil, .badRequest("\(accessory.name) cannot set \(action.characteristic)")) }
            let characteristic = accessories[index].characteristics[slot]
            guard seen.insert(characteristic.id).inserted else { return (nil, .badRequest("\(accessory.name)'s \(characteristic.description) is set twice")) }
            guard let value = StructureValue.coerce(action.value, format: characteristic.format, minimum: characteristic.minimum, maximum: characteristic.maximum) else {
                return (nil, .badRequest("\(accessory.name)'s \(characteristic.description) does not take \(action.value)"))
            }
            if !allowSecurity, Self.securityTypes.contains(characteristic.type),
               !existing.contains(where: { $0.characteristic == characteristic.id && StructureValue.same($0.value as? NSNumber, value as? NSNumber) }) {
                return (nil, .security(accessory.name))
            }
            resolved.append(StructureAction(accessory: accessory.id, characteristic: characteristic.id, value: value))
        }
        return (resolved, nil)
    }

    /// A scene's write, as a bridge's would be: the value and its event.
    private func set(_ action: StructureAction) {
        guard accessories.first(where: { $0.id == action.accessory })?.reachable == true, let (index, slot) = locate(action) else { return }
        accessories[index].characteristics[slot].value = action.value
        record(accessories[index], accessories[index].characteristics[slot])
    }

    private func actionJSON(_ action: StructureAction) -> [String: Any] {
        let type = locate(action).map { accessories[$0.accessory].characteristics[$0.slot].type }
        var json: [String: Any] = ["accessory": action.accessory, "characteristic": action.characteristic, "value": action.value]
        if let type { json["type"] = type }
        return json
    }

    private func structureEvent(_ kind: String) {
        lastSeq += 1
        events.append([
            "seq": lastSeq, "time": ISO8601DateFormatter().string(from: now()), "home": Self.homeName, "kind": kind,
            "accessory": "", "appState": "active", "demo": true,
        ])
        if events.count > 500 { events.removeFirst(events.count - 500) }
        onChange?()
        onEvent?()
    }

    fileprivate static func makeScenes() -> [Scene] {
        func id(_ n: Int) -> String { String(format: "D3E0DE00-0000-4000-8000-%012d", n) }
        let lamp = id(101), ceiling = id(102), plug = id(103), lock = id(106)
        return [
            Scene(id: sceneEvening, name: "Demo Evening (Synthetic)", type: "user", actions: [
                StructureAction(accessory: lamp, characteristic: id(1011), value: true),
                StructureAction(accessory: lamp, characteristic: id(1012), value: 40),
                StructureAction(accessory: ceiling, characteristic: id(1021), value: false),
            ]),
            Scene(id: sceneNight, name: "Good Night (Demo)", type: "sleep", actions: [
                StructureAction(accessory: lamp, characteristic: id(1011), value: false),
                StructureAction(accessory: ceiling, characteristic: id(1021), value: false),
                StructureAction(accessory: plug, characteristic: id(1031), value: false),
            ]),
            // Locks the door: run only while bridges may operate locks and doors.
            Scene(id: sceneLeave, name: "Demo Leave Home (Synthetic)", type: "homeDeparture", actions: [
                StructureAction(accessory: lamp, characteristic: id(1011), value: false),
                StructureAction(accessory: lock, characteristic: id(1062), value: 1),
            ]),
        ]
    }

    fileprivate static func makeAutomations() -> [Automation] {
        func id(_ n: Int) -> String { String(format: "D3E0DE00-0000-4000-8000-%012d", n) }
        return [
            Automation(id: automationSunset, name: "Demo Sunset (Synthetic)", enabled: true,
                       time: StructureTime(significant: "sunset", offsetMinutes: -15, weekdays: [2, 3, 4, 5, 6]),
                       conditions: [["kind": "time", "before": ["hour": 23, "minute": 0]]], scenes: [sceneEvening], actions: []),
            Automation(id: automationMotion, name: "Demo Motion Light (Synthetic)", enabled: false,
                       events: [["kind": "characteristic", "accessory": id(105), "characteristic": id(1051), "type": motionDetected, "value": true]],
                       endEvents: [["kind": "duration", "seconds": 600]],
                       conditions: [["kind": "presence", "who": "anyone", "home": true]], scenes: [],
                       actions: [StructureAction(accessory: id(102), characteristic: id(1021), value: true)]),
        ]
    }
}

/// Serves the synthetic home while demo mode is on, else HomeKit's homes.
@MainActor
final class DemoSwitchStore: WingmanStore {
    let live: any WingmanStore
    let demo: DemoStore
    private let enabled: () -> Bool

    init(live: any WingmanStore, demo: DemoStore, enabled: @escaping () -> Bool) {
        self.live = live
        self.demo = demo
        self.enabled = enabled
    }

    private var current: any WingmanStore { enabled() ? demo : live }
    var homeIdentifiers: [String] { current.homeIdentifiers }
    var lastSeq: Int { current.lastSeq }
    var firstSeq: Int { current.firstSeq }
    func statusJSON() -> [String: Any] { current.statusJSON() }
    func homesJSON() -> [[String: Any]] { current.homesJSON() }
    func eventsJSON(since: Int?) -> [[String: Any]] { current.eventsJSON(since: since) }
    func readAll() async -> [String: Any] { await current.readAll() }
    func write(accessory: String, characteristic: String, value: Any, allowSecurity: Bool) async -> [String: Any] {
        await current.write(accessory: accessory, characteristic: characteristic, value: value, allowSecurity: allowSecurity)
    }
    func scenesJSON() -> [[String: Any]] { current.scenesJSON() }
    func automationsJSON() -> [[String: Any]] { current.automationsJSON() }
    func edit(_ edit: StructureEdit, allowSecurity: Bool) async -> StoreAnswer { await current.edit(edit, allowSecurity: allowSecurity) }
    func settingsChanged() { current.settingsChanged() }
}
