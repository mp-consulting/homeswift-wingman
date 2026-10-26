import CryptoKit
import Foundation

/// A synthetic Homeswift bridge inside Wingman, so a reviewer without one can watch the whole flow: it pairs with a
/// fresh code over TLS (pinning the certificate, as a real bridge does), reads the homes, toggles a light and is
/// refused a lock change. Removing it in the Bridges tab revokes its token; the next run shows the old one rejected.
///
/// Its token lives only in memory, so a demo bridge left over from an earlier launch is removed at start.
@MainActor
final class DemoBridge {
    static let name = "Demo Bridge (Synthetic)"
    static let idKey = "demoBridgeID"

    var onChange: (() -> Void)?
    private(set) var log: [String] = []
    private(set) var busy = false
    private let pairing: Pairing
    private let port: () -> UInt16
    private let session: URLSession
    private var token: String?

    init(pairing: Pairing, fingerprint: String, port: @escaping () -> UInt16) {
        self.pairing = pairing
        self.port = port
        session = URLSession(configuration: .ephemeral, delegate: PinnedCertificate(fingerprint: fingerprint), delegateQueue: nil)
        forget()
    }

    var isPaired: Bool { UserDefaults.standard.string(forKey: Self.idKey).map(pairing.contains) ?? false }

    /// Removes the demo bridge's pairing, if any.
    func forget() {
        token = nil
        if let id = UserDefaults.standard.string(forKey: Self.idKey) {
            if pairing.contains(id) { pairing.remove(id) }
            UserDefaults.standard.removeObject(forKey: Self.idKey)
        }
        log = []
        onChange?()
    }

    func run() async {
        guard !busy else { return }
        busy = true
        log = []
        onChange?()
        defer { busy = false; onChange?() }
        do {
            if let token {
                let (status, _) = try await request("GET", "/homes", token: token)
                if status == 401 {
                    note("Its old token was rejected (401): removing a bridge revokes its access.")
                    self.token = nil
                    UserDefaults.standard.removeObject(forKey: Self.idKey)
                }
            }
            if token == nil { try await pair() }
            guard let token else { return }
            let (_, body) = try await request("GET", "/homes", token: token)
            let home = (body["homes"] as? [[String: Any]])?.first
            let accessories = home?["accessories"] as? [[String: Any]] ?? []
            note("Read \(home?["name"] as? String ?? "no home"): \(accessories.count) accessories.")
            let lamp = accessories.first { $0["name"] as? String == "Demo Floor Lamp" }
            let on = Self.value(of: DemoStore.powerState, in: lamp) as? Bool ?? false
            let (writeStatus, written) = try await request("POST", "/write", token: token, body: [
                "accessory": "Demo Floor Lamp", "characteristic": "Power State", "value": !on,
            ])
            if writeStatus == 200 { note("Turned Demo Floor Lamp \(on ? "off" : "on"). See it in the Home tab.") }
            else { note("Lamp change refused: \(written["error"] as? String ?? "HTTP \(writeStatus)").") }
            let (lockStatus, refused) = try await request("POST", "/write", token: token, body: [
                "accessory": "Demo Front Door Lock", "characteristic": "Lock Mechanism Target State", "value": 0,
            ])
            note(lockStatus == 200 ? "Unexpectedly unlocked the demo lock." : "Unlock refused: \(refused["error"] as? String ?? "HTTP \(lockStatus)").")
        } catch {
            note("Demo bridge could not reach Wingman: \(error.localizedDescription)")
        }
    }

    private func pair() async throws {
        guard pairing.open == nil else {
            note("Pairing is open for another bridge. Cancel it, then run the demo bridge again.")
            return
        }
        pairing.openPairing()
        guard let code = pairing.open?.code else { return }
        let (status, body) = try await request("POST", "/pair", body: ["code": code, "name": Self.name])
        guard status == 200, let token = body["token"] as? String, let bridge = body["bridge"] as? String else {
            pairing.closePairing()
            note("Pairing failed: \(body["error"] as? String ?? "HTTP \(status)").")
            return
        }
        self.token = token
        UserDefaults.standard.set(bridge, forKey: Self.idKey)
        note("Paired over TLS with code \(code.prefix(3)) \(code.suffix(3)), pinning Wingman’s certificate.")
    }

    private func note(_ line: String) {
        log.append(line)
        onChange?()
    }

    private func request(_ method: String, _ path: String, token: String? = nil, body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: URL(string: "https://127.0.0.1:\(port())\(path)")!, timeoutInterval: 10)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }

    private static func value(of type: String, in accessory: [String: Any]?) -> Any? {
        let services = accessory?["services"] as? [[String: Any]] ?? []
        return services.flatMap { $0["characteristics"] as? [[String: Any]] ?? [] }.first { $0["type"] as? String == type }?["value"]
    }
}

/// Trusts only the certificate whose SHA-256 Wingman shows, as a paired bridge does.
private final class PinnedCertificate: NSObject, URLSessionDelegate, Sendable {
    let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        else { return (.cancelAuthenticationChallenge, nil) }
        let der = SecCertificateCopyData(leaf) as Data
        let hash = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return hash == fingerprint ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }
}
