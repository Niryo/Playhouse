import Foundation

// Compiled with scripts/task-store-seeding.swift.
//
/// Recreates the pre-split state: a standalone chat stored as a hidden board task, a board row
/// with the legacy `legacyStandaloneChatMarker` set (the old `isStandaloneChat` column).
///
/// Used to verify the one-time migration converts that row into the dedicated `StandaloneChat`
/// model, keeping its ID so the existing conversation transcript stays attached, and removes
/// the board row so it can never render as a card.
@main
struct SeedLegacyStandaloneChatTask {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard (1...2).contains(arguments.count) else { throw SeedError.usage }

        let dataDirectory = URL(fileURLWithPath: arguments[0], isDirectory: true)
        let store = try TaskStoreSeeding(dataDirectory: dataDirectory)
        let id = UUID().uuidString
        try store.write { revision in
            // A chat captured mid-turn: the migration must carry the turn state's explanation
            // and timing across, not just the raw status.
            try store.execute("""
                INSERT INTO board_tasks (
                    id, revision, title, statusRawValue, lifecycleRevision, statusMessage, progressTypeRawValue,
                    progressLabel, progressDetail, createdAt, inProgressStartedAt, totalInProgressSeconds,
                    claudeSessionID, conversationProviderRawValue, conversationEffortRawValue, hasUnsentDraft,
                    totalInputTokens, totalOutputTokens, totalCacheReadTokens, totalCacheCreationTokens,
                    autoCreatePullRequestOnReview, pullRequestAutopilot, pullRequestAutoMerge,
                    pullRequestAutopilotFixAttempts, legacyStandaloneChatMarker, schedulePaused
                ) VALUES (?, ?, 'Chat', 'In Progress', 0, ?, 'searching', 'Searching', ?, ?, ?, 42, ?, 'codex', 'medium',
                          0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0)
                """, [
                    id, revision, "Carried from the legacy chat task.", "Looking into volcanoes",
                    Date().timeIntervalSinceReferenceDate,
                    Date(timeIntervalSince1970: 1_700_000_000).timeIntervalSinceReferenceDate,
                    arguments.count == 2 ? arguments[1] : "legacy-chat-session",
                ])
        }
        print(id)
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
