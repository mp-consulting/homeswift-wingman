import CoreLocation
import HomeKit

/// Apple Home's rooms, scenes (action sets) and automations (triggers) through HomeKit: the JSON of `GET /scenes` and
/// `GET /automations`, and the edits of `StructureEdit`. README.md, "Rooms, scenes and automations", has the API.
extension HomeStore {
    /// HomeKit refuses structural edits from a user who does not administer the home.
    func isAdministrator(_ home: HMHome) -> Bool {
        home.homeAccessControl(for: home.currentUser).isAdministrator
    }

    // MARK: Scenes

    func scenesJSON() -> [[String: Any]] {
        homes.flatMap { home in
            home.actionSets.filter { $0.actionSetType != HMActionSetTypeTriggerOwned }.map { set in
                let type = Self.sceneType(set.actionSetType)
                var json: [String: Any] = [
                    "id": set.uniqueIdentifier.uuidString, "home": home.uniqueIdentifier.uuidString, "name": set.name,
                    "type": type, "builtIn": type != "user", "executing": set.isExecuting,
                    "actions": Self.writeActions(set).map(Self.actionJSON), "unsupported": Self.unsupported(set),
                ]
                if let date = set.lastExecutionDate { json["lastExecuted"] = ISO8601DateFormatter().string(from: date) }
                return json
            }
        }
    }

    private static func sceneType(_ type: String) -> String {
        switch type {
        case HMActionSetTypeWakeUp: "wakeUp"
        case HMActionSetTypeSleep: "sleep"
        case HMActionSetTypeHomeArrival: "homeArrival"
        case HMActionSetTypeHomeDeparture: "homeDeparture"
        case HMActionSetTypeTriggerOwned: "automation"
        default: "user"
        }
    }

    /// Its characteristic writes, in a stable order (HomeKit keeps them in a set).
    private static func writeActions(_ set: HMActionSet) -> [HMCharacteristicWriteAction<NSCopying>] {
        set.actions.compactMap { $0 as? HMCharacteristicWriteAction<NSCopying> }.sorted {
            ($0.characteristic.service?.accessory?.uniqueIdentifier.uuidString ?? "", $0.characteristic.uniqueIdentifier.uuidString)
                < ($1.characteristic.service?.accessory?.uniqueIdentifier.uuidString ?? "", $1.characteristic.uniqueIdentifier.uuidString)
        }
    }

    /// Shortcut and media actions have no public API: they are counted, and a list of actions never replaces them.
    private static func unsupported(_ set: HMActionSet) -> Int {
        set.actions.count - writeActions(set).count
    }

    private static func actionJSON(_ action: HMCharacteristicWriteAction<NSCopying>) -> [String: Any] {
        var json = characteristicReference(action.characteristic)
        json["value"] = jsonValue(action.targetValue)
        return json
    }

    private static func characteristicReference(_ characteristic: HMCharacteristic) -> [String: Any] {
        var json: [String: Any] = [
            "characteristic": characteristic.uniqueIdentifier.uuidString, "type": characteristic.characteristicType,
        ]
        if let accessory = characteristic.service?.accessory { json["accessory"] = accessory.uniqueIdentifier.uuidString }
        return json
    }

    // MARK: Automations

    func automationsJSON() -> [[String: Any]] {
        homes.flatMap { home in home.triggers.map { automationJSON($0, in: home) } }
    }

    private func automationJSON(_ trigger: HMTrigger, in home: HMHome) -> [String: Any] {
        let own = trigger.actionSets.filter { $0.actionSetType == HMActionSetTypeTriggerOwned }
        var json: [String: Any] = [
            "id": trigger.uniqueIdentifier.uuidString, "home": home.uniqueIdentifier.uuidString, "name": trigger.name,
            "enabled": trigger.isEnabled,
            "scenes": trigger.actionSets.filter { $0.actionSetType != HMActionSetTypeTriggerOwned }.map(\.uniqueIdentifier.uuidString),
            "actions": own.flatMap(Self.writeActions).map(Self.actionJSON),
            "unsupported": own.reduce(0) { $0 + Self.unsupported($1) },
        ]
        switch trigger {
        case let timer as HMTimerTrigger:
            json["trigger"] = ["kind": "time", "time": Self.timerTime(timer)]
        case let event as HMEventTrigger:
            if event.events.count == 1, let time = Self.time(of: event.events[0], recurrences: event.recurrences) {
                json["trigger"] = ["kind": "time", "time": time]
            } else {
                json["trigger"] = ["kind": "event", "events": event.events.map { Self.eventJSON($0, recurrences: event.recurrences) }]
            }
            json["endEvents"] = event.endEvents.map { Self.eventJSON($0, recurrences: nil) }
            json["conditions"] = Self.conditions(event.predicate)
            json["executeOnce"] = event.executeOnce
        default:
            json["trigger"] = ["kind": "event", "events": [["kind": "other", "text": String(describing: type(of: trigger))]]]
        }
        return json
    }

    /// A timer's time of day and days: weekly on its fire date's weekday, else every day (`once` when it does not repeat).
    private static func timerTime(_ timer: HMTimerTrigger) -> [String: Any] {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: timer.fireDate)
        var time: [String: Any] = ["hour": parts.hour ?? 0, "minute": parts.minute ?? 0]
        if let recurrence = timer.recurrence {
            if recurrence.weekOfYear == 1 || recurrence.day == 7, let weekday = parts.weekday { time["weekdays"] = [weekday] }
        } else {
            time["once"] = true
        }
        return time
    }

    /// A significant or calendar event as a time, with the trigger's weekdays; nil for any other event.
    private static func time(of event: HMEvent, recurrences: [DateComponents]?) -> [String: Any]? {
        var time: [String: Any]
        switch event {
        case let significant as HMSignificantTimeEvent:
            let offset = significant.offset.map { ($0.hour ?? 0) * 60 + ($0.minute ?? 0) } ?? 0
            time = ["significant": significant.significantEvent == .sunrise ? "sunrise" : "sunset", "offsetMinutes": offset]
        case let calendar as HMCalendarEvent:
            time = ["hour": calendar.fireDateComponents.hour ?? 0, "minute": calendar.fireDateComponents.minute ?? 0]
        default: return nil
        }
        let weekdays = (recurrences ?? []).compactMap(\.weekday).sorted()
        if !weekdays.isEmpty { time["weekdays"] = weekdays }
        return time
    }

    private static func eventJSON(_ event: HMEvent, recurrences: [DateComponents]?) -> [String: Any] {
        switch event {
        case let range as HMCharacteristicThresholdRangeEvent:
            var json = characteristicReference(range.characteristic)
            json["kind"] = "threshold"
            if let minimum = range.thresholdRange.minValue { json["min"] = minimum }
            if let maximum = range.thresholdRange.maxValue { json["max"] = maximum }
            return json
        case let change as HMCharacteristicEvent<NSCopying>:
            var json = characteristicReference(change.characteristic)
            json["kind"] = "characteristic"
            if let value = change.triggerValue { json["value"] = jsonValue(value) }
            return json
        case let presence as HMPresenceEvent:
            return ["kind": "presence", "who": who(presence), "arriving": [.everyEntry, .firstEntry].contains(presence.presenceEventType)]
        case let location as HMLocationEvent:
            // The region is left out: it is where someone lives.
            return ["kind": "location", "arriving": location.region?.notifyOnEntry ?? true]
        case let duration as HMDurationEvent:
            return ["kind": "duration", "seconds": Int(duration.duration.rounded())]
        default:
            if let time = time(of: event, recurrences: recurrences) { return ["kind": "time", "time": time] }
            return ["kind": "other", "text": String(describing: type(of: event))]
        }
    }

    /// "me" for this Mac's user; "everyone" for the first to arrive or the last to leave (the household as a whole);
    /// "anyone" for each arrival or departure.
    private static func who(_ presence: HMPresenceEvent) -> String {
        if presence.presenceUserType == .currentUser { return "me" }
        return [.firstEntry, .lastExit].contains(presence.presenceEventType) ? "everyone" : "anyone"
    }

    // MARK: Conditions

    /// The trigger's predicate as conditions. HomeKit keeps an `NSPredicate` whose shape is its own, so a part is
    /// recognised by building it again with `HMEventTrigger`'s builders from the constants it holds; anything else is
    /// listed as written.
    private static func conditions(_ predicate: NSPredicate?) -> [[String: Any]] {
        guard let predicate else { return [] }
        if let condition = condition(predicate) { return [condition] }
        if let compound = predicate as? NSCompoundPredicate, compound.compoundPredicateType == .and {
            return mergingTimeWindows((compound.subpredicates as? [NSPredicate] ?? []).flatMap(conditions))
        }
        return [["kind": "other", "text": predicate.predicateFormat]]
    }

    private static func condition(_ predicate: NSPredicate) -> [String: Any]? {
        func same(_ candidate: NSPredicate) -> Bool { candidate == predicate || candidate.predicateFormat == predicate.predicateFormat }
        let values = constants(in: predicate)
        for case let event as HMSignificantTimeEvent in values {
            let time = self.time(of: event, recurrences: nil) ?? [:]
            if same(HMEventTrigger.predicateForEvaluatingTriggerOccurring(beforeSignificantEvent: event)) { return ["kind": "time", "before": time] }
            if same(HMEventTrigger.predicateForEvaluatingTriggerOccurring(afterSignificantEvent: event)) { return ["kind": "time", "after": time] }
        }
        for case let components as DateComponents in values {
            let time: [String: Any] = ["hour": components.hour ?? 0, "minute": components.minute ?? 0]
            if same(HMEventTrigger.predicateForEvaluatingTrigger(occurringBefore: components)) { return ["kind": "time", "before": time] }
            if same(HMEventTrigger.predicateForEvaluatingTrigger(occurringAfter: components)) { return ["kind": "time", "after": time] }
        }
        for case let characteristic as HMCharacteristic in values {
            for value in values where !(value is HMCharacteristic) {
                for (operation, comparison) in comparisons
                where same(HMEventTrigger.predicateForEvaluatingTrigger(characteristic, relatedBy: operation, toValue: value)) {
                    var json = characteristicReference(characteristic)
                    json["kind"] = "characteristic"
                    json["comparison"] = comparison
                    json["value"] = jsonValue(value)
                    return json
                }
            }
        }
        for type in [HMPresenceEventType.everyEntry, .everyExit, .firstEntry, .lastExit] {
            for user in [HMPresenceEventUserType.currentUser, .homeUsers] {
                let presence = HMPresenceEvent(presenceEventType: type, presenceUserType: user)
                guard same(HMEventTrigger.predicateForEvaluatingTrigger(withPresence: presence)) else { continue }
                let home = [.everyEntry, .firstEntry].contains(type)
                return ["kind": "presence", "who": user == .currentUser ? "me" : (home ? "anyone" : "everyone"), "home": home]
            }
        }
        return nil
    }

    private static let comparisons: [(NSComparisonPredicate.Operator, String)] = [
        (.equalTo, "=="), (.notEqualTo, "!="), (.lessThan, "<"), (.lessThanOrEqualTo, "<="), (.greaterThan, ">"),
        (.greaterThanOrEqualTo, ">="),
    ]

    /// The constants a predicate compares with; only the expression types whose accessors are valid are opened.
    private static func constants(in predicate: NSPredicate) -> [Any] {
        switch predicate {
        case let compound as NSCompoundPredicate: (compound.subpredicates as? [NSPredicate] ?? []).flatMap { constants(in: $0) }
        case let comparison as NSComparisonPredicate: constants(in: comparison.leftExpression) + constants(in: comparison.rightExpression)
        default: []
        }
    }

    private static func constants(in expression: NSExpression) -> [Any] {
        switch expression.expressionType {
        case .constantValue:
            guard let value = expression.constantValue else { return [] }
            return (value as? [Any]) ?? [value]
        case .function: return (expression.arguments ?? []).flatMap { constants(in: $0) }
        case .aggregate: return (expression.collection as? [NSExpression] ?? []).flatMap { constants(in: $0) }
        default: return []
        }
    }

    /// "After sunset" and "before 23:00" side by side are one window.
    private static func mergingTimeWindows(_ conditions: [[String: Any]]) -> [[String: Any]] {
        var merged: [[String: Any]] = []
        for condition in conditions {
            if condition["kind"] as? String == "time", let last = merged.last, last["kind"] as? String == "time",
               (last["after"] == nil) != (condition["after"] == nil), (last["before"] == nil) != (condition["before"] == nil) {
                merged[merged.count - 1] = last.merging(condition) { first, _ in first }
            } else {
                merged.append(condition)
            }
        }
        return merged
    }

    // MARK: Edits

    func edit(_ edit: StructureEdit, allowSecurity: Bool) async -> StoreAnswer {
        let answer = await apply(edit, allowSecurity: allowSecurity)
        // HomeKit tells this app's delegate only of changes made elsewhere: say this one to every bridge.
        if answer.status.hasPrefix("200"), let kind = edit.eventKind { structureChanged(kind, nil) }
        return answer
    }

    private func apply(_ edit: StructureEdit, allowSecurity: Bool) async -> StoreAnswer {
        switch edit {
        case .renameRoom(let id, let name):
            guard let (home, room) = room(id) else { return .notFound("no room \(id)") }
            guard isAdministrator(home) else { return .notAdministrator }
            if let error = await Self.homeKit({ room.updateName(name, completionHandler: $0) }) { return .refused(Self.describe(error)) }
            return .ok(["renamed": id, "name": room.name])

        case .moveAccessory(let id, let roomName):
            guard let home = homes.first(where: { $0.accessories.contains { $0.uniqueIdentifier.uuidString == id } }),
                  let accessory = home.accessories.first(where: { $0.uniqueIdentifier.uuidString == id }) else {
                return .notFound("no accessory \(id)")
            }
            guard isAdministrator(home) else { return .notAdministrator }
            var added = false
            let target: HMRoom
            if let existing = home.rooms.first(where: { $0.name.compare(roomName, options: .caseInsensitive) == .orderedSame }) {
                target = existing
            } else {
                let (room, error) = await Self.addRoom(roomName, to: home)
                guard let room else { return .refused(error.map(Self.describe) ?? "HomeKit added no room") }
                target = room
                added = true
            }
            if accessory.room?.uniqueIdentifier != target.uniqueIdentifier,
               let error = await Self.homeKit({ home.assignAccessory(accessory, to: target, completionHandler: $0) }) {
                return .refused(Self.describe(error), done: added ? 1 : 0)
            }
            return .ok(["accessory": id, "room": target.name, "roomID": target.uniqueIdentifier.uuidString, "added": added])

        case .runScene(let id):
            guard let (home, set) = scene(id) else { return .notFound("no scene \(id)") }
            if !allowSecurity, Self.writeActions(set).contains(where: { Self.securityTypes.contains($0.characteristic.characteristicType) }) {
                return .security(set.name)
            }
            if let error = await Self.homeKit({ home.executeActionSet(set, completionHandler: $0) }) { return .refused(Self.describe(error)) }
            return .ok(["ran": id])

        case .renameScene(let id, let name):
            guard let (home, set) = scene(id) else { return .notFound("no scene \(id)") }
            guard isAdministrator(home) else { return .notAdministrator }
            guard set.actionSetType == HMActionSetTypeUserDefined else { return .builtIn(set.name) }
            if let error = await Self.homeKit({ set.updateName(name, completionHandler: $0) }) { return .refused(Self.describe(error)) }
            return .ok(["renamed": id, "name": set.name])

        case .sceneActions(let id, let actions):
            guard let (home, set) = scene(id) else { return .notFound("no scene \(id)") }
            guard isAdministrator(home) else { return .notAdministrator }
            let wanted: [(HMCharacteristic, NSCopying)]
            switch resolve(actions, in: home, allowSecurity: allowSecurity) {
            case .actions(let resolved): wanted = resolved
            case .refused(let refusal): return refusal
            }
            if let refusal = await replaceActions(of: set, with: wanted) { return refusal }
            return .ok(["scene": id, "actions": wanted.count])

        case .createScene(let homeID, let name, let actions):
            guard let home = homes.first(where: { $0.uniqueIdentifier.uuidString == homeID }) else { return .notFound("no home \(homeID)") }
            guard isAdministrator(home) else { return .notAdministrator }
            let wanted: [(HMCharacteristic, NSCopying)]
            switch resolve(actions, in: home, allowSecurity: allowSecurity) {
            case .actions(let resolved): wanted = resolved
            case .refused(let refusal): return refusal
            }
            let (created, error) = await Self.addActionSet(name, to: home)
            guard let set = created else { return .refused(error.map(Self.describe) ?? "HomeKit added no scene") }
            if let refusal = await replaceActions(of: set, with: wanted) {
                // Half a scene is worse than none.
                _ = await Self.homeKit({ home.removeActionSet(set, completionHandler: $0) })
                return .refused("\(refusal.body["error"] ?? "HomeKit refused an action"); the scene was not kept")
            }
            return .ok(["id": set.uniqueIdentifier.uuidString, "name": set.name])

        case .deleteScene(let id):
            guard let (home, set) = scene(id) else { return .notFound("no scene \(id)") }
            guard isAdministrator(home) else { return .notAdministrator }
            guard set.actionSetType == HMActionSetTypeUserDefined else { return .builtIn(set.name) }
            if let error = await Self.homeKit({ home.removeActionSet(set, completionHandler: $0) }) { return .refused(Self.describe(error)) }
            return .ok(["deleted": id])

        case .enableAutomation(let id, let enabled):
            guard let (home, trigger) = trigger(id) else { return .notFound("no automation \(id)") }
            guard isAdministrator(home) else { return .notAdministrator }
            if trigger.isEnabled != enabled, let error = await Self.homeKit({ trigger.enable(enabled, completionHandler: $0) }) {
                return .refused(Self.describe(error))
            }
            return .ok(["automation": id, "enabled": trigger.isEnabled])

        case .renameAutomation(let id, let name):
            guard let (home, trigger) = trigger(id) else { return .notFound("no automation \(id)") }
            guard isAdministrator(home) else { return .notAdministrator }
            if let error = await Self.homeKit({ trigger.updateName(name, completionHandler: $0) }) { return .refused(Self.describe(error)) }
            return .ok(["renamed": id, "name": trigger.name])

        case .automationTime(let id, let time):
            guard let (home, trigger) = trigger(id) else { return .notFound("no automation \(id)") }
            guard isAdministrator(home) else { return .notAdministrator }
            return await retime(trigger, to: time)

        case .automationScenes(let id, let sceneIDs):
            guard let (home, trigger) = trigger(id) else { return .notFound("no automation \(id)") }
            guard isAdministrator(home) else { return .notAdministrator }
            var wanted: [HMActionSet] = []
            for sceneID in sceneIDs {
                guard let set = home.actionSets.first(where: {
                    $0.uniqueIdentifier.uuidString == sceneID && $0.actionSetType != HMActionSetTypeTriggerOwned
                }) else { return .notFound("no scene \(sceneID) in \(home.name)") }
                if !allowSecurity, Self.writeActions(set).contains(where: { Self.securityTypes.contains($0.characteristic.characteristicType) }) {
                    return .security(set.name)
                }
                wanted.append(set)
            }
            var done = 0
            for set in trigger.actionSets where set.actionSetType != HMActionSetTypeTriggerOwned && !wanted.contains(set) {
                if let error = await Self.homeKit({ trigger.removeActionSet(set, completionHandler: $0) }) {
                    return .refused(Self.describe(error), done: done)
                }
                done += 1
            }
            for set in wanted where !trigger.actionSets.contains(set) {
                if let error = await Self.homeKit({ trigger.addActionSet(set, completionHandler: $0) }) {
                    return .refused(Self.describe(error), done: done)
                }
                done += 1
            }
            return .ok(["automation": id, "scenes": wanted.map(\.uniqueIdentifier.uuidString)])

        case .automationActions(let id, let actions):
            guard let (home, trigger) = trigger(id) else { return .notFound("no automation \(id)") }
            guard isAdministrator(home) else { return .notAdministrator }
            let wanted: [(HMCharacteristic, NSCopying)]
            switch resolve(actions, in: home, allowSecurity: allowSecurity) {
            case .actions(let resolved): wanted = resolved
            case .refused(let refusal): return refusal
            }
            guard let own = trigger.actionSets.first(where: { $0.actionSetType == HMActionSetTypeTriggerOwned }) else {
                // HomeKit's API makes no action set of that type: only the Home app gives an automation its own actions.
                if wanted.isEmpty { return .ok(["automation": id, "actions": 0]) }
                return .refused("\(trigger.name) has no actions of its own in HomeKit: give it one in the Home app first, or run a scene")
            }
            if let refusal = await replaceActions(of: own, with: wanted) { return refusal }
            return .ok(["automation": id, "actions": wanted.count])

        case .deleteAutomation(let id):
            guard let (home, trigger) = trigger(id) else { return .notFound("no automation \(id)") }
            guard isAdministrator(home) else { return .notAdministrator }
            if let error = await Self.homeKit({ home.removeTrigger(trigger, completionHandler: $0) }) { return .refused(Self.describe(error)) }
            return .ok(["deleted": id])
        }
    }

    private func room(_ id: String) -> (HMHome, HMRoom)? {
        for home in homes { if let room = home.rooms.first(where: { $0.uniqueIdentifier.uuidString == id }) { return (home, room) } }
        return nil
    }

    /// A scene: an action set other than an automation's own.
    private func scene(_ id: String) -> (HMHome, HMActionSet)? {
        for home in homes {
            if let set = home.actionSets.first(where: { $0.uniqueIdentifier.uuidString == id && $0.actionSetType != HMActionSetTypeTriggerOwned }) {
                return (home, set)
            }
        }
        return nil
    }

    private func trigger(_ id: String) -> (HMHome, HMTrigger)? {
        for home in homes { if let trigger = home.triggers.first(where: { $0.uniqueIdentifier.uuidString == id }) { return (home, trigger) } }
        return nil
    }

    private enum Resolved {
        case actions([(HMCharacteristic, NSCopying)])
        case refused(StoreAnswer)
    }

    /// Every action checked before anything changes: the accessory in this home, a writable characteristic, a value
    /// of its format within its range, and no lock, garage door or alarm unless `allowSecurity`.
    private func resolve(_ actions: [StructureAction], in home: HMHome, allowSecurity: Bool) -> Resolved {
        var resolved: [(HMCharacteristic, NSCopying)] = []
        var seen: Set<UUID> = []
        for action in actions {
            guard let accessory = home.accessories.first(where: { $0.uniqueIdentifier.uuidString == action.accessory }) else {
                return .refused(.badRequest("no accessory \(action.accessory) in \(home.name)"))
            }
            let all = accessory.services.flatMap(\.characteristics)
            let byID = all.filter { $0.uniqueIdentifier.uuidString.caseInsensitiveCompare(action.characteristic) == .orderedSame }
            let candidates = byID.isEmpty ? all.filter {
                $0.characteristicType.caseInsensitiveCompare(action.characteristic) == .orderedSame || $0.localizedDescription == action.characteristic
            } : byID
            guard let characteristic = candidates.first(where: { $0.properties.contains(HMCharacteristicPropertyWritable) }) else {
                let problem = candidates.isEmpty ? "has no characteristic \(action.characteristic)" : "cannot set \(action.characteristic)"
                return .refused(.badRequest("\(accessory.name) \(problem)"))
            }
            guard seen.insert(characteristic.uniqueIdentifier).inserted else {
                return .refused(.badRequest("\(accessory.name)'s \(characteristic.localizedDescription) is set twice"))
            }
            if !allowSecurity, Self.securityTypes.contains(characteristic.characteristicType) { return .refused(.security(accessory.name)) }
            let metadata = characteristic.metadata
            guard let value = StructureValue.coerce(
                action.value, format: metadata?.format, minimum: metadata?.minimumValue?.doubleValue, maximum: metadata?.maximumValue?.doubleValue,
                validValues: metadata?.validValues?.map(\.intValue)), let object = Self.object(value) else {
                return .refused(.badRequest("\(accessory.name)'s \(characteristic.localizedDescription) does not take \(action.value)"))
            }
            resolved.append((characteristic, object))
        }
        return .actions(resolved)
    }

    private static func object(_ value: Any) -> NSCopying? {
        switch value {
        case let bool as Bool: NSNumber(value: bool)
        case let int as Int: NSNumber(value: int)
        case let double as Double: NSNumber(value: double)
        case let string as String: string as NSString
        case let number as NSNumber: number
        default: nil
        }
    }

    /// Makes the action set write exactly these characteristics: those not listed removed, those kept updated, the new
    /// ones added. Its shortcut and media actions stay. HomeKit has no transaction: a refusal says how far it got.
    private func replaceActions(of set: HMActionSet, with wanted: [(HMCharacteristic, NSCopying)]) async -> StoreAnswer? {
        let existing = Self.writeActions(set)
        let wantedIDs = Set(wanted.map(\.0.uniqueIdentifier))
        var done = 0
        for action in existing where !wantedIDs.contains(action.characteristic.uniqueIdentifier) {
            if let error = await Self.homeKit({ set.removeAction(action, completionHandler: $0) }) { return .refused(Self.describe(error), done: done) }
            done += 1
        }
        for (characteristic, value) in wanted {
            if let action = existing.first(where: { $0.characteristic.uniqueIdentifier == characteristic.uniqueIdentifier }) {
                guard !StructureValue.same(action.targetValue, value) else { continue }
                if let error = await Self.homeKit({ action.updateTargetValue(value, completionHandler: $0) }) {
                    return .refused(Self.describe(error), done: done)
                }
            } else {
                let action = HMCharacteristicWriteAction(characteristic: characteristic, targetValue: value)
                if let error = await Self.homeKit({ set.addAction(action, completionHandler: $0) }) { return .refused(Self.describe(error), done: done) }
            }
            done += 1
        }
        return nil
    }

    /// A timer takes a clock time, daily or on one weekday; an event trigger whose only event is a time takes a new
    /// significant or calendar event and its weekdays as recurrences.
    private func retime(_ trigger: HMTrigger, to time: StructureTime) async -> StoreAnswer {
        let id = trigger.uniqueIdentifier.uuidString
        switch trigger {
        case let timer as HMTimerTrigger:
            guard time.significant == nil else {
                return .refused("\(timer.name) is a timer: HomeKit runs it at a clock time, not at sunrise or sunset")
            }
            guard time.weekdays.count <= 1 else {
                return .refused("\(timer.name) is a timer: HomeKit repeats it every day or on one weekday, not on several")
            }
            var match = DateComponents(hour: time.hour, minute: time.minute, second: 0)
            match.weekday = time.weekdays.first
            guard let fireDate = Calendar.current.nextDate(after: Date(), matching: match, matchingPolicy: .nextTime) else {
                return .refused("no next \(time.hour ?? 0):\(time.minute ?? 0)")
            }
            if let error = await Self.homeKit({ timer.updateFireDate(fireDate, completionHandler: $0) }) { return .refused(Self.describe(error)) }
            let recurrence = time.weekdays.isEmpty ? DateComponents(day: 1) : DateComponents(weekOfYear: 1)
            if let error = await Self.homeKit({ timer.updateRecurrence(recurrence, completionHandler: $0) }) {
                return .refused(Self.describe(error), done: 1)
            }
            return .ok(["automation": id, "time": Self.timerTime(timer)])
        case let event as HMEventTrigger:
            guard event.events.count == 1, Self.time(of: event.events[0], recurrences: nil) != nil else {
                return .refused("\(event.name) does not start at a time: change what starts it in the Home app")
            }
            let new: HMEvent
            if let significant = time.significant {
                let offset = time.offsetMinutes == 0 ? nil : DateComponents(minute: time.offsetMinutes)
                new = HMSignificantTimeEvent(significantEvent: significant == "sunrise" ? .sunrise : .sunset, offset: offset)
            } else {
                new = HMCalendarEvent(fire: DateComponents(hour: time.hour, minute: time.minute))
            }
            if let error = await Self.homeKit({ event.updateEvents([new], completionHandler: $0) }) { return .refused(Self.describe(error)) }
            let recurrences = time.weekdays.isEmpty ? nil : time.weekdays.map { DateComponents(weekday: $0) }
            if let error = await Self.homeKit({ event.updateRecurrences(recurrences, completionHandler: $0) }) {
                return .refused(Self.describe(error), done: 1)
            }
            return .ok(["automation": id, "time": time.json])
        default:
            return .refused("\(trigger.name) does not start at a time")
        }
    }

    // MARK: HomeKit calls

    private static func homeKit(_ call: (@escaping @Sendable (Error?) -> Void) -> Void) async -> Error? {
        await withCheckedContinuation { continuation in call { error in continuation.resume(returning: error) } }
    }

    private static func addRoom(_ name: String, to home: HMHome) async -> (HMRoom?, Error?) {
        await withCheckedContinuation { continuation in
            home.addRoom(withName: name) { room, error in continuation.resume(returning: (room, error)) }
        }
    }

    private static func addActionSet(_ name: String, to home: HMHome) async -> (HMActionSet?, Error?) {
        await withCheckedContinuation { continuation in
            home.addActionSet(withName: name) { set, error in continuation.resume(returning: (set, error)) }
        }
    }
}
