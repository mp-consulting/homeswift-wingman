import CryptoKit
import Foundation
import Security

/// Which Homeswift bridges may use the API, and the pairing that adds one.
///
/// Pairing is opened from the menu: it shows a six-digit code for ten minutes. A bridge sends it to `POST /pair` over
/// TLS and gets a token back, which it sends as `Authorization: Bearer` from then on, and it pins the certificate it
/// saw. A code serves once, and five wrong ones close the pairing. Only the tokens' SHA-256 is kept, in
/// `~/Library/Application Support/com.mpconsulting.HomeswiftWingman/bridges.json` (owner only).
@MainActor
final class Pairing {
    struct Bridge: Codable {
        let id: String
        var name: String
        let tokenSHA256: String
        let pairedAt: Date
        var lastSeenAt: Date?
    }

    struct Open {
        let code: String
        let until: Date
        var failures = 0
    }

    static let codeLifetime: TimeInterval = 600
    static let maximumFailures = 5

    var onChange: (() -> Void)?
    private(set) var bridges: [Bridge] = []
    private(set) var open: Open?
    private var closing: Timer?
    private let file: URL

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mpconsulting.HomeswiftWingman", isDirectory: true)
        file = directory.appendingPathComponent("bridges.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: file) { bridges = (try? decoder.decode([Bridge].self, from: data)) ?? [] }
    }

    /// Wingman's own id, for the Bonjour TXT record and `/info`: made once, kept with the bridges.
    lazy var wingmanID: String = {
        let url = file.deletingLastPathComponent().appendingPathComponent("id")
        if let id = try? String(contentsOf: url, encoding: .utf8), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        try? write(Data(id.utf8), to: url)
        return id
    }()

    // MARK: Pairing

    func openPairing() {
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        open = Open(code: code, until: Date().addingTimeInterval(Self.codeLifetime))
        closing?.invalidate()
        closing = Timer.scheduledTimer(withTimeInterval: Self.codeLifetime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePairing() }
        }
        onChange?()
    }

    func closePairing() {
        open = nil
        closing?.invalidate()
        closing = nil
        onChange?()
    }

    enum PairResult {
        case paired(token: String, bridge: Bridge)
        case notOpen
        case wrongCode(closed: Bool)
    }

    func pair(code: String, name: String) -> PairResult {
        guard var current = open, current.until > Date() else {
            closePairing()
            return .notOpen
        }
        guard Self.equal(Data(code.filter(\.isNumber).utf8), Data(current.code.utf8)) else {
            current.failures += 1
            if current.failures >= Self.maximumFailures {
                closePairing()
                return .wrongCode(closed: true)
            }
            open = current
            return .wrongCode(closed: false)
        }
        let token = Self.randomToken()
        let bridge = Bridge(id: UUID().uuidString.lowercased(), name: String(name.prefix(80)), tokenSHA256: Self.sha256(token), pairedAt: Date())
        bridges.append(bridge)
        save()
        closePairing()
        return .paired(token: token, bridge: bridge)
    }

    func remove(_ id: String) {
        bridges.removeAll { $0.id == id }
        save()
        onChange?()
    }

    // MARK: Requests

    /// The bridge an `Authorization: Bearer` token belongs to, its last visit noted (saved at most every minute).
    func bridge(token: String) -> Bridge? {
        let hash = Data(Self.sha256(token).utf8)
        guard let index = bridges.firstIndex(where: { Self.equal(Data($0.tokenSHA256.utf8), hash) }) else { return nil }
        let previous = bridges[index].lastSeenAt
        bridges[index].lastSeenAt = Date()
        if previous.map({ Date().timeIntervalSince($0) > 60 }) ?? true {
            save()
            onChange?()
        }
        return bridges[index]
    }

    // MARK: Helpers

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do { try write(encoder.encode(bridges), to: file) } catch { NSLog("Wingman: cannot save the paired bridges: \(error)") }
    }

    private func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { fatalError("no random bytes") }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Compares in time that depends on the length only.
    private static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
