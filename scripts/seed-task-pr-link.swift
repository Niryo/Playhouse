import Foundation
import SQLite3
import SwiftData

@main
@MainActor
struct SeedTaskPullRequestLink {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2, let taskID = UUID(uuidString: arguments[1]) else {
            throw SeedError.usage
        }

        let dataDirectory = URL(fileURLWithPath: arguments[0], isDirectory: true)
        let storeURL = dataDirectory.appendingPathComponent("Playhouse-v2.store")
        let schema = Schema([BoardTask.self, StandaloneChat.self])
        let configuration = ModelConfiguration(
            "Playhouse",
            schema: schema,
            url: storeURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<BoardTask>(predicate: #Predicate { $0.id == taskID })
        guard let task = try context.fetch(descriptor).first else {
            throw SeedError.taskUnavailable
        }

        if arguments.count == 3, arguments[2] == "--clear-provider-session" {
            task.codexThreadID = nil
            task.claudeSessionID = nil
            try context.save()
            // Playhouse keeps the transcript itself, so a task without a provider
            // session also starts without a conversation.
            try clearTranscript(dataDirectory.appendingPathComponent("Conversations-v1.sqlite"), taskID: taskID.uuidString)
            print("Cleared provider sessions for task \(taskID).")
            return
        }

        guard (4...5).contains(arguments.count),
              let number = Int(arguments[2]), number > 0,
              let repositoryIndex = arguments.count == 5 ? Int(arguments[4]) : 0,
              let url = URL(string: arguments[3]), url.scheme == "https", url.host != nil,
              task.repositoryWorktrees.indices.contains(repositoryIndex) else {
            throw SeedError.usage
        }

        var worktrees = task.repositoryWorktrees
        worktrees[repositoryIndex].pullRequestNumber = number
        worktrees[repositoryIndex].pullRequestURL = url.absoluteString
        task.repositoryWorktrees = worktrees
        try context.save()
        print("Seeded linked PR #\(number) for task \(taskID).")
    }
}

private func clearTranscript(_ databaseURL: URL, taskID: String) throws {
    guard FileManager.default.fileExists(atPath: databaseURL.path) else { return }
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else { throw SeedError.transcriptUnavailable }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 30_000)
    for table in ["conversation_state", "conversation_token_usage", "conversation_turns", "conversation_messages", "conversation_activities"] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM \(table) WHERE task_id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw SeedError.transcriptUnavailable
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, taskID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SeedError.transcriptUnavailable }
    }
}

private enum SeedError: LocalizedError {
    case usage
    case taskUnavailable
    case transcriptUnavailable

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: seed-task-pr-link <data-directory> <task-id> <pr-number> <https-url> [repository-index] | <data-directory> <task-id> --clear-provider-session"
        case .taskUnavailable:
            "The task must exist and have at least one repository."
        case .transcriptUnavailable:
            "The task's conversation transcript couldn't be cleared."
        }
    }
}
