import Foundation
import SwiftData

@main
@MainActor
struct SeedTaskPullRequestLink {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard (4...5).contains(arguments.count),
              let taskID = UUID(uuidString: arguments[1]),
              let number = Int(arguments[2]), number > 0,
              let repositoryIndex = arguments.count == 5 ? Int(arguments[4]) : 0,
              let url = URL(string: arguments[3]), url.scheme == "https", url.host != nil else {
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
        guard let task = try context.fetch(descriptor).first,
              task.repositoryWorktrees.indices.contains(repositoryIndex) else {
            throw SeedError.taskUnavailable
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
            "Usage: seed-task-pr-link <data-directory> <task-id> <pr-number> <https-url> [repository-index]"
        case .taskUnavailable:
            "The task must exist and have at least one repository."
        }
    }
}
