import HomeKit
import UIKit

/// The homes HomeKit gives this app, kept current through HomeKit's delegates.
///
/// Every accessory gets this store as its delegate and notifications on the characteristics that send events, so
/// `events` shows whether HomeKit keeps pushing changes while the app sits in the menu bar.
@MainActor
final class HomeStore: NSObject, WingmanStore {
    var homeIdentifiers: [String] { homes.map(\.uniqueIdentifier.uuidString) }
    struct Event {
        /// Counts from 1 for the app's life: `GET /events?since=` answers the newer ones.
        let seq: Int
        let time: Date
        let home: String
        let accessory: String
        let accessoryID: String
        let characteristic: String
        let characteristicID: String
        let type: String
        let value: Any?
        let appState: String
    }

    var onChange: (() -> Void)?
    /// Called after each value change, for the server's waiting `GET /events`.
    var onEvent: (() -> Void)?
    private(set) var lastSeq = 0
    /// The oldest event kept (500 at most): a client asking `since` an earlier one missed some.
    var firstSeq: Int { events.first?.seq ?? lastSeq + 1 }
    private var manager: HMHomeManager?
    private(set) var homesLoaded = false
    private(set) var events: [Event] = []
    private(set) var eventCount = 0
    /// For a soak test: when the app started, and how many events arrived in each hour since.
    private let startedAt = Date()
    private(set) var lastEventAt: Date?
    private var eventsPerHour: [String: Int] = [:]
    private(set) var lastRefresh: [String: Any]?
    private var notificationErrors: [String: Int] = [:]
    private var lastValueChange: [UUID: Date] = [:]

    var homes: [HMHome] { manager?.homes ?? [] }

    func start() {
        let manager = HMHomeManager()
        manager.delegate = self
        self.manager = manager
    }

    var authorization: String {
        guard let status = manager?.authorizationStatus else { return "unknown" }
        if status.contains(.authorized) { return "authorized" }
        if status.contains(.restricted) { return "restricted" }
        if status.contains(.determined) { return "denied" }
        return "not determined"
    }

    var accessoryCount: Int { homes.reduce(0) { $0 + $1.accessories.count } }

    var summary: String {
        guard authorization == "authorized" else { return "HomeKit: \(authorization)" }
        guard homesLoaded else { return "Loading homes…" }
        let rooms = homes.reduce(0) { $0 + $1.rooms.count }
        let unreachable = homes.reduce(0) { $0 + $1.accessories.filter { !$0.isReachable }.count }
        var text = "\(homes.count) home\(homes.count == 1 ? "" : "s"), \(rooms) rooms, \(accessoryCount) accessories"
        if unreachable > 0 { text += " (\(unreachable) not responding)" }
        return text
    }

    // MARK: Watching

    private func watchAll() {
        for home in homes {
            home.delegate = self
            for accessory in home.accessories { watch(accessory) }
        }
    }

    private func watch(_ accessory: HMAccessory) {
        accessory.delegate = self
        for service in accessory.services {
            for characteristic in service.characteristics
            where characteristic.properties.contains(HMCharacteristicPropertySupportsEventNotification) && !characteristic.isNotificationEnabled {
                characteristic.enableNotification(true) { [weak self] error in
                    guard let error else { return }
                    MainActor.assumeIsolated { self?.notificationErrors[Self.describe(error), default: 0] += 1 }
                }
            }
        }
    }

    private func record(_ characteristic: HMCharacteristic, of accessory: HMAccessory) {
        eventCount += 1
        lastValueChange[characteristic.uniqueIdentifier] = Date()
        lastEventAt = Date()
        eventsPerHour[String(ISO8601DateFormatter().string(from: Date()).prefix(13)), default: 0] += 1
        lastSeq += 1
        let event = Event(
            seq: lastSeq, time: Date(), home: home(of: accessory)?.name ?? "", accessory: accessory.name,
            accessoryID: accessory.uniqueIdentifier.uuidString, characteristic: characteristic.localizedDescription,
            characteristicID: characteristic.uniqueIdentifier.uuidString, type: characteristic.characteristicType,
            value: characteristic.value, appState: Self.appState
        )
        events.append(event)
        if events.count > 500 { events.removeFirst(events.count - 500) }
        onChange?()
        onEvent?()
    }

    private func home(of accessory: HMAccessory) -> HMHome? {
        homes.first { $0.accessories.contains(accessory) }
    }

    // MARK: Reading every value

    /// Reads every readable characteristic, to see what HomeKit answers (and refuses) from a menu bar app.
    func readAll() async -> [String: Any] {
        let characteristics = homes.flatMap(\.accessories).flatMap(\.services).flatMap(\.characteristics)
            .filter { $0.properties.contains(HMCharacteristicPropertyReadable) }
        let started = Date()
        let state = Self.appState
        var failures: [String: Int] = [:]
        var failedBy: [String: Int] = [:]
        var succeeded = 0
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var pending = characteristics.count
            guard pending > 0 else { continuation.resume(); return }
            for characteristic in characteristics {
                characteristic.readValue { error in
                    MainActor.assumeIsolated {
                        if let error {
                            failures[Self.describe(error), default: 0] += 1
                            let accessory = characteristic.service?.accessory
                            let key = "\(accessory?.manufacturer ?? "?") · \(accessory?.name ?? "?") · \(characteristic.localizedDescription)"
                            failedBy[key, default: 0] += 1
                        } else {
                            succeeded += 1
                        }
                        pending -= 1
                        if pending == 0 { continuation.resume() }
                    }
                }
            }
        }
        let result: [String: Any] = [
            "characteristics": characteristics.count,
            "succeeded": succeeded,
            "failures": failures,
            "failed": failedBy,
            "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100,
            "appState": state,
            "finishedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        lastRefresh = result
        onChange?()
        return result
    }

    // MARK: Writing a value

    /// Locks, garage doors and alarms: never written through this API (Homeswift sends them through its confirmed path).
    static let securityTypes: Set<String> = [
        HMCharacteristicTypeTargetLockMechanismState, HMCharacteristicTypeTargetDoorState,
        HMCharacteristicTypeTargetSecuritySystemState,
    ]

    /// Writes `value` to the characteristic with id `type` (its `id` in `/homes`), else to the first writable
    /// characteristic of `type` (a HAP UUID or HomeKit's description, such as "Power State") on the accessory with id
    /// or exact name `accessory`.
    func write(accessory: String, characteristic type: String, value: Any) async -> [String: Any] {
        guard let target = homes.flatMap(\.accessories).first(where: { $0.uniqueIdentifier.uuidString == accessory || $0.name == accessory })
        else { return ["error": "no accessory \(accessory)"] }
        // The native HomeKit action also works when Identify is absent from the service list.
        if type == "Identify" {
            guard target.supportsIdentify else { return ["error": "this accessory does not support Identify"] }
            guard let enabled = value as? Bool, enabled else { return ["error": "Identify requires true"] }
            let error: Error? = await withCheckedContinuation { continuation in
                target.identify { error in continuation.resume(returning: error) }
            }
            if let error { return ["error": Self.describe(error)] }
            return ["accessory": target.name, "characteristic": "Identify", "written": true]
        }
        let all = target.services.flatMap(\.characteristics)
        let byID = all.filter { $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(type) == .orderedSame }
        let candidates = byID.isEmpty ? all.filter {
            $0.characteristicType.caseInsensitiveCompare(type) == .orderedSame || $0.localizedDescription == type
        } : byID
        guard let characteristic = candidates.first(where: { $0.properties.contains(HMCharacteristicPropertyWritable) }) else {
            return ["error": candidates.isEmpty ? "no characteristic \(type)" : "\(type) is not writable"]
        }
        if Self.securityTypes.contains(characteristic.characteristicType) {
            return ["error": "\(characteristic.localizedDescription) is a security control; not written through Wingman"]
        }
        let started = Date()
        let error: Error? = await withCheckedContinuation { continuation in
            characteristic.writeValue(value) { error in continuation.resume(returning: error) }
        }
        var result: [String: Any] = [
            "accessory": target.name,
            "characteristic": characteristic.localizedDescription,
            "seconds": (Date().timeIntervalSince(started) * 100).rounded() / 100,
            "appState": Self.appState,
        ]
        if let error { result["error"] = Self.describe(error) } else { result["written"] = Self.jsonValue(value) }
        if let current = characteristic.value { result["value"] = Self.jsonValue(current) }
        return result
    }

    // MARK: JSON

    func statusJSON() -> [String: Any] {
        var status: [String: Any] = [
            "authorization": authorization,
            "homesLoaded": homesLoaded,
            "homes": homes.count,
            "accessories": accessoryCount,
            "events": eventCount,
            "appState": Self.appState,
            "notificationErrors": notificationErrors,
            "startedAt": ISO8601DateFormatter().string(from: startedAt),
            "eventsPerHour": eventsPerHour,
        ]
        if let lastRefresh { status["lastRead"] = lastRefresh }
        if let lastEventAt { status["lastEventAt"] = ISO8601DateFormatter().string(from: lastEventAt) }
        return status
    }

    func homesJSON() -> [[String: Any]] {
        homes.map { home in
            let roomNames = Dictionary(uniqueKeysWithValues: (home.rooms + [home.roomForEntireHome()]).map { ($0.uniqueIdentifier, $0.name) })
            return [
                "id": home.uniqueIdentifier.uuidString,
                "name": home.name,
                "primary": home.isPrimary,
                "rooms": home.rooms.map { room in
                    ["id": room.uniqueIdentifier.uuidString, "name": room.name, "accessories": room.accessories.count] as [String: Any]
                },
                "zones": home.zones.map { zone in
                    ["name": zone.name, "rooms": zone.rooms.map(\.name)] as [String: Any]
                },
                "scenes": home.actionSets.map { set in
                    ["name": set.name, "type": set.actionSetType, "actions": set.actions.count] as [String: Any]
                },
                "accessories": home.accessories.map { accessory in
                    accessoryJSON(accessory, room: accessory.room.flatMap { roomNames[$0.uniqueIdentifier] })
                },
            ]
        }
    }

    private func accessoryJSON(_ accessory: HMAccessory, room: String?) -> [String: Any] {
        // The bridge it sits behind, so a Homeswift bridge can leave out its own accessories.
        let bridge = accessory.isBridged ? homes.flatMap(\.accessories).first {
            $0.uniqueIdentifiersForBridgedAccessories?.contains(accessory.uniqueIdentifier) == true
        } : nil
        var json: [String: Any] = [
            "id": accessory.uniqueIdentifier.uuidString,
            "name": accessory.name,
            "category": accessory.category.localizedDescription,
            "reachable": accessory.isReachable,
            "supportsIdentify": accessory.supportsIdentify,
            "bridged": accessory.isBridged,
            "blocked": accessory.isBlocked,
        ]
        if let room { json["room"] = room }
        if let bridge {
            var info: [String: Any] = ["id": bridge.uniqueIdentifier.uuidString, "name": bridge.name]
            if let manufacturer = bridge.manufacturer { info["manufacturer"] = manufacturer }
            if let model = bridge.model { info["model"] = model }
            json["bridge"] = info
        }
        if let manufacturer = accessory.manufacturer { json["manufacturer"] = manufacturer }
        if let model = accessory.model { json["model"] = model }
        if let firmware = accessory.firmwareVersion { json["firmware"] = firmware }
        // Set for every accessory in the home, HAP ones too: Apple's fabric numbers them all.
        if let node = accessory.matterNodeID { json["matterNodeID"] = node }
        // Set only for a service of a Matter device (HMService.h).
        if accessory.services.contains(where: { $0.matterEndpointID != nil }) { json["matter"] = true }
        json["services"] = accessory.services.map { service in
            [
                "id": service.uniqueIdentifier.uuidString,
                "name": service.name,
                "type": service.serviceType,
                "description": service.localizedDescription,
                "primary": service.isPrimaryService,
                "characteristics": service.characteristics.map(characteristicJSON),
            ] as [String: Any]
        }
        return json
    }

    private func characteristicJSON(_ characteristic: HMCharacteristic) -> [String: Any] {
        var json: [String: Any] = [
            "id": characteristic.uniqueIdentifier.uuidString,
            "type": characteristic.characteristicType,
            "description": characteristic.localizedDescription,
            "properties": characteristic.properties.map(Self.shortProperty),
            "notifying": characteristic.isNotificationEnabled,
        ]
        if let value = characteristic.value { json["value"] = Self.jsonValue(value) }
        if let metadata = characteristic.metadata {
            if let format = metadata.format { json["format"] = format }
            if let units = metadata.units { json["units"] = units }
            if let minimum = metadata.minimumValue { json["min"] = minimum }
            if let maximum = metadata.maximumValue { json["max"] = maximum }
            if let step = metadata.stepValue { json["step"] = step }
            if let valid = metadata.validValues, !valid.isEmpty { json["validValues"] = valid }
            if let length = metadata.maxLength { json["maxLength"] = length }
        }
        if let changed = lastValueChange[characteristic.uniqueIdentifier] {
            json["changedAt"] = ISO8601DateFormatter().string(from: changed)
        }
        return json
    }

    /// The latest value changes, newest first; with `since`, only those after that `seq`, oldest first.
    func eventsJSON(since: Int? = nil) -> [[String: Any]] {
        let formatter = ISO8601DateFormatter()
        let chosen = since.map { since in events.filter { $0.seq > since } } ?? events.reversed()
        return chosen.map { event in
            var json: [String: Any] = [
                "seq": event.seq,
                "time": formatter.string(from: event.time),
                "home": event.home,
                "accessory": event.accessory,
                "accessoryID": event.accessoryID,
                "characteristic": event.characteristic,
                "characteristicID": event.characteristicID,
                "type": event.type,
                "appState": event.appState,
            ]
            if let value = event.value { json["value"] = Self.jsonValue(value) }
            return json
        }
    }

    // MARK: Helpers

    static var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    static func describe(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code): \(error.localizedDescription)"
    }

    private static func shortProperty(_ property: String) -> String {
        switch property {
        case HMCharacteristicPropertyReadable: "read"
        case HMCharacteristicPropertyWritable: "write"
        case HMCharacteristicPropertySupportsEventNotification: "events"
        case HMCharacteristicPropertyHidden: "hidden"
        default: property
        }
    }

    private static func jsonValue(_ value: Any) -> Any {
        switch value {
        case let data as Data: data.base64EncodedString()
        case let array as [Any]: array.map(jsonValue)
        case let dictionary as [String: Any]: dictionary.mapValues(jsonValue)
        case is NSNumber, is String: value
        default: String(describing: value)
        }
    }
}

extension HomeStore: @preconcurrency HMHomeManagerDelegate {
    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        homesLoaded = true
        watchAll()
        onChange?()
    }

    func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        onChange?()
    }

    func homeManager(_ manager: HMHomeManager, didAdd home: HMHome) {
        watchAll()
        onChange?()
    }

    func homeManager(_ manager: HMHomeManager, didRemove home: HMHome) {
        onChange?()
    }
}

extension HomeStore: @preconcurrency HMHomeDelegate {
    func home(_ home: HMHome, didAdd accessory: HMAccessory) {
        watch(accessory)
        onChange?()
    }

    func home(_ home: HMHome, didRemove accessory: HMAccessory) { onChange?() }
    func home(_ home: HMHome, didUpdate room: HMRoom, for accessory: HMAccessory) { onChange?() }
    func home(_ home: HMHome, didAdd room: HMRoom) { onChange?() }
    func home(_ home: HMHome, didRemove room: HMRoom) { onChange?() }
    func home(_ home: HMHome, didUpdateNameFor room: HMRoom) { onChange?() }
}

extension HomeStore: @preconcurrency HMAccessoryDelegate {
    func accessory(_ accessory: HMAccessory, service: HMService, didUpdateValueFor characteristic: HMCharacteristic) {
        record(characteristic, of: accessory)
    }

    func accessoryDidUpdateReachability(_ accessory: HMAccessory) { onChange?() }
    func accessoryDidUpdateName(_ accessory: HMAccessory) { onChange?() }
    func accessoryDidUpdateServices(_ accessory: HMAccessory) {
        watch(accessory)
        onChange?()
    }
}
