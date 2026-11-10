import CryptoKit
import Foundation
import Security

struct TVIdentity {
    let publicKey: SecKey
    let identity: SecIdentity

    private static let keyTag = Data("tvremote.identity.rsa.v1".utf8)

    static func load() throws -> TVIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrApplicationTag as String: keyTag,
            kSecReturnRef as String: true
        ]
        var stored: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &stored)
        let privateKey: SecKey
        switch status {
        case errSecSuccess:
            guard let stored, CFGetTypeID(stored) == SecKeyGetTypeID() else {
                throw IdentityError.keychain(status)
            }
            privateKey = stored as! SecKey
        case errSecItemNotFound:
            privateKey = try generateKey()
        default:
            throw IdentityError.keychain(status)
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw IdentityError.certificate
        }
        let certificate = try makeCertificate(privateKey: privateKey, publicKey: publicKey)
        guard let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw IdentityError.certificate
        }
        return TVIdentity(publicKey: publicKey, identity: identity)
    }

    private static func generateKey() throws -> SecKey {
        let privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: privateAttributes
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw IdentityError.certificate
        }
        return key
    }

    private static func makeCertificate(privateKey: SecKey, publicKey: SecKey) throws -> SecCertificate {
        var error: Unmanaged<CFError>?
        guard let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw IdentityError.certificate
        }

        // Keep the certificate deterministic so the TV sees the same identity on later launches.
        let signatureAlgorithm = DER.rsaAlgorithm(0x0b)
        let name = DER.sequence(DER.encode(0x31, DER.sequence(
            DER.encode(0x06, Data([0x55, 0x04, 0x03])),
            DER.encode(0x0c, Data("iPhone TV Remote".utf8))
        )))
        let validity = DER.sequence(
            DER.encode(0x17, Data("240101000000Z".utf8)),
            DER.encode(0x17, Data("491231235959Z".utf8))
        )
        let publicKeyInfo = DER.sequence(DER.rsaAlgorithm(0x01), DER.bitString(publicBytes as Data))
        var serial = Data(SHA256.hash(data: publicBytes as Data).prefix(16))
        serial[0] = (serial[0] & 0x3f) | 0x40
        let tbs = DER.sequence(DER.encode(0x02, serial), signatureAlgorithm, name,
                               validity, name, publicKeyInfo)
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                    tbs as CFData, &error) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw IdentityError.certificate
        }
        let bytes = DER.sequence(tbs, signatureAlgorithm, DER.bitString(signature as Data))
        guard let certificate = SecCertificateCreateWithData(nil, bytes as CFData) else {
            throw IdentityError.certificate
        }
        return certificate
    }
}

private enum IdentityError: LocalizedError {
    case keychain(OSStatus)
    case certificate

    var errorDescription: String? {
        switch self {
        case .keychain(let status): return "读取 iPhone 钥匙串失败（\(status)）。"
        case .certificate: return "无法创建遥控器配对证书。"
        }
    }
}

private enum DER {
    static func encode(_ tag: UInt8, _ content: Data) -> Data {
        var header = Data([tag])
        if content.count < 128 {
            header.append(UInt8(content.count))
        } else {
            var size = content.count
            var bytes = [UInt8]()
            while size > 0 {
                bytes.append(UInt8(truncatingIfNeeded: size))
                size >>= 8
            }
            header.append(0x80 | UInt8(bytes.count))
            header.append(contentsOf: bytes.reversed())
        }
        return header + content
    }

    static func sequence(_ fields: Data...) -> Data {
        encode(0x30, fields.reduce(into: Data()) { $0.append($1) })
    }

    static func bitString(_ bytes: Data) -> Data {
        encode(0x03, Data([0x00]) + bytes)
    }

    static func rsaAlgorithm(_ suffix: UInt8) -> Data {
        let oid = Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, suffix])
        return sequence(encode(0x06, oid), encode(0x05, Data()))
    }
}
