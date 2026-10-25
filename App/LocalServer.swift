import Foundation
import Network

/// A read-only JSON API on 127.0.0.1, which a Homeswift plugin would poll or stream from:
/// `GET /status`, `GET /homes`, `GET /events` (the latest value changes), `POST /read` (reads every value).
///
/// Spike only: no token yet, so any process of this user on this Mac can read the home's layout.
@MainActor
final class LocalServer {
    static let defaultPort: UInt16 = 8619

    private let store: HomeStore
    private let port: UInt16
    private var listener: NWListener?

    init(store: HomeStore, port: UInt16) {
        self.store = store
        self.port = port
    }

    func start() {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { NSLog("Sidecar: listener failed: \(error)") }
            }
            listener.start(queue: .main)
            self.listener = listener
            NSLog("Sidecar: serving on http://127.0.0.1:\(port)")
        } catch {
            NSLog("Sidecar: cannot listen on \(port): \(error)")
        }
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
                    self.respond(to: head, on: connection)
                } else if isComplete || error != nil || buffer.count > 65_536 {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        let parts = head.split(separator: "\r\n").first?.split(separator: " ") ?? []
        let method = parts.first.map(String.init) ?? ""
        let path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "") : ""
        switch (method, path) {
        case ("GET", "/status"): send(store.statusJSON(), on: connection)
        case ("GET", "/homes"): send(["homes": store.homesJSON()], on: connection)
        case ("GET", "/events"): send(["events": store.eventsJSON()], on: connection)
        case ("POST", "/read"):
            Task { send(await store.readAll(), on: connection) }
        default: send(["error": "not found"], status: "404 Not Found", on: connection)
        }
    }

    private func send(_ json: Any, status: String = "200 OK", on connection: NWConnection) {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
