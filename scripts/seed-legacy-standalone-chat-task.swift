import Foundation
import SwiftData

// The persisted properties match the BoardTask model from before the standalone chat was
// split into its own `StandaloneChat` model — including the original `isStandaloneChat`
// column and no StandaloneChat entity in the schema. Keep the class name: SwiftData uses it
// for the entity and model hash, so this produces a genuinely pre-split store rather than a
// current-schema one. That is what makes the test exercise SwiftData's lightweight migration
// across both the added entity and the `@Attribute(originalName: "isStandaloneChat")` rename.
@Model final class BoardTask {
    var id: UUID
    var title: String
    var statusRawValue: String
    var lifecycleRevision: Int = 0
    var statusMessage: String?
    var progressTypeRawValue: String?
    var progressLabel: String?
    var progressDetail: String?
    var createdAt: Date
    var inProgressStartedAt: Date?
    var totalInProgressSeconds: Double = 0
    var codexThreadID: String?
    var claudeSessionID: String?
    var conversationProviderRawValue: String?
    var conversationEffortRawValue: String?
    var conversationModelIDsData: Data?
    var savedPrompt: String?
    var pendingSubmittedPrompt: String?
    var workspaceRootPathsData: Data?
    var repositoryWorktreesData: Data?
    var contextFolderPathsData: Data?
    var draftImageDataURLsData: Data?
    var conversationActivityDurationsData: Data?
    var answeredAsyncQuestionIDsData: Data?
    var isStandaloneChat: Bool = false

    init(claudeSessionID: String) {
        id = UUID()
        title = "Chat"
        // Seed a chat captured mid-turn: the migration must carry the turn state's
        // explanation and timing across, not just the raw status.
        statusRawValue = "In Progress"
        statusMessage = "Carried from the legacy chat task."
        progressTypeRawValue = "searching"
        progressLabel = "Searching"
        progressDetail = "Looking into volcanoes"
        createdAt = .now
        inProgressStartedAt = Date(timeIntervalSince1970: 1_700_000_000)
        totalInProgressSeconds = 42
        self.claudeSessionID = claudeSessionID
        conversationProviderRawValue = "codex"
        conversationEffortRawValue = "medium"
        isStandaloneChat = true
    }
}

/// Recreates the pre-split state: a standalone chat stored as a hidden board task.
///
/// Used to verify the one-time migration converts that row into the dedicated `StandaloneChat`
/// model, keeping its ID so the existing conversation transcript stays attached, and removes
/// the board row so it can never render as a card.
@main
@MainActor
struct SeedLegacyStandaloneChatTask {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard (1...2).contains(arguments.count) else { throw SeedError.usage }

        let dataDirectory = URL(fileURLWithPath: arguments[0], isDirectory: true)
        let storeURL = dataDirectory.appendingPathComponent("Playhouse-v2.store")
        let schema = Schema([BoardTask.self])
        let configuration = ModelConfiguration(
            "Playhouse",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)

        let task = BoardTask(claudeSessionID: arguments.count == 2 ? arguments[1] : "legacy-chat-session")
        context.insert(task)
        try context.save()
        // The chat split came after the v2 lifecycle reset, so such a store has already been
        // through it; without the marker the app's first launch resets it and drops this row.
        try Data("1\n".utf8).write(to: dataDirectory.appendingPathComponent("task-lifecycle-v2-reset"), options: .atomic)
        print(task.id.uuidString)
    }
}

private enum SeedError: LocalizedError {
    case usage

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: seed-legacy-standalone-chat-task <data-directory> [claude-session-id]"
        }
    }
}
