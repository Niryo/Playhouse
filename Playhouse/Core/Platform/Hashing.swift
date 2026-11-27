#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// The digests Playhouse computes (content fingerprints, socket names, the WebSocket handshake).
/// CryptoKit computes them on Apple platforms; elsewhere a small Swift implementation does, so
/// the core needs no crypto library on Linux.
package enum Hashing {
    package static func sha256(_ data: Data) -> [UInt8] {
        #if canImport(CryptoKit)
        Array(CryptoKit.SHA256.hash(data: data))
        #else
        var hasher = SHA256Hasher()
        hasher.update(data: data)
        return hasher.finalize()
        #endif
    }

    package static func sha256Hex(_ data: Data) -> String {
        sha256(data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-1, only for protocols that require it (the WebSocket accept key).
    package static func sha1(_ data: Data) -> [UInt8] {
        #if canImport(CryptoKit)
        Array(Insecure.SHA1.hash(data: data))
        #else
        PortableDigest.sha1(Array(data))
        #endif
    }

    /// SHA-256 over data fed in pieces, as when hashing a large file.
    package struct SHA256Hasher {
        #if canImport(CryptoKit)
        private var hasher = CryptoKit.SHA256()
        #else
        private var buffer: [UInt8] = []
        #endif

        package init() {}

        package mutating func update(data: Data) {
            #if canImport(CryptoKit)
            hasher.update(data: data)
            #else
            buffer.append(contentsOf: data)
            #endif
        }

        package func finalize() -> [UInt8] {
            #if canImport(CryptoKit)
            Array(hasher.finalize())
            #else
            PortableDigest.sha256(buffer)
            #endif
        }
    }
}

#if !canImport(CryptoKit)
/// FIPS 180-4 SHA-256 and SHA-1 for platforms without CryptoKit.
enum PortableDigest {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    /// The message padded to a whole number of 64-byte blocks with its bit length at the end.
    private static func padded(_ message: [UInt8]) -> [UInt8] {
        var bytes = message
        let bitLength = UInt64(message.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        return bytes
    }

    private static func word(_ bytes: [UInt8], _ index: Int) -> UInt32 {
        UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16 | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
    }

    private static func bytes(_ words: [UInt32]) -> [UInt8] {
        words.flatMap { word in [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: word >> UInt32($0)) } }
    }

    private static func rotateRight(_ value: UInt32, _ count: UInt32) -> UInt32 { (value >> count) | (value << (32 - count)) }

    static func sha256(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        let bytes = padded(message)
        var w = [UInt32](repeating: 0, count: 64)
        for block in stride(from: 0, to: bytes.count, by: 64) {
            for t in 0..<16 { w[t] = word(bytes, block + t * 4) }
            for t in 16..<64 {
                let s0 = rotateRight(w[t - 15], 7) ^ rotateRight(w[t - 15], 18) ^ (w[t - 15] >> 3)
                let s1 = rotateRight(w[t - 2], 17) ^ rotateRight(w[t - 2], 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for t in 0..<64 {
                let s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ choice &+ k[t] &+ w[t]
                let s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                hh = g; g = f; f = e; e = d &+ temp1; d = c; c = b; b = a; a = temp1 &+ temp2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
        }
        return Self.bytes(h)
    }

    static func sha1(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        let bytes = padded(message)
        var w = [UInt32](repeating: 0, count: 80)
        for block in stride(from: 0, to: bytes.count, by: 64) {
            for t in 0..<16 { w[t] = word(bytes, block + t * 4) }
            for t in 16..<80 { w[t] = rotateRight(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 31) }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for t in 0..<80 {
                let (f, constant): (UInt32, UInt32) = switch t {
                case 0..<20: ((b & c) | (~b & d), 0x5A827999)
                case 20..<40: (b ^ c ^ d, 0x6ED9EBA1)
                case 40..<60: ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                default: (b ^ c ^ d, 0xCA62C1D6)
                }
                let temp = rotateRight(a, 27) &+ f &+ e &+ constant &+ w[t]
                e = d; d = c; c = rotateRight(b, 2); b = a; a = temp
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        return Self.bytes(h)
    }
}
#endif
