import Foundation
import SwiftData

// Supplemental assertion for the paired CLI/XPC question case. Compile this
// with the same production core as the XPC service; no replacement managers.
@main
struct CodexQuestionOwnershipProbe {
    @MainActor static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "CodexQuestionOwnershipProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    @MainActor static func wait(_ message: String, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try check(predicate(), message)
    }

    @MainActor static func main() async throws {
        let arguments = CommandLine.arguments
        try check(arguments.count == 5, "Expected data directory, owned peer executable, and two task IDs.")
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let marker = directory.appendingPathComponent(".stationai-codex-fixture-owner")
        try check(try String(contentsOf: marker, encoding: .utf8) == "StationAI test owns this Codex protocol fixture (v1).\n", "Refusing unowned test data.")
        guard let originalID = UUID(uuidString: arguments[3]), let parallelID = UUID(uuidString: arguments[4]) else {
            throw NSError(domain: "CodexQuestionOwnershipProbe", code: 2)
        }
        let schema = Schema([BoardTask.self])
        let configuration = ModelConfiguration(schema: schema, url: directory.appendingPathComponent("StationAI-v2.store"))
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let tasks = BoardTaskManager(modelContext: container.mainContext)
        let codex = CodexAppServerClient(codexExecutableOverride: arguments[2], goalRuntimeEnabled: true)
        defer { codex.shutdown() }
        let suite = ProcessInfo.processInfo.environment["STATIONAI_E2E_DEFAULTS_SUITE"]!
        let preferences = UserDefaults(suiteName: suite)!
        let manager = ConversationManager(tasks: tasks, clients: ConversationClients(codex: codex, claude: ClaudeCodeClient()), preferences: preferences)
        var requests: [UUID: [ConversationUserInputRequest]] = [:]
        func receive(_ taskID: UUID, _ update: ConversationUpdate) {
            if update.type == "user_input", let request = update.userInputRequest { requests[taskID, default: []].append(request) }
        }
        let originalSend = Task { @MainActor in
            try await manager.send(taskID: originalID, text: "Ask original questions.", mode: .plan, onUpdate: { receive(originalID, $0) })
        }
        try await wait("Original question missing.") { requests[originalID]?.count == 1 }
        let original = requests[originalID]![0]
        try check(try tasks.get(originalID).status == TaskStatus.waitingResponse.rawValue, "Blocking original question did not enter Waiting Response.")
        let parallelSend = Task { @MainActor in
            try await manager.send(taskID: parallelID, text: "Ask parallel questions.", mode: .code, onUpdate: { receive(parallelID, $0) })
        }
        try await wait("Parallel question missing.") { requests[parallelID]?.count == 1 }
        let parallel = requests[parallelID]![0]
        try check(try tasks.get(parallelID).status == TaskStatus.inProgress.rawValue, "Nonblocking parallel question interrupted its task.")
        try check(original.threadID != parallel.threadID, "Two conversations must use different threads.")
        try check(original.mode == .plan && original.isBlocking, "Original request lost Plan mode.")
        try check(parallel.mode == .code && !parallel.isBlocking, "Parallel request borrowed original mode.")
        let store = try tasks.conversationTranscriptStore()
        try check(try store.read(originalID).pendingUserInputRequest == original, "Original request persisted under wrong task.")
        try check(try store.read(parallelID).pendingUserInputRequest == parallel, "Parallel request persisted under wrong task.")
        // Exercise history switching on the GUI-configured shared production client.
        _ = try await manager.history(taskID: parallelID)
        _ = try await manager.history(taskID: originalID)
        let answers = ["color": ["Blue"], "token": ["fixture-secret"]]
        try check(try await manager.answerUserInput(taskID: originalID, request: original, answers: answers), "Original answer rejected.")
        try check(try tasks.get(originalID).status == TaskStatus.inProgress.rawValue, "Answer did not resume original task in In Progress.")
        try await wait("Original followup missing after parallel callback installed.") { requests[originalID]?.count == 2 }
        let followup = requests[originalID]![1]
        try check(try tasks.get(originalID).status == TaskStatus.waitingResponse.rawValue, "Blocking followup did not enter Waiting Response.")
        try check(followup.threadID == original.threadID && followup.mode == .plan && followup.id != original.id, "Original followup lost its owner, identity, or mode.")
        try check(try store.read(originalID).pendingUserInputRequest == followup, "Followup persisted under the parallel task.")
        try check(try store.read(parallelID).pendingUserInputRequest == parallel, "Followup replaced parallel question.")
        try check(try await manager.answerUserInput(taskID: originalID, request: followup, answers: answers), "Original followup answer rejected.")
        try check(try tasks.get(originalID).status == TaskStatus.inProgress.rawValue, "Followup answer did not resume original task.")
        _ = try await originalSend.value
        try check(try store.read(parallelID).pendingUserInputRequest == parallel, "Completing original task cleared parallel question.")
        do {
            _ = try await manager.answerUserInput(taskID: parallelID, request: parallel, answers: ["color": ["Blue"]])
            try check(false, "Incomplete parallel answer accepted.")
        } catch let error as BridgeCommandError {
            try check(error.code == "invalid_argument", "Incomplete answer returned wrong validation code.")
        }
        try check(try store.read(parallelID).pendingUserInputRequest == parallel, "Invalid answer cleared parallel question.")
        try check(try await manager.answerUserInput(taskID: parallelID, request: parallel, answers: answers), "Parallel answer rejected after original completion.")
        _ = try await parallelSend.value
        for id in [originalID, parallelID] {
            try check(try store.read(id).pendingUserInputRequest == nil, "Answered request remained pending.")
            // The answered turns report no outcome, so their status nudges run out into Blocked.
            try check(try tasks.get(id).status == TaskStatus.blocked.rawValue, "Answered task did not settle in Blocked.")
        }
        print("{\"sharedClientQuestionOwnership\":true,\"originalQuestions\":2,\"parallelQuestions\":1}")
    }
}
