// Go2 LAN (AP mode) signaling and data-channel crypto, ported from
// unitree_webrtc_connect 2.2.0 (unitree_auth.py, encryption.py, msgs/validation.py).
// Pure Foundation/CryptoKit/Security: no WebRTC, no UI, never logs key material.

import CommonCrypto
import CryptoKit
import Foundation
import Security

enum Go2ProtocolError: Error, CustomStringConvertible {
    case badKey, badData1, keyRejected, badPublicKey, rsaFailed, aesFailed, badAnswer

    var description: String {
        switch self {
        case .badKey: return "robot key must be 32 hex characters"
        case .badData1: return "con_notify data1 malformed"
        case .keyRejected: return "robot rejected the AES-128 key (GCM tag check failed)"
        case .badPublicKey: return "robot public key could not be parsed"
        case .rsaFailed: return "RSA encryption failed"
        case .aesFailed: return "AES-ECB operation failed"
        case .badAnswer: return "robot SDP answer malformed"
        }
    }
}

enum Go2Protocol {
    // AESGCMUtil.keyBytes in the Unitree apk; used when con_notify says data2 == 2.
    static let legacyGCMKey = Data([232, 86, 130, 189, 22, 84, 155, 0, 142, 4, 166, 104, 43, 179, 235, 227])

    static func keyBytes(hex: String) throws -> Data {
        let s = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.count == 32 else { throw Go2ProtocolError.badKey }
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { throw Go2ProtocolError.badKey }
            out.append(b)
            i = j
        }
        return out
    }

    /// data1 layout: ciphertext | nonce(12) | tag(16), base64.
    static func decryptData1(_ b64: String, key: Data) throws -> String {
        guard let raw = Data(base64Encoded: b64), raw.count >= 28 else { throw Go2ProtocolError.badData1 }
        let tag = raw.suffix(16)
        let nonce = raw.subdata(in: raw.count - 28 ..< raw.count - 16)
        let ciphertext = raw.prefix(raw.count - 28)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            let plain = try AES.GCM.open(box, using: SymmetricKey(data: key))
            guard let text = String(data: plain, encoding: .utf8) else { throw Go2ProtocolError.badData1 }
            return text
        } catch is Go2ProtocolError {
            throw Go2ProtocolError.badData1
        } catch {
            throw Go2ProtocolError.keyRejected
        }
    }

    /// Plain data1 → (robot public key base64, con_ing path ending).
    static func parseData1(_ data1: String) throws -> (publicKeyB64: String, path: String) {
        let chars = Array(data1)
        guard chars.count > 20 else { throw Go2ProtocolError.badData1 }
        let pem = String(chars[10 ..< chars.count - 10])
        let last10 = Array(chars.suffix(10))
        let letters: [Character] = ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J"]
        var path = ""
        var i = 0
        while i + 1 < last10.count {
            if let idx = letters.firstIndex(of: last10[i + 1]) { path += String(idx) }
            i += 2
        }
        return (pem, path)
    }

    /// Session key: uuid4 as 32 lowercase hex chars; used as a 32-byte AES-256 key (its UTF-8 bytes).
    static func newSessionKey() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func aesECB(_ input: Data, key: String, encrypt: Bool) throws -> Data {
        let keyData = Data(key.utf8)
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status = out.withUnsafeMutableBytes { outPtr in
            input.withUnsafeBytes { inPtr in
                keyData.withUnsafeBytes { keyPtr in
                    CCCrypt(
                        CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                        keyPtr.baseAddress, keyData.count, nil,
                        inPtr.baseAddress, input.count, outPtr.baseAddress, outCount, &moved)
                }
            }
        }
        guard status == kCCSuccess else { throw Go2ProtocolError.aesFailed }
        return out.prefix(moved)
    }

    static func aesEncrypt(_ text: String, key: String) throws -> String {
        try aesECB(Data(text.utf8), key: key, encrypt: true).base64EncodedString()
    }

    static func aesDecrypt(_ b64: String, key: String) throws -> String {
        guard let data = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let text = String(data: try aesECB(data, key: key, encrypt: false), encoding: .utf8)
        else { throw Go2ProtocolError.aesFailed }
        return text
    }

    /// Accepts SubjectPublicKeyInfo or PKCS#1 DER (base64); Security wants PKCS#1.
    static func publicKey(b64: String) throws -> SecKey {
        let cleaned = b64.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: cleaned) else { throw Go2ProtocolError.badPublicKey }
        let pkcs1 = try spkiToPKCS1(der) ?? der
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, nil) else {
            throw Go2ProtocolError.badPublicKey
        }
        return key
    }

    static func rsaEncrypt(_ text: String, key: SecKey) throws -> String {
        let data = Data(text.utf8)
        let chunk = SecKeyGetBlockSize(key) - 11
        var out = Data()
        var start = 0
        while start < data.count {
            let piece = data.subdata(in: start ..< min(start + chunk, data.count))
            guard let enc = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, piece as CFData, nil) else {
                throw Go2ProtocolError.rsaFailed
            }
            out.append(enc as Data)
            start += chunk
        }
        return out.base64EncodedString()
    }

    /// Data-channel validation reply: base64(md5("UnitreeGo2_" + challenge)).
    static func validationReply(_ challenge: String) -> String {
        Data(Insecure.MD5.hash(data: Data("UnitreeGo2_\(challenge)".utf8))).base64EncodedString()
    }

    // MARK: minimal DER walk

    private static func readTLV(_ d: [UInt8], _ i: inout Int) throws -> (tag: UInt8, body: Range<Int>) {
        guard i + 2 <= d.count else { throw Go2ProtocolError.badPublicKey }
        let tag = d[i]
        var len = Int(d[i + 1])
        i += 2
        if len & 0x80 != 0 {
            let n = len & 0x7f
            guard n <= 4, i + n <= d.count else { throw Go2ProtocolError.badPublicKey }
            len = 0
            for _ in 0 ..< n { len = (len << 8) | Int(d[i]); i += 1 }
        }
        guard i + len <= d.count else { throw Go2ProtocolError.badPublicKey }
        let body = i ..< i + len
        i += len
        return (tag, body)
    }

    /// Returns the inner PKCS#1 key for an SPKI wrapper, or nil if `der` is not SPKI.
    static func spkiToPKCS1(_ der: Data) throws -> Data? {
        let d = [UInt8](der)
        var i = 0
        let outer = try readTLV(d, &i)
        guard outer.tag == 0x30 else { throw Go2ProtocolError.badPublicKey }
        var j = outer.body.lowerBound
        let first = try readTLV(d, &j)
        guard first.tag == 0x30 else { return nil }  // PKCS#1 starts with INTEGER
        let bits = try readTLV(d, &j)
        guard bits.tag == 0x03, bits.body.count > 1, d[bits.body.lowerBound] == 0 else {
            throw Go2ProtocolError.badPublicKey
        }
        return Data(d[(bits.body.lowerBound + 1) ..< bits.body.upperBound])
    }
}
