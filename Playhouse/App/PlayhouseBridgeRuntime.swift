import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

@MainActor
final class PlayhouseBridgeRuntime {
    func perform(
        _ request: BridgeRequest,
        eventHandler: @escaping (BridgeEvent) -> Void
    ) async -> BridgeResponse {
        // A change this request saves raises plugin events whose services run
        // their bridge commands as this request: same store, settings and fixtures.
        await PluginServiceHost.$origin.withValue(request) {
            await performRequest(request, eventHandler: eventHandler)
        }
    }

    private func performRequest(
        _ request: BridgeRequest,
        eventHandler: @escaping (BridgeEvent) -> Void
    ) async -> BridgeResponse {
        let requestStartedAt = DispatchTime.now().uptimeNanoseconds
        let requestFields = Self.diagnosticRequestFields(request)
        PlayhouseDiagnostics.record("bridge.request.started", fields: requestFields)
        guard request.version == BridgeContract.currentVersion else {
            let response = BridgeResponse.failure(
                request,
                code: "unsupported_version",
                message: "Unsupported bridge version \(request.version). This service supports version \(BridgeContract.currentVersion)."
            )
            PlayhouseDiagnostics.record("bridge.request.failed", fields: requestFields.merging([
                "errorCode": "unsupported_version",
                "durationMilliseconds": Self.elapsedMilliseconds(since: requestStartedAt)
            ]) { _, new in new })
            await PlayhouseDiagnostics.endBatch()
            return response
        }

        // Turn state lives in this process's memory, so reading it needs no store.
        if request.command == "conversation.runtime" || request.command == "conversation.runtime.subscribe" {
            return await conversationRuntimeResponse(request, eventHandler: eventHandler)
        }

        // CPU samples also live only in this process's memory (the real PIDs).
        if request.command == "conversation.cpuUsage" || request.command == "conversation.cpuUsage.subscribe" {
            return await conversationCPUUsageResponse(request, eventHandler: eventHandler)
        }

        do {
            let dataDirectory: String?
            #if DEBUG
            dataDirectory = request.dataDirectory
            #else
            dataDirectory = nil
            #endif
            let container = try PlayhouseStore.makeContainer(dataDirectory: dataDirectory)
            try await PlayhouseStore.prepareLifecycle(container: container, dataDirectory: dataDirectory)
            let context = ModelContext(container)
            // Beside the store this request opened, whatever chose its directory.
            let storeDirectory = container.configurations.first?.url.deletingLastPathComponent().path ?? dataDirectory
            let worktreeRoot: URL
            #if DEBUG
            worktreeRoot = request.worktreeDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? PlayhouseWorktreeManager.defaultRoot(dataDirectory: storeDirectory)
            #else
            worktreeRoot = PlayhouseWorktreeManager.defaultRoot(dataDirectory: storeDirectory)
            #endif
            let preferences: UserDefaults
            #if DEBUG
            if let suite = request.defaultsSuite, let isolated = UserDefaults(suiteName: suite) {
                preferences = isolated
            } else {
                let applicationIdentifier = Bundle.main.infoDictionary?["PlayhouseApplicationBundleIdentifier"] as? String
                    ?? "com.playhouse.app"
                preferences = UserDefaults(suiteName: applicationIdentifier) ?? .standard
            }
            #else
            let applicationIdentifier = Bundle.main.infoDictionary?["PlayhouseApplicationBundleIdentifier"] as? String
                ?? "com.playhouse.app"
            preferences = UserDefaults(suiteName: applicationIdentifier) ?? .standard
            #endif
            let taskManager = BoardTaskManager(modelContext: context, worktreeRoot: worktreeRoot, preferences: preferences)
            let settings = WorkspaceSettingsManager(defaults: preferences)
            let workspaces = WorkspaceManager(taskManager: taskManager, settingsManager: settings)
            try await workspaces.reconcileDeferredRepositoryRemovals()
            try taskManager.importLegacyPullRequestModes(into: settings)
            try taskManager.pinPullRequestModeOfExistingTasks(into: settings)

            let codexExecutable = request.arguments["__codexExecutable"]?.string
            let claudeExecutable = request.arguments["__claudeExecutable"]?.string
            let claudeConfigDirectory = request.arguments["__claudeConfigDirectory"]?.string
            // A window's requests follow the Goal turns of the threads they read and set. The
            // window and the CLI share one Codex client and app-server per Codex home.
            let guiRuntime = request.arguments["__guiRuntime"]?.bool == true
            // The caller's Codex home, so a window and the CLI read the same threads.
            let callerCodexHome = request.arguments["__codexHome"]?.string
            let skillsHome: String?
            #if DEBUG
            // A test bundle's data directory gets its own skill homes, so bridge
            // tests never read or bridge the host's own skills. Development
            // builds still use the user's real skills.
            skillsHome = PlayhouseAppIdentity.isTestBundle && dataDirectory != nil
                ? storeDirectory.map { $0 + "/skills-home" }
                : nil
            #else
            skillsHome = nil
            #endif
            let agentEnvironment = SkillEnvironment.resolve(
                homeOverride: skillsHome,
                claudeConfigOverride: claudeConfigDirectory,
                codexHomeOverride: callerCodexHome,
                storeDirectory: storeDirectory
            )
            let skills = SkillCatalogManager(environment: agentEnvironment, preferences: preferences)
            let rules = RuleCatalogManager(environment: agentEnvironment, preferences: preferences)
            let mcp = McpCatalogManager(environment: agentEnvironment, preferences: preferences)
            let mentions = MentionCatalogManager(environment: agentEnvironment, preferences: preferences, skills: skills, mcp: mcp)
            func conversationClients() -> ConversationClients {
                ConversationClients(
                    codex: CodexAppServerClient.sharedClient(executableOverride: codexExecutable, codexHomeOverride: callerCodexHome, dataDirectory: dataDirectory, runDirectory: storeDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }),
                    claude: ClaudeCodeClient.sharedPrimaryClient(executableOverride: claudeExecutable, configDirectoryOverride: claudeConfigDirectory, dataDirectory: dataDirectory, runDirectory: storeDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }),
                    skills: skills,
                    rules: rules,
                    mcp: mcp,
                    mentions: mentions,
                    observesGoalTurns: guiRuntime
                )
            }
            // Watchers receive provider pushes immediately and periodically refresh both
            // accounts to catch usage incurred by other clients or missed notifications.
            if request.command == "usage.subscribe" {
                let clients = conversationClients()
                let refresh = Task { @MainActor in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(30)) } catch { break }
                        guard !Task.isCancelled else { break }
                        _ = await AgentUsageService.report(clients: clients, refresh: true)
                    }
                }
                defer { refresh.cancel() }
                for await report in AgentUsageStore.shared(scope: dataDirectory).changes() {
                    if Task.isCancelled { break }
                    eventHandler(BridgeEvent(requestID: request.id, type: "usage_state", payload: try Self.value(report)))
                }
                await PlayhouseDiagnostics.endBatch()
                return .success(request, result: .object(["subscribed": .boolean(false)]))
            }
            func pluginLibrary() throws -> PluginLibrary {
                guard let storeDirectory else {
                    throw BridgeCommandError(code: "operation_failed", message: "Playhouse has no data directory for plugins.")
                }
                return PluginLibrary(dataDirectory: storeDirectory)
            }
            func skillRoots() throws -> [SkillRoot] {
                guard request.arguments["taskID"]?.string?.isEmpty == false else { return [] }
                return SkillRoot.roots(for: try taskManager.conversationSubject(request.requiredUUID("taskID")))
            }
            func skillRoot(in roots: [SkillRoot]) throws -> SkillRoot? {
                guard let value = request.arguments["root"]?.string, !value.isEmpty else { return roots.count == 1 ? roots[0] : nil }
                let path = URL(fileURLWithPath: value).standardizedFileURL.path
                guard let root = roots.first(where: { $0.path == path || $0.repositoryPath == path }) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "\(value) is not one of the task's repositories.")
                }
                return root
            }
            func skillScope() throws -> SkillScope {
                guard let scope = SkillScope(rawValue: try request.requiredString("scope")), scope != .builtin else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Scope must be 'repo', 'private' or 'global'.")
                }
                return scope
            }
            /// One skill as `skillID`, or several as `skillIDs`.
            func skillIDs() throws -> [String] {
                if let ids = request.arguments["skillIDs"]?.strings, !ids.isEmpty { return ids }
                return [try request.requiredString("skillID")]
            }
            /// One rule as `ruleID`, or several as `ruleIDs`.
            func ruleIDs() throws -> [String] {
                if let ids = request.arguments["ruleIDs"]?.strings, !ids.isEmpty { return ids }
                return [try request.requiredString("ruleID")]
            }
            /// One MCP server as `serverID`, or several as `serverIDs`.
            func mcpServerIDs() throws -> [String] {
                if let ids = request.arguments["serverIDs"]?.strings, !ids.isEmpty { return ids }
                return [try request.requiredString("serverID")]
            }
            func mcpConfig() throws -> McpServerConfig {
                guard let value = request.arguments["config"], value != .null else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Give the server's command or URL.")
                }
                do {
                    return try value.decoded(McpServerConfig.self)
                } catch {
                    throw BridgeCommandError(code: "invalid_argument", message: "The server needs a transport of stdio or http, with a command or a URL.")
                }
            }
            /// Optional SKILL.md header fields, such as license, keyed by name.
            func skillFields() throws -> [String: String] {
                guard let value = request.arguments["fields"], value != .null else { return [:] }
                guard let object = value.object else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Fields must be an object of text values.")
                }
                return try object.mapValues { value in
                    guard let text = value.string else {
                        throw BridgeCommandError(code: "invalid_argument", message: "Each skill field must be text.")
                    }
                    return text
                }
            }
            func bundledClaudeSkills(_ roots: [SkillRoot]) async -> [(name: String, description: String)] {
                guard request.arguments["includeBundled"]?.bool == true || request.arguments["includeBundled"]?.string == "true" else { return [] }
                let workspace = (try? ConversationWorkspaceContext(roots: roots.map { URL(fileURLWithPath: $0.path, isDirectory: true) }))
                    ?? (try? ConversationWorkspaceContext(roots: []))
                guard let workspace else { return [] }
                return (try? await conversationClients().claude.bundledSkills(workspace: workspace)) ?? []
            }

            if let storeDirectory {
                AgentUsageStore.shared(scope: dataDirectory).configurePersistence(directory: URL(fileURLWithPath: storeDirectory, isDirectory: true))
            }
            // Agents outlive their daemon: before this daemon answers anything, it goes back to the
            // turns its predecessor was running, so no request sees them as stopped.
            await ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                .resumeReattachedRuns(storeDirectory: storeDirectory)

            let result: BridgeValue
            switch request.command {
            case "status", "board.list", "task.list", "archive.search":
                result = try await bridgeOverviewOperation(
                    request, taskManager: taskManager, settings: settings
                )
            case "update.status", "update.check", "update.download", "update.cancel", "update.install", "update.set-auto-check", "update.launched", "update.dismiss-notice":
                let updates = UpdateManager(request: request, storeDirectory: storeDirectory, runtimeScope: dataDirectory, preferences: preferences) {
                    (try? taskManager.unsentDraftCount()) ?? 0
                }
                defer { updates.resumeWaitingInstall() }
                switch request.command {
                case "update.check":
                    result = try Self.value(await updates.check(automatic: request.arguments["automatic"]?.bool == true))
                case "update.download":
                    result = try Self.value(await updates.download { fraction in
                        eventHandler(BridgeEvent(requestID: request.id, type: "update_progress", payload: .object(["progress": .decimal(fraction)])))
                    })
                case "update.cancel":
                    result = try Self.value(updates.cancelDownload())
                case "update.install":
                    result = .object(try updates.install(whenIdle: request.arguments["whenIdle"]?.bool == true))
                case "update.set-auto-check":
                    guard let enabled = request.arguments["enabled"]?.bool else {
                        throw BridgeCommandError(code: "invalid_argument", message: "Give enabled as true or false.")
                    }
                    result = try Self.value(updates.setAutoCheck(enabled))
                case "update.launched":
                    result = try Self.value(updates.markLaunched())
                case "update.dismiss-notice":
                    result = try Self.value(updates.dismissNotice())
                default:
                    result = try Self.value(updates.status())
                }
            case "task.create":
                let title = try request.requiredString("title")
                let roots = try request.requiredStrings("roots")
                let repositories = try request.repositorySpecs("repositories")
                let provider = try request.arguments["provider"]?.string.map(ConversationProvider.parse) ?? settings.defaultConversationProvider
                let prompt = try request.requiredString("prompt")
                result = try Self.value(await taskManager.create(
                    title: title, repositories: repositories, contextFolders: roots, provider: provider,
                    prompt: prompt
                ))
            case "schedule.list":
                result = try Self.value(["tasks": taskManager.scheduledTasks()])
            case "schedule.set":
                let taskID = try request.requiredUUID("taskID")
                let scheduled = try await taskManager.setSchedule(taskID, request.scheduleRequest())
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = try Self.value(try await conversations.nameScheduledTask(taskID) ?? scheduled)
            case "schedule.name":
                // The app saves a schedule through its own model context, then names it here.
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                let taskID = try request.requiredUUID("taskID")
                result = try Self.value(try await conversations.nameScheduledTask(taskID) ?? taskManager.get(taskID))
            case "schedule.clear":
                result = try Self.value(await taskManager.clearSchedule(request.requiredUUID("taskID")))
            case "schedule.pause", "schedule.resume":
                result = try Self.value(await taskManager.setSchedulePaused(
                    request.requiredUUID("taskID"),
                    paused: request.command == "schedule.pause"
                ))
            case "schedule.run-now", "schedule.tick":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                let scheduler = TaskScheduler(
                    tasks: taskManager,
                    conversations: conversations
                )
                if request.command == "schedule.tick" {
                    // Only the test harness may move the clock; a real tick always uses now.
                    let now = try request.optionalDate("now")
                    if now != nil, !BridgeContract.isTestBundle(PlayhouseAppIdentity.applicationIdentifier) {
                        throw BridgeCommandError(code: "invalid_argument", message: "schedule tick takes no --now outside the test harness.")
                    }
                    let tickTime = now ?? .now
                    let tickResult = await scheduler.tick(now: tickTime)
                    let compactions = await conversations.idleCompactionTick(now: now)
                    if !compactions.isEmpty { PlayhouseDiagnostics.record("conversation.compaction.idle_tick", fields: ["taskIDs": compactions.joined(separator: ",")]) }
                    result = try Self.value(tickResult)
                } else {
                    result = try Self.value(await scheduler.runNow(request.requiredUUID("taskID")))
                }
            case "task.get", "task.show":
                let taskID = try request.requiredUUID("taskID")
                result = try Self.value(taskManager.get(taskID))
            case "task.token-usage":
                let taskID = try request.requiredUUID("taskID")
                result = try Self.value(taskManager.tokenUsageSummary(taskID))
            case "task.token-waste":
                let taskID = try request.requiredUUID("taskID")
                let homes = ProviderSessionHomes.resolve(claudeConfigDirectory: claudeConfigDirectory, codexHome: callerCodexHome)
                result = try Self.value(await taskManager.tokenWasteReport(taskID, homes: homes))
            case "task.raw-input":
                let taskID = try request.requiredUUID("taskID")
                let homes = ProviderSessionHomes.resolve(claudeConfigDirectory: claudeConfigDirectory, codexHome: callerCodexHome)
                result = try Self.value(await taskManager.rawInputPage(
                    taskID, homes: homes,
                    agent: request.arguments["agent"]?.string,
                    scope: request.optionalChoice("scope", default: TaskRawInputScope.finalTranscript),
                    order: request.optionalChoice("order", default: TaskRawInputOrder.transcript),
                    query: request.arguments["query"]?.string ?? "",
                    offset: request.optionalInteger("offset", in: 0...Int.max) ?? 0,
                    limit: request.optionalInteger("limit", in: 1...1_000) ?? 100,
                    focus: request.optionalInteger("focus", in: 0...Int.max),
                    request: request.optionalInteger("request", in: 1...Int.max)
                ))
            case "task.raw-input-export":
                let taskID = try request.requiredUUID("taskID")
                let homes = ProviderSessionHomes.resolve(claudeConfigDirectory: claudeConfigDirectory, codexHome: callerCodexHome)
                result = try Self.value(await taskManager.rawInputExport(
                    taskID, homes: homes,
                    agent: request.arguments["agent"]?.string,
                    request: request.optionalInteger("request", in: 1...Int.max),
                    format: request.optionalChoice("format", default: TaskRawInputExportFormat.text)
                ))
            case "task.raw-input-text":
                let taskID = try request.requiredUUID("taskID")
                let homes = ProviderSessionHomes.resolve(claudeConfigDirectory: claudeConfigDirectory, codexHome: callerCodexHome)
                guard let item = try request.optionalInteger("item", in: 0...Int.max) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Argument item must name an item of the raw input.")
                }
                result = try Self.value(await taskManager.rawInputText(
                    taskID, homes: homes,
                    agent: request.arguments["agent"]?.string,
                    item: item,
                    offset: request.optionalInteger("offset", in: 0...Int.max) ?? 0,
                    length: request.optionalInteger("length", in: 1...Int.max) ?? ProviderTokenMap.defaultTextChunk
                ))
            case "task.cpu-usage":
                let taskID = try request.requiredUUID("taskID")
                result = try Self.value(await taskManager.cpuUsage(taskID, dataDirectory: dataDirectory))
            case "task.move":
                let taskID = try request.requiredUUID("taskID")
                let status = try request.requiredString("status")
                if status == TaskStatus.review.rawValue {
                    result = try Self.value(await taskManager.moveToReview(
                        taskID,
                        clients: conversationClients(),
                        settingsManager: settings
                    ))
                } else {
                    result = try Self.value(await taskManager.move(
                        taskID,
                        to: status,
                        allowUnmergedPullRequests: request.arguments["allowUnmergedPullRequests"]?.bool ?? false,
                        allowDiscardingUncommittedChanges: request.arguments["allowDiscardingUncommittedChanges"]?.bool ?? false
                    ))
                }
            case "task.pr.autopilot", "task.pr.create", "task.pr.link",
                 "task.pr.conflicts", "task.pr.status", "task.pr.verify", "task.pr.resolve", "task.pr.sync":
                result = try await pullRequestOperation(
                    request, taskManager: taskManager, settings: settings,
                    conversationClients: conversationClients, eventHandler: eventHandler
                )
            case "task.progress.publish", "task.progress.custom", "task.progress.clear", "task.outcome":
                result = try await taskWorkspaceOperation(request, taskManager: taskManager, workspaces: workspaces, settings: settings)
            case "chat.open":
                result = try Self.value(await taskManager.getOrCreateStandaloneChat(provider: settings.defaultConversationProvider))
            case "chat.status":
                let chatTask = try await taskManager.getOrCreateStandaloneChat(provider: settings.defaultConversationProvider)
                // The agent may ask for chat status from inside its active turn while
                // holding this reservation. Never let a read-only status request wait
                // for the turn that is currently waiting on that very tool result.
                let turnIsActive = (try? taskManager.hasConversationTurnReservation(chatTask.id)) ?? true
                if !turnIsActive {
                    let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                    try await taskManager.withConversationTurnReservation(chatTask.id) {
                        await conversations.resolvePendingStandalonePageFallback(taskID: chatTask.id)
                    }
                }
                let chatManager = try StandaloneChatManager(dataDirectory: dataDirectory)
                result = .object([
                    "activePage": try chatManager.activePage().map(Self.value) ?? .null,
                    "missedPreviousPageSignal": .boolean(try chatManager.lastTurnMissedSignal()),
                ])
            case "chat.page.list":
                let chatManager = try StandaloneChatManager(dataDirectory: dataDirectory)
                let limit = request.arguments["limit"]?.string.flatMap(Int.init) ?? 50
                result = .object([
                    "pages": try Self.value(chatManager.listPages(limit: limit, titleContaining: request.arguments["title"]?.string)),
                    "archiveDirectory": .string(chatManager.pageFilesDirectoryURL.path),
                ])
            case "chat.page.search":
                let chatManager = try StandaloneChatManager(dataDirectory: dataDirectory)
                result = try Self.value(["matches": chatManager.searchPages(query: request.requiredString("query"))])
            case "chat.page.read":
                let chatManager = try StandaloneChatManager(dataDirectory: dataDirectory)
                let pageID = try request.requiredString("pageID")
                let page = try chatManager.page(id: pageID)
                result = .object([
                    "page": try Self.value(page),
                    "messages": try Self.value(chatManager.messages(pageID: pageID)),
                    "filePath": .string(chatManager.pageFileURL(pageID: pageID).path),
                ])
            case "chat.page.new":
                let chatManager = try StandaloneChatManager(dataDirectory: dataDirectory)
                let page = try chatManager.createExplicitPage(title: request.requiredString("title"), provider: settings.defaultConversationProvider.rawValue)
                result = try Self.value(["page": page])
            case "chat.page.close-turn":
                let chatManager = try StandaloneChatManager(dataDirectory: dataDirectory)
                // The chat-id argument identifies which hidden task's turn this is (for logs/future
                // multi-chat support); v1 has a single page store, so pages are always scoped to
                // StandaloneChatManager.defaultChatID regardless of which task passed this signal.
                let chatID = try request.requiredString("chatID")
                let continues = request.arguments["continues"]?.bool ?? true
                if !continues, (request.arguments["newTitle"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw BridgeCommandError(code: "invalid_argument", message: "A new page requires --new-title when --continues is false.")
                }
                let page = try chatManager.resolveTurnPage(
                    provider: settings.defaultConversationProvider.rawValue,
                    continues: continues,
                    newTitle: request.arguments["newTitle"]?.string
                )
                // Kept with its page and time, so the turn it settles can still be filed on
                // that page by a daemon that took the turn over after a restart.
                try chatManager.recordTurnSignal(pageID: page.id)
                if let summaryHint = request.arguments["summaryHint"]?.string, !summaryHint.isEmpty {
                    try chatManager.setSummary(pageID: page.id, summary: summaryHint)
                }
                // close-turn is the chat's end-of-turn report: it settles the running turn the
                // way `task outcome` settles a task's, so the shared recovery loop sees it. The
                // page is already filed, so a failure here must not fail the command and invite a
                // retry that files the turn twice; the loop's one nudge covers a lost settlement.
                do {
                    try await taskManager.settleStandaloneChatTurn(chatID)
                } catch {
                    var fields = PlayhouseDiagnostics.errorFields(error)
                    fields["chatID"] = chatID
                    PlayhouseDiagnostics.record("chat.page.close_turn.settle_failed", fields: fields)
                }
                result = try Self.value(["page": page])
            case "task.rename", "task.repository.add", "task.repository.add-batch", "task.repository.add-worktree", "task.repository.replace",
                 "task.repository.recent", "task.repository.edit", "task.repository.renew", "task.repository.remove",
                 "task.prompt.save", "task.draft.save", "task.comments.save", "task.comments.edit",
                 "task.roots.get", "workspace.roots", "task.roots.set", "task.terminal",
                 "task.changes.list", "task.changes.mark-viewed", "task.changes.mark-all-viewed",
                 "task.changes.mark-unviewed", "task.changes.diff", "workspace.suggest", "workspace.repositories.list":
                result = try await taskWorkspaceOperation(request, taskManager: taskManager, workspaces: workspaces, settings: settings)
            case "task.delete":
                let clients = conversationClients()
                let conversations = ConversationManager(tasks: taskManager, clients: clients, settingsManager: settings)
                try await conversations.deleteTask(request.requiredUUID("taskID"), diagnostics: clients.codex.diagnosticFields())
                result = .object(["deleted": .boolean(true)])
            case "task.delete.requires-confirmation":
                let requiresConfirmation = try await taskManager.deleteRequiresConfirmation(request.requiredUUID("taskID"))
                result = .object(["requiresConfirmation": .boolean(requiresConfirmation)])
            case "settings.get", "settings.set-auto-compaction", "settings.set-token-usage-color-max",
                 "settings.set-cpu-usage-color-max", "settings.set-status-sounds", "settings.set-default-provider", "settings.set-appearance",
                 "settings.set-parent", "settings.clear-parent", "settings.set-last-repositories":
                result = try settingsOperation(request, manager: settings)
            case "usage.get":
                result = try Self.value(await AgentUsageService.report(
                    clients: conversationClients(), refresh: request.arguments["refresh"]?.bool == true
                ))
            case "usage.login", "usage.switch-account":
                let name = try request.requiredString("provider")
                guard let provider = ConversationProvider(rawValue: name) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Unknown provider '\(name)'. Valid providers: codex, claude.")
                }
                let clients = conversationClients()
                let url = request.command == "usage.login"
                    ? try await AgentUsageService.login(provider, clients: clients)
                    : try await AgentUsageService.switchAccount(provider, clients: clients)
                result = .object(["loginURL": url.map(BridgeValue.string) ?? .null])
            case "conversation.history":
                let taskID = try request.requiredUUID("taskID")
                let clients = conversationClients()
                _ = try await taskManager.reconcileLifecycleStatusOnOpen(taskID, clients: clients)
                let conversations = ConversationManager(
                    tasks: taskManager, clients: clients, settingsManager: settings, defersHistoryImages: request.defersHistoryImages
                )
                let messageLimit = try request.optionalHistoryLimit("limit")
                result = try Self.value(await conversations.history(
                    taskID: taskID,
                    onActionRequest: {
                        eventHandler(BridgeEvent(requestID: request.id, type: "action_request", payload: .object([:])))
                    },
                    messageLimit: messageLimit,
                    beforeMessageID: request.arguments["before"]?.string,
                    afterMessageID: request.arguments["after"]?.string,
                    chatPageID: request.arguments["page"]?.string,
                    includesImageData: true
                ))
            case "conversation.images":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = try Self.value(await conversations.messageImages(
                    taskID: request.requiredUUID("taskID"), messageIDs: request.arguments["messages"]?.strings ?? []
                ))
            case "conversation.present-image":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = try Self.value(await conversations.publishImage(
                    taskID: request.requiredUUID("taskID"),
                    path: request.requiredString("path"),
                    caption: request.arguments["caption"]?.string ?? ""
                ))
            case "conversation.models":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings, preferences: preferences)
                result = .object(["models": .array(try await conversations.models(taskID: request.requiredUUID("taskID")).map { try Self.value($0) })])
            case "conversation.effort.get":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = .object(["effort": .string(try conversations.effort(taskID: request.requiredUUID("taskID")).rawValue)])
            case "conversation.effort.set":
                let taskID = try request.requiredUUID("taskID")
                guard let effort = ConversationEffort(rawValue: try request.requiredString("effort")) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Effort must be one of: low, medium, high, xhigh.")
                }
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                let task = try await conversations.setEffort(taskID: taskID, effort: effort)
                result = try Self.value(task)
            case "conversation.context-mode.get":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = .object(["mode": .string(try conversations.contextMode(taskID: request.requiredUUID("taskID")).rawValue)])
            case "conversation.context-mode.set":
                let taskID = try request.requiredUUID("taskID")
                guard let mode = ConversationContextMode(rawValue: try request.requiredString("mode")) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Context mode must be one of: full, optimized.")
                }
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = try Self.value(try await conversations.setContextMode(taskID: taskID, mode: mode))
            case "conversation.outline":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = try Self.value(try conversations.outline(taskID: request.requiredUUID("taskID")))
            case "conversation.read":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = try Self.value(try conversations.read(
                    taskID: request.requiredUUID("taskID"),
                    positions: request.arguments["at"]?.strings ?? [],
                    from: request.arguments["from"]?.string,
                    to: request.arguments["to"]?.string,
                    kinds: request.arguments["kinds"]?.strings ?? [],
                    includesTools: request.arguments["includeTools"]?.bool ?? false
                ))
            case "conversation.model.get":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings, preferences: preferences)
                result = .object(["modelID": try conversations.modelID(taskID: request.requiredUUID("taskID")).map(BridgeValue.string) ?? .null])
            case "conversation.model.set":
                let taskID = try request.requiredUUID("taskID")
                let modelID = try request.requiredString("modelID")
                guard ConversationManager.isValidModelID(modelID) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Model ID must contain only letters, numbers, periods, underscores, or hyphens.")
                }
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings, preferences: preferences)
                try await conversations.setModelID(taskID: taskID, modelID: modelID)
                result = .object(["modelID": .string(modelID)])
            case "conversation.models.cached":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings, preferences: preferences)
                result = .object(["models": .array(try conversations.cachedModels(taskID: request.requiredUUID("taskID")).map { try Self.value($0) })])
            case "conversation.stop":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = .object(["interrupted": .boolean(try await conversations.interrupt(taskID: request.requiredUUID("taskID")))])
            case "conversation.provider.get":
                let task = try taskManager.conversationSubject(request.requiredUUID("taskID"))
                result = .object([
                    "provider": .string(task.conversationProvider.rawValue),
                    "supportsGoals": .boolean(task.conversationProvider.supportsGoals)
                ])
            case "conversation.provider.set":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings, preferences: preferences)
                result = try Self.value(await conversations.setProvider(
                    taskID: request.requiredUUID("taskID"),
                    provider: ConversationProvider.parse(request.requiredString("provider"))
                ))
            case "plugin.mode":
                if let enabled = request.arguments["enabled"]?.bool {
                    settings.setPluginAddMode(enabled)
                }
                result = .object(["enabled": .boolean(settings.pluginAddMode)])
            case "plugin.list", "plugin.refresh":
                let library = try pluginLibrary()
                let disabled = settings.disabledPluginIDs
                let installed = await Task.detached { library.list(disabled: disabled) }.value
                let revision = request.command == "plugin.refresh" ? settings.bumpPluginsRevision() : settings.pluginsRevision
                let states = settings.pluginStates
                // The built-ins first, then the installed plugins by id, each with its saved state.
                let plugins = (BuiltInPlugins.records(disabled: disabled) + installed).map { plugin in
                    var plugin = plugin
                    plugin.state = states[plugin.id] ?? [:]
                    return plugin
                }
                result = .object([
                    "directory": .string(library.directory.path),
                    "revision": .integer(revision),
                    "plugins": try Self.value(plugins)
                ])
            // A plugin's own saved values, kept across launches and reported as
            // `Playhouse.props.state`; any plugin keeps its settings here, as the
            // built-in Changes keeps whether its section is collapsed.
            case "plugin.state.get", "plugin.state.set":
                let id = try request.requiredString("pluginID")
                if !BuiltInPlugins.isBuiltIn(id) {
                    do { _ = try pluginLibrary().plugin(id: id, validate: false) }
                    catch let error as PluginLibraryError { throw BridgeCommandError(code: "not_found", message: error.localizedDescription) }
                    catch let error as PluginTreeError { throw BridgeCommandError(code: "invalid_argument", message: error.message) }
                }
                guard request.command == "plugin.state.set" else {
                    result = .object([
                        "pluginID": .string(id),
                        "state": .object(settings.pluginState(id).mapValues(BridgeValue.init(plugin:))),
                        "enabled": .boolean(!settings.disabledPluginIDs.contains(id))
                    ])
                    break
                }
                let key = try request.requiredString("key").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { throw BridgeCommandError(code: "invalid_argument", message: "A plugin state key can't be empty.") }
                guard let value = request.arguments["value"] else {
                    throw BridgeCommandError(code: "invalid_argument", message: "plugin.state.set needs a value; null removes the key.")
                }
                let state = settings.setPluginState(id, key: key, value: PluginValue(bridge: value))
                // The plugin's service hears the change, as the pull request
                // mode starts following a task switched to Green in Review.
                PluginServiceHost.publish(.stateChanged(pluginID: id, key: key, value: PluginValue(bridge: value)))
                result = .object([
                    "pluginID": .string(id),
                    "state": .object(state.mapValues(BridgeValue.init(plugin:))),
                    // Windows reload their plugins, so every mounted copy gets the new props.state.
                    "revision": .integer(settings.bumpPluginsRevision())
                ])
            // Disabling hides a plugin's entry (or inline section) and stops it from
            // running; enabling restores it. The state is kept across launches.
            case "plugin.enable", "plugin.disable":
                let id = try request.requiredString("pluginID")
                if !BuiltInPlugins.isBuiltIn(id) {
                    do { _ = try pluginLibrary().plugin(id: id, validate: false) }
                    catch let error as PluginLibraryError { throw BridgeCommandError(code: "not_found", message: error.localizedDescription) }
                    catch let error as PluginTreeError { throw BridgeCommandError(code: "invalid_argument", message: error.message) }
                }
                let enabled = request.command == "plugin.enable"
                settings.setPluginEnabled(id, enabled)
                result = .object(["pluginID": .string(id), "enabled": .boolean(enabled), "revision": .integer(settings.bumpPluginsRevision())])
            // An app event (`app.focus`, or a change a window saved itself) for
            // the built-in plugins' services, which run here in the daemon.
            case "plugin.event":
                let name = try request.requiredString("name")
                guard PluginEvent.names.contains(name) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Unknown plugin event \"\(name)\". Events: \(PluginEvent.names.joined(separator: ", ")).")
                }
                var payload: [String: PluginValue] = [:]
                if let raw = request.arguments["payload"], raw != .null {
                    guard let object = PluginValue(bridge: raw).object else {
                        throw BridgeCommandError(code: "invalid_argument", message: "A plugin event's payload must be a JSON object.")
                    }
                    payload = object
                }
                let event = PluginEvent(name: name, payload: payload, pluginID: PluginEvent.target(of: name, payload: payload))
                PluginServiceHost.publish(event)
                // A move's reactions (opening pull requests) finish before the answer.
                if let taskID = payload["taskID"]?.string.flatMap(UUID.init(uuidString:)) {
                    await PluginServiceHost.settle(taskID: taskID)
                }
                result = .object(["name": .string(name), "delivered": .integer(PluginServiceHost.services.count)])
            case "plugin.sessions":
                result = .object(["sessions": try Self.value(taskManager.pluginConversations())])
            case "plugin.edit":
                let id = try request.requiredString("pluginID")
                if BuiltInPlugins.isBuiltIn(id) {
                    throw BridgeCommandError(code: "invalid_argument", message: "\"\(id)\" is a built-in plugin; it is compiled into Playhouse and can't be edited.")
                }
                let editor = try await taskManager.withPluginOperationLock(id) {
                    let library = try pluginLibrary()
                    do { try library.prepareDraft(id: id) }
                    catch let error as PluginTreeError { throw BridgeCommandError(code: "invalid_argument", message: error.message) }
                    if let existing = try taskManager.pluginConversations().first(where: { $0.authoredPluginID == id }) {
                        return try taskManager.setPluginDraftContext(existing.id, folder: library.draftLibrary.directory.path)
                    }
                    let plugin: PluginRecord
                    do { plugin = try library.plugin(id: id, validate: false) }
                    catch let error as PluginTreeError { throw BridgeCommandError(code: "invalid_argument", message: error.message) }
                    catch { throw BridgeCommandError(code: "not_found", message: error.localizedDescription) }
                    let created = try await taskManager.createPluginConversation(
                        name: plugin.name, pluginID: plugin.id, placement: plugin.placement,
                        contextFolder: library.draftLibrary.directory.path, provider: settings.defaultConversationProvider, authoringName: plugin.name, presentation: plugin.presentation)
                    _ = settings.bumpPluginsRevision()
                    return created
                }
                result = .object(["task": try Self.value(editor)])
            case "plugin.versions":
                let library = try pluginLibrary()
                let id = try request.requiredString("pluginID")
                result = .object(["versions": .array(try library.versions(id: id).map { .integer($0) }),
                                  "hasChanges": .boolean(library.hasDraftChanges(id: id))])
            case "plugin.save", "plugin.discard", "plugin.restore":
                let library = try pluginLibrary()
                let id = try request.requiredString("pluginID")
                result = try await taskManager.withPluginOperationLock(id) {
                  // A plugin that was never saved has no saved version to reset to:
                  // discarding it removes its draft and editor conversations, as deleting does.
                  if request.command == "plugin.discard", !library.isInstalled(id: id) {
                      do { try await taskManager.deletePlugin(id: id, library: library) }
                      catch let error as PluginLibraryError { throw BridgeCommandError(code: "not_found", message: error.localizedDescription) }
                      catch let error as PluginTreeError { throw BridgeCommandError(code: "invalid_argument", message: error.message) }
                      if let store = storeDirectory.map(PluginAgentRunStore.init(storeDirectory:)) { PluginAgentRuns.cancelAll(pluginID: id, store: store, codex: conversationClients().codex) }
                      settings.clearPluginState(id)
                      return .object(["discarded": .string(id), "deleted": .boolean(true), "revision": .integer(settings.bumpPluginsRevision())])
                  }
                  return try await taskManager.withPluginEditorsReserved(id: id) {
                    switch request.command {
                    case "plugin.save":
                        // Publishing an unchanged draft would only add an identical version.
                        if library.isInstalled(id: id), !library.hasDraftChanges(id: id) {
                            throw BridgeCommandError(code: "invalid_argument", message: "The plugin has no unpublished changes.")
                        }
                        let published = try library.saveDraft(id: id)
                        return .object(["plugin": try Self.value(published.plugin), "revision": .integer(settings.bumpPluginsRevision()),
                                        "draftSyncFailed": .boolean(published.draftSyncFailed)])
                    case "plugin.discard":
                        try library.discardDraft(id: id)
                        return .object(["discarded": .string(id)])
                    default:
                        let version = try request.requiredInt("version")
                        let published = try library.restoreVersion(id: id, version: version)
                        return .object(["plugin": try Self.value(published.plugin), "revision": .integer(settings.bumpPluginsRevision()),
                                        "draftSyncFailed": .boolean(published.draftSyncFailed)])
                    }
                  }
                }
            case "plugin.delete":
                let library = try pluginLibrary()
                let id = try request.requiredString("pluginID")
                if BuiltInPlugins.isBuiltIn(id) {
                    throw BridgeCommandError(code: "invalid_argument", message: "\"\(id)\" is a built-in plugin; it can be disabled but not removed.")
                }
                do {
                    try await taskManager.withPluginOperationLock(id) {
                        try await taskManager.deletePlugin(id: id, library: library)
                    }
                } catch let error as PluginLibraryError {
                    throw BridgeCommandError(code: "not_found", message: error.localizedDescription)
                } catch let error as PluginTreeError {
                    throw BridgeCommandError(code: "invalid_argument", message: error.message)
                }
                // A plugin installed again later under this id starts enabled, with no saved state.
                if let store = storeDirectory.map(PluginAgentRunStore.init(storeDirectory:)) { PluginAgentRuns.cancelAll(pluginID: id, store: store, codex: conversationClients().codex) }
                settings.setPluginEnabled(id, true)
                settings.clearPluginState(id)
                result = .object(["deleted": .string(id), "revision": .integer(settings.bumpPluginsRevision())])
            // The task an Add Plugin mode placeholder opens: its agent builds a plugin for the placement.
            case "plugin.author":
                let placement: PluginPlacement
                do {
                    placement = try PluginPlacement.parse(request.requiredString("placement"))
                } catch let error as PluginTreeError {
                    throw BridgeCommandError(code: "invalid_argument", message: error.message)
                }
                let library = try pluginLibrary()
                try FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
                let provider = try request.arguments["provider"]?.string.map(ConversationProvider.parse) ?? settings.defaultConversationProvider
                let name = request.arguments["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
                let presentation = request.arguments["presentation"]?.string
                if name != nil || presentation != nil {
                    guard let name, !name.isEmpty, let presentation, let kind = PluginPresentation(rawValue: presentation) else {
                        throw BridgeCommandError(code: "invalid_argument", message: "A plugin name and valid presentation are required.")
                    }
                    if let problem = kind.placementError(placement) {
                        throw BridgeCommandError(code: "invalid_argument", message: problem)
                    }
                }
                let pluginID = "plugin-" + UUID().uuidString.lowercased()
                let prompt = ""
                let created = try await taskManager.withPluginOperationLock(pluginID) {
                    try library.prepareDraft(id: pluginID)
                    return try await taskManager.createPluginConversation(
                        name: name ?? placement.title, pluginID: pluginID, placement: placement.rawValue,
                        contextFolder: library.draftLibrary.directory.path, provider: provider, authoringName: name, presentation: presentation)
                }
                _ = settings.bumpPluginsRevision()
                result = .object(["task": try Self.value(created), "prompt": .string(prompt)])
            // A plugin runs headlessly off the main actor; its runtime lives only for this request.
            case "plugin.render":
                do {
                    var command = PluginRenderCommand()
                    command.file = request.arguments["file"]?.string
                    command.page = request.arguments["page"]?.string
                    command.propsJSON = request.arguments["props"]?.string
                    // An installed plugin renders with its placement's real context.
                    if let pluginID = request.arguments["pluginID"]?.string {
                        let plugin: PluginRecord
                        if BuiltInPlugins.isBuiltIn(pluginID) {
                            throw BridgeCommandError(code: "invalid_argument", message: "\"\(pluginID)\" is a built-in plugin; it renders natively in the window, not headlessly.")
                        }
                        do {
                            plugin = try pluginLibrary().plugin(id: pluginID, validate: false)
                        } catch let error as PluginLibraryError {
                            throw BridgeCommandError(code: "not_found", message: error.localizedDescription)
                        }
                        if let problem = plugin.errors.first { throw BridgeCommandError(code: "invalid_argument", message: problem) }
                        if settings.disabledPluginIDs.contains(plugin.id) {
                            throw BridgeCommandError(code: "unavailable", message: "The plugin \"\(plugin.id)\" is disabled; enable it to run it.")
                        }
                        let task = try request.arguments["taskID"]?.string.map { _ in
                            PluginTaskContext(task: try taskManager.conversationSubject(request.requiredUUID("taskID")))
                        }
                        var stated = plugin
                        stated.state = settings.pluginState(plugin.id)
                        command.file = plugin.entryPath
                        command.placement = PluginPlacement(rawValue: plugin.placement)
                        // The board's agents: the last-known usage and each provider's running tasks.
                        var agents: PluginAgentsContext?
                        if command.placement == .mainSidebarBottom {
                            let report = await AgentUsageService.report(clients: conversationClients(), refresh: false)
                            agents = PluginAgentsContext(
                                usage: PluginValue(bridge: try Self.value(report)),
                                runningTasks: try taskManager.list(status: .inProgress).reduce(into: [:]) { $0[$1.conversationProvider, default: 0] += 1 }
                            )
                        }
                        // The board's scheduled tasks, as `schedule.list` returns them. Only the
                        // app can ask macOS about Login Items, so headlessly it reads false.
                        var schedules: PluginSchedulesContext?
                        if command.placement == .mainSidebar {
                            schedules = PluginSchedulesContext(tasks: PluginValue(bridge: try Self.value(taskManager.scheduledTasks())).array ?? [])
                        }
                        command.baseProps = PluginContext.props(plugin: stated, appearance: settings.appearance, task: task, composer: nil, agents: agents, schedules: schedules)
                    }
                    // The plugin's Playhouse.bridge calls run as requests of this caller,
                    // against the same managers the CLI reaches.
                    let caller = request
                    command.bridge = { command, arguments in
                        var nested = caller
                        nested.id = UUID().uuidString
                        nested.command = command
                        nested.arguments = caller.arguments.filter { $0.key.hasPrefix("__") }.merging(BridgeValue(plugin: arguments).object ?? [:]) { _, new in new }
                        let response = await PlayhouseBridgeRuntime().perform(nested) { _ in }
                        guard response.ok else {
                            throw PluginHostError(code: response.error?.code ?? "operation_failed", message: response.error?.message ?? "The bridge command failed.")
                        }
                        return PluginValue(bridge: response.result ?? .null)
                    }
                    if case .array(let events)? = request.arguments["events"] {
                        command.events = try events.map { try PluginRenderCommand.Event(parsing: $0.string ?? "") }
                    }
                    if case .object(let mocks)? = request.arguments["mocks"] {
                        command.mocks = mocks.mapValues(PluginValue.init(bridge:))
                    }
                    switch request.arguments["advance"] {
                    case .decimal(let seconds)?: command.advance = seconds
                    case .integer(let seconds)?: command.advance = Double(seconds)
                    default: break
                    }
                    let render = command
                    result = try Self.value(try await Task.detached { try await render.run() }.value)
                } catch let error as PluginTreeError {
                    throw BridgeCommandError(code: "invalid_argument", message: error.message)
                }
            case "plugin.service", "plugin.services", "agent.run", "agent.cancel", "agent.runs", "mcp.call":
                result = try await pluginBackgroundOperation(
                    request, settings: settings, library: pluginLibrary, storeDirectory: storeDirectory, conversationClients: conversationClients,
                    mcpWorkspace: { ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings).mcpWorkspace(taskID: nil) }
                )
            case "skills.list":
                let roots = try skillRoots()
                result = try Self.value(skills.catalog(roots: roots, bundledClaudeSkills: await bundledClaudeSkills(roots)))
            case "skills.get":
                let roots = try skillRoots()
                let catalog = skills.catalog(roots: roots, bundledClaudeSkills: await bundledClaudeSkills(roots))
                let skillID = try request.requiredString("skillID")
                guard let record = catalog.skill(id: skillID) else {
                    throw BridgeCommandError(code: "not_found", message: "No skill matches \(skillID).")
                }
                result = .object([
                    "skill": try Self.value(record),
                    "content": record.folderPath == nil ? .null : .string(try skills.content(id: skillID, roots: roots)),
                    "manifest": record.folderPath == nil ? .null : try Self.value(skills.manifest(id: skillID, roots: roots)),
                ])
            case "skills.create":
                let roots = try skillRoots()
                let scope = try skillScope()
                result = try Self.value(skills.create(
                    name: request.requiredString("name"),
                    description: request.arguments["description"]?.string ?? "",
                    body: request.arguments["body"]?.string ?? "",
                    fields: try skillFields(),
                    scope: scope,
                    root: scope == .global ? nil : try skillRoot(in: roots),
                    roots: roots
                ))
            case "skills.update":
                let skillID = try request.requiredString("skillID")
                if let content = request.arguments["content"]?.string {
                    result = try Self.value(skills.update(id: skillID, content: content, roots: skillRoots()))
                } else {
                    let description = request.arguments["description"]?.string
                    let body = request.arguments["body"]?.string
                    let fields = try skillFields()
                    guard description != nil || body != nil || !fields.isEmpty else {
                        throw BridgeCommandError(code: "invalid_argument", message: "Give the new SKILL.md content, or a description, instructions, or field to change.")
                    }
                    result = try Self.value(skills.update(id: skillID, description: description, body: body, fields: fields, roots: skillRoots()))
                }
            case "skills.delete":
                try skills.delete(ids: skillIDs(), roots: skillRoots())
                result = .object(["deleted": .boolean(true)])
            case "skills.fix":
                let taskID = try request.requiredUUID("taskID")
                let plan = try skills.fixPlan(ids: skillIDs(), roots: skillRoots())
                let source = try taskManager.conversationSubject(taskID)
                let created = try await taskManager.create(
                    title: plan.title,
                    repositories: plan.repositoryPaths.map { RepositoryWorktreeSpec(repositoryPath: $0, branch: nil, branchFrom: nil) },
                    contextFolders: plan.contextFolders,
                    provider: source.conversationProvider,
                    prompt: plan.prompt
                )
                result = .object(["task": try Self.value(created), "prompt": .string(plan.prompt)])
            case "skills.move":
                let roots = try skillRoots()
                let scope = try skillScope()
                result = try Self.value(skills.move(
                    id: request.requiredString("skillID"), to: scope,
                    root: scope == .global ? nil : try skillRoot(in: roots), roots: roots
                ))
            case "skills.enable":
                let roots = try skillRoots()
                let value = request.arguments["enabled"]
                guard let enabled = value?.bool ?? value?.string.flatMap({ ["true": true, "false": false][$0] }) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Enabled must be true or false.")
                }
                result = try Self.value(await skills.setEnabled(
                    id: request.requiredString("skillID"), enabled: enabled, roots: roots,
                    bundledClaudeSkills: { await bundledClaudeSkills(roots) }
                ))
            case "skills.link":
                result = try Self.value(skills.link(id: request.requiredString("skillID"), roots: skillRoots()))
            case "skills.unlink":
                result = try Self.value(skills.unlink(id: request.requiredString("skillID"), roots: skillRoots()))
            case "skills.bridge":
                // A task's report matches what its launch passes, Playhouse skills included.
                if request.arguments["taskID"]?.string?.isEmpty == false {
                    let task = try taskManager.conversationSubject(request.requiredUUID("taskID"))
                    result = try Self.value(skills.bridge(for: task, message: request.arguments["message"]?.string ?? ""))
                } else {
                    var bridge = skills.bridge(roots: [])
                    bridge.invocations = skills.invocations(in: request.arguments["message"]?.string ?? "", roots: [])
                    result = try Self.value(bridge)
                }
            case "mentions.list":
                let task = try taskManager.conversationSubject(request.requiredUUID("taskID"))
                let catalog = await mentions.catalog(for: task, tasks: taskManager, settings: settings)
                result = .object([
                    "items": try Self.value(catalog.items),
                    "recentIDs": try Self.value(catalog.recentIDs),
                    "suggestions": try Self.value(catalog.suggestions(query: request.arguments["query"]?.string ?? "")),
                ])
            case "slash.list", "slash.run":
                // The composer's `/` commands, each a plugin's (the Built-in Commands
                // plugin's first), run headlessly with the composer's context: bridge
                // calls run as this caller's requests, `ui` calls are recorded.
                let task = try taskManager.conversationSubject(request.requiredUUID("taskID"))
                let library = try pluginLibrary()
                let disabled = settings.disabledPluginIDs
                let installed = await Task.detached { library.list(disabled: disabled) }.value
                let states = settings.pluginStates
                let plugins = (BuiltInPlugins.records(disabled: disabled) + installed).map { plugin in
                    var plugin = plugin
                    plugin.state = states[plugin.id] ?? [:]
                    return plugin
                }
                let draft = request.arguments["draft"]?.string ?? ""
                let appearance = settings.appearance
                let context = PluginTaskContext(task: task)
                let caller = request
                let headless = PluginHeadlessHost(placement: .composerActions, confirm: request.arguments["confirm"]?.bool == true) { command, arguments in
                    var nested = caller
                    nested.id = UUID().uuidString
                    nested.command = command
                    nested.arguments = caller.arguments.filter { $0.key.hasPrefix("__") }.merging(BridgeValue(plugin: arguments).object ?? [:]) { _, new in new }
                    let response = await PlayhouseBridgeRuntime().perform(nested) { _ in }
                    guard response.ok else {
                        throw PluginHostError(code: response.error?.code ?? "operation_failed", message: response.error?.message ?? "The bridge command failed.")
                    }
                    return PluginValue(bridge: response.result ?? .null)
                }
                let manager = SlashCommandManager(
                    plugins: plugins,
                    props: { plugin in
                        PluginContext.props(
                            plugin: plugin, appearance: appearance, task: context,
                            composer: PluginComposerContext(draft: draft, selectionLocation: (draft as NSString).length, selectionLength: 0)
                        )
                    },
                    host: { _ in headless.answer }
                )
                let entries = await manager.entries()
                // `hostCalls` reports the command's own calls, not the availability checks above.
                let listingCalls = headless.hostCalls.count
                if request.command == "slash.list" {
                    let query = request.arguments["query"]?.string ?? ""
                    let complete = request.arguments["complete"]?.bool == true || request.arguments["includeStatus"]?.bool == true
                    var list: PluginCommandList?
                    if let entry = SlashCommandCatalog.listedCommand(query, in: entries) {
                        do {
                            list = try await manager.list(entry, filter: SlashCommandCatalog.parse(query).filter ?? "", complete: complete)
                        } catch let error as PluginHostError {
                            throw BridgeCommandError(code: error.code, message: error.message)
                        }
                    }
                    result = try Self.value(SlashCommandCatalog.menu(query: query, entries: entries, list: list))
                } else {
                    let name = try request.requiredString("command").trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                    guard let entry = entries.first(where: { $0.name == name }) else {
                        throw BridgeCommandError(code: "not_found", message: "No plugin exposes the command /\(name).")
                    }
                    let itemID = request.arguments["item"]?.string
                    let button = request.arguments["button"]?.string
                    do {
                        var item: PluginCommandItem?
                        if let itemID { item = try await manager.item(entry, id: itemID) }
                        let outcome = try await manager.act(entry, item: item, button: button)
                        result = .object(["outcome": try Self.value(outcome), "hostCalls": BridgeValue(plugin: .array(Array(headless.hostCalls.dropFirst(listingCalls))))])
                    } catch let error as PluginHostError {
                        throw BridgeCommandError(code: error.code, message: error.message)
                    }
                }
            case "rules.list":
                result = try Self.value(rules.catalog(roots: skillRoots()))
            case "rules.get":
                let roots = try skillRoots()
                let ruleID = try request.requiredString("ruleID")
                guard let record = rules.catalog(roots: roots).rule(id: ruleID) else {
                    throw BridgeCommandError(code: "not_found", message: "No rule matches \(ruleID).")
                }
                result = .object(["rule": try Self.value(record), "content": .string(try rules.content(id: ruleID, roots: roots))])
            case "rules.create":
                let roots = try skillRoots()
                guard let scope = RuleScope(rawValue: try request.requiredString("scope")), scope != .managed else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Scope must be 'repo' or 'global'.")
                }
                result = try Self.value(rules.create(
                    name: request.arguments["name"]?.string,
                    paths: request.arguments["paths"]?.strings ?? [],
                    body: request.arguments["body"]?.string ?? "",
                    scope: scope,
                    root: scope == .repo ? try skillRoot(in: roots) : nil,
                    roots: roots
                ))
            case "rules.update":
                result = try Self.value(rules.update(
                    id: request.requiredString("ruleID"), content: request.requiredString("content"), roots: skillRoots()
                ))
            case "rules.delete":
                try rules.delete(ids: ruleIDs(), roots: skillRoots())
                result = .object(["deleted": .boolean(true)])
            case "rules.enable":
                let value = request.arguments["enabled"]
                guard let enabled = value?.bool ?? value?.string.flatMap({ ["true": true, "false": false][$0] }) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Enabled must be true or false.")
                }
                result = try Self.value(rules.setEnabled(id: request.requiredString("ruleID"), enabled: enabled, roots: skillRoots()))
            case "rules.link":
                result = try Self.value(rules.link(id: request.requiredString("ruleID"), roots: skillRoots()))
            case "rules.unlink":
                result = try Self.value(rules.unlink(id: request.requiredString("ruleID"), roots: skillRoots()))
            case "rules.fix":
                let taskID = try request.requiredUUID("taskID")
                let plan = try rules.fixPlan(ids: ruleIDs(), roots: skillRoots())
                let source = try taskManager.conversationSubject(taskID)
                let created = try await taskManager.create(
                    title: plan.title,
                    repositories: plan.repositoryPaths.map { RepositoryWorktreeSpec(repositoryPath: $0, branch: nil, branchFrom: nil) },
                    contextFolders: plan.contextFolders,
                    provider: source.conversationProvider,
                    prompt: plan.prompt
                )
                result = .object(["task": try Self.value(created), "prompt": .string(plan.prompt)])
            case "rules.bridge":
                result = try Self.value(rules.bridge(roots: skillRoots()))
            case "mcp.list":
                result = try Self.value(mcp.catalog(roots: skillRoots()))
            case "mcp.get":
                let roots = try skillRoots()
                let serverID = try request.requiredString("serverID")
                guard let record = mcp.catalog(roots: roots).server(id: serverID) else {
                    throw BridgeCommandError(code: "not_found", message: "No MCP server matches \(serverID).")
                }
                result = .object(["server": try Self.value(record), "config": try Self.value(mcp.config(id: serverID, roots: roots))])
            case "mcp.create":
                let roots = try skillRoots()
                guard let scope = McpScope(rawValue: try request.requiredString("scope")), scope != .managed else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Scope must be 'repo' or 'global'.")
                }
                result = try Self.value(mcp.create(
                    name: request.requiredString("name"),
                    config: mcpConfig(),
                    scope: scope,
                    root: scope == .repo ? try skillRoot(in: roots) : nil,
                    roots: roots
                ))
            case "mcp.update":
                result = try Self.value(mcp.update(id: request.requiredString("serverID"), config: mcpConfig(), roots: skillRoots()))
            case "mcp.delete":
                try mcp.delete(ids: mcpServerIDs(), roots: skillRoots())
                result = .object(["deleted": .boolean(true)])
            case "mcp.enable":
                let value = request.arguments["enabled"]
                guard let enabled = value?.bool ?? value?.string.flatMap({ ["true": true, "false": false][$0] }) else {
                    throw BridgeCommandError(code: "invalid_argument", message: "Enabled must be true or false.")
                }
                result = try Self.value(mcp.setEnabled(id: request.requiredString("serverID"), enabled: enabled, roots: skillRoots()))
            case "mcp.link":
                result = try Self.value(mcp.link(id: request.requiredString("serverID"), roots: skillRoots()))
            case "mcp.fix":
                let taskID = try request.requiredUUID("taskID")
                let plan = try mcp.fixPlan(ids: mcpServerIDs(), roots: skillRoots())
                let source = try taskManager.conversationSubject(taskID)
                let created = try await taskManager.create(
                    title: plan.title,
                    repositories: plan.repositoryPaths.map { RepositoryWorktreeSpec(repositoryPath: $0, branch: nil, branchFrom: nil) },
                    contextFolders: plan.contextFolders,
                    provider: source.conversationProvider,
                    prompt: plan.prompt
                )
                result = .object(["task": try Self.value(created), "prompt": .string(plan.prompt)])
            case "mcp.bridge":
                result = try Self.value(mcp.bridge(roots: skillRoots()))
            case "mcp.status", "mcp.authenticate", "mcp.authenticate.wait":
                let taskID = request.arguments["taskID"]?.string?.isEmpty == false ? try request.requiredUUID("taskID") : nil
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                let provider = try request.arguments["provider"]?.string.map { value -> ConversationProvider in
                    guard let provider = ConversationProvider(rawValue: value) else {
                        throw BridgeCommandError(code: "invalid_argument", message: "Provider must be 'claude' or 'codex'.")
                    }
                    return provider
                }
                switch request.command {
                case "mcp.status":
                    result = try Self.value(await conversations.mcpStatus(taskID: taskID, provider: provider))
                case "mcp.authenticate":
                    guard let provider else { throw BridgeCommandError(code: "invalid_argument", message: "Provider must be 'claude' or 'codex'.") }
                    result = try Self.value(await conversations.startMcpLogin(taskID: taskID, provider: provider, name: request.requiredString("name")))
                default:
                    guard let provider else { throw BridgeCommandError(code: "invalid_argument", message: "Provider must be 'claude' or 'codex'.") }
                    result = try Self.value(await conversations.mcpLoginResult(taskID: taskID, provider: provider, name: request.requiredString("name")))
                }
            case "conversation.provider.capabilities":
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings)
                result = .array(try await conversations.providerCapabilities(taskID: request.requiredUUID("taskID")).map { try Self.value($0) })
            case "conversation.goal":
                // The shared app-server serves the window too, so a CLI Goal call only finishes
                // its request; it never stops the server.
                let conversations = ConversationManager(tasks: taskManager, clients: conversationClients(), settingsManager: settings, preferences: preferences)
                let goal = try await conversations.goal(
                    taskID: request.requiredUUID("taskID"),
                    objective: request.arguments["objective"]?.string,
                    action: request.arguments["action"]?.string ?? "get",
                    observeRuntime: guiRuntime && request.arguments["observe"]?.bool == true
                )
                if let goal { result = try Self.value(goal) } else { result = .null }
            case "conversation.queue", "conversation.queue.list", "conversation.queue.retry", "conversation.queue.remove",
                 "conversation.queue.steer", "conversation.steer", "conversation.answer_async", "conversation.repair_user_input",
                 "conversation.answer_user_input", "conversation.subagent_history", "conversation.answered_async",
                 "conversation.queue.missed_steer":
                result = try await conversationFlowOperation(
                    request, taskManager: taskManager, settings: settings,
                    conversationClients: conversationClients, eventHandler: eventHandler
                )
            case "task.reconcile":
                result = try Self.value(await taskManager.reconcileLifecycleStatusOnOpen(request.requiredUUID("taskID"), clients: conversationClients()))
            case "task.title.generate":
                let taskID = try request.requiredUUID("taskID")
                let prompt = try request.requiredString("prompt")
                let task = try taskManager.taskModel(taskID)
                guard let workspace = try? ConversationWorkspaceContext(roots: task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }) else {
                    PlayhouseDiagnostics.record("task.title_generation.failed", fields: [
                        "taskID": taskID.uuidString,
                        "phase": "workspace-resolution",
                        "reason": "workspace_unavailable"
                    ])
                    result = .null
                    break
                }
                let generated = await ConversationTitleGenerator(clients: conversationClients().helperClients(preferring: task.conversationProvider))
                    .generateTitle(from: prompt, workspace: workspace, taskID: taskID)
                result = generated.map { .object(["title": .string($0.title), "provider": .string($0.provider.rawValue)]) } ?? .null
            case "conversation.send", "conversation.side_chat", "conversation.side_chats.list",
                 "conversation.side_chat.close", "conversation.events.subscribe":
                result = try await conversationOperation(
                    request, taskManager: taskManager, settings: settings,
                    conversationClients: conversationClients, eventHandler: eventHandler
                )
            default:
                throw BridgeCommandError(code: "unknown_command", message: "Unknown command '\(request.command)'. Run 'playhouse help' to list commands.")
            }
            let response = BridgeResponse.success(request, result: result)
            PlayhouseDiagnostics.record("bridge.request.succeeded", fields: requestFields.merging(
                Self.diagnosticResultFields(result).merging([
                    "durationMilliseconds": Self.elapsedMilliseconds(since: requestStartedAt)
                ]) { _, new in new }
            ) { _, new in new })
            await PlayhouseDiagnostics.endBatch()
            return response
        } catch let error as ReleaseVerificationError {
            PlayhouseDiagnostics.record("bridge.request.failed", fields: requestFields.merging([
                "errorCode": error.code,
                "errorDescription": error.message,
                "durationMilliseconds": Self.elapsedMilliseconds(since: requestStartedAt)
            ]) { _, new in new })
            await PlayhouseDiagnostics.endBatch()
            return .failure(request, code: error.code, message: error.message)
        } catch let error as BridgeCommandError {
            PlayhouseDiagnostics.record("bridge.request.failed", fields: requestFields.merging([
                "errorCode": error.code,
                "errorDescription": error.message,
                "durationMilliseconds": Self.elapsedMilliseconds(since: requestStartedAt)
            ]) { _, new in new })
            await PlayhouseDiagnostics.endBatch()
            return .failure(request, code: error.code, message: error.message)
        } catch let error as PlayhouseManagerError {
            let code: String
            switch error {
            case .taskNotFound: code = "not_found"
            case .invalidTitle, .invalidStatus, .noWorkspaceRoots, .unavailableWorkspaceRoot, .invalidParentFolder, .invalidMessage, .repositoryAssigned, .branchAssigned: code = "invalid_argument"
            case .invalidTransition: code = "invalid_argument"
            case .unmergedPullRequests, .uncommittedChanges: code = "invalid_transition"
            }
            PlayhouseDiagnostics.record("bridge.request.failed", fields: requestFields.merging([
                "errorCode": code,
                "errorDescription": error.localizedDescription,
                "durationMilliseconds": Self.elapsedMilliseconds(since: requestStartedAt)
            ]) { _, new in new })
            await PlayhouseDiagnostics.endBatch()
            return .failure(request, code: code, message: error.localizedDescription)
        } catch {
            var fields = requestFields
            fields.merge(PlayhouseDiagnostics.errorFields(error, includeUserInfoDetails: true)) { _, new in new }
            fields["errorCode"] = "operation_failed"
            fields["durationMilliseconds"] = Self.elapsedMilliseconds(since: requestStartedAt)
            PlayhouseDiagnostics.record("bridge.request.failed", fields: fields)
            await PlayhouseDiagnostics.endBatch()
            return .failure(request, code: "operation_failed", message: error.localizedDescription)
        }
    }


}
