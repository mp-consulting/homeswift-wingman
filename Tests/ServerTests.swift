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
    func statusJSON() -> [String: Any] { ["fixture": true] }
    func homesJSON() -> [[String: Any]] { [["name": "Demo Home"]] }
    func eventsJSON(since: Int?) -> [[String: Any]] { lastSeq > (since ?? 0) ? [["seq": lastSeq, "value": "private-event"]] : [] }
    func readAll() async -> [String: Any] { reads += 1; return ["read": true] }
    func write(accessory: String, characteristic: String, value: Any) async -> [String: Any] { writes += 1; return ["written": true] }
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
        try pairing()
        try await network()
        print("PASS: parser, pairing transactions, last-seen persistence, network limits, revocation and listener recovery")
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

    @MainActor static func network() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pairing = Pairing(directory: root)
        pairing.openPairing()
        guard case let .paired(token, bridge) = pairing.pair(code: pairing.open!.code, name: "Fixture") else { throw TestFailure(message: "fixture pairing") }
        let store = FakeStore()
        var config = LocalServer.Configuration(port: 0, advertise: false)
        let server = LocalServer(store: store, pairing: pairing, fingerprint: "fixture", configuration: { config }, changesAllowed: { true },
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
