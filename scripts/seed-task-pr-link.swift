import Foundation
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
            print("Cleared provider sessions for task \(taskID).")
            return
        }

        if arguments.count == 5, arguments[2] == "--legacy-plugin" {
            task.authoredPluginID = arguments[3]
            task.pluginPlacement = "mainSidebar"
            task.contextFolderPaths = [arguments[4]]
            task.workspaceRootPaths = [arguments[4]]
            try context.save()
            print("Seeded legacy plugin task \(taskID).")
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

private enum SeedError: LocalizedError {
    case usage
    case taskUnavailable

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: seed-task-pr-link <data-directory> <task-id> <pr-number> <https-url> [repository-index] | <data-directory> <task-id> --clear-provider-session"
        case .taskUnavailable:
            "The task must exist and have at least one repository."
        }
    }
}
