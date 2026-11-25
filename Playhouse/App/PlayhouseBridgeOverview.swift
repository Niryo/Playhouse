import Foundation

extension PlayhouseBridgeRuntime {
    func bridgeOverviewOperation(
        _ request: BridgeRequest,
        taskManager: BoardTaskManager,
        settings: WorkspaceSettingsManager
    ) async throws -> BridgeValue {
        switch request.command {
        case "status":
            return .object([
                "service": .string("Playhouse"),
                "bridgeVersion": .integer(BridgeContract.currentVersion),
                "processID": .integer(Int(ProcessInfo.processInfo.processIdentifier))
            ])
        case "board.list", "task.list":
            return try Self.value(["tasks": taskManager.list()])
        case "archive.search":
            let conversations = ConversationManager(
                tasks: taskManager,
                clients: ConversationClients(codex: CodexAppServerClient(), claude: ClaudeCodeClient(), opencode: OpenCodeClient()),
                settingsManager: settings
            )
            return try Self.value(await conversations.searchArchive(query: request.requiredString("query")))
        default:
            throw BridgeCommandError(code: "unsupported_command", message: "Unsupported overview command: \(request.command).")
        }
    }
}
