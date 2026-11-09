import AppKit
import SwiftUI

/// The MCP servers that give agents tools: each repository's `.mcp.json` and
/// `.codex/config.toml`, the user's own servers in Claude Code's and Codex's
/// configuration, and the organization's managed ones. Like skills and rules,
/// each server is passed to the provider that would not start it on its own.
struct McpServersSectionView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case repo = "Repo"
        case global = "Global"
        case managed = "Managed"
        var id: String { rawValue }
    }

    enum Panel {
        case editing(McpServerRecord, McpServerConfig)
        case creating
    }

    let task: any ConversationSubject
    let manager: RemoteConversationManager
    @Binding var isPresentingPanel: Bool
    let onFixTask: (UUID, String) -> Void

    @State private var tab: Tab = .repo
    @State private var catalog: McpCatalog?
    @State private var status: McpStatusReport?
    @State private var isCheckingStatus = false
    @State private var recheckRequested = false
    /// Sign-ins waiting for the browser, as `name|provider`.
    @State private var signingIn = Set<String>()
    @State private var errorMessage: String?
    @State private var panel: Panel?
    @State private var pendingDelete: McpServerRecord?
    @State private var pendingLink: McpServerRecord?
    /// A toggle shows its new state at once; the daemon's answer settles it.
    @State private var enabledOverrides: [String: Bool] = [:]
    @State private var isFixing = false

    private static let panelAnimation = Animation.spring(response: 0.34, dampingFraction: 0.9)

    /// A server's name is unique in its scope, so a repository server is told
    /// apart by its repository.
    static func key(_ server: McpServerRecord) -> String {
        switch server.scope {
        case .repo: URL(fileURLWithPath: server.repositoryPath ?? "").lastPathComponent + ":" + server.name
        case .global: server.name
        case .managed: "managed:" + server.name
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Picker("Server source", selection: $tab) {
                    ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .accessibilityIdentifier("mcp-tab-picker")
                Spacer()
                if isCheckingStatus {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking sign-in…").font(.callout).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("mcp-checking-status")
                }
                Button { setPanel(.creating) } label: { Label("New Server", systemImage: "plus") }
                    .buttonHoverPointer()
                    .nativeHelp("Add an MCP server that both Claude and Codex can use")
                    .accessibilityIdentifier("new-mcp-server-button")
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("mcp-error")
            }
            Text("MCP servers give agents tools. Click one to open it. Turning a server on or off reaches both agents on their next turn.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .accessibilityIdentifier("mcp-provider-timing")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) { content }
                    .padding(20)
            }
            .accessibilityIdentifier("mcp-list")
        }
        // A closed panel's removal transition can leave the overlay catching clicks over the
        // header (New Server stopped responding after a create), so it takes hits only while open.
        .overlay { panels.allowsHitTesting(panel != nil) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mcp-page")
        .task {
            // Opening the page asks both agents which servers need a sign-in, while the list loads.
            async let statuses: Void = checkStatus()
            await reload()
            await statuses
        }
        .alert(
            "Delete \(pendingDelete?.name ?? "server")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { server in
            Button("Delete", role: .destructive) { perform { try await manager.deleteMcpServers(taskID: task.id, serverIDs: [server.id]) } }
                .buttonHoverPointer()
                .nativeHelp("Remove the server from every file that defines it")
                .accessibilityIdentifier("confirm-delete-mcp")
            Button("Cancel", role: .cancel) {}
                .buttonHoverPointer()
                .nativeHelp("Keep the server")
        } message: { server in
            Text("This removes \(server.name) from \(server.locations.map(\.path).joined(separator: " and ")), so neither Claude nor Codex starts it.")
        }
        .confirmationDialog(
            "Make \(pendingLink?.name ?? "server") available outside Playhouse?",
            isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
            presenting: pendingLink
        ) { server in
            Button("Add to Both CLIs") { perform { _ = try await manager.linkMcpServer(taskID: task.id, serverID: server.id) } }
                .buttonHoverPointer()
                .nativeHelp("Write the server into the configuration of the CLI that doesn't have it")
                .accessibilityIdentifier("confirm-link-mcp")
            Button("Cancel", role: .cancel) {}
                .buttonHoverPointer()
                .nativeHelp("Keep passing the server only in Playhouse sessions")
        } message: { server in
            Text(Self.linkMessage(server))
        }
    }

    private static func linkMessage(_ server: McpServerRecord) -> String {
        let missing = Set(ConversationProvider.allCases).subtracting(server.nativeProviders)
        switch (server.scope, missing.contains(.codex)) {
        case (.repo, true): return "Playhouse adds it to the repository's .codex/config.toml, so the codex CLI starts it outside Playhouse too in a trusted project. Commit it to share it with teammates."
        case (.repo, false): return "Playhouse adds it to the repository's .mcp.json, so the claude CLI starts it outside Playhouse too. Commit it to share it with teammates."
        case (_, true): return "Playhouse adds it to Codex's config.toml, so the codex CLI starts it outside Playhouse too."
        case (_, false): return "Playhouse adds it to Claude Code's user servers, so the claude CLI starts it outside Playhouse too."
        }
    }

    private func setPanel(_ value: Panel?) {
        withAnimation(Self.panelAnimation) { panel = value }
        isPresentingPanel = value != nil
    }

    private var panels: some View {
        ZStack {
            if panel != nil {
                Color.black.opacity(0.18).ignoresSafeArea().transition(.opacity).zIndex(0)
            }
            switch panel {
            case .editing(let server, let config):
                McpServerEditorPanel(server: server, config: config, roots: [], onClose: { setPanel(nil) }) { _, edited, _, _ in
                    let record = try await manager.updateMcpServer(taskID: task.id, serverID: server.id, config: edited)
                    catalog = catalog?.replacing(record)
                    await reload()
                }
                .id(server.id)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .transition(.move(edge: .bottom))
                .zIndex(1)
            case .creating:
                McpServerEditorPanel(server: nil, config: McpServerConfig(transport: .stdio), roots: catalog?.repositories ?? [], onClose: { setPanel(nil) }) { name, config, scope, root in
                    let record = try await manager.createMcpServer(taskID: task.id, name: name, config: config, scope: scope, root: root)
                    tab = record.scope == .global ? .global : .repo
                    await reload()
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .transition(.move(edge: .bottom))
                .zIndex(1)
            case nil:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let catalog {
            ForEach(catalog.problems, id: \.path) { problem in
                Label("\(problem.path): \(problem.message)", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("mcp-file-problem")
            }
            switch tab {
            case .repo:
                Text("Servers in the task's repositories: .mcp.json, which Claude reads, and .codex/config.toml, which Codex reads. Playhouse passes each one to the agent that would not start it on its own.")
                    .font(.callout).foregroundStyle(.secondary)
                if catalog.repositories.isEmpty {
                    emptyState("This task has no repositories.", identifier: "mcp-empty-repo")
                }
                ForEach(catalog.repositories, id: \.rootPath) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.name)
                            .font(.headline)
                            .padding(.top, 6)
                            .accessibilityIdentifier("mcp-repo-section-\(section.name)")
                        if section.servers.isEmpty {
                            emptyState("No MCP servers in \(section.name).", identifier: "mcp-empty-\(section.name)")
                        }
                        ForEach(section.servers) { row($0) }
                    }
                }
            case .global:
                Text("Your servers for every repository, from Claude Code's ~/.claude.json and Codex's config.toml. New global servers are written into both, so both CLIs start them.")
                    .font(.callout).foregroundStyle(.secondary)
                if catalog.global.isEmpty { emptyState("No global MCP servers.", identifier: "mcp-empty-global") }
                ForEach(catalog.global) { row($0) }
            case .managed:
                Text("Your organization's managed servers. Claude Code always starts them, and they can't be edited or turned off here.")
                    .font(.callout).foregroundStyle(.secondary)
                if catalog.managed.isEmpty { emptyState("No managed MCP servers on this Mac.", identifier: "mcp-empty-managed") }
                ForEach(catalog.managed) { row($0) }
                connectors(catalog)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("mcp-loading")
        }
    }

    /// Servers Claude Code reports that no file here defines, such as claude.ai
    /// connectors and plugin servers. Known once the sign-in check has answered.
    @ViewBuilder
    private func connectors(_ catalog: McpCatalog) -> some View {
        let known = Set(catalog.allServers.map(\.name))
        let others = (status?.claude ?? []).filter { !known.contains($0.name) }
        Text("Also started by Claude Code")
            .font(.headline)
            .padding(.top, 10)
        if status == nil {
            Text("Checking which claude.ai connectors and plugin servers Claude Code starts on its own…")
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("mcp-connectors-hint")
        } else if others.isEmpty {
            emptyState("Claude Code starts no other servers.", identifier: "mcp-connectors-empty")
        }
        ForEach(others, id: \.name) { server in
            HStack(spacing: 8) {
                Text(server.name).font(.body.weight(.semibold))
                if server.needsSignIn {
                    connectorSignInButton(server)
                } else {
                    badge(server.status, systemImage: "circle.fill", color: .secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mcp-connector-\(server.name)")
        }
    }

    /// A claude.ai connector is signed in to on claude.ai, not from Claude Code,
    /// so its badge opens the connectors settings; a plugin server is signed in
    /// to the same way as any other server.
    @ViewBuilder
    private func connectorSignInButton(_ server: McpProviderStatus) -> some View {
        let isConnector = server.name.hasPrefix("claude.ai ")
        let key = "\(server.name)|claude"
        Button {
            if isConnector {
                openInBrowser("https://claude.ai/settings/connectors")
            } else {
                signIn(name: server.name, provider: .claude)
            }
        } label: {
            signInLabel("Sign in for Claude", waiting: signingIn.contains(key))
        }
        .buttonStyle(.plain)
        .disabled(signingIn.contains(key))
        .buttonHoverPointer()
        .nativeHelp(isConnector ? "Connect \(server.name) in claude.ai's connector settings" : "Open your browser to sign in to \(server.name) for Claude")
        .accessibilityIdentifier("mcp-connector-signin-\(server.name)")
    }

    private func signInLabel(_ text: String, waiting: Bool) -> some View {
        HStack(spacing: 4) {
            if waiting { ProgressView().controlSize(.mini) } else { Image(systemName: "person.badge.key") }
            Text(waiting ? "Waiting for sign-in…" : text).lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(.orange)
        .background(Color.orange.opacity(0.12), in: Capsule())
    }

    private func emptyState(_ text: String, identifier: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding(.vertical, 6).accessibilityIdentifier(identifier)
    }

    private func isEnabled(_ server: McpServerRecord) -> Bool { enabledOverrides[server.id] ?? server.enabled }

    /// Only names: values can be secrets.
    private static func variableNames(_ server: McpServerRecord) -> String {
        var parts: [String] = []
        if !server.envNames.isEmpty { parts.append("Environment: " + server.envNames.joined(separator: ", ")) }
        if !server.headerNames.isEmpty { parts.append("Headers: " + server.headerNames.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    private static func sharedNote(_ server: McpServerRecord) -> String? {
        guard !server.sharedWith.isEmpty else { return nil }
        return "Playhouse passes it to " + server.sharedWith.map(\.displayName).joined(separator: " and ") + "."
    }

    /// The providers that reported the server needs a sign-in.
    private func signInNeeded(_ server: McpServerRecord) -> [ConversationProvider] {
        guard let status else { return [] }
        return [ConversationProvider.claude, .codex].filter { provider in
            let reports = provider == .claude ? status.claude : status.codex
            return reports.contains { $0.name == server.name && $0.needsSignIn }
        }
    }

    private func row(_ server: McpServerRecord) -> some View {
        let key = Self.key(server)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(server.name)
                            .font(.body.weight(.semibold))
                            .accessibilityIdentifier("mcp-name-\(key)")
                        badge(server.transport == .stdio ? "Local" : server.transport.rawValue.uppercased(),
                              systemImage: server.transport == .stdio ? "terminal" : "network", color: .purple)
                            .accessibilityIdentifier("mcp-transport-\(key)")
                        ForEach([ConversationProvider.claude, .codex]) { provider in
                            if server.providers.contains(provider) {
                                badge(provider.displayName, systemImage: "checkmark", color: .green)
                                    .accessibilityIdentifier("mcp-provider-\(key)-\(provider.rawValue)")
                            }
                        }
                        if server.availableOutsidePlayhouse {
                            badge("Both CLIs", systemImage: "checkmark.seal", color: .blue)
                                .accessibilityIdentifier("mcp-native-\(key)")
                        }
                        if server.conflict {
                            badge("Conflict", systemImage: "exclamationmark.triangle", color: .orange)
                                .accessibilityIdentifier("mcp-conflict-\(key)")
                        } else if server.issue != nil {
                            badge("Problem", systemImage: "exclamationmark.triangle", color: .orange)
                                .accessibilityIdentifier("mcp-problem-\(key)")
                        }
                    }
                    Text(server.summary)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("mcp-summary-\(key)")
                    if !server.envNames.isEmpty || !server.headerNames.isEmpty {
                        Text(Self.variableNames(server))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("mcp-env-\(key)")
                    }
                    if let issue = server.issue {
                        Text(issue).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("mcp-issue-\(key)")
                    }
                    if let limitation = server.limitation {
                        Text(limitation).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("mcp-limitation-\(key)")
                    }
                    if !isEnabled(server), !server.alwaysOnFor.isEmpty {
                        Text("\(server.alwaysOnFor.map(\.displayName).joined(separator: " and ")) still starts it from its own configuration, so turning it off applies to the other agent only. Delete it to stop both.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("mcp-always-on-\(key)")
                    } else if let note = Self.sharedNote(server) {
                        Text(note).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("mcp-shared-\(key)")
                    }
                    Text(server.locations.map(\.layout.displayName).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("mcp-location-\(key)")
                }
                Spacer(minLength: 8)
            }
            .overlay {
                SkillRowPressArea(showsPointingHand: true, onClick: { openEditor(server) }, onLongPress: {})
            }
            // Outside the click-to-open area above, so the buttons get their own clicks.
            signInButtons(server, key: key)
            }
            if server.issue != nil, server.scope != .managed {
                Button { fix(server) } label: { Label("Fix with Agent", systemImage: "wand.and.stars") }
                    .controlSize(.small)
                    .disabled(isFixing)
                    .buttonHoverPointer()
                    .nativeHelp("Open a task whose agent fixes \(server.name)")
                    .accessibilityIdentifier("mcp-fix-\(key)")
            }
            if server.scope != .managed {
                Toggle("Enabled", isOn: Binding(get: { isEnabled(server) }, set: { setEnabled(server, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .buttonHoverPointer()
                    .nativeHelp(isEnabled(server) ? "Turn the server off in Playhouse sessions" : "Turn the server on in Playhouse sessions")
                    .accessibilityLabel("\(server.name) enabled")
                    .accessibilityIdentifier("mcp-toggle-\(key)")
            }
            actions(server, key: key)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mcp-row-\(key)")
    }

    /// One button per agent that needs the server's sign-in: the label that says
    /// so is what starts it.
    @ViewBuilder
    private func signInButtons(_ server: McpServerRecord, key: String) -> some View {
        let providers = signInNeeded(server)
        if !providers.isEmpty {
            HStack(spacing: 6) {
                ForEach(providers) { provider in
                    let waiting = signingIn.contains("\(server.name)|\(provider.rawValue)")
                    Button { signIn(name: server.name, provider: provider) } label: {
                        signInLabel("Sign in for \(provider.displayName)", waiting: waiting)
                    }
                    .buttonStyle(.plain)
                    .disabled(waiting)
                    .buttonHoverPointer()
                    .nativeHelp("Open your browser to sign in to \(server.name) for \(provider.displayName)")
                    .accessibilityIdentifier("mcp-signin-\(key)-\(provider.rawValue)")
                }
            }
        }
    }

    private func badge(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func actions(_ server: McpServerRecord, key: String) -> some View {
        Menu {
            Button(server.editable ? "Edit…" : "View…") { openEditor(server) }
                .buttonHoverPointer()
                .help(server.editable ? "Edit the server" : "Read the server's definition")
                .accessibilityIdentifier("mcp-edit-\(key)")
            if let path = server.locations.first?.path {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    .buttonHoverPointer()
                    .help("Show the file that defines the server in Finder")
                    .accessibilityIdentifier("mcp-reveal-\(key)")
            }
            if server.editable {
                if server.linkable {
                    Divider()
                    Button("Make Available Outside Playhouse…") { pendingLink = server }
                        .buttonHoverPointer()
                        .help("Write the server into the configuration of the CLI that doesn't start it yet")
                        .accessibilityIdentifier("mcp-link-\(key)")
                }
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = server }
                    .buttonHoverPointer()
                    .help("Remove the server from every file that defines it")
                    .accessibilityIdentifier("mcp-delete-\(key)")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonHoverPointer()
        .nativeHelp("More actions for \(server.name)")
        .accessibilityLabel("Actions for \(server.name)")
        .accessibilityIdentifier("mcp-actions-\(key)")
    }

    private func openEditor(_ server: McpServerRecord) {
        perform(reloading: false) {
            let config = try await manager.mcpServerConfig(taskID: task.id, serverID: server.id)
            setPanel(.editing(server, config))
        }
    }

    private func setEnabled(_ server: McpServerRecord, _ enabled: Bool) {
        enabledOverrides[server.id] = enabled
        Task { @MainActor in
            do {
                let record = try await manager.setMcpServerEnabled(taskID: task.id, serverID: server.id, enabled: enabled)
                catalog = catalog?.replacing(record)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            if enabledOverrides[server.id] == enabled { enabledOverrides[server.id] = nil }
        }
    }

    /// Asks both agents which servers need a sign-in. It runs whenever the page
    /// opens and after a sign-in finishes.
    private func checkStatus() async {
        // A check asked for while one is running (a sign-in that just finished) runs right after it.
        guard !isCheckingStatus else {
            recheckRequested = true
            return
        }
        isCheckingStatus = true
        repeat {
            recheckRequested = false
            do {
                status = try await manager.mcpStatus(taskID: task.id)
                let failures = (status?.errors ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key.capitalized): \($0.value)" }
                errorMessage = failures.isEmpty ? nil : failures.joined(separator: " ")
            } catch {
                errorMessage = error.localizedDescription
            }
        } while recheckRequested
        isCheckingStatus = false
    }

    private func openInBrowser(_ link: String) {
        // A test build never opens a browser.
        guard let url = URL(string: link), !BridgeContract.isTestBundle(PlayhouseAppIdentity.applicationIdentifier) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Has the agent start its OAuth sign-in, opens the link it returns, waits
    /// for the browser's redirect to finish it, and then checks again.
    private func signIn(name: String, provider: ConversationProvider) {
        let key = "\(name)|\(provider.rawValue)"
        guard signingIn.insert(key).inserted else { return }
        Task { @MainActor in
            var failure: String?
            do {
                let start = try await manager.startMcpLogin(taskID: task.id, provider: provider, name: name)
                openInBrowser(start.authorizationUrl)
                let result = try await manager.mcpLoginResult(taskID: task.id, provider: provider, name: name)
                if !result.signedIn { failure = result.error ?? "The sign-in to \(name) wasn't finished." }
            } catch {
                failure = error.localizedDescription
            }
            signingIn.remove(key)
            await checkStatus()
            if let failure { errorMessage = failure }
        }
    }

    private func fix(_ server: McpServerRecord) {
        guard !isFixing else { return }
        isFixing = true
        Task { @MainActor in
            defer { isFixing = false }
            do {
                let created = try await manager.fixMcpServers(taskID: task.id, serverIDs: [server.id])
                errorMessage = nil
                onFixTask(created.task.id, created.prompt)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func perform(reloading: Bool = true, _ operation: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await operation()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            if reloading { await reload() }
        }
    }

    private func reload() async {
        do {
            catalog = try await manager.mcpServers(taskID: task.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Opens a server's definition as a form, for a new server or an existing one.
private struct McpServerEditorPanel: View {
    enum Kind: String, CaseIterable, Identifiable {
        case local = "Local command"
        case remote = "Remote HTTP"
        var id: String { rawValue }
    }

    /// Nil for a new server.
    let server: McpServerRecord?
    let roots: [McpRepositorySection]
    let onClose: () -> Void
    /// Name, definition, scope, and the repository root for a new server.
    let onSave: (String, McpServerConfig, McpScope, String?) async throws -> Void

    @State private var name = ""
    @State private var kind: Kind
    @State private var command: String
    @State private var arguments: String
    @State private var environment: String
    @State private var url: String
    @State private var headers: String
    /// "global", or the root path of one of the task's repositories.
    @State private var destination = "global"
    @State private var errorMessage: String?
    @State private var isSaving = false
    private let originalTransport: McpServerConfig.Transport

    init(server: McpServerRecord?, config: McpServerConfig, roots: [McpRepositorySection], onClose: @escaping () -> Void,
         onSave: @escaping (String, McpServerConfig, McpScope, String?) async throws -> Void) {
        self.server = server
        self.roots = roots
        self.onClose = onClose
        self.onSave = onSave
        originalTransport = config.transport
        _kind = State(initialValue: config.transport == .stdio ? .local : .remote)
        _command = State(initialValue: config.command ?? "")
        _arguments = State(initialValue: config.args.joined(separator: "\n"))
        _environment = State(initialValue: config.env.keys.sorted().map { "\($0)=\(config.env[$0]!)" }.joined(separator: "\n"))
        _url = State(initialValue: config.url ?? "")
        _headers = State(initialValue: config.headers.keys.sorted().map { "\($0): \(config.headers[$0]!)" }.joined(separator: "\n"))
    }

    /// Managed servers and SSE servers, which Codex can't run, are read-only.
    private var editable: Bool { (server?.editable ?? true) && originalTransport != .sse }

    private var target: String {
        if let server {
            return server.locations.map(\.path).joined(separator: " and ")
        }
        return destination == "global"
            ? "Saved in Claude Code's ~/.claude.json and Codex's config.toml, so both CLIs start it."
            : "Saved in the repository's .mcp.json; Playhouse passes it to Codex. Commit it to share it with teammates."
    }

    var body: some View {
        SkillPanel(identifier: "mcp-editor-panel") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Text(server?.name ?? "New MCP Server")
                        .font(.title2.weight(.semibold))
                        .accessibilityIdentifier("mcp-editor-title")
                    Spacer()
                    if server == nil {
                        Picker("Save to", selection: $destination) {
                            Text("Global").tag("global")
                            ForEach(roots, id: \.rootPath) { root in Text(root.name).tag(root.rootPath) }
                        }
                        .fixedSize()
                        .accessibilityIdentifier("mcp-editor-scope")
                    }
                    Picker("Kind", selection: $kind) {
                        ForEach(Kind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(!editable)
                    .accessibilityIdentifier("mcp-editor-kind")
                }
                Text(target)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("mcp-editor-target")
                if server == nil {
                    TextField("server-name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Name")
                        .accessibilityIdentifier("mcp-editor-name")
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                switch kind {
                case .local:
                    field("Command") {
                        TextField("npx", text: $command)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .disabled(!editable)
                            .accessibilityLabel("Command")
                            .accessibilityIdentifier("mcp-editor-command")
                    }
                    field("Arguments, one per line") {
                        SkillTextEditor(text: $arguments, identifier: "mcp-editor-args", isEditable: editable)
                    }
                    field("Environment, one NAME=value per line. ${NAME} passes a variable through.") {
                        SkillTextEditor(text: $environment, identifier: "mcp-editor-env", isEditable: editable)
                    }
                case .remote:
                    field("URL") {
                        TextField("https://example.com/mcp", text: $url)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .disabled(!editable)
                            .accessibilityLabel("URL")
                            .accessibilityIdentifier("mcp-editor-url")
                    }
                    field("Headers, one Name: value per line. Authorization: Bearer ${TOKEN} reads a token from the environment.") {
                        SkillTextEditor(text: $headers, identifier: "mcp-editor-headers", isEditable: editable)
                    }
                }
            }
        } footer: {
            HStack {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout).accessibilityIdentifier("mcp-editor-error")
                } else if !editable {
                    Text(server?.scope == .managed
                         ? "Your organization manages this server, so it is read-only."
                         : server?.editable == false
                         ? "It is written inline in config.toml, so Playhouse leaves it to you. Edit it there."
                         : "Playhouse edits local and HTTP servers; edit this SSE server in its file.")
                        .accessibilityIdentifier("mcp-editor-read-only")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(editable ? "Cancel" : "Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .buttonHoverPointer()
                    .nativeHelp(editable ? "Discard changes" : "Close the server")
                    .accessibilityIdentifier("mcp-editor-cancel")
                if editable {
                    Button(server == nil ? "Create" : "Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)
                        .buttonHoverPointer()
                        .nativeHelp(server == nil ? "Create the server (⌘S)" : "Save the server (⌘S)")
                        .accessibilityIdentifier("mcp-editor-save")
                }
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private static func lines(_ text: String) -> [String] {
        text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func pairs(_ text: String, separator: Character, label: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in lines(text) {
            guard let index = line.firstIndex(of: separator), index != line.startIndex else {
                throw BridgeCommandError(code: "invalid_argument", message: "Write each \(label) line as \(separator == "=" ? "NAME=value" : "Name: value").")
            }
            result[String(line[..<index]).trimmingCharacters(in: .whitespaces)] =
                String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    private func save() {
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                let config: McpServerConfig
                switch kind {
                case .local:
                    config = McpServerConfig(transport: .stdio, command: command, args: Self.lines(arguments),
                                             env: try Self.pairs(environment, separator: "=", label: "environment"))
                case .remote:
                    config = McpServerConfig(transport: .http, url: url, headers: try Self.pairs(headers, separator: ":", label: "header"))
                }
                let scope: McpScope = destination == "global" ? .global : .repo
                try await onSave(name.trimmingCharacters(in: .whitespaces), config, scope, scope == .repo ? destination : nil)
                onClose()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
