import CryptoKit
import Darwin
import Foundation

enum BridgeContract {
    static let currentVersion = 1
    /// The answer of a daemon that is shutting down, given without running the
    /// request; the caller sends it again once that daemon has gone.
    static let daemonExitingCode = "daemon_exiting"
    static let serviceName = "com.playhouse.app.bridge"

    /// The login-session variables work runs with: what the XPC service this
    /// replaced received from launchd, with the caller's values. Everything else
    /// in a caller's environment (shell setup, IDE or agent session variables,
    /// per-test overrides) stays out of the daemon and its provider children;
    /// per-invocation Playhouse settings travel as `BridgeRequest` fields.
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

    /// Environment variables a test sets to point the release system at a local
    /// feed, release listing, key and install location, each sent as the named request argument.
    /// Only a test bundle's daemon honors them (see `UpdateManager`).
    static let updateOverrideArguments: [(String, String)] = [
        ("PLAYHOUSE_E2E_UPDATE_FEED_URL", "__updateFeedURL"),
        ("PLAYHOUSE_E2E_UPDATE_API_URL", "__updateReleaseAPIURL"),
        ("PLAYHOUSE_E2E_UPDATE_PUBLIC_KEY", "__updatePublicKey"),
        ("PLAYHOUSE_E2E_UPDATE_TARGET_APP", "__updateTargetApp"),
    ]

    /// The caller's environment names this request's `environment` field should
    /// carry in addition to `sessionEnvironmentNames`: in a test bundle only, its
    /// `PLAYHOUSE_E2E_*` test-fixture overrides (for example the `gh` fixture's
    /// state/call-log paths), since those names only ever exist in the test
    /// harness and would otherwise be stripped before reaching a subprocess
    /// (like `gh`) that the request spawns.
    static func environmentNamesToForward(applicationIdentifier: String, from environment: [String: String]) -> Set<String> {
        guard isTestBundle(applicationIdentifier) else { return sessionEnvironmentNames }
        return sessionEnvironmentNames.union(environment.keys.filter { $0.hasPrefix("PLAYHOUSE_E2E_") })
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
            .appendingPathComponent("playhouse-bridge", isDirectory: true)
            .appendingPathComponent(String(getuid()), isDirectory: true)
            .appendingPathComponent("\(hex.prefix(32)).sock")
    }
}

enum BridgeValue: Codable, Equatable, Sendable {
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
    var int: Int? {
        switch self {
        case .integer(let value): value
        // A CLI argument arrives as text; JSON transports may also widen it.
        case .decimal(let value): Int(exactly: value.rounded())
        case .string(let value): Int(value.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }
    var double: Double? {
        switch self {
        case .decimal(let value): value
        case .integer(let value): Double(value)
        default: nil
        }
    }
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

struct BridgeRequest: Codable, Sendable {
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

/// What a read-only side chat may do: read, and run the Playhouse CLI's board commands, never
/// edit files or run any other command. The CLI, the daemon and the app each compile this file.
///
/// Codex runs a side chat in its read-only sandbox, so the operating system stops its writes,
/// and the daemon, which runs outside that sandbox, accepts only board requests from a
/// read-only sandboxed caller (`allowsSandboxedRequest`), so the CLI can't do on its behalf
/// what the sandbox stops. Claude Code has no such sandbox, so it applies the policy to each tool call
/// twice: a `PreToolUse` hook (`playhouse-cli hook side-chat-pre-tool-use`, passed through the
/// launch's `--settings`) runs before the user's own allow rules can approve a call, and the
/// permission handler checks what Claude Code still asks about. A user who turns off every
/// Claude Code hook (`disableAllHooks`) is left with the permission handler alone.
enum SideChatReadOnlyPolicy {
    static let hookSubcommand = ["hook", "side-chat-pre-tool-use"]
    static let deniedTools = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    /// The CLI commands of the side chat's audience, which its help lists: `help` and the
    /// read-only board commands, never a turn, outcome, progress or repository command, which
    /// belong to the task's own conversation.
    static let allowedCLICommands = CLICommandCatalog.commands
        .filter { $0.audiences.contains(.sideChat) }
        .flatMap(\.expandedPaths)
        .reduce(into: [String]()) { paths, path in if !paths.contains(path) { paths.append(path) } }
    static let denialMessage = "This side chat is read-only: it can read files and run the Playhouse CLI's board commands (\(allowedCLICommands.joined(separator: ", "))), one per shell call, but it can't change files or run other commands."

    /// `cliPaths` are the forms of the CLI's path a command may start with (as given and with
    /// symlinks such as /tmp resolved).
    static func allows(toolName: String, input: [String: Any], cliPaths: [String]) -> Bool {
        guard !deniedTools.contains(toolName) else { return false }
        guard toolName == "Bash" else { return true }
        let command = (input["command"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runsAnotherCommand(command) else { return false }
        // The instructions quote the path, so the command starts with it, quoted or not.
        let paths = Set(cliPaths + cliPaths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        let invocations = paths.flatMap { [$0, "'\($0)'", "\"\($0)\""] }
        guard let invocation = invocations.first(where: { command.hasPrefix($0 + " ") }) else { return false }
        let subcommand = command.dropFirst(invocation.count + 1).trimmingCharacters(in: .whitespaces)
        // As `allowsSandboxedRequest` does for Codex, a saved prompt can't also move or start its task.
        if subcommand.hasPrefix("task prompt "), subcommand.contains("--status") || subcommand.contains("--submitted") { return false }
        return allowedCLICommands.contains { subcommand == $0 || subcommand.hasPrefix($0 + " ") }
    }

    /// Whether a shell command would run more than its first command: a separator, pipe,
    /// background `&`, redirection or command substitution outside single quotes (inside
    /// double quotes only substitution still runs), or a quote left open. Text a quoted
    /// argument carries, such as a task description, may contain any of them.
    static func runsAnotherCommand(_ command: String) -> Bool {
        var quote: Character?
        var escaped = false
        var previous: Character?
        for character in command {
            defer { previous = character }
            if escaped { escaped = false; continue }
            switch quote {
            case "'":
                if character == "'" { quote = nil }
            case "\"":
                if character == "\\" { escaped = true }
                else if character == "\"" { quote = nil }
                else if character == "`" || (previous == "$" && character == "(") { return true }
            default:
                if character == "\\" { escaped = true }
                else if character == "'" || character == "\"" { quote = character }
                else if ";&|<>`\n".contains(character) || (previous == "$" && character == "(") { return true }
            }
        }
        return quote != nil || escaped
    }

    /// The `PreToolUse` hook's answer for one tool call Claude Code describes in `hookInput`:
    /// a denial, or nil to let Claude Code's own permission flow continue.
    /// Input it can't read is denied, so a call never passes for want of a description.
    static func hookOutput(for hookInput: Data, cliPaths: [String]) -> Data? {
        let input = (try? JSONSerialization.jsonObject(with: hookInput)) as? [String: Any] ?? [:]
        let toolName = input["tool_name"] as? String ?? ""
        guard toolName.isEmpty || !allows(toolName: toolName, input: input["tool_input"] as? [String: Any] ?? [:], cliPaths: cliPaths) else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["hookSpecificOutput": [
            "hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": denialMessage,
        ]], options: [.sortedKeys])
    }
}

extension SideChatReadOnlyPolicy {
    static let sandboxedCallerMessage = "A caller in a read-only sandbox, such as a side chat, can only make board requests: task list, get, create, rename and prompt (without a status or submission), and workspace repos list."

    /// The bridge requests a caller in a read-only sandbox may make: the board commands `allowedCLICommands`
    /// lists, as the CLI sends them. A saved prompt can't also move or start its task.
    static func allowsSandboxedRequest(_ request: BridgeRequest) -> Bool {
        switch request.command {
        case "task.list", "task.get", "task.create", "task.rename", "workspace.repositories.list":
            return true
        case "task.prompt.save":
            return request.arguments["status"] == nil && request.arguments["submitted"] == nil
        default:
            return false
        }
    }
}
