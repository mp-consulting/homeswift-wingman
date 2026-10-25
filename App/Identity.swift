import CryptoKit
import Foundation
import Security

/// Wingman's TLS identity: a P-256 key and a self-signed certificate, made once and kept in the data protection
/// keychain. A bridge pins the certificate's SHA-256 when it pairs, so the certificate names nothing and is no CA; it
/// lasts until 2049 because making a new one would unpair every bridge.
struct Identity {
    let identity: SecIdentity
    let certificateDER: Data

    /// The SHA-256 of the certificate, lowercase hex without separators, as Homeswift's `HTTPClient` pins it.
    var fingerprint: String { SHA256.hash(data: certificateDER).map { String(format: "%02x", $0) }.joined() }

    /// The first eight bytes, `AB:CD:…`, for the menu: enough for a person to compare with what the bridge shows.
    var shortFingerprint: String {
        stride(from: 0, to: 16, by: 2).map { offset in
            String(fingerprint.dropFirst(offset).prefix(2)).uppercased()
        }.joined(separator: ":")
    }

    private static let label = "Homeswift Wingman TLS"

    enum Failure: Error, CustomStringConvertible {
        case keychain(String, OSStatus)
        var description: String {
            switch self {
            case .keychain(let step, let status): "\(step): \(SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)")"
            }
        }
    }

    static func load() throws -> Identity {
        if let found = try find() { return found }
        let key = P256.Signing.PrivateKey()
        // Bridges pin the certificate fingerprint; resolving a hostname here can block launch.
        let der = try selfSigned(key: key, name: "Homeswift Wingman")
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256,
        ]
        guard let secKey = SecKeyCreateWithData(key.x963Representation as CFData, attributes as CFDictionary, &error),
              let certificate = SecCertificateCreateWithData(nil, der as CFData)
        else { throw Failure.keychain("making the key", errSecParam) }
        for (kind, value) in [(kSecClassKey, secKey as AnyObject), (kSecClassCertificate, certificate as AnyObject)] {
            let status = SecItemAdd([
                kSecClass as String: kind,
                kSecValueRef as String: value,
                kSecAttrLabel as String: label,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecUseDataProtectionKeychain as String: true,
            ] as CFDictionary, nil)
            guard status == errSecSuccess else { throw Failure.keychain("saving the \(kind == kSecClassKey ? "key" : "certificate")", status) }
        }
        guard let made = try find() else { throw Failure.keychain("finding the identity", errSecItemNotFound) }
        NSLog("Wingman: made a TLS certificate, SHA-256 \(made.fingerprint)")
        return made
    }

    private static func find() throws -> Identity? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result, CFGetTypeID(result) == SecIdentityGetTypeID() else {
            throw Failure.keychain("reading the identity", status)
        }
        let identity = result as! SecIdentity
        var certificate: SecCertificate?
        let copied = SecIdentityCopyCertificate(identity, &certificate)
        guard copied == errSecSuccess, let certificate else { throw Failure.keychain("reading the certificate", copied) }
        return Identity(identity: identity, certificateDER: SecCertificateCopyData(certificate) as Data)
    }

    // MARK: A self-signed certificate (RFC 5280), DER by hand, as Homeswift's UICertificate makes its own

    static func selfSigned(key: P256.Signing.PrivateKey, name: String) throws -> Data {
        let ecdsaWithSHA256 = DER.sequence([DER.oid([1, 2, 840, 10045, 4, 3, 2])])
        let subject = DER.sequence([
            DER.set([DER.sequence([DER.oid([2, 5, 4, 3]), DER.utf8(name)])]),
            DER.set([DER.sequence([DER.oid([2, 5, 4, 10]), DER.utf8("Homeswift")])]),
        ])
        var serial = (0..<16).map { _ in UInt8.random(in: 0...255) }
        serial[0] &= 0x7F   // positive
        let extensions = DER.sequence([
            // digitalSignature.
            DER.extensionValue([2, 5, 29, 15], critical: true, DER.tagged(0x03, Data([0x07, 0x80]))),
            // serverAuth.
            DER.extensionValue([2, 5, 29, 37], critical: false, DER.sequence([DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1])])),
        ])
        let now = Date()
        let tbs = DER.sequence([
            DER.tagged(0xA0, DER.integer([2])),
            DER.integer(serial),
            ecdsaWithSHA256,
            subject,
            DER.sequence([DER.time(now.addingTimeInterval(-86_400)), DER.time(Date(timeIntervalSince1970: 2_524_607_999))]),   // 2049-12-31
            subject,
            key.publicKey.derRepresentation,
            DER.tagged(0xA3, extensions),
        ])
        let signature = try key.signature(for: tbs).derRepresentation
        return DER.sequence([tbs, ecdsaWithSHA256, DER.tagged(0x03, Data([0]) + signature)])
    }
}

/// The few DER encodings a certificate needs (X.690).
enum DER {
    static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let count = content.count
        if count < 0x80 {
            out.append(UInt8(count))
        } else {
            var bytes: [UInt8] = []
            var remaining = count
            while remaining > 0 {
                bytes.insert(UInt8(remaining & 0xFF), at: 0)
                remaining >>= 8
            }
            out.append(0x80 | UInt8(bytes.count))
            out.append(contentsOf: bytes)
        }
        return out + content
    }

    static func sequence(_ parts: [Data]) -> Data { tagged(0x30, parts.reduce(Data(), +)) }
    static func set(_ parts: [Data]) -> Data { tagged(0x31, parts.reduce(Data(), +)) }
    static func boolean(_ value: Bool) -> Data { tagged(0x01, Data([value ? 0xFF : 0x00])) }
    static func utf8(_ text: String) -> Data { tagged(0x0C, Data(text.utf8)) }

    /// A non-negative INTEGER from big-endian bytes: no superfluous leading zero, one added when the top bit is set.
    static func integer(_ bytes: [UInt8]) -> Data {
        var value = Array(bytes.drop { $0 == 0 })
        if value.isEmpty { value = [0] }
        if value[0] & 0x80 != 0 { value.insert(0, at: 0) }
        return tagged(0x02, Data(value))
    }

    static func oid(_ arcs: [UInt]) -> Data {
        var out = Data([UInt8(arcs[0] * 40 + arcs[1])])
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var rest = arc >> 7
            while rest > 0 {
                chunk.insert(UInt8(rest & 0x7F) | 0x80, at: 0)
                rest >>= 7
            }
            out.append(contentsOf: chunk)
        }
        return tagged(0x06, out)
    }

    /// UTCTime: every date this certificate carries is before 2050 (RFC 5280 §4.1.2.5).
    static func time(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tagged(0x17, Data(formatter.string(from: date).utf8))
    }

    static func extensionValue(_ oid: [UInt], critical: Bool, _ value: Data) -> Data {
        sequence([DER.oid(oid)] + (critical ? [boolean(true)] : []) + [tagged(0x04, value)])
    }
}
