import Foundation
import SwiftData

// The persisted properties match the BoardTask model before pendingSubmittedPrompt
// was added. Keep the class name: SwiftData uses it for the entity and model hash.
@Model final class BoardTask {
    var id: UUID
    var title: String
    var statusRawValue: String
    var statusMessage: String?
    var progressTypeRawValue: String?
    var progressLabel: String?
    var progressDetail: String?
    var createdAt: Date
    var codexThreadID: String?
    var savedPrompt: String?
    var workspaceRootPathsData: Data?
    var repositoryWorktreesData: Data?
    var contextFolderPathsData: Data?

    init() {
        id = UUID(uuidString: "948A506B-0AE6-47E4-A99E-EAE60CDDDAFB")!
        title = "Legacy pending prompt store"
        statusRawValue = "Backlog"
        statusMessage = nil
        progressTypeRawValue = nil
        progressLabel = nil
        progressDetail = nil
        createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        codexThreadID = nil
        savedPrompt = "Keep this draft through the store repair."
        workspaceRootPathsData = nil
        repositoryWorktreesData = nil
        contextFolderPathsData = nil
    }
}

@main struct LegacyStoreSeeder {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "LegacyStoreSeeder", code: 1)
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = directory.appendingPathComponent("StationAI.store")
        guard !FileManager.default.fileExists(atPath: store.path) else {
            throw NSError(domain: "LegacyStoreSeeder", code: 2)
        }
        let schema = Schema([BoardTask.self])
        let configuration = ModelConfiguration("StationAI", schema: schema, url: store, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let task = BoardTask()
        context.insert(task)
        try context.save()
        try Data("1\n".utf8).write(to: directory.appendingPathComponent("task-lifecycle-v2-reset"), options: .atomic)
        print(task.id.uuidString)
    }
}
