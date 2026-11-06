import CryptoKit
import Foundation
import Network

@MainActor
protocol WingmanStore: AnyObject {
    var homeIdentifiers: [String] { get }
    var lastSeq: Int { get }
    var firstSeq: Int { get }
    func statusJSON() -> [String: Any]
    func homesJSON() -> [[String: Any]]
    func eventsJSON(since: Int?) -> [[String: Any]]
    func readAll() async -> [String: Any]
    /// Lock, garage door and alarm targets are refused unless `allowSecurity`.
    func write(accessory: String, characteristic: String, value: Any, allowSecurity: Bool) async -> [String: Any]
    /// Every home's scenes (action sets other than automations' own) and automations (triggers).
    func scenesJSON() -> [[String: Any]]
    func automationsJSON() -> [[String: Any]]
    /// Applies a structural edit or runs a scene; the server has checked the owner's settings. A scene, or actions,
    /// that operate a lock, garage door or alarm are refused unless `allowSecurity`.
    func edit(_ edit: StructureEdit, allowSecurity: Bool) async -> StoreAnswer
    /// The owner changed a setting bridges see in `/info`: a "settings" event.
    func settingsChanged()
    /// The name of an accessory, service, room, zone, group, scene or automation by id, for the panel's Activity.
    func name(of id: String) -> String?
}

extension WingmanStore {
    func name(of id: String) -> String? { nil }
}

/// A JSON API over TLS on every interface, advertised over Bonjour as `_homeswift-wingman._tcp`, for a Homeswift
/// plugin to find, pair with and read:
///
/// - `GET /info` (open): Wingman's id, version, certificate fingerprint and whether pairing is open.
/// - `POST /pair` (open): `{"code": "123456", "name": "<the bridge>"}` → `{"token", "bridge", "wingman", "fingerprint"}`.
/// - With `Authorization: Bearer <token>`: `GET /status`, `GET /homes`, `GET /events` (the latest value changes;
///   `?since=<seq>&wait=<seconds>` waits up to 30 s for those after `seq`, oldest first, with `last` and `first`, the
///   oldest kept: a `since` before `first - 1` missed events),
///   `POST /read` (reads every value), `POST /write` (`{"accessory": id or name, "characteristic": its id, HAP UUID or
///   description, "value": …}`; lock, garage door and alarm targets only while **Let bridges operate locks and
///   doors** is on).
/// - Apple Home's structure (`/info`'s `"features": ["structure"]`): `GET /scenes`, `GET /automations`, `POST
///   /scenes/run` (needs **Let bridges change accessories**) and the edits in `StructureEdit.paths` (need that and
///   **Let bridges edit rooms, scenes and automations**; `"structure"` in `/info` says whether both are on).
/// - The Home Link (`"home-link"` in `/info`'s features): `/homes` gives each home its `defaultRoom`, `serviceGroups`,
///   zones' `id` and `roomIDs` and accessories' `roomID`; the edits `rooms/create`, `rooms/delete`, `accessories/room`
///   with a `roomID`, `zones/…` and `groups/…`, by HomeKit id, are structural like the others.
///
/// The TXT record carries `v` (the API version), `id` (Wingman's) and `home` (the start of the SHA-256 of the
/// homes' identifiers), so a bridge that finds two Wingmen for the same home can keep one.
@MainActor
final class LocalServer {
    nonisolated static let defaultPort: UInt16 = 8619
    static let serviceType = "_homeswift-wingman._tcp"
    static let apiVersion = "1"

    private let store: any WingmanStore
    private let pairing: Pairing
    private let makeParameters: () -> NWParameters
    private let configuration: () -> Configuration
    private let changesAllowed: () -> Bool
    private let securityAllowed: () -> Bool
    private let structureAllowed: () -> Bool
    struct Configuration: Equatable { var port: UInt16; var advertise: Bool }
    struct Limits {
        var connections = 64
        var requestSeconds: Double = 10
        var responseSeconds: Double = 90
        /// First wait before the watchdog restarts an unhealthy listener.
        var restartSeconds: Double = 10
    }
    private let limits: Limits
    private final class Client {
        let connection: NWConnection
        var bridgeID: String?
        var deadline: Task<Void, Never>?
        var poll: Task<Void, Never>?
        var work: Task<Void, Never>?
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private var clients: [ObjectIdentifier: Client] = [:]
    var activeConnections: Int { clients.count }
    var pendingPolls: Int { waiting.count }
    var boundPort: UInt16? { listener?.port?.rawValue }
    private var generation = UUID()
    private(set) var port: UInt16
    private var advertising = true
    private var listener: NWListener?
    private var advertisedHome: String?
    /// Local Network privacy blocks the Bonjour advertisement: the listener fails with PolicyDenied, or stays ready
    /// with no registration. Kept across restarts so the panel does not flicker; cleared once Bonjour adds the service.
    private(set) var advertisementMissing = false
    private var advertised = false
    /// Restarts a listener that failed, or that Bonjour has not confirmed: a failed NWListener never recovers, and
    /// setting the service again on a blocked one does not register it once access is allowed.
    private var watchdog: DispatchWorkItem?
    /// Doubles while the listener stays unhealthy, back to `limits.restartSeconds` once it is healthy.
    private lazy var restartDelay = limits.restartSeconds
    /// `GET /events?since=&wait=` requests held until a value changes or their wait ends.
    private var waiting: [(id: UUID, since: Int, connection: NWConnection)] = []
    private(set) var state = "starting"
    var onChange: (() -> Void)?
    /// What paired bridges asked for, for the panel.
    let activity: ActivityFeed
    /// The certificate's SHA-256 (lowercase hex), for the menu bar panel.
    let fingerprint: String

    convenience init(store: any WingmanStore, pairing: Pairing, identity: Identity) {
        self.init(store: store, pairing: pairing, fingerprint: identity.fingerprint, activity: ActivityFeed(file: ActivityFeed.appFile),
                  configuration: { Configuration(port: Settings.port, advertise: Settings.advertise) },
                  changesAllowed: { Settings.allowChanges }, securityAllowed: { Settings.allowSecurity },
                  structureAllowed: { Settings.allowStructure }, makeParameters: {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity.identity)!)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            return NWParameters(tls: tls)
        })
    }

    /// Dependency injection keeps network tests on loopback without HomeKit, defaults or Keychain access.
    init(store: any WingmanStore, pairing: Pairing, fingerprint: String, activity: ActivityFeed = ActivityFeed(),
         configuration: @escaping () -> Configuration, changesAllowed: @escaping () -> Bool,
         securityAllowed: @escaping () -> Bool = { false }, structureAllowed: @escaping () -> Bool = { false },
         limits: Limits = Limits(), makeParameters: @escaping () -> NWParameters) {
        self.store = store
        self.pairing = pairing
        self.fingerprint = fingerprint
        self.activity = activity
        self.configuration = configuration
        self.changesAllowed = changesAllowed
        self.securityAllowed = securityAllowed
        self.structureAllowed = structureAllowed
        self.limits = limits
        self.makeParameters = makeParameters
        port = configuration().port
        pairing.onRemove = { [weak self] id in self?.revoke(id) }
    }

    /// Starts again when the port or Bonjour setting changed.
    func applySettings() {
        let desired = configuration()
        guard desired != Configuration(port: port, advertise: advertising) || state != "listening" else { return }
        start()
    }

    /// `publishing: false` keeps the panel on its last state through a restart the watchdog makes.
    func start(publishing: Bool = true) {
        let previous = state
        stop()
        let desired = configuration()
        port = desired.port
        advertising = desired.advertise
        // Kept across restarts so the panel does not flicker; cleared when Bonjour adds the service.
        if !advertising { advertisementMissing = false }
        if publishing {
            state = "starting"
            onChange?()
        } else {
            state = previous
        }
        let currentGeneration = generation
        let parameters = makeParameters()
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            if advertising { listener.service = service() }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    guard let self, self.generation == currentGeneration else { connection.cancel(); return }
                    self.accept(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, self.generation == currentGeneration else { return }
                    switch state {
                    case .ready:
                        self.state = "listening"
                        if self.advertising && !self.advertised { self.arm(currentGeneration) } else { self.healthy() }
                    case .cancelled: return
                    case .failed(let error):
                        NSLog("Wingman: listener failed: \(error)")
                        self.state = "failed: \(error)"
                        // Other DNS errors such as ServiceNotRunning can follow the block; a bind error is its own story.
                        if Self.blocksBonjour(error) { self.advertisementMissing = true }
                        else if case .dns = error {} else { self.advertisementMissing = false }
                        self.arm(currentGeneration)
                    case .waiting(let error):
                        self.state = "waiting: \(error)"
                        self.arm(currentGeneration)
                    default: break
                    }
                    self.onChange?()
                }
            }
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                MainActor.assumeIsolated {
                    guard let self, self.generation == currentGeneration else { return }
                    switch change {
                    case .add(let endpoint):
                        NSLog("Wingman: advertised \(endpoint)")
                        self.advertised = true
                        if self.state == "listening" { self.healthy() }
                    case .remove:
                        // Bonjour dropped it (mDNSResponder restarted, or the homes changed and it is re-adding).
                        self.advertised = false
                        self.arm(currentGeneration)
                    @unknown default: break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            NSLog("Wingman: serving on https://*:\(port), certificate SHA-256 \(fingerprint)")
        } catch {
            state = "cannot listen on \(port): \(error)"
            NSLog("Wingman: cannot listen on \(port): \(error)")
            advertisementMissing = false
            arm(currentGeneration)
            onChange?()
        }
    }

    /// PolicyDenied: Local Network privacy refused the advertisement. ServiceNotRunning (-65563) also follows a
    /// mDNSResponder restart after sleep, so it alone does not name the setting.
    nonisolated static func blocksBonjour(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == -65570 }
        return false
    }

    private func healthy() {
        watchdog?.cancel()
        restartDelay = limits.restartSeconds
        if advertisementMissing { advertisementMissing = false; onChange?() }
    }

    private func arm(_ currentGeneration: UUID) {
        watchdog?.cancel()
        let delay = restartDelay
        let check = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == currentGeneration else { return }
                let serving = self.state == "listening" && !self.clients.isEmpty
                if self.state == "listening", !self.advertisementMissing { self.advertisementMissing = true; self.onChange?() }
                // Bridges connected by address are served: drop them for the advertisement only every 5 minutes.
                let cap: Double = serving ? 300 : 60
                self.restartDelay = min(delay * 2, cap)
                if serving, delay < cap { self.arm(currentGeneration); return }
                NSLog("Wingman: \(self.state == "listening" ? "not advertised" : self.state) after \(Int(delay)) s, restarting the listener")
                self.start(publishing: false)
            }
        }
        watchdog = check
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: check)
    }

    /// Advertises the homes again when they change (they load after the listener starts).
    func homesChanged() {
        guard let listener, advertising, homeHash != advertisedHome else { return }
        listener.service = service()
    }

    private var homeHash: String {
        let ids = store.homeIdentifiers.sorted().joined(separator: ",")
        guard !ids.isEmpty else { return "" }
        return String(SHA256.hash(data: Data(ids.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    private func service() -> NWListener.Service {
        advertisedHome = homeHash
        var txt = NWTXTRecord()
        txt["v"] = Self.apiVersion
        txt["id"] = pairing.wingmanID
        if let advertisedHome, !advertisedHome.isEmpty { txt["home"] = advertisedHome }
        return NWListener.Service(type: Self.serviceType, txtRecord: txt)
    }

    func stop() {
        generation = UUID()
        watchdog?.cancel()
        watchdog = nil
        advertised = false
        listener?.cancel()
        listener = nil
        for client in Array(clients.values) { close(client.connection) }
        state = "stopped"
    }

    private func close(_ connection: NWConnection) {
        let client = clients.removeValue(forKey: ObjectIdentifier(connection))
        client?.deadline?.cancel()
        client?.poll?.cancel()
        client?.work?.cancel()
        waiting.removeAll { $0.connection === connection }
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func revoke(_ bridgeID: String) {
        for client in Array(clients.values) where client.bridgeID == bridgeID { close(client.connection) }
    }

    private func deadline(_ connection: NWConnection, seconds: Double) {
        guard let client = clients[ObjectIdentifier(connection)] else { return }
        client.deadline?.cancel()
        client.deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.close(connection)
        }
    }

    private func accept(_ connection: NWConnection) {
        guard clients.count < limits.connections else { connection.cancel(); return }
        clients[ObjectIdentifier(connection)] = Client(connection)
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.close(connection)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        // Includes the TLS handshake and the entire request, not a sliding idle timeout.
        deadline(connection, seconds: limits.requestSeconds)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: HTTPRequest.maximumBytes + 1) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, self.clients[ObjectIdentifier(connection)] != nil else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch HTTPRequest.parse(buffer) {
                case .complete(let head, let body):
                    self.deadline(connection, seconds: self.limits.responseSeconds)
                    self.respond(to: head, body: body, on: connection)
                case .invalid(let status):
                    self.send(["error": "Invalid or oversized HTTP request"], status: status, on: connection)
                case .incomplete:
                    if isComplete || error != nil { self.close(connection) }
                    else { self.receive(connection, buffer: buffer) }
                }
            }
        }
    }

    private func respond(to head: String, body: Data, on connection: NWConnection) {
        let started = Date()
        let lines = head.split(separator: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let method = parts.first.map(String.init) ?? ""
        let target = parts.count > 1 ? parts[1].split(separator: "?", maxSplits: 1) : []
        let path = target.first.map(String.init) ?? ""
        let query = Self.query(target.count > 1 ? String(target[1]) : "")
        switch (method, path) {
        case ("GET", "/info"):
            send([
                "service": "homeswift-wingman", "api": Self.apiVersion, "id": pairing.wingmanID,
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                "fingerprint": fingerprint, "pairing": pairing.open != nil,
                // Additive, so `api` stays "1": a bridge looks for the feature rather than a version.
                "features": ["structure", "home-link"], "structure": structureAllowed() && changesAllowed(),
            ], on: connection)
            return
        case ("POST", "/pair"):
            pair(body, from: connection, started: started)
            return
        default: break
        }
        guard let token = Self.bearer(lines), let bridge = pairing.bridge(token: token) else {
            send(["error": "pair first: POST /pair with the code Wingman's menu shows, then send Authorization: Bearer <token>"],
                 status: "401 Unauthorized", on: connection)
            return
        }
        clients[ObjectIdentifier(connection)]?.bridgeID = bridge.id
        switch (method, path) {
        case ("GET", "/status"):
            var status = store.statusJSON()
            status["bridges"] = pairing.bridges.count
            send(status, on: connection)
        case ("GET", "/homes"): send(["homes": store.homesJSON()], on: connection)
        case ("GET", "/events"):
            guard let since = query["since"].flatMap(Int.init) else {
                send(["events": store.eventsJSON(since: nil), "last": store.lastSeq, "first": store.firstSeq], on: connection)
                return
            }
            // Long-poll: answered now when there is something newer, else at the next change or after `wait` seconds.
            guard let wait = HTTPRequest.waitSeconds(query["wait"]) else {
                send(["error": "wait must be a finite number"], status: "400 Bad Request", on: connection)
                return
            }
            if store.lastSeq > since || wait == 0 {
                send(["events": store.eventsJSON(since: since), "last": store.lastSeq, "first": store.firstSeq], on: connection)
            } else {
                let id = UUID()
                waiting.append((id, since, connection))
                // No second request is accepted. Observe EOF while waiting so disconnected polls release their slot.
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                    MainActor.assumeIsolated { self?.close(connection) }
                }
                clients[ObjectIdentifier(connection)]?.poll = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                    self?.answerWaiting(id)
                }
            }
        case ("POST", "/read"):
            clients[ObjectIdentifier(connection)]?.work = Task {
                guard !Task.isCancelled, pairing.contains(bridge.id) else { close(connection); return }
                let result = await store.readAll()
                let failures = ActivityFeed.failures(inRead: result)
                note(bridge.name, "Read all values", "\(result["succeeded"] ?? 0) read" + (failures > 0 ? ", \(failures) failed" : ""),
                     failures > 0 ? .failed : .read, since: started)
                send(result, on: connection)
            }
        case ("POST", "/write"):
            guard changesAllowed() else {
                let refusal = StoreAnswer.changesOff
                note(bridge.name, "Changed accessory", about: store.name(of: request(body)?["accessory"] as? String ?? "") ?? "An accessory",
                     answer: refusal.body, since: started)
                send(refusal.body, status: refusal.status, on: connection)
                return
            }
            guard let request = request(body),
                  let accessory = request["accessory"] as? String, let characteristic = request["characteristic"] as? String,
                  let value = request["value"]
            else {
                send(["error": #"expected {"accessory", "characteristic", "value"}"#], status: "400 Bad Request", on: connection)
                return
            }
            clients[ObjectIdentifier(connection)]?.work = Task {
                guard !Task.isCancelled, pairing.contains(bridge.id), changesAllowed() else { close(connection); return }
                let result = await store.write(accessory: accessory, characteristic: characteristic, value: value,
                                               allowSecurity: securityAllowed())
                let target = result["accessory"] as? String ?? store.name(of: accessory) ?? accessory
                let what = result["characteristic"] as? String ?? characteristic
                note(bridge.name, "Changed accessory",
                     about: result["error"] == nil ? "\(target): \(what) → \(ActivityFeed.describe(result["written"] ?? value))" : target,
                     answer: result, since: started)
                send(result, status: result["error"] == nil ? "200 OK" : "422 Unprocessable Content", on: connection)
            }
        case ("GET", "/scenes"): send(["scenes": store.scenesJSON()], on: connection)
        case ("GET", "/automations"): send(["automations": store.automationsJSON()], on: connection)
        case ("POST", let path) where StructureEdit.paths.contains(String(path.dropFirst())):
            let edit: StructureEdit
            do { edit = try StructureEdit.parse(path: String(path.dropFirst()), body: body) } catch {
                send(["error": error.message], status: "400 Bad Request", on: connection)
                return
            }
            // Checked again once the edit's turn comes, as for writes: the owner may have turned it off meanwhile.
            // An edit changes what scenes and automations write, so a read-only Wingman refuses it too.
            let allowed = { self.changesAllowed() && (!edit.isStructural || self.structureAllowed()) }
            // Named now: a deleted room has no name once the edit ran.
            let described = edit.activity { self.store.name(of: $0) }
            guard allowed() else {
                let refusal = changesAllowed() ? StoreAnswer.turnedOff : .changesOff
                note(bridge.name, described.title, about: described.summary, answer: refusal.body, since: started)
                send(refusal.body, status: refusal.status, on: connection)
                return
            }
            clients[ObjectIdentifier(connection)]?.work = Task {
                guard !Task.isCancelled, pairing.contains(bridge.id), allowed() else { close(connection); return }
                let answer = await store.edit(edit, allowSecurity: securityAllowed())
                note(bridge.name, described.title, about: described.summary, answer: answer.body, since: started)
                send(answer.body, status: answer.status, on: connection)
            }
        default: send(["error": "not found"], status: "404 Not Found", on: connection)
        }
    }

    /// A value changed: every waiting `GET /events` gets the events after its `since`.
    func eventsArrived() {
        for entry in waiting { answerWaiting(entry.id) }
    }

    private func answerWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let entry = waiting.remove(at: index)
        send(["events": store.eventsJSON(since: entry.since), "last": store.lastSeq, "first": store.firstSeq], on: entry.connection)
    }

    private static func query(_ text: String) -> [String: String] {
        var query: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard let key = parts.first?.removingPercentEncoding else { continue }
            query[key] = parts.count > 1 ? String(parts[1]).removingPercentEncoding : ""
        }
        return query
    }

    /// What a request was about and how it was answered: an error follows the summary, and decides the outcome.
    private func note(_ bridge: String, _ title: String, about summary: String, answer: [String: Any], since started: Date) {
        let reason = answer["error"].map { " · \($0)" } ?? ""
        note(bridge, title, summary + reason, ActivityFeed.outcome(answer), since: started)
    }

    private func request(_ body: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }

    private func note(_ bridge: String, _ title: String, _ summary: String, _ outcome: ActivityFeed.Entry.Outcome, since started: Date) {
        activity.record(.init(date: started, bridge: bridge, title: title, summary: summary, outcome: outcome,
                              milliseconds: Int((Date().timeIntervalSince(started) * 1000).rounded())))
    }

    private func pair(_ body: Data, from connection: NWConnection, started: Date) {
        guard let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let code = request["code"] as? String else {
            send(["error": #"expected {"code", "name"}"#], status: "400 Bad Request", on: connection)
            return
        }
        let name = (request["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.describe(connection.endpoint)
        switch pairing.pair(code: code, name: name) {
        case .paired(let token, let bridge):
            NSLog("Wingman: paired \(bridge.name) from \(Self.describe(connection.endpoint))")
            note(bridge.name, "Paired", "from \(Self.describe(connection.endpoint))", .changed, since: started)
            send(["token": token, "bridge": bridge.id, "wingman": pairing.wingmanID, "fingerprint": fingerprint], on: connection)
        case .storageFailure:
            note(name, "Paired", "Wingman could not save the pairing", .failed, since: started)
            send(["error": "Cannot persist pairing; check Wingman and retry"], status: "500 Internal Server Error", on: connection)
        case .notOpen:
            // Not noted: anyone on the network can ask while pairing is closed, and would push real entries out.
            send(["error": "pairing is not open: choose Pair a Homeswift Bridge in Wingman's menu"], status: "403 Forbidden", on: connection)
        case .wrongCode(let closed):
            NSLog("Wingman: wrong pairing code from \(Self.describe(connection.endpoint))\(closed ? ", pairing closed" : "")")
            note(name, "Paired", "wrong code from \(Self.describe(connection.endpoint))\(closed ? "; pairing closed" : "")", .refused, since: started)
            send(["error": closed ? "wrong code: pairing closed, open it again from the menu" : "wrong code"], status: "403 Forbidden", on: connection)
        }
    }

    private static func bearer(_ lines: [Substring]) -> String? {
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "authorization" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value.lowercased().hasPrefix("bearer ") else { return nil }
            return String(value.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return "\(host)" }
        return "\(endpoint)"
    }

    private func send(_ json: Any, status: String = "200 OK", on connection: NWConnection) {
        guard let client = clients[ObjectIdentifier(connection)] else { return }
        if let id = client.bridgeID, !pairing.contains(id) { close(connection); return }
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        // Half-close (TLS close_notify, then FIN) and cancel only once the bridge hangs up, or at the response
        // deadline. Cancelling as soon as the send is processed stalls a response still in flight and drops it
        // after about 10 seconds: a bridge on the LAN saw `uncleanShutdown` reading a few hundred KB of homes.
        connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard error == nil else { self?.close(connection); return }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                    MainActor.assumeIsolated { self?.close(connection) }
                }
            }
        })
    }
}
