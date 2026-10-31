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
    func write(accessory: String, characteristic: String, value: Any) async -> [String: Any]
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
///   description, "value": …}`).
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
    struct Configuration: Equatable { var port: UInt16; var advertise: Bool }
    struct Limits {
        var connections = 64
        var requestSeconds: Double = 10
        var responseSeconds: Double = 90
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
    /// `GET /events?since=&wait=` requests held until a value changes or their wait ends.
    private var waiting: [(id: UUID, since: Int, connection: NWConnection)] = []
    private(set) var state = "starting"
    var onChange: (() -> Void)?
    /// The certificate's SHA-256 (lowercase hex), for the menu bar panel.
    let fingerprint: String

    convenience init(store: any WingmanStore, pairing: Pairing, identity: Identity) {
        self.init(store: store, pairing: pairing, fingerprint: identity.fingerprint,
                  configuration: { Configuration(port: Settings.port, advertise: Settings.advertise) },
                  changesAllowed: { Settings.allowChanges }, makeParameters: {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity.identity)!)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            return NWParameters(tls: tls)
        })
    }

    /// Dependency injection keeps network tests on loopback without HomeKit, defaults or Keychain access.
    init(store: any WingmanStore, pairing: Pairing, fingerprint: String,
         configuration: @escaping () -> Configuration, changesAllowed: @escaping () -> Bool,
         limits: Limits = Limits(), makeParameters: @escaping () -> NWParameters) {
        self.store = store
        self.pairing = pairing
        self.fingerprint = fingerprint
        self.configuration = configuration
        self.changesAllowed = changesAllowed
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

    func start() {
        stop()
        let desired = configuration()
        port = desired.port
        advertising = desired.advertise
        state = "starting"
        onChange?()
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
                    guard self?.generation == currentGeneration else { return }
                    switch state {
                    case .ready: self?.state = "listening"
                    case .cancelled: return
                    case .failed(let error):
                        self?.state = "failed: \(error)"
                        NSLog("Wingman: listener failed: \(error)")
                    case .waiting(let error): self?.state = "waiting: \(error)"
                    default: break
                    }
                    self?.onChange?()
                }
            }
            listener.serviceRegistrationUpdateHandler = { change in
                if case .add(let endpoint) = change { NSLog("Wingman: advertised \(endpoint)") }
            }
            listener.start(queue: .main)
            self.listener = listener
            NSLog("Wingman: serving on https://*:\(port), certificate SHA-256 \(fingerprint)")
        } catch {
            state = "cannot listen on \(port): \(error)"
            NSLog("Wingman: cannot listen on \(port): \(error)")
            onChange?()
        }
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
            ], on: connection)
            return
        case ("POST", "/pair"):
            pair(body, from: connection)
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
                send(await store.readAll(), on: connection)
            }
        case ("POST", "/write"):
            guard changesAllowed() else {
                send(["error": "changes are turned off in Wingman's settings"], status: "403 Forbidden", on: connection)
                return
            }
            guard let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let accessory = request["accessory"] as? String, let characteristic = request["characteristic"] as? String,
                  let value = request["value"]
            else {
                send(["error": #"expected {"accessory", "characteristic", "value"}"#], status: "400 Bad Request", on: connection)
                return
            }
            clients[ObjectIdentifier(connection)]?.work = Task {
                guard !Task.isCancelled, pairing.contains(bridge.id), changesAllowed() else { close(connection); return }
                let result = await store.write(accessory: accessory, characteristic: characteristic, value: value)
                send(result, status: result["error"] == nil ? "200 OK" : "422 Unprocessable Content", on: connection)
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

    private func pair(_ body: Data, from connection: NWConnection) {
        guard let request = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any], let code = request["code"] as? String else {
            send(["error": #"expected {"code", "name"}"#], status: "400 Bad Request", on: connection)
            return
        }
        let name = (request["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? Self.describe(connection.endpoint)
        switch pairing.pair(code: code, name: name) {
        case .paired(let token, let bridge):
            NSLog("Wingman: paired \(bridge.name) from \(Self.describe(connection.endpoint))")
            send(["token": token, "bridge": bridge.id, "wingman": pairing.wingmanID, "fingerprint": fingerprint], on: connection)
        case .storageFailure:
            send(["error": "Cannot persist pairing; check Wingman and retry"], status: "500 Internal Server Error", on: connection)
        case .notOpen:
            send(["error": "pairing is not open: choose Pair a Homeswift Bridge in Wingman's menu"], status: "403 Forbidden", on: connection)
        case .wrongCode(let closed):
            NSLog("Wingman: wrong pairing code from \(Self.describe(connection.endpoint))\(closed ? ", pairing closed" : "")")
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
