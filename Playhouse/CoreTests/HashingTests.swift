import Foundation
import XCTest
@testable import PlayhouseCore

/// Known-answer vectors, so the portable implementation used without CryptoKit (Linux) is
/// checked against the same answers as CryptoKit.
final class HashingTests: XCTestCase {
    func testSHA256KnownAnswers() {
        XCTAssertEqual(Hashing.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(Hashing.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(
            Hashing.sha256Hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testSHA256IncrementalMatchesOneShot() {
        let data = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        var hasher = Hashing.SHA256Hasher()
        hasher.update(data: data.prefix(4_097))
        hasher.update(data: data.dropFirst(4_097))
        XCTAssertEqual(hasher.finalize(), Hashing.sha256(data))
    }

    func testSHA1KnownAnswer() {
        // The WebSocket handshake's example key and accept value (RFC 6455, section 1.3).
        let accept = Data(Hashing.sha1(Data("dGhlIHNhbXBsZSBub25jZQ==258EAFA5-E914-47DA-95CA-C5AB0DC85B11".utf8))).base64EncodedString()
        XCTAssertEqual(accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }
}
