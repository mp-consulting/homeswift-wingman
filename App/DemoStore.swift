import Foundation

/// A synthetic home for App Review and evaluation, served through the same API as HomeKit's homes.
///
/// Nothing here touches HomeKit: names say "Demo" and "(Synthetic)", `/status` reports `"demo": true`, and writes only
/// change these in-memory values. Locks, garage doors and alarms follow the same security setting as real ones.
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
        let room: String
        let category: String
        let symbol: String
        let serviceType: String
        let serviceName: String
        var reachable = true
        var characteristics: [Characteristic]
    }

    static let homeID = "D3E0DE00-0000-4000-8000-000000000001"
    static let homeName = "Demo Home (Synthetic)"
    static let rooms = ["Living Room", "Kitchen", "Office", "Entrance"]

    var onChange: (() -> Void)?
    var onEvent: (() -> Void)?
    private(set) var accessories: [Accessory]
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
        var text = "Demo: 1 home, \(Self.rooms.count) rooms, \(accessories.count) accessories"
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
            "id": Self.homeID, "name": Self.homeName, "primary": true, "demo": true,
            "rooms": Self.rooms.map { room in
                ["id": Self.roomID(room), "name": room, "accessories": accessories.filter { $0.room == room }.count] as [String: Any]
            },
            "zones": [] as [Any],
            "scenes": [["name": "Good Night (Demo)", "type": "HMActionSetTypeSleep", "actions": 2] as [String: Any]],
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
        let byID = target.characteristics.indices.filter { target.characteristics[$0].id.caseInsensitiveCompare(type) == .orderedSame }
        let candidates = byID.isEmpty ? target.characteristics.indices.filter {
            target.characteristics[$0].type.caseInsensitiveCompare(type) == .orderedSame || target.characteristics[$0].description == type
        } : byID
        guard let slot = candidates.first(where: { target.characteristics[$0].properties.contains("write") }) else {
            return ["error": candidates.isEmpty ? "no characteristic \(type)" : "\(type) is not writable"]
        }
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
            "rooms": Self.rooms.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.compactMap { room -> [String: Any]? in
                let members = accessories.filter { $0.room == room }
                    .sorted { ($0.category, $0.name) < ($1.category, $1.name) }
                guard !members.isEmpty else { return nil }
                return [
                    "id": Self.roomID(room), "name": room,
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

    private static func roomID(_ room: String) -> String {
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
}
