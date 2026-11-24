import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension ConversationManager {
    func modelCacheKey(for provider: ConversationProvider) -> String {
        "conversation.models.cache.\(provider.rawValue)"
    }

    func selectedModelKey(for provider: ConversationProvider) -> String {
        "conversation.model.selected.\(provider.rawValue)"
    }

    func cachedModels(taskID: UUID) throws -> [ConversationModelOption] {
        let task = try tasks.conversationSubject(taskID)
        return try cachedModels(provider: task.conversationProvider)
    }

    func cachedModels(taskID: UUID, provider: ConversationProvider) throws -> [ConversationModelOption] {
        _ = try tasks.conversationSubject(taskID)
        return try cachedModels(provider: provider)
    }

    func cachedModels(provider: ConversationProvider) throws -> [ConversationModelOption] {
        guard let data = preferences.data(forKey: modelCacheKey(for: provider)),
              let models = try? JSONDecoder().decode([ConversationModelOption].self, from: data),
              !models.isEmpty else { return [] }
        return models.newestVersionPerFamily()
    }

    func models(taskID: UUID) async throws -> [ConversationModelOption] {
        PlayhouseDiagnostics.record("conversation.models.read.started", fields: ["taskID": taskID.uuidString])
        let task = try tasks.conversationSubject(taskID)
        var selectionToReconcile = task.conversationModelID
        if let selectedModelID = task.conversationModelID,
           let replacement = try cachedModels(provider: task.conversationProvider)
                .supersedingModel(forSelectedID: selectedModelID) {
            let replaced = try await tasks.replaceConversationModelID(
                taskID,
                expectedProvider: task.conversationProvider,
                expectedModelID: selectedModelID,
                replacementModelID: replacement.id
            )
            selectionToReconcile = replaced ? replacement.id : nil
        }
        let workspace = try ConversationWorkspaceContext(roots: task.workspaceRootPaths.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        })
        let models = try await client(for: task).availableModels(workspace: workspace).newestVersionPerFamily()
        if let data = try? JSONEncoder().encode(models) {
            preferences.set(data, forKey: modelCacheKey(for: task.conversationProvider))
        }
        if let selectedModelID = selectionToReconcile,
           let replacement = models.supersedingModel(forSelectedID: selectedModelID) {
            _ = try await tasks.replaceConversationModelID(
                taskID,
                expectedProvider: task.conversationProvider,
                expectedModelID: selectedModelID,
                replacementModelID: replacement.id
            )
        }
        PlayhouseDiagnostics.record("conversation.models.read.succeeded", fields: [
            "taskID": taskID.uuidString,
            "provider": task.conversationProvider.rawValue,
            "modelCount": String(models.count),
            "modelIDs": models.map(\.id).joined(separator: ",")
        ])
        return models
    }

    func effort(taskID: UUID) throws -> ConversationEffort {
        ConversationEffort(rawValue: try tasks.conversationSubject(taskID).conversationEffort) ?? .medium
    }

    func modelID(taskID: UUID) throws -> String? {
        try modelID(taskID: taskID, provider: tasks.conversationSubject(taskID).conversationProvider)
    }

    /// The model the conversation would run with `provider`, which need not be the
    /// provider it runs now: a window shows a switch before the switch is saved.
    func modelID(taskID: UUID, provider: ConversationProvider) throws -> String? {
        let task = try tasks.conversationSubject(taskID)
        let key = selectedModelKey(for: provider)
        if let conversationModelID = task.conversationModelID(for: provider) {
            return supersededSelection(conversationModelID, provider: provider, key: nil)
        }
        if let historicalModelID = latestTranscriptModelID(taskID: taskID, provider: provider) {
            return supersededSelection(historicalModelID, provider: provider, key: nil)
        }
        if let selectedModelID = preferences.string(forKey: key) {
            return supersededSelection(selectedModelID, provider: provider, key: key)
        }
        return nil
    }

    func latestTranscriptModelID(taskID: UUID, provider: ConversationProvider) -> String? {
        // Opening a conversation asks this on the main thread, so it reads the segments and
        // then only as many messages as it takes to find a model, never the whole transcript.
        guard let transcript = try? transcripts.readState(taskID) else { return nil }
        let segmentIDs = Set(transcript.segments.filter { $0.provider == provider }.map(\.id))
        return try? transcripts.latestAssistantModelID(taskID, segmentIDs: segmentIDs)
    }

    /// A remembered model the provider no longer offers keeps running behind the
    /// picker, so a selection superseded within its own family follows the family
    /// forward, keeping sends and the composer on one model.
    ///
    /// This sits on the read rather than on the model refresh so that every consumer
    /// converges at once: the composer primes from cache before `models(taskID:)`
    /// returns, and a send reads the remembered ID without refreshing the list. The
    /// write is idempotent — once the stored ID is one the provider offers, later
    /// reads find nothing to supersede. `key` is nil when the caller persists the
    /// result itself.
    ///
    /// The cache is the only source of truth here, so on the first launch after an
    /// update a send issued before the first `models(taskID:)` fetch lands still uses
    /// the remembered ID. That window closes on the next read and never clobbers a
    /// selection, which is why an empty cache deliberately supersedes nothing.
    func supersededSelection(_ selectedModelID: String, provider: ConversationProvider, key: String?) -> String {
        guard let models = try? cachedModels(provider: provider),
              let replacement = models.supersedingModel(forSelectedID: selectedModelID) else { return selectedModelID }
        if let key { preferences.set(replacement.id, forKey: key) }
        PlayhouseDiagnostics.record("conversation.model.selection.superseded", fields: [
            "provider": provider.rawValue, "from": selectedModelID, "to": replacement.id
        ])
        return replacement.id
    }

    func setEffort(taskID: UUID, effort: ConversationEffort) async throws -> BoardTaskRecord {
        try await tasks.setConversationEffort(taskID, effort: effort)
    }

    func contextMode(taskID: UUID) throws -> ConversationContextMode {
        try tasks.conversationSubject(taskID).conversationContextMode
    }

    func setContextMode(taskID: UUID, mode: ConversationContextMode) async throws -> BoardTaskRecord {
        defer { Self.bumpVisibleRevision(taskID) }
        return try await tasks.setConversationContextMode(taskID, mode: mode)
    }

    /// Without `provider`, the choice is the current provider's.
    func setModelID(taskID: UUID, modelID: String, provider: ConversationProvider? = nil) async throws {
        let provider = try provider ?? tasks.conversationSubject(taskID).conversationProvider
        try await tasks.setConversationModelID(taskID, modelID: modelID, provider: provider)
        preferences.set(modelID, forKey: selectedModelKey(for: provider))
    }
    // MARK: - Providers

    /// OpenCode finds only the skills in its own folders, so it doesn't get Playhouse's plugin
    /// skill, and a plugin editor can't run on it.
    static func canRun(_ task: any ConversationSubject, on provider: ConversationProvider) -> Bool {
        task.authoringPluginPlacement == nil || canAuthorPlugins(on: provider)
    }

    static func canAuthorPlugins(on provider: ConversationProvider) -> Bool {
        provider != .opencode
    }

    static var pluginAuthoringUnavailable: PlayhouseManagerError {
        .invalidTransition("Plugin editors can't use OpenCode: it doesn't get Playhouse's plugin skill. Use Claude or Codex.")
    }

    /// Detected native capabilities, so switching can show what differs. Playhouse
    /// starts Codex without apps or hooks and with the MCP servers turned on in
    /// the MCP page; Claude Code uses its own configuration.
    func providerCapabilities(taskID: UUID) async throws -> [ConversationProviderCapabilities] {
        let task = try tasks.conversationSubject(taskID)
        let workspace = try ConversationWorkspaceContext(roots: Self.historyRoots(task).map { URL(fileURLWithPath: $0, isDirectory: true) })
        let codex = ConversationProviderCapabilities(
            provider: .codex,
            isAvailable: clients.codex.isInstalled,
            supportsGoals: true,
            notes: ["Playhouse runs Codex without apps or hooks, with the MCP servers turned on in Skills, Rules & MCP.", "Goals are available."]
        )
        let opencode = ConversationProviderCapabilities(
            provider: .opencode,
            isAvailable: clients.opencode.isInstalled,
            supportsGoals: false,
            notes: [
                "Playhouse runs OpenCode with its own model providers, skills, rules and MCP servers: the on/off switches in Skills, Rules & MCP don't apply to it.",
            ]
        )
        return [codex, await clients.claude.capabilities(workspace: workspace), opencode]
    }

    /// What each provider reports about the MCP servers it would start for the
    /// task, such as one that needs the user to sign in. Claude Code is asked
    /// with the task's own MCP bridge, so it also reports the servers Playhouse
    /// passes it and its claude.ai connectors and plugin servers; Codex reports
    /// the servers in its own configuration.
    /// The workspace a provider is asked about the task's MCP servers in: the
    /// task's folders with its MCP bridge, or an empty one without a task.
    func mcpWorkspace(taskID: UUID?) -> ConversationWorkspaceContext? {
        let task = taskID.flatMap { try? tasks.conversationSubject($0) }
        let roots = task.map { Self.historyRoots($0).map { URL(fileURLWithPath: $0, isDirectory: true) } } ?? []
        guard var workspace = (try? ConversationWorkspaceContext(roots: roots)) ?? (try? ConversationWorkspaceContext(roots: [])) else { return nil }
        if let task, let mcp = clients.mcp { workspace.mcpBridge = mcp.bridge(roots: SkillRoot.roots(for: task)) }
        return workspace
    }

    /// With `provider`, only that provider is asked, so a sign-in that is being
    /// waited on doesn't start the other one.
    func mcpStatus(taskID: UUID?, provider: ConversationProvider? = nil) async -> McpStatusReport {
        var report = McpStatusReport()
        guard let workspace = mcpWorkspace(taskID: taskID) else {
            report.errors = Dictionary(uniqueKeysWithValues: ConversationProvider.allCases.map { ($0.rawValue, "The task's folders are missing.") })
            return report
        }
        if provider == nil || provider == .claude {
            let claude = await clients.claude.capabilities(workspace: workspace)
            if claude.isAvailable {
                report.claude = claude.mcpServers.map { McpProviderStatus(name: $0.name, status: $0.status, needsSignIn: $0.status == "needs-auth") }
            } else {
                report.errors["claude"] = claude.error ?? "Claude Code is not installed."
            }
        }
        if provider == nil || provider == .opencode {
            if clients.opencode.isInstalled {
                do {
                    report.opencode = try await clients.opencode.mcpServerStatuses(workspace: workspace)
                } catch {
                    report.errors["opencode"] = error.localizedDescription
                }
            } else if provider == .opencode {
                report.errors["opencode"] = "OpenCode is not installed."
            }
        }
        if provider == nil || provider == .codex {
            if clients.codex.isInstalled {
                do {
                    report.codex = try await clients.codex.mcpServerStatuses(workspace: workspace)
                } catch {
                    report.errors["codex"] = error.localizedDescription
                }
            } else {
                report.errors["codex"] = "Codex is not installed."
            }
        }
        PlayhouseDiagnostics.record("mcp.status.read", fields: [
            "claudeCount": String(report.claude.count), "codexCount": String(report.codex.count),
            "opencodeCount": String(report.opencode.count),
        ])
        return report
    }

    /// Starts the sign-in of an MCP server in one provider and returns the link
    /// to open in the browser. The provider finishes the sign-in when the browser
    /// redirects back to it; `mcpLoginResult` waits for that.
    func startMcpLogin(taskID: UUID?, provider: ConversationProvider, name: String) async throws -> McpLoginStart {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BridgeCommandError(code: "invalid_argument", message: "Name the MCP server to sign in to.")
        }
        guard let workspace = mcpWorkspace(taskID: taskID) else {
            throw BridgeCommandError(code: "invalid_argument", message: "The task's folders are missing.")
        }
        let link: String
        switch provider {
        case .claude: link = try await clients.claude.startMcpLogin(name: name, workspace: workspace)
        case .codex:
            guard clients.codex.isInstalled else { throw BridgeCommandError(code: "unavailable", message: "Codex is not installed.") }
            link = try await clients.codex.startMcpLogin(name: name, workspace: workspace)
        case .opencode:
            guard clients.opencode.isInstalled else { throw BridgeCommandError(code: "unavailable", message: "OpenCode is not installed.") }
            link = try await clients.opencode.startMcpLogin(name: name, workspace: workspace)
        }
        return McpLoginStart(provider: provider, name: name, authorizationUrl: link)
    }

    /// Waits for a started sign-in to finish: signed in, failed, or timed out.
    func mcpLoginResult(taskID: UUID?, provider: ConversationProvider, name: String) async -> McpLoginResult {
        switch provider {
        case .claude: return await clients.claude.waitForMcpLogin(name: name)
        case .codex:
            guard let workspace = mcpWorkspace(taskID: taskID) else { return McpLogin.notStarted(provider: .codex, name: name) }
            return await clients.codex.waitForMcpLogin(name: name, workspace: workspace)
        case .opencode:
            guard let workspace = mcpWorkspace(taskID: taskID) else { return McpLogin.notStarted(provider: .opencode, name: name) }
            return await clients.opencode.waitForMcpLogin(name: name, workspace: workspace)
        }
    }

    /// Changes the provider that runs the task's next turn. A switch waits for the
    /// current turn, pending questions, queued follow-ups, and background
    /// subagents to settle, and records a boundary in the transcript.
    /// `remembersDefault` is false when Playhouse picks the provider itself (an unstarted
    /// conversation moving to the provider that is installed), which isn't the user's choice.
    func setProvider(taskID: UUID, provider: ConversationProvider, remembersDefault: Bool = true) async throws -> BoardTaskRecord {
        _ = await ConversationTurnLaunch.providerStopOutcome(taskID)
        var task = try tasks.conversationSubject(taskID)
        PlayhouseDiagnostics.record("conversation.provider.switch.started", fields: [
            "taskID": taskID.uuidString, "from": task.conversationProvider.rawValue, "to": provider.rawValue
        ])
        guard task.status != .done else {
            throw PlayhouseManagerError.invalidTransition("Done tasks are closed. Create a new task to use another provider.")
        }
        guard Self.canRun(task, on: provider) else { throw Self.pluginAuthoringUnavailable }
        // The user's explicit choice becomes the default for the next task or
        // chat, so a provider switch doesn't keep reverting to Codex.
        if remembersDefault { try? settingsManager.setDefaultConversationProvider(provider.rawValue) }
        guard task.conversationProvider != provider else { return BoardTaskRecord(task: task) }
        guard task.hasConversation else {
            return try await tasks.setConversationProvider(taskID, provider: provider)
        }
        let history = try await requireSettledConversation(task)
        if history.activities.contains(where: { $0.isSubagent && $0.isActive }) {
            throw Self.switchBlocked("Subagents are still running. Wait for them to finish before switching providers.")
        }
        // Turns follow their segments in order, so the last segment has turns
        // exactly when it owns the latest turn.
        try transcripts.mutate(taskID, turns: .latest) { transcript in
            if transcript.segments.isEmpty {
                transcript.segments.append(.init(id: UUID().uuidString, provider: task.conversationProvider, startedAt: .now, handoffDelivered: true))
            }
            // A segment with no turns can be replaced instead of leaving an empty boundary.
            if let last = transcript.segments.last, transcript.turns(in: last).isEmpty, transcript.segments.count > 1 {
                transcript.segments.removeLast()
            }
            if transcript.segments.last?.provider != provider {
                transcript.segments.append(.init(id: UUID().uuidString, provider: provider, startedAt: .now))
            }
        }
        task = try tasks.conversationSubject(taskID)
        let record = try await tasks.setConversationProvider(taskID, provider: provider)
        PlayhouseDiagnostics.record("conversation.provider.switch.succeeded", fields: [
            "taskID": taskID.uuidString, "provider": provider.rawValue,
            "segmentCount": String((try? transcripts.readState(taskID).segments.count) ?? 0)
        ])
        return record
    }

    /// The provider dividers a history read shows, from the newest page alone.
    func providerBoundaries(taskID: UUID) async throws -> [ConversationProviderBoundary] {
        try await history(taskID: taskID, messageLimit: 1).providerBoundaries
    }

    /// Returns the newest page of history once nothing is still running or waiting.
    /// A page is enough: it carries the saved question request and every subagent's
    /// activity, and a question still waiting for its answer is the latest turn's.
    /// Composing a long conversation in full held up every switch for its length.
    func requireSettledConversation(_ task: any ConversationSubject) async throws -> ConversationHistory {
        let client = client(for: task)
        if try tasks.hasConversationTurnReservation(task.id) || activeSendTaskIDs.contains(task.id) {
            throw Self.switchBlocked("Wait for the current turn to finish before switching providers.")
        }
        if let conversationID = task.activeConversationID,
           client.isTurnActive(threadID: conversationID) || client.isTurnActiveInProcess(threadID: conversationID)
            || client.activeTurnOwnerProcessID(threadID: conversationID) != nil {
            throw Self.switchBlocked("Wait for the current turn to finish before switching providers.")
        }
        if task.pendingSubmittedPrompt != nil {
            throw Self.switchBlocked("Wait for the submitted prompt to start before switching providers.")
        }
        if !(try tasks.queuedConversationMessages(taskID: task.id)).isEmpty {
            throw Self.switchBlocked("Send or remove the queued follow-ups before switching providers.")
        }
        let history = try await self.history(taskID: task.id, messageLimit: Self.settledCheckMessageLimit)
        if history.pendingUserInputRequest != nil {
            throw Self.switchBlocked("Answer the pending structured question before switching providers.")
        }
        let answered = Set(history.answeredAsyncQuestionIDs)
        if history.messages.contains(where: { $0.asyncQuestions != nil && !answered.contains($0.id) }),
           task.status == .waitingResponse {
            throw Self.switchBlocked("Answer the pending question before switching providers.")
        }
        return history
    }

    /// The page the settled check reads; any page holding the latest turn will do.
    static let settledCheckMessageLimit = 80

    static func switchBlocked(_ message: String) -> BridgeCommandError {
        PlayhouseDiagnostics.record("conversation.provider.switch.blocked", fields: ["reason": message])
        return BridgeCommandError(code: "invalid_transition", message: message)
    }
}

// MARK: - Installing providers

/// Whether one provider's CLI can be found, and the official installer Playhouse runs for it.
struct ConversationProviderInstallStatus: Codable, Equatable {
    let provider: ConversationProvider
    /// The product the installer adds, such as Claude Code.
    let productName: String
    var isInstalled: Bool
    let installCommand: String
}

/// Finds and installs the providers' CLIs. The window and the CLI both reach it through the
/// daemon's `providers` commands, so an install started in either is the one the other sees.
@MainActor
enum ConversationProviderInstaller {
    nonisolated static func productName(_ provider: ConversationProvider) -> String {
        switch provider {
        case .claude: "Claude Code"
        case .codex: "Codex CLI"
        case .opencode: "OpenCode"
        }
    }

    /// Each provider's own documented installer: a script that installs the CLI where
    /// Playhouse looks for it (`~/.local/bin`, or `~/.opencode/bin` for OpenCode), with no prompts.
    nonisolated static func officialInstallCommand(_ provider: ConversationProvider) -> String {
        switch provider {
        case .claude: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh"
        case .opencode: "curl -fsSL https://opencode.ai/v2/install | bash"
        }
    }

    static func isInstalled(_ provider: ConversationProvider, clients: ConversationClients) -> Bool {
        switch provider {
        case .claude: clients.claude.isInstalled
        case .codex: clients.codex.isInstalled
        case .opencode: clients.opencode.isInstalled
        }
    }

    static func statuses(clients: ConversationClients) -> [ConversationProviderInstallStatus] {
        ConversationProvider.allCases.map { status($0, clients: clients) }
    }

    static func status(_ provider: ConversationProvider, clients: ConversationClients) -> ConversationProviderInstallStatus {
        ConversationProviderInstallStatus(
            provider: provider, productName: productName(provider),
            isInstalled: isInstalled(provider, clients: clients),
            installCommand: officialInstallCommand(provider)
        )
    }

    /// Runs the provider's installer unless its CLI is already there, then checks that
    /// Playhouse now finds it. A second request while one install runs waits for that one.
    /// `fixtureInstaller` is a test's owned installer script, run with the provider's name
    /// instead of the network installer.
    static func install(
        _ provider: ConversationProvider, clients: ConversationClients, fixtureInstaller: String? = nil
    ) async throws -> ConversationProviderInstallStatus {
        if isInstalled(provider, clients: clients) { return status(provider, clients: clients) }
        let running = runningInstalls[provider] ?? Task {
            defer { runningInstalls[provider] = nil }
            try await runInstaller(provider, fixtureInstaller: fixtureInstaller)
        }
        runningInstalls[provider] = running
        try await running.value
        guard isInstalled(provider, clients: clients) else {
            PlayhouseDiagnostics.record("provider.install.not_found", fields: ["provider": provider.rawValue])
            throw BridgeCommandError(
                code: "operation_failed",
                message: "The \(productName(provider)) installer finished, but Playhouse couldn't find `\(provider.executableName)` where it installs or on PATH."
            )
        }
        AgentUsageStore.shared(scope: clients.codex.runtimeScope).setInstalled(provider, true)
        return status(provider, clients: clients)
    }

    private static var runningInstalls: [ConversationProvider: Task<Void, Error>] = [:]

    private static let installTimeout = Duration.seconds(15 * 60)

    private static let fixtureMarker = (name: ".playhouse-provider-installer-fixture-owner", value: "Playhouse test owns this provider installer fixture (v1).\n")

    private static func runInstaller(_ provider: ConversationProvider, fixtureInstaller: String?) async throws {
        let process = Process()
        var environment = PlayhouseProcessEnvironment.current
        let home = NSHomeDirectory()
        // A window's PATH is launchd's short one; the installers need curl, bash and sh.
        environment["PATH"] = ClaudeCodeClient.expandedSearchPath(environment["PATH"])
        environment["HOME"] = environment["HOME"] ?? home
        if let fixtureInstaller {
            guard let owned = ConversationProviderFixture.ownedExecutable(fixtureInstaller, providerMarker: fixtureMarker),
                  owned != ConversationProviderFixture.notInstalledOverride else {
                throw BridgeCommandError(code: "invalid_argument", message: "The provider installer fixture isn't one a Playhouse test owns.")
            }
            let command = ConversationProviderFixture.launchCommand(executable: owned, arguments: [provider.rawValue])
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", officialInstallCommand(provider)]
        }
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: home, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let collected = InstallerOutput()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                collected.finish()
            } else {
                collected.append(chunk)
            }
        }
        PlayhouseDiagnostics.record("provider.install.started", fields: [
            "provider": provider.rawValue, "fixture": fixtureInstaller == nil ? "false" : "true",
        ])
        // A stuck download would otherwise hold this provider's install forever. The shell's
        // children (curl and the piped shell) go first, so none is left holding the output open.
        let timeout = installTimeout
        let watchdog = Task.detached {
            try await Task.sleep(for: timeout)
            guard process.isRunning else { return }
            let children = Process()
            children.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            children.arguments = ["-TERM", "-P", String(process.processIdentifier)]
            try? children.run()
            children.waitUntilExit()
            process.terminate()
        }
        defer { watchdog.cancel() }
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        // The last output arrives just after exit. A child still holding the pipe open must not
        // stall the daemon, so the wait for the end of output is short.
        for _ in 0..<40 {
            guard !collected.isFinished else { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        output.fileHandleForReading.readabilityHandler = nil
        guard status == 0 else {
            let tail = collected.tail
            // The installers' own messages are terse ("Failed to fetch package information"),
            // so say which of the hosts they download from this Mac can't reach.
            let unreachable = fixtureInstaller == nil ? await unreachableHosts(installHosts(provider), environment: environment) : []
            PlayhouseDiagnostics.record("provider.install.failed", fields: [
                "provider": provider.rawValue, "exitStatus": String(status), "output": tail,
                "unreachableHosts": unreachable.joined(separator: ","),
            ])
            var message = "Installing \(productName(provider)) failed (exit \(status))."
            if !tail.isEmpty { message += " The installer said: \"\(tail)\"." }
            if !unreachable.isEmpty {
                message += " This Mac can't reach \(unreachable.joined(separator: " or ")), which the installer downloads from."
                    + " A firewall, VPN or proxy may be blocking it; allow access, or install from another network."
            }
            if fixtureInstaller == nil {
                message += " To see the full output, run `\(officialInstallCommand(provider))` in Terminal."
            }
            throw BridgeCommandError(code: "operation_failed", message: message)
        }
        PlayhouseDiagnostics.record("provider.install.succeeded", fields: ["provider": provider.rawValue])
    }

    /// The hosts each official installer downloads from: the script's own host, plus npm for
    /// OpenCode 2, whose installer fetches the binary package from the npm registry.
    private static func installHosts(_ provider: ConversationProvider) -> [String] {
        switch provider {
        case .claude: ["claude.ai"]
        case .codex: ["chatgpt.com"]
        case .opencode: ["opencode.ai", "registry.npmjs.org"]
        }
    }

    /// The hosts curl can't connect to within a few seconds. It uses curl, with the installer's
    /// environment, so proxies and certificates are the ones the installer saw.
    private static func unreachableHosts(_ hosts: [String], environment: [String: String]) async -> [String] {
        await Task.detached {
            hosts.filter { host in
                let curl = Process()
                curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                curl.arguments = ["-s", "-o", "/dev/null", "--connect-timeout", "5", "--max-time", "8", "https://\(host)/"]
                curl.environment = environment
                curl.standardInput = FileHandle.nullDevice
                curl.standardOutput = FileHandle.nullDevice
                curl.standardError = FileHandle.nullDevice
                guard (try? curl.run()) != nil else { return false }
                curl.waitUntilExit()
                // Any HTTP response, even an error status, means the host is reachable.
                return curl.terminationStatus != 0
            }
        }.value
    }

    /// The installer's combined output, collected off the main thread.
    private final class InstallerOutput: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        private var finished = false

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock(); data.append(chunk); lock.unlock()
        }

        /// Marks the end of the output.
        func finish() {
            lock.lock(); finished = true; lock.unlock()
        }

        var isFinished: Bool {
            lock.lock(); defer { lock.unlock() }
            return finished
        }

        /// The last lines, enough to say why an install failed.
        var tail: String {
            lock.lock(); defer { lock.unlock() }
            let text = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            return text.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        }
    }
}

extension ConversationProvider {
    /// The command its CLI installs.
    var executableName: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .opencode: "opencode"
        }
    }
}
