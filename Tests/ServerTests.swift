import Foundation
import Network
import Darwin

struct TestFailure: Error { let message: String }
func expect(_ condition: Bool, _ message: String) throws {
    if !condition { throw TestFailure(message: message) }
}
@MainActor func eventually(_ message: String, seconds: Double = 4, _ predicate: () -> Bool) async throws {
    let until = Date().addingTimeInterval(seconds)
    while !predicate() {
        if Date() > until { throw TestFailure(message: message) }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor final class FakeStore: WingmanStore {
    var homeIdentifiers = ["fixture-home"]
    var lastSeq = 0
    var firstSeq = 1
    var reads = 0
    var writes = 0
    var securityWrites = 0
    func statusJSON() -> [String: Any] { ["fixture": true] }
    func homesJSON() -> [[String: Any]] { [["name": "Demo Home"]] }
    func eventsJSON(since: Int?) -> [[String: Any]] { lastSeq > (since ?? 0) ? [["seq": lastSeq, "value": "private-event"]] : [] }
    func readAll() async -> [String: Any] { reads += 1; return ["read": true] }
    func write(accessory: String, characteristic: String, value: Any, allowSecurity: Bool) async -> [String: Any] {
        writes += 1
        if allowSecurity { securityWrites += 1 }
        return ["written": true]
    }
    var edits: [StructureEdit] = []
    var settingsEvents = 0
    func scenesJSON() -> [[String: Any]] { [["id": "scene-1", "name": "Fixture Scene"]] }
    func automationsJSON() -> [[String: Any]] { [["id": "automation-1", "name": "Fixture Automation"]] }
    func edit(_ edit: StructureEdit, allowSecurity: Bool) async -> StoreAnswer {
        edits.append(edit)
        return .ok(["edited": true, "security": allowSecurity])
    }
    func settingsChanged() { settingsEvents += 1 }
}

@MainActor final class TestClient {
    let connection: NWConnection
    var received = Data()
    var ended = false
    var ready = false
    init(port: UInt16, request: String? = nil) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.ready = true
                    if let request { self.send(request) }
                    self.receive()
                case .failed, .cancelled: self.ended = true
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }
    func send(_ value: String) { connection.send(content: Data(value.utf8), completion: .contentProcessed { _ in }) }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 100_000) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data { self.received.append(data) }
                if complete || error != nil { self.ended = true; self.connection.cancel() }
                else { self.receive() }
            }
        }
    }
    func close() { connection.cancel() }
    var text: String { String(decoding: received, as: UTF8.self) }
}

@main struct ServerTests {
    @MainActor static func main() async throws {
        try parser()
        try structureRequests()
        try pairing()
        try await network()
        try await demo()
        try await demoStructure()
        print("PASS: parser, structure requests, pairing transactions, last-seen persistence, network limits, revocation, listener recovery and the demo home's structure")
    }

    static func parser() throws {
        for value in ["nan", "NaN", "inf", "-inf", "1e999", "bad", ""] {
            try expect(HTTPRequest.waitSeconds(value) == nil, "reject non-finite wait: \(value)")
        }
        try expect(HTTPRequest.waitSeconds(nil) == 0, "default wait")
        try expect(HTTPRequest.waitSeconds("-1") == 0 && HTTPRequest.waitSeconds("100") == 30, "bounded wait")
        try expect(HTTPRequest.waitSeconds("0.5") == 0.5, "fractional wait")
        let valid = Data("POST /pair HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8)
        for size in 0..<valid.count {
            guard case .incomplete = HTTPRequest.parse(Data(valid.prefix(size))) else { throw TestFailure(message: "partial request \(size)") }
        }
        guard case .complete(_, let body) = HTTPRequest.parse(valid), body == Data("{}".utf8) else { throw TestFailure(message: "valid request") }
        for header in ["Content-Length: -1", "Content-Length: nan", "Content-Length: 9999999999999999999999999",
                       "Content-Length: 1\r\nContent-Length: 1", "Transfer-Encoding: chunked", "Content-Length: 65536", "Bad header"] {
            guard case .invalid = HTTPRequest.parse(Data("POST /pair HTTP/1.1\r\n\(header)\r\n\r\n".utf8)) else { throw TestFailure(message: "accepted invalid framing") }
        }
        for data in [Data(repeating: 65, count: HTTPRequest.maximumHeaderBytes + 1), Data(repeating: 65, count: HTTPRequest.maximumBytes + 1), valid + Data("extra".utf8)] {
            guard case .invalid = HTTPRequest.parse(data) else { throw TestFailure(message: "accepted oversized request or extra body") }
        }
        print("PASS: finite waits and strict incremental HTTP framing")
    }

    /// The bodies of the structural edits, as Homeswift's Wingman plugin sends them, and the values actions may write.
    static func structureRequests() throws {
        func parse(_ path: String, _ json: String) throws -> StructureEdit { try StructureEdit.parse(path: path, body: Data(json.utf8)) }
        func refused(_ path: String, _ json: String) -> String? {
            do { _ = try parse(path, json); return nil } catch let error as StructureRequestError { return error.message } catch { return "\(error)" }
        }
        try expect(StructureEdit.paths.count == 13, "every edit path")
        guard case .renameRoom("room-1", "Séjour") = try parse("rooms/rename", #"{"room": "room-1", "name": "  Séjour "}"#) else {
            throw TestFailure(message: "room rename, name trimmed")
        }
        guard case .moveAccessory("acc-1", "Garage") = try parse("accessories/room", #"{"accessory": "acc-1", "room": "Garage"}"#) else {
            throw TestFailure(message: "accessory move")
        }
        guard case .runScene("scene-1") = try parse("scenes/run", #"{"scene": "scene-1"}"#) else { throw TestFailure(message: "scene run") }
        let run = try parse("scenes/run", #"{"scene": "scene-1"}"#)
        try expect(!run.isStructural && run.eventKind == nil, "running a scene is a change, not an edit")
        guard case .sceneActions("scene-1", let actions) = try parse("scenes/actions", #"{"scene": "scene-1", "actions": [{"accessory": "a", "characteristic": "c", "value": 40}]}"#),
              actions.count == 1, actions[0].accessory == "a", (actions[0].value as? NSNumber)?.intValue == 40 else {
            throw TestFailure(message: "scene actions")
        }
        guard case .createScene("home-1", "Nuit", let created) = try parse("scenes/create", #"{"home": "home-1", "name": "Nuit", "actions": []}"#), created.isEmpty else {
            throw TestFailure(message: "scene creation")
        }
        guard case .enableAutomation("auto-1", false) = try parse("automations/enable", #"{"automation": "auto-1", "enabled": false}"#) else {
            throw TestFailure(message: "automation enable")
        }
        guard case .automationTime("auto-1", let clock) = try parse("automations/time", #"{"automation": "auto-1", "time": {"hour": 7, "minute": 30, "weekdays": [7, 1, 1]}}"#),
              clock == StructureTime(hour: 7, minute: 30, weekdays: [1, 7]) else {
            throw TestFailure(message: "clock time, weekdays sorted once each")
        }
        guard case .automationTime(_, let sunset) = try parse("automations/time", #"{"automation": "auto-1", "time": {"significant": "sunset", "offsetMinutes": -15}}"#),
              sunset.json["significant"] as? String == "sunset", sunset.json["offsetMinutes"] as? Int == -15, sunset.json["hour"] == nil else {
            throw TestFailure(message: "sunset time")
        }
        guard case .automationScenes(_, let scenes) = try parse("automations/scenes", #"{"automation": "auto-1", "scenes": ["s1", "s2", "s1"]}"#),
              scenes == ["s1", "s2"] else { throw TestFailure(message: "automation scenes, once each") }
        try expect(try parse("automations/delete", #"{"automation": "auto-1"}"#).eventKind == "automations", "automation edits make automations events")
        try expect(try parse("accessories/room", #"{"accessory": "a", "room": "b"}"#).eventKind == "homes", "room edits make homes events")
        try expect(refused("rooms/rename", "[]") == "expected a JSON object", "a body that is not an object")
        try expect(refused("rooms/rename", #"{"room": "r", "name": "   "}"#) != nil, "an empty name")
        try expect(refused("scenes/actions", #"{"scene": "s", "actions": [{"accessory": "a", "value": 1}]}"#) != nil, "an action without its characteristic")
        try expect(refused("scenes/actions", #"{"scene": "s", "actions": [{"accessory": "a", "characteristic": "c", "value": null}]}"#) != nil, "an action without a value")
        try expect(refused("automations/enable", #"{"automation": "a", "enabled": 1}"#) != nil, "enabled is a boolean")
        try expect(refused("automations/time", #"{"automation": "a", "time": {"hour": 24, "minute": 0}}"#) != nil, "no hour 24")
        try expect(refused("automations/time", #"{"automation": "a", "time": {"hour": 7}}"#) != nil, "a time needs its minute")
        try expect(refused("automations/time", #"{"automation": "a", "time": {"hour": 7, "minute": 0, "weekdays": [0]}}"#) != nil, "weekdays from 1")
        try expect(refused("automations/time", #"{"automation": "a", "time": {"significant": "noon"}}"#) != nil, "only sunrise and sunset")
        try expect(refused("automations/time", #"{"automation": "a", "time": {"significant": "sunrise", "offsetMinutes": 1000}}"#) != nil, "offsets within 12 hours")

        try expect(StructureValue.coerce(true, format: "bool", minimum: nil, maximum: nil) as? Bool == true, "a bool")
        try expect(StructureValue.coerce(NSNumber(value: 1), format: "bool", minimum: nil, maximum: nil) as? Bool == true, "1 as a bool")
        try expect(StructureValue.coerce(40, format: "int", minimum: 0, maximum: 100) as? Int == 40, "an int in range")
        try expect(StructureValue.coerce(140, format: "int", minimum: 0, maximum: 100) == nil, "out of range is refused, not clamped")
        try expect(StructureValue.coerce(4.5, format: "uint8", minimum: nil, maximum: nil) == nil, "a fraction is not an integer")
        try expect(StructureValue.coerce(-1, format: "uint8", minimum: nil, maximum: nil) == nil, "unsigned")
        try expect(StructureValue.coerce(2, format: "uint8", minimum: 0, maximum: 3, validValues: [0, 1]) == nil, "outside the valid values")
        try expect(StructureValue.coerce(true, format: "int", minimum: nil, maximum: nil) == nil, "a bool is not a number")
        try expect(StructureValue.coerce(21.5, format: "float", minimum: 10, maximum: 38) as? Double == 21.5, "a float")
        try expect(StructureValue.coerce("on", format: "float", minimum: nil, maximum: nil) == nil, "a string is not a float")
        try expect(StructureValue.coerce("AQI=", format: "tlv8", minimum: nil, maximum: nil) as? Data == Data([1, 2]), "TLV8 from base64, as /scenes lists it")
        try expect(StructureValue.coerce("not base64", format: "data", minimum: nil, maximum: nil) == nil, "data is base64")
        try expect(StructureValue.same(Data([1]), Data([1])) && !StructureValue.same(Data([1]), "AQ=="), "data compares as data")
        try expect(sameRoomName("Entrée", "entree") && !sameRoomName("Entrée", "Entry"), "room names compare without case or accents")
        print("PASS: structure request bodies, times and action values")
    }

    /// The synthetic home: labelled, writable like a real one, with the same security refusals.
    @MainActor static func demo() async throws {
        let demo = DemoStore()
        var changes = 0
        var events = 0
        demo.onChange = { changes += 1 }
        demo.onEvent = { events += 1 }
        let home = demo.homesJSON()[0]
        try expect(home["name"] as? String == "Demo Home (Synthetic)" && home["demo"] as? Bool == true, "demo home is labelled")
        try expect(demo.statusJSON()["demo"] as? Bool == true, "status reports demo mode")
        let accessories = home["accessories"] as? [[String: Any]] ?? []
        try expect(accessories.count == 7 && accessories.allSatisfy { ($0["name"] as? String ?? "").hasPrefix("Demo ") }, "every demo accessory is named Demo")
        let off = await demo.write(accessory: "Demo Floor Lamp", characteristic: "Power State", value: false, allowSecurity: false)
        try expect(off["written"] as? Bool == false && demo.lastSeq == 1 && events == 1 && changes >= 1, "write changes the value and records an event")
        try expect(demo.eventsJSON(since: 0).first?["accessory"] as? String == "Demo Floor Lamp", "event is served after since")
        try expect(demo.panelHomes().description.contains("Lightbulb · Off"), "panel shows the written state")
        let dim = await demo.write(accessory: "Demo Floor Lamp", characteristic: DemoStore.brightness, value: 250, allowSecurity: false)
        try expect(dim["written"] as? Int == 100, "brightness is clamped to its range")
        let lock = await demo.write(accessory: "Demo Front Door Lock", characteristic: "Lock Mechanism Target State", value: 0, allowSecurity: false)
        try expect((lock["error"] as? String ?? "").contains("security control") && demo.lastSeq == 2, "lock write is refused without an event")
        let garage = await demo.write(accessory: "Demo Garage Door", characteristic: DemoStore.targetDoorState, value: 0, allowSecurity: false)
        try expect((garage["error"] as? String ?? "").contains("security control"), "garage write is refused")
        let unlocked = await demo.write(accessory: "Demo Front Door Lock", characteristic: "Lock Mechanism Target State", value: 0, allowSecurity: true)
        try expect(unlocked["error"] == nil && demo.lastSeq == 3, "lock write is accepted once security writes are allowed")
        let sensor = await demo.write(accessory: "Demo Motion Sensor", characteristic: "Motion Detected", value: true, allowSecurity: false)
        try expect((sensor["error"] as? String ?? "").contains("not responding"), "unreachable accessory refuses writes")
        let wrong = await demo.write(accessory: "Demo Floor Lamp", characteristic: "Power State", value: "on", allowSecurity: false)
        try expect(wrong["error"] != nil, "mistyped value is refused")
        try expect((await demo.write(accessory: "Nope", characteristic: "Power State", value: true, allowSecurity: false))["error"] as? String == "no accessory Nope", "unknown accessory")
        let read = await demo.readAll()
        try expect(read["succeeded"] as? Int ?? 0 > 0 && (read["failures"] as? [String: Int])?.values.reduce(0, +) == 1, "read reports the unreachable sensor")
        var enabled = false
        let live = FakeStore()
        let served = DemoSwitchStore(live: live, demo: demo) { enabled }
        try expect(served.homeIdentifiers == ["fixture-home"], "live homes while demo mode is off")
        enabled = true
        try expect(served.homeIdentifiers == [DemoStore.homeID] && served.lastSeq == demo.lastSeq, "demo home while demo mode is on")
        _ = await served.write(accessory: "Demo Ceiling Light", characteristic: "Power State", value: true, allowSecurity: false)
        try expect(live.writes == 0 && demo.lastSeq == 4, "demo writes never reach the live store")
        print("PASS: demo home labelling, writes, events, security refusals and store switching")
    }

    /// The demo home's rooms, scenes and automations take every edit a bridge sends, with HomeKit's checks.
    @MainActor static func demoStructure() async throws {
        let demo = DemoStore()
        func kinds() -> [String] { demo.eventsJSON(since: 0).compactMap { $0["kind"] as? String } }
        func edit(_ path: String, _ json: String, security: Bool = false) async throws -> StoreAnswer {
            await demo.edit(try StructureEdit.parse(path: path, body: Data(json.utf8)), allowSecurity: security)
        }
        let lamp = "D3E0DE00-0000-4000-8000-000000000101", lampPower = "D3E0DE00-0000-4000-8000-000000001011"
        let lampLevel = "D3E0DE00-0000-4000-8000-000000001012", lockTarget = "D3E0DE00-0000-4000-8000-000000001062"
        let home = demo.homesJSON()[0]
        try expect(home["editable"] as? Bool == true && home["id"] as? String == DemoStore.homeID, "the demo home can be edited")

        // Rooms
        let living = (home["rooms"] as? [[String: Any]] ?? []).first { $0["name"] as? String == "Living Room" }?["id"] as? String ?? ""
        try expect(try await edit("rooms/rename", #"{"room": "\#(living)", "name": "Lounge"}"#).status.hasPrefix("200"), "room renamed")
        let renamed = demo.homesJSON()[0]
        try expect((renamed["rooms"] as? [[String: Any]])?.first { $0["id"] as? String == living }?["name"] as? String == "Lounge", "the room keeps its id")
        try expect((renamed["accessories"] as? [[String: Any]])?.first { $0["id"] as? String == lamp }?["room"] as? String == "Lounge", "its accessories follow")
        try expect(kinds() == ["homes"], "a homes event")
        let moved = try await edit("accessories/room", #"{"accessory": "\#(lamp)", "room": "kitchen"}"#)
        try expect(moved.body["room"] as? String == "Kitchen" && moved.body["added"] as? Bool == false, "moved to the room of that name, case aside")
        let garage = try await edit("accessories/room", #"{"accessory": "\#(lamp)", "room": "Garage"}"#)
        try expect(garage.body["added"] as? Bool == true && demo.rooms.contains { $0.name == "Garage" }, "a room the home lacks is added")
        try expect(try await edit("accessories/room", #"{"accessory": "nope", "room": "Garage"}"#).status.hasPrefix("404"), "no such accessory")
        try expect(try await edit("rooms/rename", #"{"room": "\#(living)", "name": "kitchen"}"#).status.hasPrefix("422"), "no two rooms of one name")
        let readded = try await edit("accessories/room", #"{"accessory": "\#(lamp)", "room": "Living Room"}"#)
        try expect(readded.body["added"] as? Bool == true && readded.body["roomID"] as? String != living && Set(demo.rooms.map(\.id)).count == demo.rooms.count,
                   "a room added under a renamed room's first name gets its own id")
        try expect(try await edit("rooms/rename", #"{"room": "nope", "name": "X"}"#).status.hasPrefix("404"), "no such room")

        // Scenes, in the shape the plugin decodes
        let scenes = demo.scenesJSON()
        let evening = scenes.first { $0["id"] as? String == DemoStore.sceneEvening } ?? [:]
        try expect(evening["home"] as? String == DemoStore.homeID && evening["builtIn"] as? Bool == false && evening["unsupported"] as? Int == 0, "a user scene")
        try expect((evening["actions"] as? [[String: Any]])?.first?["type"] as? String == DemoStore.powerState, "actions carry their type")
        try expect(scenes.allSatisfy { ($0["name"] as? String ?? "").contains("Demo") }, "every demo scene is labelled")
        try expect(scenes.first { $0["id"] as? String == DemoStore.sceneNight }?["builtIn"] as? Bool == true, "built-in scenes say so")
        let before = demo.lastSeq
        try expect(try await edit("scenes/run", #"{"scene": "\#(DemoStore.sceneEvening)"}"#).status.hasPrefix("200"), "scene run")
        try expect(demo.lastSeq == before + 3 && demo.panelHomes().description.contains("On, 40%"), "running writes its values, with their events")
        let leave = try await edit("scenes/run", #"{"scene": "\#(DemoStore.sceneLeave)"}"#)
        try expect(leave.status.hasPrefix("403") && (leave.body["error"] as? String ?? "").contains("locks and doors"), "a scene that locks a door needs the security setting")
        try expect(try await edit("scenes/run", #"{"scene": "\#(DemoStore.sceneLeave)"}"#, security: true).status.hasPrefix("200"), "and runs with it")
        // "Keep the lights as they are" sends the scene's lock action back unchanged: no security setting needed for that.
        let lock = "D3E0DE00-0000-4000-8000-000000000106"
        let keptLock = try await edit("scenes/actions", #"{"scene": "\#(DemoStore.sceneLeave)", "actions": [{"accessory": "\#(lamp)", "characteristic": "\#(lampPower)", "value": true}, {"accessory": "\#(lock)", "characteristic": "\#(lockTarget)", "value": 1}]}"#)
        try expect(keptLock.status.hasPrefix("200"), "an unchanged lock action is kept without the security setting")
        let changedLock = try await edit("scenes/actions", #"{"scene": "\#(DemoStore.sceneLeave)", "actions": [{"accessory": "\#(lock)", "characteristic": "\#(lockTarget)", "value": 0}]}"#)
        try expect(changedLock.status.hasPrefix("403"), "a changed one needs it")
        try expect(try await edit("scenes/rename", #"{"scene": "\#(DemoStore.sceneEvening)", "name": "Demo Dusk (Synthetic)"}"#).status.hasPrefix("200"), "scene renamed")
        try expect(try await edit("scenes/rename", #"{"scene": "\#(DemoStore.sceneNight)", "name": "X"}"#).status.hasPrefix("422"), "a built-in scene keeps its name")
        try expect(try await edit("scenes/delete", #"{"scene": "\#(DemoStore.sceneNight)"}"#).status.hasPrefix("422"), "and is not deleted")
        let replaced = try await edit("scenes/actions", #"{"scene": "\#(DemoStore.sceneNight)", "actions": [{"accessory": "\#(lamp)", "characteristic": "\#(lampLevel)", "value": 10}, {"accessory": "\#(lamp)", "characteristic": "Power State", "value": true}]}"#)
        try expect(replaced.status.hasPrefix("200"), "a built-in scene's actions change")
        let night = demo.scenesJSON().first { $0["id"] as? String == DemoStore.sceneNight }?["actions"] as? [[String: Any]] ?? []
        try expect(night.count == 2 && night.contains { $0["characteristic"] as? String == lampPower && $0["value"] as? Bool == true }, "replaced, by characteristic id")
        for (body, status, what) in [
            (#"[{"accessory": "nope", "characteristic": "Power State", "value": true}]"#, "400", "an accessory the home lacks"),
            (#"[{"accessory": "\#(lamp)", "characteristic": "\#(lampLevel)", "value": 140}]"#, "400", "a value out of range"),
            (#"[{"accessory": "\#(lamp)", "characteristic": "\#(lampPower)", "value": true}, {"accessory": "\#(lamp)", "characteristic": "Power State", "value": false}]"#, "400", "a characteristic set twice"),
            (#"[{"accessory": "D3E0DE00-0000-4000-8000-000000000105", "characteristic": "Motion Detected", "value": true}]"#, "400", "a read-only characteristic"),
            (#"[{"accessory": "D3E0DE00-0000-4000-8000-000000000106", "characteristic": "\#(lockTarget)", "value": 0}]"#, "403", "a lock without the security setting"),
        ] {
            let answer = try await edit("scenes/actions", #"{"scene": "\#(DemoStore.sceneEvening)", "actions": \#(body)}"#)
            try expect(answer.status.hasPrefix(status), "refused: \(what)")
        }
        try expect((demo.scenesJSON().first { $0["id"] as? String == DemoStore.sceneEvening }?["actions"] as? [Any])?.count == 3, "a refusal changes nothing")
        let created = try await edit("scenes/create", #"{"home": "\#(DemoStore.homeID)", "name": "Demo Reading (Synthetic)", "actions": [{"accessory": "\#(lamp)", "characteristic": "\#(lampPower)", "value": true}]}"#)
        let newID = created.body["id"] as? String ?? ""
        try expect(created.status.hasPrefix("200") && demo.scenes.contains { $0.id == newID && $0.name == "Demo Reading (Synthetic)" }, "scene created, answering its id")
        try expect(try await edit("scenes/create", #"{"home": "nope", "name": "X", "actions": []}"#).status.hasPrefix("404"), "no such home")

        // Automations
        let sunset = demo.automationsJSON().first { $0["id"] as? String == DemoStore.automationSunset } ?? [:]
        let trigger = sunset["trigger"] as? [String: Any] ?? [:]
        try expect(trigger["kind"] as? String == "time" && (trigger["time"] as? [String: Any])?["significant"] as? String == "sunset", "a sunset trigger")
        try expect(sunset["scenes"] as? [String] == [DemoStore.sceneEvening] && (sunset["conditions"] as? [[String: Any]])?.count == 1, "its scenes and condition")
        let motion = demo.automationsJSON().first { $0["id"] as? String == DemoStore.automationMotion } ?? [:]
        try expect((motion["trigger"] as? [String: Any])?["kind"] as? String == "event" && (motion["endEvents"] as? [[String: Any]])?.first?["seconds"] as? Int == 600,
                   "an event trigger with its end")
        let target = DemoStore.automationSunset
        for (path, body) in [
            ("automations/enable", #"{"automation": "\#(target)", "enabled": false}"#),
            ("automations/rename", #"{"automation": "\#(target)", "name": "Demo Morning (Synthetic)"}"#),
            ("automations/time", #"{"automation": "\#(target)", "time": {"hour": 7, "minute": 30, "weekdays": [1, 7]}}"#),
            ("automations/scenes", #"{"automation": "\#(target)", "scenes": ["\#(newID)"]}"#),
            ("automations/actions", #"{"automation": "\#(target)", "actions": [{"accessory": "\#(lamp)", "characteristic": "\#(lampLevel)", "value": 50}]}"#),
        ] {
            let answer = try await edit(path, body)
            try expect(answer.status.hasPrefix("200"), "\(path): \(answer.body)")
        }
        let morning = demo.automationsJSON().first { $0["id"] as? String == target } ?? [:]
        try expect(morning["enabled"] as? Bool == false && morning["name"] as? String == "Demo Morning (Synthetic)", "enabled and name changed")
        let time = (morning["trigger"] as? [String: Any])?["time"] as? [String: Any] ?? [:]
        try expect(time["hour"] as? Int == 7 && time["minute"] as? Int == 30 && time["weekdays"] as? [Int] == [1, 7] && time["significant"] == nil, "time changed")
        try expect(morning["scenes"] as? [String] == [newID] && (morning["actions"] as? [[String: Any]])?.first?["value"] as? Int == 50, "scenes and actions changed")
        try expect(try await edit("automations/time", #"{"automation": "\#(DemoStore.automationMotion)", "time": {"hour": 7, "minute": 0}}"#).status.hasPrefix("422"),
                   "an automation started by events keeps its events")
        try expect(try await edit("automations/scenes", #"{"automation": "\#(target)", "scenes": ["nope"]}"#).status.hasPrefix("404"), "a scene the home lacks")
        try expect(try await edit("automations/scenes", #"{"automation": "\#(target)", "scenes": ["\#(DemoStore.sceneLeave)"]}"#).status.hasPrefix("403"),
                   "an automation runs a scene that locks a door only with the security setting")
        try expect(try await edit("scenes/delete", #"{"scene": "\#(newID)"}"#).status.hasPrefix("200") && demo.automationsJSON().first { $0["id"] as? String == target }?["scenes"] as? [String] == [],
                   "a deleted scene leaves the automations that ran it")
        try expect(try await edit("automations/delete", #"{"automation": "\#(target)"}"#).status.hasPrefix("200") && demo.automations.count == 1, "automation deleted")
        try expect(try await edit("automations/enable", #"{"automation": "\#(target)", "enabled": true}"#).status.hasPrefix("404"), "no such automation")

        demo.settingsChanged()
        let seen = Set(kinds())
        try expect(seen == ["homes", "value", "scenes", "automations", "settings"], "every kind of event: \(seen)")
        try expect(demo.eventsJSON(since: 0).filter { $0["kind"] as? String != "value" }.allSatisfy { $0["characteristicID"] == nil }, "structure events name no characteristic")
        print("PASS: demo rooms, scenes and automations: listing, edits, refusals and events")
    }

    @MainActor static func pairing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var time = Date(timeIntervalSince1970: 1_800_000_000)
        var fail = true
        let pairing = Pairing(directory: root, now: { time }, writeFile: { data, url in
            if fail { throw POSIXError(.ENOSPC) }
            try Pairing.write(data, to: url)
        })
        pairing.openPairing()
        let code = pairing.open!.code
        guard case .storageFailure = pairing.pair(code: code, name: "Fixture") else { throw TestFailure(message: "pairing claimed success on failed write") }
        try expect(pairing.bridges.isEmpty && pairing.persistenceError != nil && pairing.open != nil, "failed pairing state")
        fail = false
        guard case let .paired(token, bridge) = pairing.pair(code: code, name: "Fixture") else { throw TestFailure(message: "pair retry") }
        try expect(Pairing(directory: root).bridge(token: token) != nil, "new pairing durable")
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("bridges.json").path)
        try expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "owner-only file")
        _ = pairing.bridge(token: token)
        for _ in 0..<6 { time += 30; _ = pairing.bridge(token: token) }
        try expect(Pairing(directory: root).bridges.first?.lastSeenAt == time, "polling every 30s persists every minute")
        var revoked = false
        pairing.onRemove = { _ in revoked = true }
        fail = true
        try expect(!pairing.remove(bridge.id), "failed revocation returns false")
        try expect(pairing.contains(bridge.id) && !revoked && pairing.persistenceError != nil, "failed revocation stays visible")
        try expect(Pairing(directory: root).contains(bridge.id), "disk and memory agree after failed revocation")
        fail = false
        try expect(pairing.remove(bridge.id) && revoked && pairing.persistenceError == nil, "revocation retry succeeds")
        try expect(Pairing(directory: root).bridge(token: token) == nil, "revocation survives restart")
        pairing.openPairing()
        for index in 1...5 {
            guard case .wrongCode(let closed) = pairing.pair(code: "wrong", name: "Fixture"), closed == (index == 5) else { throw TestFailure(message: "pairing attempt limit") }
        }
        pairing.openPairing(); time += 601
        guard case .notOpen = pairing.pair(code: pairing.open!.code, name: "Fixture") else { throw TestFailure(message: "expired code accepted") }
        print("PASS: storage failures, retry, permissions, revocation, expiry, attempt limit and periodic saves")
    }

    /// `/info` says Wingman serves the structure and whether edits are on; the reads always answer, edits only while
    /// the owner allows them, and the server refuses a bad body before the store sees it.
    @MainActor static func structureRoutes(port: UInt16, token: String, store: FakeStore, allow: (Bool) -> Void,
                                           allowChanges: (Bool) -> Void) async throws {
        func request(_ method: String, _ path: String, _ body: String = "") async throws -> (status: String, json: [String: Any]) {
            let client = TestClient(port: port, request: "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)")
            try await eventually("\(method) \(path) response") { client.ended }
            let parts = client.text.components(separatedBy: "\r\n\r\n")
            let status = parts.first?.components(separatedBy: "\r\n").first ?? ""
            let json = (try? JSONSerialization.jsonObject(with: Data((parts.dropFirst().first ?? "").utf8))) as? [String: Any] ?? [:]
            return (status, json)
        }
        let info = try await request("GET", "/info")
        try expect(info.json["features"] as? [String] == ["structure"] && info.json["structure"] as? Bool == false && info.json["api"] as? String == "1",
                   "info lists the structure feature, edits off, the same API version")
        let scenes = try await request("GET", "/scenes")
        try expect((scenes.json["scenes"] as? [[String: Any]])?.first?["id"] as? String == "scene-1", "scenes are read with edits off")
        let automations = try await request("GET", "/automations")
        try expect((automations.json["automations"] as? [[String: Any]])?.count == 1, "automations are read with edits off")
        let off = try await request("POST", "/rooms/rename", #"{"room": "room-1", "name": "Séjour"}"#)
        try expect(off.status.contains("403") && off.json["error"] as? String == "structural edits are turned off in Wingman's settings" && store.edits.isEmpty,
                   "edits are refused while the owner has not allowed them")
        let ran = try await request("POST", "/scenes/run", #"{"scene": "scene-1"}"#)
        try expect(ran.status.contains("200") && store.edits.count == 1, "running a scene needs only changes")
        allow(true)
        let on = try await request("GET", "/info")
        try expect(on.json["structure"] as? Bool == true, "info says edits are on")
        let renamed = try await request("POST", "/rooms/rename", #"{"room": "room-1", "name": "Séjour"}"#)
        try expect(renamed.status.contains("200") && store.edits.count == 2 && renamed.json["security"] as? Bool == false, "the edit reaches the store")
        guard case .renameRoom("room-1", "Séjour") = store.edits[1] else { throw TestFailure(message: "the store gets the parsed edit") }
        let bad = try await request("POST", "/automations/time", #"{"automation": "a", "time": {"hour": 99, "minute": 0}}"#)
        try expect(bad.status.contains("400") && store.edits.count == 2, "a bad body is refused before the store")
        let unknown = try await request("POST", "/scenes/explode", "{}")
        try expect(unknown.status.contains("404"), "an unknown path")
        // Read-only: an edit would change what scenes and automations write, so it is refused too.
        allowChanges(false)
        let readOnly = try await request("POST", "/rooms/rename", #"{"room": "room-1", "name": "Séjour"}"#)
        try expect(readOnly.status.contains("403") && readOnly.json["error"] as? String == "changes are turned off in Wingman's settings" && store.edits.count == 2,
                   "a read-only Wingman refuses edits")
        try expect(try await request("GET", "/info").json["structure"] as? Bool == false, "info says edits are off while changes are")
        allowChanges(true)
        allow(false)
        print("PASS: structure routes, the owner's setting and request validation over loopback")
    }

    @MainActor static func network() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pairing = Pairing(directory: root)
        pairing.openPairing()
        guard case let .paired(token, bridge) = pairing.pair(code: pairing.open!.code, name: "Fixture") else { throw TestFailure(message: "fixture pairing") }
        let store = FakeStore()
        var config = LocalServer.Configuration(port: 0, advertise: false)
        var security = false
        var structure = false
        var changes = true
        let server = LocalServer(store: store, pairing: pairing, fingerprint: "fixture", configuration: { config }, changesAllowed: { changes },
                                 securityAllowed: { security }, structureAllowed: { structure },
                                 limits: .init(connections: 3, requestSeconds: 0.5, responseSeconds: 2), makeParameters: {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            return parameters
        })
        defer { server.stop() }
        server.start()
        try await eventually("listener ready") { server.state == "listening" }
        let port = server.boundPort!
        func request(_ path: String, authenticated: Bool = true) -> TestClient {
            TestClient(port: port, request: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\(authenticated ? "Authorization: Bearer \(token)\r\n" : "")\r\n")
        }
        let unauth = request("/homes", authenticated: false)
        try await eventually("unauthorized response") { unauth.ended }
        try expect(unauth.text.contains("401 Unauthorized"), "authentication enforced")
        for value in ["nan", "inf", "-inf"] {
            let bad = request("/events?since=9223372036854775807&wait=\(value)")
            try await eventually("invalid wait response") { bad.ended }
            try expect(bad.text.contains("400 Bad Request"), "non-finite query rejected on wire")
        }
        let good = request("/info", authenticated: false)
        try await eventually("still alive after bad waits") { good.ended }
        try expect(good.text.contains("200 OK"), "server still serves")
        func write() -> TestClient {
            let body = #"{"accessory":"lock","characteristic":"Lock Mechanism Target State","value":0}"#
            return TestClient(port: port, request: "POST /write HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)")
        }
        let guarded = write()
        try await eventually("write response") { guarded.ended }
        try expect(store.writes == 1 && store.securityWrites == 0, "security writes are off by default")
        security = true
        let allowed = write()
        try await eventually("security write response") { allowed.ended }
        try expect(store.writes == 2 && store.securityWrites == 1, "the setting reaches the store")
        security = false
        try await structureRoutes(port: port, token: token, store: store, allow: { structure = $0 }, allowChanges: { changes = $0 })
        let oversized = TestClient(port: port, request: "POST /pair HTTP/1.1\r\nContent-Length: 999999\r\n\r\n")
        try await eventually("oversized request rejected") { oversized.ended }
        try expect(oversized.text.contains("413"), "size rejected before body upload")
        let slow = TestClient(port: port, request: "GET /info HTTP/1.1\r\n")
        try await eventually("partial request connected") { server.activeConnections == 1 }
        for _ in 0..<4 { try await Task.sleep(for: .milliseconds(100)); slow.send("x") }
        try await eventually("absolute request deadline") { server.activeConnections == 0 }
        let idle = (0..<3).map { _ in TestClient(port: port) }
        try await eventually("connection limit filled") { server.activeConnections == 3 }
        let excess = TestClient(port: port)
        try await eventually("excess connection refused") { excess.ended }
        try expect(server.activeConnections <= 3, "connection cap")
        idle.forEach { $0.close() }
        try await eventually("idle cleanup") { server.activeConnections == 0 }
        let disconnected = request("/events?since=0&wait=30")
        try await eventually("poll pending") { server.pendingPolls == 1 }
        disconnected.close()
        // EOF releases the poll without waiting for the response deadline.
        try await eventually("disconnected poll cleanup", seconds: 1) { server.pendingPolls == 0 }
        let poll = request("/events?since=0&wait=30")
        try await eventually("revocation poll pending") { server.pendingPolls == 1 }
        try expect(pairing.remove(bridge.id), "remove fixture bridge")
        store.lastSeq = 1
        server.eventsArrived()
        try await eventually("revoked poll closed") { poll.ended }
        try expect(!poll.text.contains("private-event") && server.pendingPolls == 0, "no data after revocation")
        let revoked = request("/homes")
        try await eventually("revoked request response") { revoked.ended }
        try expect(revoked.text.contains("401"), "revoked token denied")
        server.stop()
        // Occupy a real port, fail a bind, free it and retry the SAME configuration.
        let blocker = try NWListener(using: .tcp, on: .any)
        blocker.newConnectionHandler = { $0.cancel() }
        var blockerReady = false
        blocker.stateUpdateHandler = { state in MainActor.assumeIsolated { if case .ready = state { blockerReady = true } } }
        blocker.start(queue: .main)
        try await eventually("blocker port") { blockerReady }
        config.port = blocker.port!.rawValue
        server.start()
        try await eventually("bind failure") { server.state.hasPrefix("waiting:") || server.state.hasPrefix("failed:") || server.state.hasPrefix("cannot listen") }
        blocker.cancel()
        try await Task.sleep(for: .milliseconds(100))
        server.applySettings()
        try await eventually("same-port retry recovers") { server.state == "listening" }
        let recovered = TestClient(port: server.boundPort!, request: "GET /info HTTP/1.1\r\n\r\n")
        try await eventually("recovered API") { recovered.ended }
        try expect(recovered.text.contains("200 OK"), "recovered listener responds")
        print("PASS: real loopback HTTP requests, finite waits, deadlines, limits, revocation and bind retry")
    }
}
