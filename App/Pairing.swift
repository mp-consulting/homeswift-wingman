import CryptoKit
import Foundation
import Security
import Darwin

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
    var onRemove: ((String) -> Void)?
    private(set) var persistenceError: String?
    private let now: () -> Date
    private let writeFile: (Data, URL) throws -> Void
    private var lastSavedSeen: [String: Date] = [:]
    private(set) var bridges: [Bridge] = []
    private(set) var open: Open?
    private var closing: Timer?
    private let file: URL

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mpconsulting.HomeswiftWingman", isDirectory: true),
         now: @escaping () -> Date = Date.init,
         writeFile: @escaping (Data, URL) throws -> Void = Pairing.write) {
        self.now = now
        self.writeFile = writeFile
        file = directory.appendingPathComponent("bridges.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            bridges = try decoder.decode([Bridge].self, from: Data(contentsOf: file))
            lastSavedSeen = Dictionary(uniqueKeysWithValues: bridges.compactMap { bridge in
                bridge.lastSeenAt.map { (bridge.id, $0) }
            })
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First launch.
        } catch {
            persistenceError = "Cannot load paired bridges. Check access to the application data folder."
        }
    }

    /// Wingman's own id, for the Bonjour TXT record and `/info`: made once, kept with the bridges.
    lazy var wingmanID: String = {
        let url = file.deletingLastPathComponent().appendingPathComponent("id")
        if let id = try? String(contentsOf: url, encoding: .utf8), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        try? writeFile(Data(id.utf8), url)
        return id
    }()

    // MARK: Pairing

    func openPairing() {
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        open = Open(code: code, until: now().addingTimeInterval(Self.codeLifetime))
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
        case storageFailure
        case notOpen
        case wrongCode(closed: Bool)
    }

    func pair(code: String, name: String) -> PairResult {
        guard var current = open, current.until > now() else {
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
        let bridge = Bridge(id: UUID().uuidString.lowercased(), name: String(name.prefix(80)), tokenSHA256: Self.sha256(token), pairedAt: now())
        guard save(bridges + [bridge]) else { return .storageFailure }
        bridges.append(bridge)
        closePairing()
        return .paired(token: token, bridge: bridge)
    }

    @discardableResult func remove(_ id: String) -> Bool {
        let remaining = bridges.filter { $0.id != id }
        guard save(remaining) else { return false }
        bridges = remaining
        lastSavedSeen.removeValue(forKey: id)
        onRemove?(id)
        onChange?()
        return true
    }

    func contains(_ id: String) -> Bool { bridges.contains { $0.id == id } }

    // MARK: Requests

    /// The bridge an `Authorization: Bearer` token belongs to, its last visit noted (saved at most every minute).
    func bridge(token: String) -> Bridge? {
        let hash = Data(Self.sha256(token).utf8)
        guard let index = bridges.firstIndex(where: { Self.equal(Data($0.tokenSHA256.utf8), hash) }) else { return nil }
        let time = now()
        bridges[index].lastSeenAt = time
        if lastSavedSeen[bridges[index].id].map({ time.timeIntervalSince($0) >= 60 }) ?? true {
            _ = save(bridges)
            onChange?()
        }
        return bridges[index]
    }

    // MARK: Helpers

    private func save(_ value: [Bridge]) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try writeFile(encoder.encode(value), file)
            lastSavedSeen = Dictionary(uniqueKeysWithValues: value.compactMap { bridge in
                bridge.lastSeenAt.map { (bridge.id, $0) }
            })
            persistenceError = nil
            return true
        } catch {
            persistenceError = "Cannot save paired bridges. No pairing or removal was completed. Check available disk space and folder permissions, then retry."
            onChange?()
            return false
        }
    }

    /// Create the temporary file owner-only before writing, then atomically replace the destination.
    /// All fallible preparation precedes rename, so a failed write never reports a committed change.
    nonisolated static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
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
