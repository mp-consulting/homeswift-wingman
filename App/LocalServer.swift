import CryptoKit
import Foundation
import Network

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

    private let store: HomeStore
    private let pairing: Pairing
    private let identity: Identity
    private(set) var port: UInt16
    private var advertising = true
    private var listener: NWListener?
    private var advertisedHome: String?
    /// `GET /events?since=&wait=` requests held until a value changes or their wait ends.
    private var waiting: [(id: UUID, since: Int, connection: NWConnection)] = []
    private(set) var state = "starting"
    var onChange: (() -> Void)?
    /// The certificate's SHA-256 (lowercase hex), for the menu bar panel.
    var fingerprint: String { identity.fingerprint }

    init(store: HomeStore, pairing: Pairing, identity: Identity) {
        self.store = store
        self.pairing = pairing
        self.identity = identity
        port = Settings.port
    }

    /// Starts again when the port or Bonjour setting changed.
    func applySettings() {
        guard Settings.port != port || Settings.advertise != advertising else { return }
        listener?.cancel()
        listener = nil
        start()
    }

    func start() {
        port = Settings.port
        advertising = Settings.advertise
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity.identity)!)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let parameters = NWParameters(tls: tls)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            if advertising { listener.service = service() }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
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
            NSLog("Wingman: serving on https://*:\(port), certificate SHA-256 \(identity.fingerprint)")
        } catch {
            state = "cannot listen on \(port): \(error)"
            NSLog("Wingman: cannot listen on \(port): \(error)")
        }
    }

    /// Advertises the homes again when they change (they load after the listener starts).
    func homesChanged() {
        guard let listener, advertising, homeHash != advertisedHome else { return }
        listener.service = service()
    }

    private var homeHash: String {
        let ids = store.homes.map(\.uniqueIdentifier.uuidString).sorted().joined(separator: ",")
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

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    let body = buffer[end.upperBound...]
                    if body.count >= Self.contentLength(head) {
                        self.respond(to: head, body: Data(body), on: connection)
                        return
                    }
                }
                if isComplete || error != nil || buffer.count > 65_536 {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private static func contentLength(_ head: String) -> Int {
        for line in head.split(separator: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
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
                "fingerprint": identity.fingerprint, "pairing": pairing.open != nil,
            ], on: connection)
            return
        case ("POST", "/pair"):
            pair(body, from: connection)
            return
        default: break
        }
        guard let token = Self.bearer(lines), pairing.bridge(token: token) != nil else {
            send(["error": "pair first: POST /pair with the code Wingman's menu shows, then send Authorization: Bearer <token>"],
                 status: "401 Unauthorized", on: connection)
            return
        }
        switch (method, path) {
        case ("GET", "/status"):
            var status = store.statusJSON()
            status["bridges"] = pairing.bridges.count
            send(status, on: connection)
        case ("GET", "/homes"): send(["homes": store.homesJSON()], on: connection)
        case ("GET", "/events"):
            guard let since = query["since"].flatMap(Int.init) else {
                send(["events": store.eventsJSON(), "last": store.lastSeq, "first": store.firstSeq], on: connection)
                return
            }
            // Long-poll: answered now when there is something newer, else at the next change or after `wait` seconds.
            let wait = min(max(query["wait"].flatMap(Double.init) ?? 0, 0), 30)
            if store.lastSeq > since || wait == 0 {
                send(["events": store.eventsJSON(since: since), "last": store.lastSeq, "first": store.firstSeq], on: connection)
            } else {
                let id = UUID()
                waiting.append((id, since, connection))
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    self?.answerWaiting(id)
                }
            }
        case ("POST", "/read"):
            Task { send(await store.readAll(), on: connection) }
        case ("POST", "/write"):
            guard Settings.allowChanges else {
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
            Task {
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
            send(["token": token, "bridge": bridge.id, "wingman": pairing.wingmanID, "fingerprint": identity.fingerprint], on: connection)
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
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
