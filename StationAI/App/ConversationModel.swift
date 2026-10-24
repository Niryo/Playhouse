import Darwin
import Foundation

extension ConversationProvider {
    /// The model StationAI requests when the user hasn't picked one.
    var defaultModelID: String {
        switch self {
        case .codex: CodexAppServerClient.modelID
        case .claude: ClaudeCodeClient.defaultModelID
        }
    }

    /// A fast model for one-shot helper turns such as title generation.
    var titleModelID: String {
        switch self {
        case .codex: CodexAppServerClient.modelID
        case .claude: ClaudeCodeClient.titleModelID
        }
    }

    var defaultModelName: String {
        switch self {
        case .codex: "GPT-6 Luna"
        case .claude: "Default"
        }
    }

    /// The short name shown above assistant messages.
    var assistantLabel: String {
        switch self {
        case .codex: "Codex · Luna"
        case .claude: "Claude"
        }
    }

    /// Goals are a Codex app-server feature with no Claude Code equivalent.
    var supportsGoals: Bool { self == .codex }

    static func parse(_ value: String) throws -> ConversationProvider {
        guard let provider = ConversationProvider(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            throw BridgeCommandError(
                code: "invalid_argument",
                message: "Unknown conversation provider '\(value)'. Valid providers: \(allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        return provider
    }
}

enum ConversationRole: String, Codable, Equatable {
    case user
    case assistant
}

struct ConversationMessage: Codable, Identifiable, Equatable {
    let id: String
    let role: ConversationRole
    var text: String
    var imageDataURLs: [String]
    var phase: String?
    var turnID: String?
    var timelineOrder: Int?
    var asyncQuestions: [ConversationAsyncQuestion]?
    /// The runtime that produced an assistant message, or received a user message.
    /// Nil for transcripts saved before StationAI supported more than Codex.
    var provider: ConversationProvider?

    init(id: String, role: ConversationRole, text: String, imageDataURLs: [String] = [], phase: String? = nil, turnID: String? = nil, timelineOrder: Int? = nil, asyncQuestions: [ConversationAsyncQuestion]? = nil, provider: ConversationProvider? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.imageDataURLs = imageDataURLs
        self.phase = phase
        self.turnID = turnID
        self.timelineOrder = timelineOrder
        self.asyncQuestions = asyncQuestions
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey { case id, role, text, imageDataURLs, phase, turnID, timelineOrder, asyncQuestions, provider }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(ConversationRole.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        imageDataURLs = try container.decodeIfPresent([String].self, forKey: .imageDataURLs) ?? []
        phase = try container.decodeIfPresent(String.self, forKey: .phase)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        timelineOrder = try container.decodeIfPresent(Int.self, forKey: .timelineOrder)
        asyncQuestions = try container.decodeIfPresent([ConversationAsyncQuestion].self, forKey: .asyncQuestions)
        provider = try container.decodeIfPresent(ConversationProvider.self, forKey: .provider)
    }
}

struct ConversationAsyncQuestion: Codable, Equatable {
    let title: String
    let options: [String]?
}

struct ConversationUserQuestion: Identifiable, Codable, Equatable {
    struct Option: Identifiable, Codable, Equatable {
        let label: String
        let description: String?
        var id: String { label }
    }
    let id: String
    let header: String
    let question: String
    let options: [Option]
    let allowsOther: Bool
    let isSecret: Bool
}

struct ConversationUserInputRequest: Identifiable, Codable, Equatable {
    let id: String
    let threadID: String
    let questions: [ConversationUserQuestion]
    let isBlocking: Bool
}

enum ConversationMode: String, CaseIterable, Hashable {
    case code = "default"
    case plan

    var title: String {
        switch self {
        case .code: "Code mode"
        case .plan: "Plan mode"
        }
    }
}

struct ConversationModelOption: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let isDefault: Bool
}

/// A divider shown where a task's conversation moved to another provider.
struct ConversationProviderBoundary: Codable, Equatable, Identifiable {
    let id: String
    let provider: ConversationProvider
    /// The message the divider follows; nil places it before the first message.
    let afterMessageID: String?
}

/// The operations StationAI's shared conversation orchestration needs from a
/// provider runtime. Codex and Claude Code each implement it over their own
/// native protocol; history composition and persistence stay in the manager.
@MainActor
protocol ConversationProviderClient: AnyObject {
    var provider: ConversationProvider { get }
    var wasLastTurnInterrupted: Bool { get }
    var isPreparingForApplicationTermination: Bool { get }
    var lastTurnActivityDurations: [String: Int] { get }

    func diagnosticFields(_ additionalFields: [String: String]) -> [String: String]
    func startThread(workspace: ConversationWorkspaceContext, modelID: String, developerInstructions: String?) async throws -> String
    func availableModels(workspace: ConversationWorkspaceContext) async throws -> [ConversationModelOption]
    func sendMessage(
        _ text: String,
        imageDataURLs: [String],
        mode: ConversationMode,
        modelID: String,
        threadID: String,
        workspace: ConversationWorkspaceContext,
        developerInstructions: String?,
        onDelta: @escaping (String) -> Void,
        onFinalMessage: @escaping (String) -> Void,
        onActivity: @escaping (ConversationActivity) -> Void,
        onDiff: @escaping (ConversationTurnDiff) -> Void,
        onHistory: @escaping (ConversationHistory) -> Void,
        onActionRequest: @escaping () -> Void,
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void,
        onSteerMessage: @escaping (String, [String]) -> Void,
        onProgressMessage: @escaping (ConversationMessage) -> Void
    ) async throws
    func interruptActiveTurn(threadID: String) async throws -> Bool
    func steerActiveTurn(threadID: String, text: String, imageDataURLs: [String]) async throws -> Bool
    func answerUserInput(requestID: String, threadID: String, answers: [String: [String]]) -> Bool
    func rejectUserInput(requestID: String, threadID: String, message: String)
    func isTurnActive(threadID: String) -> Bool
    func isTurnActiveInProcess(threadID: String) -> Bool
    func canInterruptActiveTurn(threadID: String) -> Bool
    func activeTurnOwnerProcessID(threadID: String) -> Int32?
    func markTurnStarting(threadID: String)
    func clearTurnStarting(threadID: String)
    func beginConversationOperation()
    func finishConversationOperation()
    func prepareForApplicationTermination() async
    func shutdown()
    /// A separate client for one-shot helper turns such as title generation.
    func makeAuxiliaryClient() -> ConversationProviderClient
    /// Whether an error means this provider can't run here at all (not
    /// installed, can't start, or not signed in), rather than a failed turn.
    func isProviderUnavailable(_ error: Error) -> Bool
}

extension ConversationProviderClient {
    func diagnosticFields() -> [String: String] { diagnosticFields([:]) }

    func sendMessage(
        _ text: String,
        imageDataURLs: [String] = [],
        mode: ConversationMode,
        modelID: String,
        threadID: String,
        workspace: ConversationWorkspaceContext,
        developerInstructions: String? = nil,
        onFinalMessage: @escaping (String) -> Void,
        onUserInput: @escaping (ConversationUserInputRequest) async -> Void = { _ in }
    ) async throws {
        try await sendMessage(
            text, imageDataURLs: imageDataURLs, mode: mode, modelID: modelID, threadID: threadID,
            workspace: workspace, developerInstructions: developerInstructions,
            onDelta: { _ in }, onFinalMessage: onFinalMessage, onActivity: { _ in }, onDiff: { _ in },
            onHistory: { _ in }, onActionRequest: {}, onUserInput: onUserInput,
            onSteerMessage: { _, _ in }, onProgressMessage: { _ in }
        )
    }
}

/// One client per provider, shared by a window or a single bridge request.
@MainActor
struct ConversationClients {
    let codex: CodexAppServerClient
    let claude: ClaudeCodeClient

    func client(for provider: ConversationProvider) -> ConversationProviderClient {
        switch provider {
        case .codex: codex
        case .claude: claude
        }
    }

    var all: [ConversationProviderClient] { [codex, claude] }

    /// Separate clients for one-shot helper turns: the task's provider first,
    /// then the other provider for when the preferred one is unavailable.
    func helperClients(preferring provider: ConversationProvider) -> [ConversationProviderClient] {
        let preferred = client(for: provider)
        return [preferred.makeAuxiliaryClient()] + all.filter { $0.provider != provider }.map { $0.makeAuxiliaryClient() }
    }
}

private struct ConversationSteerMailboxRequest: Codable {
    let id: String
    let threadID: String
    let expectedTurnID: String
    let text: String
    var imageDataURLs: [String]? = []
    /// "interrupt" asks the owner to stop its turn; absent means steer.
    var kind: String? = nil
}

private struct ConversationSteerMailboxActiveTurn: Codable {
    let threadID: String
    let turnID: String
    let processID: Int32
}

private struct ConversationSteerMailboxResponse: Codable {
    let accepted: Bool
    let error: String?
}

struct ConversationSteerMailboxError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// File-based handoff that lets another StationAI process (usually the CLI)
/// steer a turn owned by the app. The turn owner publishes its active turn
/// and services requests; any provider can use it because thread and session
/// IDs are globally unique.
@MainActor
enum ConversationSteerMailbox {
    private static var directory: URL?

    static func configure(directory: URL) {
        self.directory = directory
    }

    static func requestSteer(threadID: String, text: String, imageDataURLs: [String]) async throws -> Bool {
        try await request(threadID: threadID, text: text, imageDataURLs: imageDataURLs, kind: nil)
    }

    /// Asks the process that owns the thread's active turn to stop it.
    static func requestInterrupt(threadID: String) async throws -> Bool {
        try await request(threadID: threadID, text: "", imageDataURLs: [], kind: "interrupt")
    }

    private static func request(threadID: String, text: String, imageDataURLs: [String], kind: String?) async throws -> Bool {
        guard let directory else { return false }
        let activeURL = activeTurnURL(threadID: threadID, directory: directory)
        guard FileManager.default.fileExists(atPath: activeURL.path) else { return false }
        let activeTurn = try JSONDecoder().decode(ConversationSteerMailboxActiveTurn.self, from: Data(contentsOf: activeURL))
        guard activeTurn.threadID == threadID else { return false }
        guard Darwin.kill(activeTurn.processID, 0) == 0 || errno == EPERM else {
            try? FileManager.default.removeItem(at: activeURL)
            return false
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = Darwin.chmod(directory.path, mode_t(0o700))
        let requestID = UUID().uuidString
        let requestURL = directory.appendingPathComponent("\(requestID).request.json")
        let responseURL = directory.appendingPathComponent("\(requestID).response.json")
        let request = ConversationSteerMailboxRequest(id: requestID, threadID: threadID, expectedTurnID: activeTurn.turnID, text: text, imageDataURLs: imageDataURLs, kind: kind)
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        _ = Darwin.chmod(requestURL.path, mode_t(0o600))
        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: responseURL)
        }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: responseURL.path) {
                let response = try JSONDecoder().decode(ConversationSteerMailboxResponse.self, from: Data(contentsOf: responseURL))
                if let error = response.error {
                    throw ConversationSteerMailboxError(message: error)
                }
                return response.accepted
            }
            if !FileManager.default.fileExists(atPath: activeURL.path) { return false }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Answers pending requests for the owner's active turn. `steer` and
    /// `interrupt` return whether the runtime accepted the request; a thrown
    /// error is reported back.
    static func service(
        threadID: String,
        turnID: String,
        steer: (String, [String]) async throws -> Bool,
        interrupt: () async throws -> Bool
    ) async {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for requestURL in files where requestURL.lastPathComponent.hasSuffix(".request.json") {
            guard let request = try? JSONDecoder().decode(ConversationSteerMailboxRequest.self, from: Data(contentsOf: requestURL)),
                  request.threadID == threadID else { continue }
            let claimedURL = directory.appendingPathComponent("\(request.id).claimed.json")
            do { try FileManager.default.moveItem(at: requestURL, to: claimedURL) }
            catch { continue }
            let responseURL = directory.appendingPathComponent("\(request.id).response.json")
            let response: ConversationSteerMailboxResponse
            if request.expectedTurnID != turnID {
                response = ConversationSteerMailboxResponse(accepted: false, error: nil)
            } else {
                do {
                    let accepted = request.kind == "interrupt"
                        ? try await interrupt()
                        : try await steer(request.text, request.imageDataURLs ?? [])
                    response = ConversationSteerMailboxResponse(accepted: accepted, error: nil)
                } catch {
                    response = ConversationSteerMailboxResponse(accepted: false, error: error.localizedDescription)
                }
            }
            if let data = try? JSONEncoder().encode(response) {
                try? data.write(to: responseURL, options: .atomic)
            }
            try? FileManager.default.removeItem(at: claimedURL)
        }
    }

    static func publishActiveTurn(threadID: String, turnID: String) {
        guard let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = Darwin.chmod(directory.path, mode_t(0o700))
            let data = try JSONEncoder().encode(ConversationSteerMailboxActiveTurn(
                threadID: threadID,
                turnID: turnID,
                processID: Int32(ProcessInfo.processInfo.processIdentifier)
            ))
            let url = activeTurnURL(threadID: threadID, directory: directory)
            try data.write(to: url, options: .atomic)
            _ = Darwin.chmod(url.path, mode_t(0o600))
        } catch {
            StationAIDiagnostics.record("conversation.steer_mailbox.publish_failed", fields: ["threadID": threadID])
        }
    }

    static func clearActiveTurn(threadID: String) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: activeTurnURL(threadID: threadID, directory: directory))
    }

    /// The live process that published an active turn for this thread, if any.
    static func activeTurnOwnerProcessID(threadID: String) -> Int32? {
        guard let directory else { return nil }
        let activeURL = activeTurnURL(threadID: threadID, directory: directory)
        guard let active = try? JSONDecoder().decode(ConversationSteerMailboxActiveTurn.self, from: Data(contentsOf: activeURL)),
              active.threadID == threadID else { return nil }
        guard Darwin.kill(active.processID, 0) == 0 || errno == EPERM else {
            try? FileManager.default.removeItem(at: activeURL)
            return nil
        }
        return active.processID
    }

    private static func activeTurnURL(threadID: String, directory: URL) -> URL {
        let key = threadID.utf8.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("active-\(key).json")
    }
}

/// Shared child-process environment for provider CLIs.
@MainActor
enum ConversationProcessEnvironment {
    /// Lets a provider's child process run `stationai` back into this app's service.
    /// The child inherits the launching process's environment (the GUI app or the
    /// XPC service), not the CLI caller's, so the service name and store directory
    /// must be passed on explicitly. The app identity is the same in both processes.
    static func forwardStationAIBridgeEnvironment(_ environment: inout [String: String]) {
        if environment["STATIONAI_BRIDGE_SERVICE_NAME"] == nil {
            environment["STATIONAI_BRIDGE_SERVICE_NAME"] = BridgeContract.serviceName(
                forApplication: StationAIAppIdentity.applicationIdentifier
            )
        }
        if environment["STATIONAI_DATA_DIRECTORY"] == nil {
            environment["STATIONAI_DATA_DIRECTORY"] = StationAIDiagnostics.storeURL.deletingLastPathComponent().path
        }
    }
}

/// A provider executable override is honored only inside a directory that a
/// StationAI test fixture owns, so the environment can't redirect real turns.
enum ConversationProviderFixture {
    static func ownedExecutable(_ path: String?, providerMarker: (name: String, value: String)) -> String? {
        guard let path, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let markers = [providerMarker, (".stationai-bridge-fixture", "StationAI bridge tests own this deterministic fixture (v1).\n")]
        for (name, value) in markers {
            if (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) == value { return path }
        }
        return nil
    }
}

/// A model occasionally writes its final `stationai-cli task outcome` command as
/// answer text instead of running it. A trailing echo of that command is removed
/// from the visible answer and still counts as the turn's reported outcome.
enum LeakedTurnOutcome {
    private static let pattern: NSRegularExpression = {
        let executable = NSRegularExpression.escapedPattern(for: TaskProgressReportInstructions.executableName)
        let subcommand = TaskProgressReportInstructions.outcomeSubcommand
            .split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: #"\s+"#)
        return try! NSRegularExpression(pattern:
            #"[\p{So}\x{FE0F}\s`]*\n[\p{So}\x{FE0F}\s`$>]*(?:'[^'\n]*|[^\s'`]*)"# + executable + #"'?\s+"# + subcommand
            + #"\s+([0-9A-Fa-f-]{36})\s+(completed|waiting-response)[\s`.]*\z"#)
    }()

    static func split(_ text: String) -> (text: String, taskID: UUID?, outcome: String?) {
        // The leading newline lets an answer that is only the echoed command match too.
        let candidate = "\n" + text
        guard let match = pattern.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
              let echo = Range(match.range, in: candidate),
              let id = Range(match.range(at: 1), in: candidate),
              let outcome = Range(match.range(at: 2), in: candidate) else {
            return (text, nil, nil)
        }
        let visible = candidate[..<echo.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return (visible, UUID(uuidString: String(candidate[id])), String(candidate[outcome]))
    }

    static func visibleText(_ text: String) -> String { split(text).text }
}
