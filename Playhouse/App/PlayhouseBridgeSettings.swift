import Foundation

extension PlayhouseBridgeRuntime {
    func settingsOperation(_ request: BridgeRequest, manager: WorkspaceSettingsManager) throws -> BridgeValue {
        switch request.command {
        case "settings.get":
            return .object([
                "defaultParentFolder": manager.defaultParentFolderPath.isEmpty ? .null : .string(manager.defaultParentFolderPath),
                "defaultParentAvailable": .boolean(manager.defaultParentFolderURL != nil),
                "lastSelectedRepositories": .array(manager.lastSelectedRepositories.map(BridgeValue.string)),
                "recentRepositories": .array(manager.recentRepositories.map(BridgeValue.string)),
                "appearance": .string(manager.appearance),
                "defaultProvider": .string(manager.defaultConversationProvider.rawValue),
                "tokenUsageColorMax": .integer(manager.tokenUsageColorMax),
                "cpuUsageColorMax": .integer(manager.cpuUsageColorMax),
                "statusSounds": .boolean(manager.statusSoundsEnabled),
                "autoCompaction": Self.autoCompactionValue(manager.contextCompaction)
            ])
        case "settings.set-auto-compaction":
            let arguments = request.arguments
            let enabled = arguments["enabled"]?.bool
            let idleMinutes = arguments["idleMinutes"]?.int
            let minimum = arguments["minimumTokens"]?.int
            guard enabled != nil || idleMinutes != nil || minimum != nil else {
                throw BridgeCommandError(code: "invalid_argument", message: "Give at least one of enabled, idleMinutes or minimumTokens.")
            }
            try manager.setContextCompaction(enabled: enabled, idleMinutes: idleMinutes, minimumTokens: minimum)
            return .object(["autoCompaction": Self.autoCompactionValue(manager.contextCompaction)])
        case "settings.prompts":
            return .object(["prompts": .array(SystemPromptKind.allCases.map { Self.systemPromptValue($0, manager: manager) })])
        case "settings.set-prompt":
            let kind = try WorkspaceSettingsManager.systemPromptKind(request.requiredString("prompt"))
            try manager.setSystemPrompt(kind, text: request.requiredString("text"))
            return Self.systemPromptValue(kind, manager: manager)
        case "settings.reset-prompt":
            let kind = try WorkspaceSettingsManager.systemPromptKind(request.requiredString("prompt"))
            manager.resetSystemPrompt(kind)
            return Self.systemPromptValue(kind, manager: manager)
        case "settings.set-token-usage-color-max":
            try manager.setTokenUsageColorMax(request.requiredInt("max"))
            return .object(["tokenUsageColorMax": .integer(manager.tokenUsageColorMax)])
        case "settings.set-cpu-usage-color-max":
            try manager.setCPUUsageColorMax(request.requiredInt("max"))
            return .object(["cpuUsageColorMax": .integer(manager.cpuUsageColorMax)])
        case "settings.set-status-sounds":
            guard let enabled = request.arguments["enabled"]?.bool else {
                throw BridgeCommandError(code: "invalid_argument", message: "Give enabled as true or false.")
            }
            manager.setStatusSoundsEnabled(enabled)
            return .object(["statusSounds": .boolean(manager.statusSoundsEnabled)])
        case "settings.set-default-provider":
            try manager.setDefaultConversationProvider(request.requiredString("provider"))
            return .object(["defaultProvider": .string(manager.defaultConversationProvider.rawValue)])
        case "settings.set-appearance":
            try manager.setAppearance(request.requiredString("appearance"))
            return .object(["appearance": .string(manager.appearance)])
        case "settings.set-parent":
            try manager.setDefaultParentFolder(request.requiredString("path"))
            return .object(["defaultParentFolder": .string(manager.defaultParentFolderPath)])
        case "settings.clear-parent":
            try manager.setDefaultParentFolder(nil)
            return .object(["defaultParentFolder": .null])
        case "settings.set-last-repositories":
            let repositories = try request.requiredStrings("repositories")
            try manager.setLastSelectedRepositories(repositories)
            return .object(["lastSelectedRepositories": .array(manager.lastSelectedRepositories.map(BridgeValue.string))])
        default:
            throw BridgeCommandError(code: "unsupported_command", message: "Unsupported settings command: \(request.command).")
        }
    }

    static func systemPromptValue(_ kind: SystemPromptKind, manager: WorkspaceSettingsManager) -> BridgeValue {
        let prompt = manager.systemPrompt(kind)
        return .object([
            "id": .string(kind.rawValue),
            "title": .string(kind.title),
            "usage": .string(kind.usage),
            "text": .string(prompt.text),
            "defaultText": .string(kind.defaultText),
            "custom": .boolean(prompt.isCustom)
        ])
    }

}
