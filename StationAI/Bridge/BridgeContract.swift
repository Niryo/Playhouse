import CryptoKit
import Darwin
import Foundation

enum BridgeContract {
    static let currentVersion = 1
    static let serviceName = "com.stationai.app.bridge"

    /// The login-session variables work runs with: what the XPC service this
    /// replaced received from launchd, with the caller's values. Everything else
    /// in a caller's environment (shell setup, IDE or agent session variables,
    /// per-test overrides) stays out of the daemon and its provider children;
    /// per-invocation StationAI settings travel as `BridgeRequest` fields.
    static let sessionEnvironmentNames: Set<String> = [
        "HOME", "LANG", "LOGNAME", "PATH", "SHELL", "SSH_AUTH_SOCK", "TMPDIR", "USER", "__CF_USER_TEXT_ENCODING",
    ]

    /// The daemon's launchd label is named after its app (see scripts/build-bridge.sh).
    static func serviceName(forApplication applicationIdentifier: String) -> String {
        applicationIdentifier.isEmpty ? serviceName : applicationIdentifier + ".bridge"
    }

    /// True only for a DEBUG build whose bundle identifier marks it as this
    /// repository's e2e/UI test harness build (see `scripts/prepare-e2e-build.py`
    /// and `scripts/app-profile.sh`), never for a normally-signed Release build.
    /// Shared by the app, CLI, and daemon — each compiles this file separately
    /// (see `scripts/build-bridge.sh`) — so all three agree on when test-only
    /// overrides are safe to honor.
    static func isTestBundle(_ applicationIdentifier: String) -> Bool {
        #if DEBUG
        return applicationIdentifier.contains(".e2e.")
        #else
        return false
        #endif
    }

    /// The caller's environment names this request's `environment` field should
    /// carry in addition to `sessionEnvironmentNames`: in a test bundle only, its
    /// `STATIONAI_E2E_*` test-fixture overrides (for example the `gh` fixture's
    /// state/call-log paths), since those names only ever exist in the test
    /// harness and would otherwise be stripped before reaching a subprocess
    /// (like `gh`) that the request spawns.
    static func environmentNamesToForward(applicationIdentifier: String, from environment: [String: String]) -> Set<String> {
        guard isTestBundle(applicationIdentifier) else { return sessionEnvironmentNames }
        return sessionEnvironmentNames.union(environment.keys.filter { $0.hasPrefix("STATIONAI_E2E_") })
    }

    /// A Unix domain socket's path is limited to ~104 bytes on macOS
    /// (`sizeof(sockaddr_un.sun_path)`), which a per-worktree-profile path under
    /// `~/Library/Application Support/...` can exceed. The socket lives at a short,
    /// content-derived path under `/tmp` rather than `$TMPDIR`: every process of
    /// this user must agree on it, and `TMPDIR` differs between a login shell,
    /// the app, and a test runner. The directory is private to this user.
    static func socketURL(forServiceName serviceName: String) -> URL {
        let digest = SHA256.hash(data: Data(serviceName.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("stationai-bridge", isDirectory: true)
            .appendingPathComponent(String(getuid()), isDirectory: true)
            .appendingPathComponent("\(hex.prefix(32)).sock")
    }
}

enum BridgeValue: Codable, Equatable {
    case string(String)
    case integer(Int)
    case decimal(Double)
    case boolean(Bool)
    case array([BridgeValue])
    case object([String: BridgeValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .decimal(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([BridgeValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: BridgeValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .decimal(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .boolean(let value) = self { value } else { nil } }
    var strings: [String]? {
        guard case .array(let values) = self else { return nil }
        let strings = values.compactMap(\.string)
        return strings.count == values.count ? strings : nil
    }
    var object: [String: BridgeValue]? { if case .object(let value) = self { value } else { nil } }
}

extension BridgeValue {
    /// This value as a model type, going through the same JSON it was encoded from.
    func decoded<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try BridgeFraming.decoder.decode(T.self, from: JSONEncoder().encode(self))
    }

    static func encoding<T: Encodable>(_ value: T) throws -> BridgeValue {
        try JSONDecoder().decode(BridgeValue.self, from: BridgeFraming.encoder.encode(value))
    }
}

struct BridgeRequest: Codable {
    var version = BridgeContract.currentVersion
    var id = UUID().uuidString
    var command: String
    var arguments: [String: BridgeValue] = [:]
    var dataDirectory: String?
    var defaultsSuite: String?
    var worktreeDirectory: String?
    /// The caller's `BridgeContract.sessionEnvironmentNames` values. The daemon
    /// serves many callers from one long-lived process, so work done for this
    /// request (executable lookup, `git`/`gh`, provider launches) uses these
    /// rather than those of whichever caller happened to start it. Never logged.
    var environment: [String: String]?
}

struct BridgeFailure: Codable, Equatable {
    let code: String
    let message: String
}

struct BridgeResponse: Codable {
    let version: Int
    let id: String
    let ok: Bool
    let result: BridgeValue?
    let error: BridgeFailure?

    static func success(_ request: BridgeRequest, result: BridgeValue) -> BridgeResponse {
        BridgeResponse(version: BridgeContract.currentVersion, id: request.id, ok: true, result: result, error: nil)
    }

    static func failure(_ request: BridgeRequest, code: String, message: String) -> BridgeResponse {
        BridgeResponse(
            version: BridgeContract.currentVersion,
            id: request.id,
            ok: false,
            result: nil,
            error: BridgeFailure(code: code, message: message)
        )
    }
}

struct BridgeEvent: Codable {
    let version: Int
    let requestID: String
    let type: String
    let payload: BridgeValue

    init(requestID: String, type: String, payload: BridgeValue) {
        version = BridgeContract.currentVersion
        self.requestID = requestID
        self.type = type
        self.payload = payload
    }
}

/// One connection carries exactly one `BridgeRequest`, followed by zero or more
/// `.event` frames streamed while it runs, followed by exactly one `.response`
/// frame. Framed as a 4-byte big-endian length prefix + JSON payload so a reader
/// can tell where one message ends and the next begins over a byte stream.
enum BridgeWireMessage: Codable {
    case event(BridgeEvent)
    case response(BridgeResponse)

    private enum Kind: String, Codable { case event, response }
    private enum CodingKeys: String, CodingKey { case kind, value }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .event: self = .event(try container.decode(BridgeEvent.self, forKey: .value))
        case .response: self = .response(try container.decode(BridgeResponse.self, forKey: .value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .event(let event):
            try container.encode(Kind.event, forKey: .kind)
            try container.encode(event, forKey: .value)
        case .response(let response):
            try container.encode(Kind.response, forKey: .kind)
            try container.encode(response, forKey: .value)
        }
    }
}

/// Length-prefixed JSON framing shared by both directions of the connection: a
/// client frames a single `BridgeRequest`; the daemon frames a stream of
/// `BridgeWireMessage`s back. Generic so both sides use the exact same byte
/// format without the two ends being able to drift apart.
enum BridgeFraming {
    struct FramingError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A single value as a length-prefixed byte frame.
    static func frame(_ value: some Encodable) throws -> Data {
        let payload = try Self.encoder.encode(value)
        guard payload.count <= UInt32.max else {
            throw FramingError(message: "Bridge message is too large to frame (\(payload.count) bytes).")
        }
        var length = UInt32(payload.count).bigEndian
        var framed = Data(bytes: &length, count: 4)
        framed.append(payload)
        return framed
    }

    /// Drains every complete frame currently in `buffer`, removing their bytes
    /// (including the length prefix) and leaving only a trailing partial frame,
    /// if any, for the next read to complete.
    static func extractMessages<T: Decodable>(from buffer: inout Data, as type: T.Type) throws -> [T] {
        var messages: [T] = []
        while buffer.count >= 4 {
            let lengthBytes = buffer.prefix(4)
            let length = Int(lengthBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
            guard buffer.count >= 4 + length else { break }
            let payloadStart = buffer.startIndex + 4
            let payloadEnd = payloadStart + length
            let payload = buffer.subdata(in: payloadStart..<payloadEnd)
            messages.append(try decoder.decode(T.self, from: payload))
            buffer.removeSubrange(buffer.startIndex..<payloadEnd)
        }
        return messages
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
