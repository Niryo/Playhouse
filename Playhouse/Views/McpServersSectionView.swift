import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// The MCP servers that give agents tools: each repository's `.mcp.json` and
/// `.codex/config.toml`, the user's own servers in Claude Code's and Codex's
/// configuration, and the organization's managed ones. Like skills and rules,
/// each server is passed to the provider that would not start it on its own.
package struct McpServersSectionView: PHView {
    package enum Panel {
        case editing(McpServerRecord, McpServerConfig)
        case creating
    }

    package let task: any ConversationSubject
    package let manager: RemoteConversationManager
    @PHBinding package var isPresentingPanel: Bool
    package let onFixTask: (UUID, String) -> Void
    /// A server's editor, or its sign-in with one agent, to open once the list loads.
    package var focus: SkillsPageFocus? = nil

    /// The section the list last scrolled to, and how many times it has.
    @PHState private var scrollTarget: String?
    @PHState private var scrollRequest = 0
    @PHState private var catalog: McpCatalog?
    @PHState private var search = ""
    @PHState private var status: McpStatusReport?
    @PHState private var isCheckingStatus = false
    @PHState private var recheckRequested = false
    /// Sign-ins waiting for the browser, as `name|provider`.
    @PHState private var signingIn = Set<String>()
    @PHState private var errorMessage: String?
    @PHState private var panel: Panel?
    @PHState private var pendingDelete: McpServerRecord?
    @PHState private var pendingLink: McpServerRecord?
    /// A toggle shows its new state at once; the daemon's answer settles it.
    @PHState private var enabledOverrides: [String: Bool] = [:]
    @PHState private var isFixing = false
    @PHState private var didOpenFocus = false

    private static let panelAnimation = PHAnimation.spring(response: 0.34, dampingFraction: 0.9)

    /// A server's name is unique in its scope, so a repository server is told
    /// apart by its repository.
    package static func key(_ server: McpServerRecord) -> String {
        switch server.scope {
        case .repo: URL(fileURLWithPath: server.repositoryPath ?? "").lastPathComponent + ":" + server.name
        case .global: server.name
        case .managed: "managed:" + server.name
        }
    }

    package var body: some PHView {
        AtomOverlay(common: AtomCommon(testID: "mcp-page")) {
            AtomStack(props: StackProps(axis: "v", spacing: 0, align: "leading")) {
                AtomStack(props: StackProps(axis: "h", spacing: 8), common: AtomCommon(paddingX: 20)) {
                    SkillsPageSearchField(text: search, placeholder: "Search servers", testID: "mcp-search") { search = $0 }
                    AtomButton(
                        props: ButtonProps(style: "bordered", controlSize: "small"),
                        common: AtomCommon(testID: "new-mcp-server-button", help: "Add an MCP server that both Claude and Codex can use"),
                        action: { setPanel(.creating) }
                    ) {
                        AtomLabel(props: LabelProps(text: "New Server", icon: PHIcon.plus.name))
                    }
                }
                AtomStack(props: StackProps(axis: "h", spacing: 8), common: AtomCommon(paddingX: 20, paddingY: 12)) {
                    SkillsPageAnchorBar(testID: "mcp-tab-picker", anchorPrefix: "mcp-anchor", anchors: anchors, onJump: jump)
                    AtomSpacer()
                    if isCheckingStatus {
                        AtomStack(props: StackProps(axis: "h", spacing: 5, combine: true), common: AtomCommon(testID: "mcp-checking-status")) {
                            AtomSpinner(props: SpinnerProps(size: "mini"))
                            AtomText(props: TextProps(text: "Checking sign-in…", size: 11, color: "secondary"))
                        }
                    }
                }
                if let errorMessage {
                    CatalogRows.pageError(errorMessage, testID: "mcp-error")
                }
                AtomDivider()
                AtomScroll(props: ScrollProps(spacing: 18, inset: 20, scrollTo: scrollTarget, scrollRequest: scrollRequest), common: AtomCommon(testID: "mcp-list")) {
                    content
                    CatalogRows.footnote(
                        "MCP servers give agents tools. Hover one for its details, or click it to open it. Turning a server on or off reaches both agents on their next turn.",
                        testID: "mcp-provider-timing"
                    )
                }
            }
        } overlay: {
            // A closed panel's removal transition can leave the overlay catching clicks over the
            // header (New Server stopped responding after a create), so it takes hits only while open.
            panels.allowsHitTesting(panel != nil)
        }
        .task {
            // Opening the page asks both agents which servers need a sign-in, while the list loads.
            async let statuses: Void = checkStatus()
            await reload()
            openFocus()
            await statuses
        }
        // ATOM-GAP: an alert's and a confirmation dialog's actions and message must be native
        // Buttons and Text (the system dialog reads them), and ButtonProps has no cancel role.
        .alert(
            "Delete \(pendingDelete?.name ?? "server")?",
            isPresented: PHBinding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { server in
            PHButton("Delete", role: .destructive) { perform { try await manager.deleteMcpServers(taskID: task.id, serverIDs: [server.id]) } }
                .buttonHoverPointer()
                .nativeHelp("Remove the server from every file that defines it")
                .accessibilityIdentifier("confirm-delete-mcp")
            PHButton("Cancel", role: .cancel) {}
                .buttonHoverPointer()
                .nativeHelp("Keep the server")
        } message: { server in
            PHText("This removes \(server.name) from \(server.locations.map(\.path).joined(separator: " and ")), so neither Claude nor Codex starts it.")
        }
        .confirmationDialog(
            "Make \(pendingLink?.name ?? "server") available outside Playhouse?",
            isPresented: PHBinding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
            presenting: pendingLink
        ) { server in
            PHButton("Add to Both CLIs") { perform { _ = try await manager.linkMcpServer(taskID: task.id, serverID: server.id) } }
                .buttonHoverPointer()
                .nativeHelp("Write the server into the configuration of the CLI that doesn't have it")
                .accessibilityIdentifier("confirm-link-mcp")
            PHButton("Cancel", role: .cancel) {}
                .buttonHoverPointer()
                .nativeHelp("Keep passing the server only in Playhouse sessions")
        } message: { server in
            PHText(Self.linkMessage(server))
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
        phWithAnimation(Self.panelAnimation) { panel = value }
        isPresentingPanel = value != nil
    }

    private var panels: some PHView {
        AtomStack(props: StackProps(axis: "z")) {
            if panel != nil {
                CatalogRows.dimming.ignoresSafeArea().transition(.opacity).zIndex(0)
            }
            switch panel {
            case .editing(let server, let config):
                CatalogRows.panelSlot {
                    McpServerEditorPanel(server: server, config: config, roots: [], onClose: { setPanel(nil) }) { _, edited, _, _ in
                        let record = try await manager.updateMcpServer(taskID: task.id, serverID: server.id, config: edited)
                        catalog = catalog?.replacing(record)
                        await reload()
                    }
                    .id(server.id)
                }
                .transition(.move(edge: .bottom))
                .zIndex(1)
            case .creating:
                CatalogRows.panelSlot {
                    McpServerEditorPanel(server: nil, config: McpServerConfig(transport: .stdio), roots: catalog?.repositories ?? [], onClose: { setPanel(nil) }) { name, config, scope, root in
                        let record = try await manager.createMcpServer(taskID: task.id, name: name, config: config, scope: scope, root: root)
                        jump(record.scope == .global ? "global" : "repo")
                        search = ""
                        await reload()
                    }
                }
                .transition(.move(edge: .bottom))
                .zIndex(1)
            case nil:
                PHEmptyView()
            }
        }
    }

    private func jump(_ section: String) {
        scrollTarget = section
        scrollRequest += 1
    }

    private var anchors: [SkillsPageAnchor] {
        [
            SkillsPageAnchor(value: "repo", label: "Repo", count: (catalog?.repositories ?? []).reduce(0) { $0 + filtered($1.servers).count }),
            SkillsPageAnchor(value: "global", label: "Global", count: filtered(catalog?.global ?? []).count),
            SkillsPageAnchor(value: "managed", label: "Managed", count: filtered(catalog?.managed ?? []).count),
        ]
    }

    @PHViewBuilder
    private var content: some PHView {
        if let catalog {
            let counts = Dictionary(uniqueKeysWithValues: anchors.map { ($0.value, $0) })
            PHForEach(catalog.problems, id: \.path) { problem in
                AtomLabel(
                    props: LabelProps(text: "\(problem.path): \(problem.message)", icon: PHIcon.exclamationmarkTriangle.name, size: 12, color: "orange"),
                    common: AtomCommon(testID: "mcp-file-problem")
                )
            }
            group(counts["repo"]!, intro: "Servers in the task's repositories: .mcp.json, which Claude reads, and .codex/config.toml, which Codex reads. Playhouse passes each one to the agent that would not start it on its own.") {
                if catalog.repositories.isEmpty {
                    emptyState("This task has no repositories.", identifier: "mcp-empty-repo")
                }
                PHForEach(catalog.repositories, id: \.rootPath) { section in
                    let shown = filtered(section.servers)
                    CatalogRows.sectionHeader(section.name, testID: "mcp-repo-section-\(section.name)")
                    if shown.isEmpty {
                        emptyState(section.servers.isEmpty ? "No MCP servers in \(section.name)." : "No matching servers.", identifier: "mcp-empty-\(section.name)")
                    }
                    rows(shown)
                }
            }
            let global = filtered(catalog.global)
            group(counts["global"]!, intro: "Your servers for every repository, from Claude Code's ~/.claude.json and Codex's config.toml. New global servers are written into both, so both CLIs start them.") {
                if global.isEmpty { emptyState(catalog.global.isEmpty ? "No global MCP servers." : "No matching servers.", identifier: "mcp-empty-global") }
                rows(global)
            }
            let managed = filtered(catalog.managed)
            group(counts["managed"]!, intro: "Your organization's managed servers. Claude Code always starts them, and they can't be edited or turned off here.") {
                if managed.isEmpty { emptyState(catalog.managed.isEmpty ? "No managed MCP servers on this Mac." : "No matching servers.", identifier: "mcp-empty-managed") }
                rows(managed)
                connectors(catalog)
            }
        } else {
            CatalogRows.loading(testID: "mcp-loading")
        }
    }

    /// One of the list's sections, which its anchor scrolls to.
    private func group<Content: PHView>(_ anchor: SkillsPageAnchor, intro: String, @PHViewBuilder content: @escaping () -> Content) -> some PHView {
        AtomStack(
            props: StackProps(axis: "v", spacing: 8, align: "leading", group: true, scrollID: anchor.value),
            common: AtomCommon(testID: "mcp-group-\(anchor.value)", label: anchor.label, fillWidth: true)
        ) {
            SkillsPageGroupHeader(label: anchor.label, count: anchor.count, intro: intro, introTestID: "mcp-intro-\(anchor.value)")
            content()
        }
    }

    @PHViewBuilder
    private func rows(_ servers: [McpServerRecord]) -> some PHView {
        if !servers.isEmpty {
            SkillsPageCard {
                PHForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                    if index > 0 { AtomDivider() }
                    row(server)
                }
            }
        }
    }

    /// Servers Claude Code reports that no file here defines, such as claude.ai
    /// connectors and plugin servers. Known once the sign-in check has answered.
    @PHViewBuilder
    private func connectors(_ catalog: McpCatalog) -> some PHView {
        let known = Set(catalog.allServers.map(\.name))
        let query = searchQuery
        let others = (status?.claude ?? []).filter { !known.contains($0.name) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
        CatalogRows.sectionHeader("Also started by Claude Code", paddingTop: 4)
        if status == nil {
            CatalogRows.note("Checking which claude.ai connectors and plugin servers Claude Code starts on its own…", testID: "mcp-connectors-hint")
        } else if others.isEmpty {
            emptyState("Claude Code starts no other servers.", identifier: "mcp-connectors-empty")
        }
        if !others.isEmpty {
            SkillsPageCard {
                PHForEach(Array(others.enumerated()), id: \.element.name) { index, server in
                    if index > 0 { AtomDivider() }
                    AtomStack(props: StackProps(axis: "h", spacing: 8, group: true), common: AtomCommon(testID: "mcp-connector-\(server.name)", paddingX: 12, paddingY: 7)) {
                        AtomText(props: TextProps(text: server.name, size: 13, weight: "medium", lineLimit: 1))
                        AtomSpacer()
                        if server.needsSignIn {
                            connectorSignInButton(server)
                        } else {
                            CatalogRows.badge(server.status, icon: .circleFill, color: "secondary")
                        }
                    }
                }
            }
        }
    }

    /// A claude.ai connector is signed in to on claude.ai, not from Claude Code,
    /// so its badge opens the connectors settings; a plugin server is signed in
    /// to the same way as any other server.
    private func connectorSignInButton(_ server: McpProviderStatus) -> some PHView {
        let isConnector = server.name.hasPrefix("claude.ai ")
        let key = "\(server.name)|claude"
        return AtomButton(
            props: ButtonProps(disabled: signingIn.contains(key)),
            common: AtomCommon(
                testID: "mcp-connector-signin-\(server.name)",
                help: isConnector ? "Connect \(server.name) in claude.ai's connector settings" : "Open your browser to sign in to \(server.name) for Claude"
            ),
            action: {
                if isConnector {
                    openInBrowser("https://claude.ai/settings/connectors")
                } else {
                    signIn(name: server.name, provider: .claude)
                }
            }
        ) {
            signInLabel(.claude, waiting: signingIn.contains(key))
        }
    }

    /// The provider's logo and a short "Sign in" so the badge fits the narrow
    /// modal's row; its accessibility label still names the provider. A row
    /// with a badge for each agent shows only the logos, so its name keeps room.
    private func signInLabel(_ provider: ConversationProvider, waiting: Bool, compact: Bool = false) -> some PHView {
        AtomStack(
            props: StackProps(axis: "h", spacing: 4, fill: "orange", fillOpacity: 0.12, capsule: true, summary: true),
            common: AtomCommon(label: waiting ? "Waiting for sign-in…" : "Sign in for \(provider.displayName)", fixedSize: true, paddingX: 6, paddingY: 2)
        ) {
            if waiting {
                AtomSpinner(props: SpinnerProps(size: "mini"))
            } else {
                AtomIcon(props: IconProps(asset: SkillsPageModel.logoAsset(provider), size: 10, color: "orange"), common: AtomCommon(width: 10, height: 10))
            }
            if !compact {
                AtomText(props: TextProps(text: waiting ? "Waiting…" : "Sign in", size: 10, weight: "medium", color: "orange", lineLimit: 1))
            }
        }
    }

    private func emptyState(_ text: String, identifier: String) -> some PHView {
        CatalogRows.note(text, testID: identifier)
    }
    private var searchQuery: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The servers whose name or command line contains the search, like the Skills search.
    private func filtered(_ servers: [McpServerRecord]) -> [McpServerRecord] {
        let query = searchQuery
        guard !query.isEmpty else { return servers }
        return servers.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) }
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
        return "Playhouse passes it to " + ConversationProvider.names(server.sharedWith) + "."
    }

    /// The providers that reported the server needs a sign-in.
    private func signInNeeded(_ server: McpServerRecord) -> [ConversationProvider] {
        guard let status else { return [] }
        return ConversationProvider.allCases.filter { provider in
            status.statuses(for: provider).contains { $0.name == server.name && $0.needsSignIn }
        }
    }

    /// A server on one line: its name, a mark when it conflicts or has a
    /// problem, any sign-in it needs, its Fix, switch and actions. Its details
    /// show in a hint left of the row while the pointer rests on it.
    private func row(_ server: McpServerRecord) -> some PHView {
        let key = Self.key(server)
        return AtomPopover(props: PopoverProps(isPresented: false, arrowEdge: "leading", width: 280, inset: 12, hover: true), onDismiss: {}) {
            CatalogRows.listRow(testID: "mcp-row-\(key)", hint: server.summary, onOpen: { openEditor(server) }) {
                // Who starts the server leads its name, like a skill's row.
                if let mark = SkillsPageModel.providerMark(Set(server.providers), testID: "mcp-provider-\(key)") {
                    ProviderMarkIcon(mark: mark)
                }
                AtomText(props: TextProps(text: server.name, size: 13, weight: "medium", lineLimit: 1), common: AtomCommon(testID: "mcp-name-\(key)"))
                if server.conflict {
                    CatalogRows.flag("Conflict", testID: "mcp-conflict-\(key)")
                } else if server.issue != nil {
                    CatalogRows.flag("Problem", testID: "mcp-problem-\(key)")
                }
            } controls: {
                // Outside the click-to-open area, so the buttons get their own clicks.
                signInButtons(server, key: key)
                if server.issue != nil, server.scope != .managed {
                    CatalogRows.fixButton(name: server.name, testID: "mcp-fix-\(key)", disabled: isFixing) { fix(server) }
                }
                if server.scope != .managed {
                    CatalogRows.enabledToggle(
                        isOn: isEnabled(server), name: server.name, noun: "server", testID: "mcp-toggle-\(key)",
                        onToggle: { setEnabled(server, !isEnabled(server)) }
                    )
                }
                actions(server, key: key)
            }
        } content: {
            hint(server, key: key)
        }
    }

    /// A server's details: its command line or URL, its transport, its
    /// variables, any problem, and where it is defined. The agents that start
    /// it show on the row.
    private func hint(_ server: McpServerRecord, key: String) -> some PHView {
        AtomStack(props: StackProps(axis: "v", spacing: 6, align: "leading", group: true), common: AtomCommon(testID: "mcp-hint-\(key)")) {
            AtomText(props: TextProps(text: server.name, size: 13, weight: "semibold"))
            AtomText(
                props: TextProps(text: server.summary, size: 11, design: "monospaced", color: "secondary", lineLimit: 3, truncation: "middle"),
                common: AtomCommon(testID: "mcp-summary-\(key)")
            )
            AtomStack(props: StackProps(axis: "h", spacing: 4)) {
                CatalogRows.badge(
                    server.transport == .stdio ? "Local" : server.transport.rawValue.uppercased(),
                    icon: server.transport == .stdio ? .terminal : .network, color: "purple", testID: "mcp-transport-\(key)"
                )
                if server.availableOutsidePlayhouse {
                    CatalogRows.badge("Both CLIs", icon: .checkmarkSeal, color: "blue", testID: "mcp-native-\(key)")
                }
            }
            if !server.envNames.isEmpty || !server.headerNames.isEmpty {
                CatalogRows.detail(Self.variableNames(server), testID: "mcp-env-\(key)")
            }
            if let issue = server.issue {
                CatalogRows.detail(issue, color: "orange", testID: "mcp-issue-\(key)")
            }
            if let limitation = server.limitation {
                CatalogRows.detail(limitation, testID: "mcp-limitation-\(key)")
            }
            if !isEnabled(server), !server.alwaysOnFor.isEmpty {
                CatalogRows.detail(
                    "\(ConversationProvider.names(server.alwaysOnFor)) still \(server.alwaysOnFor.count == 1 ? "starts" : "start") it from its own configuration, so turning it off applies to the other agents only. Delete it to stop it everywhere.",
                    color: "orange", testID: "mcp-always-on-\(key)"
                )
            } else if let note = Self.sharedNote(server) {
                CatalogRows.detail(note, wrap: false, testID: "mcp-shared-\(key)")
            }
            AtomText(
                props: TextProps(text: server.locations.map(\.layout.displayName).joined(separator: " · "), size: 10, color: "tertiary", wrap: true),
                common: AtomCommon(testID: "mcp-location-\(key)")
            )
        }
    }

    /// One button per agent that needs the server's sign-in: the label that says
    /// so is what starts it.
    @PHViewBuilder
    private func signInButtons(_ server: McpServerRecord, key: String) -> some PHView {
        let providers = signInNeeded(server)
        if !providers.isEmpty {
            AtomStack(props: StackProps(axis: "h", spacing: 6)) {
                PHForEach(providers) { provider in
                    let waiting = signingIn.contains("\(server.name)|\(provider.rawValue)")
                    AtomButton(
                        props: ButtonProps(disabled: waiting),
                        common: AtomCommon(
                            testID: "mcp-signin-\(key)-\(provider.rawValue)",
                            help: "Open your browser to sign in to \(server.name) for \(provider.displayName)"
                        ),
                        action: { signIn(name: server.name, provider: provider) }
                    ) {
                        signInLabel(provider, waiting: waiting, compact: providers.count > 1)
                    }
                }
            }
        }
    }

    private func actions(_ server: McpServerRecord, key: String) -> some PHView {
        var items = [[
            MenuProps.Item(
                id: "edit", title: server.editable ? "Edit…" : "View…",
                help: server.editable ? "Edit the server" : "Read the server's definition", testID: "mcp-edit-\(key)"
            ),
        ]]
        let path = server.locations.first?.path
        if path != nil {
            items[0].append(MenuProps.Item(id: "reveal", title: "Reveal in Finder", help: "Show the file that defines the server in Finder", testID: "mcp-reveal-\(key)"))
        }
        if server.editable {
            if server.linkable {
                items.append([MenuProps.Item(
                    id: "link", title: "Make Available Outside Playhouse…",
                    help: "Write the server into the configuration of the CLI that doesn't start it yet", testID: "mcp-link-\(key)"
                )])
            }
            items.append([MenuProps.Item(
                id: "delete", title: "Delete…", destructive: true, help: "Remove the server from every file that defines it", testID: "mcp-delete-\(key)"
            )])
        }
        return CatalogRows.actionsMenu(name: server.name, testID: "mcp-actions-\(key)", items: items) { choice in
            switch choice {
            case "edit": openEditor(server)
            case "reveal": if let path { Platform.services.revealInFileBrowser([URL(fileURLWithPath: path)]) }
            case "link": pendingLink = server
            case "delete": pendingDelete = server
            default: break
            }
        }
    }
    private func openEditor(_ server: McpServerRecord) {
        perform(reloading: false) {
            let config = try await manager.mcpServerConfig(taskID: task.id, serverID: server.id)
            setPanel(.editing(server, config))
        }
    }

    /// The composer's `/mcp` gear opens the server's editor; its sign-in button narrows the
    /// list to the server and starts that agent's sign-in, whose badge then shows the wait.
    private func openFocus() {
        guard !didOpenFocus else { return }
        didOpenFocus = true
        switch focus {
        case .mcpServer(let id):
            if let server = catalog?.server(id: id) { openEditor(server) }
        case .mcpSignIn(let name, let provider):
            search = name
            signIn(name: name, provider: provider)
        case .skill, nil:
            break
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
        Platform.services.open(url)
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

    package init(task: any ConversationSubject, manager: RemoteConversationManager, isPresentingPanel: PHBinding<Bool>, onFixTask: @escaping (UUID, String) -> Void, focus: SkillsPageFocus? = nil) {
        self.task = task
        self.manager = manager
        _isPresentingPanel = isPresentingPanel
        self.onFixTask = onFixTask
        self.focus = focus
    }
}

/// Opens a server's definition as a form, for a new server or an existing one.
private struct McpServerEditorPanel: PHView {
    enum Kind: String, CaseIterable, Identifiable {
        case local = "Local command"
        case remote = "Remote HTTP"
        package var id: String { rawValue }
    }

    /// Nil for a new server.
    let server: McpServerRecord?
    let roots: [McpRepositorySection]
    let onClose: () -> Void
    /// Name, definition, scope, and the repository root for a new server.
    let onSave: (String, McpServerConfig, McpScope, String?) async throws -> Void

    @PHState private var name = ""
    @PHState private var kind: Kind
    @PHState private var command: String
    @PHState private var arguments: String
    @PHState private var environment: String
    @PHState private var url: String
    @PHState private var headers: String
    /// "global", or the root path of one of the task's repositories.
    @PHState private var destination = "global"
    @PHState private var errorMessage: String?
    @PHState private var isSaving = false
    private let originalTransport: McpServerConfig.Transport

    init(server: McpServerRecord?, config: McpServerConfig, roots: [McpRepositorySection], onClose: @escaping () -> Void,
         onSave: @escaping (String, McpServerConfig, McpScope, String?) async throws -> Void) {
        self.server = server
        self.roots = roots
        self.onClose = onClose
        self.onSave = onSave
        originalTransport = config.transport
        _kind = PHState(initialValue: config.transport == .stdio ? .local : .remote)
        _command = PHState(initialValue: config.command ?? "")
        _arguments = PHState(initialValue: config.args.joined(separator: "\n"))
        _environment = PHState(initialValue: config.env.keys.sorted().map { "\($0)=\(config.env[$0]!)" }.joined(separator: "\n"))
        _url = PHState(initialValue: config.url ?? "")
        _headers = PHState(initialValue: config.headers.keys.sorted().map { "\($0): \(config.headers[$0]!)" }.joined(separator: "\n"))
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

    var body: some PHView {
        SkillPanel(identifier: "mcp-editor-panel") {
            AtomStack(props: StackProps(axis: "v", spacing: 10, align: "leading")) {
                AtomStack(props: StackProps(axis: "h", spacing: 10)) {
                    CatalogRows.panelIcon(.puzzlepieceExtension)
                    CatalogRows.panelTitle(server?.name ?? "New MCP Server", testID: "mcp-editor-title")
                    AtomSpacer()
                }
                // The controls get their own rows so the panel fits the narrow modal.
                AtomStack(props: StackProps(axis: "v", spacing: 8, align: "leading")) {
                    if server == nil {
                        CatalogRows.picker(
                            "Save to", style: "menu",
                            options: [SegmentedProps.Option(value: "global", label: "Global")] + roots.map { SegmentedProps.Option(value: $0.rootPath, label: $0.name) },
                            selected: destination, testID: "mcp-editor-scope"
                        ) { destination = $0 }
                    }
                    CatalogRows.picker(
                        "Kind", options: Kind.allCases.map { SegmentedProps.Option(value: $0.rawValue, label: $0.rawValue) },
                        selected: kind.rawValue, disabled: !editable, testID: "mcp-editor-kind"
                    ) { kind = Kind(rawValue: $0) ?? kind }
                }
                AtomText(
                    props: TextProps(text: target, size: 12, color: "secondary", lineLimit: 2, truncation: "middle", selectable: true),
                    common: AtomCommon(testID: "mcp-editor-target")
                )
                if server == nil {
                    AtomTextField(
                        props: TextFieldProps(text: name, placeholder: "server-name", style: "rounded"),
                        common: AtomCommon(testID: "mcp-editor-name", label: "Name"),
                        onChange: { name = $0 }
                    )
                }
            }
        } content: {
            AtomStack(props: StackProps(axis: "v", spacing: 8, align: "leading")) {
                switch kind {
                case .local:
                    CatalogRows.field("Command") {
                        AtomTextField(
                            props: TextFieldProps(text: command, placeholder: "npx", style: "rounded", size: 13, design: "monospaced"),
                            common: AtomCommon(testID: "mcp-editor-command", label: "Command"),
                            onChange: { command = $0 }
                        )
                        .disabled(!editable)
                    }
                    CatalogRows.field("Arguments, one per line") {
                        PHNativeTextEditor(text: $arguments, identifier: "mcp-editor-args", isEditable: editable)
                    }
                    CatalogRows.field("Environment, one NAME=value per line. ${NAME} passes a variable through.") {
                        PHNativeTextEditor(text: $environment, identifier: "mcp-editor-env", isEditable: editable)
                    }
                case .remote:
                    CatalogRows.field("URL") {
                        AtomTextField(
                            props: TextFieldProps(text: url, placeholder: "https://example.com/mcp", style: "rounded", size: 13, design: "monospaced"),
                            common: AtomCommon(testID: "mcp-editor-url", label: "URL"),
                            onChange: { url = $0 }
                        )
                        .disabled(!editable)
                    }
                    CatalogRows.field("Headers, one Name: value per line. Authorization: Bearer ${TOKEN} reads a token from the environment.") {
                        PHNativeTextEditor(text: $headers, identifier: "mcp-editor-headers", isEditable: editable)
                    }
                }
            }
        } footer: {
            AtomStack(props: StackProps(axis: "h")) {
                if let errorMessage {
                    CatalogRows.footerMessage(errorMessage, color: "red", testID: "mcp-editor-error")
                } else if !editable {
                    CatalogRows.footerMessage(
                        server?.scope == .managed
                            ? "Your organization manages this server, so it is read-only."
                            : server?.editable == false
                            ? "It is written inline in config.toml, so Playhouse leaves it to you. Edit it there."
                            : "Playhouse edits local and HTTP servers; edit this SSE server in its file.",
                        color: "secondary", testID: "mcp-editor-read-only"
                    )
                }
                AtomSpacer()
                CatalogRows.panelButton(
                    editable ? "Cancel" : "Close", testID: "mcp-editor-cancel",
                    help: editable ? "Discard changes" : "Close the server", shortcut: "cancel", action: onClose
                )
                if editable {
                    CatalogRows.panelButton(
                        server == nil ? "Create" : "Save", testID: "mcp-editor-save",
                        help: server == nil ? "Create the server" : "Save the server", shortcut: AppShortcut.save,
                        prominent: true, disabled: isSaving
                    ) { save() }
                }
            }
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

/// The atom compositions the MCP page and its editor are built from. The Rules
/// page (RulesPageView.swift) builds the same rows, forms and headers.
enum CatalogRows {
    /// The page's error line, under its header.
    static func pageError(_ text: String, testID: String) -> some PHView {
        AtomText(props: TextProps(text: text, size: 12, color: "red"), common: AtomCommon(testID: testID, fillWidth: true, paddingX: 20, paddingBottom: 4))
    }

    /// The small print under the list.
    static func footnote(_ text: String, testID: String) -> some PHView {
        AtomText(props: TextProps(text: text, size: 10, color: "tertiary"), common: AtomCommon(testID: testID, paddingX: 4))
    }

    /// A heading over a run of rows, such as a repository's name.
    static func sectionHeader(_ text: String, testID: String? = nil, paddingTop: Double? = nil) -> some PHView {
        AtomText(props: TextProps(text: text, size: 12, weight: "semibold"), common: AtomCommon(testID: testID, paddingX: 4, paddingTop: paddingTop))
    }

    /// A line in the list where rows would be: an empty section, or what is still loading.
    static func note(_ text: String, testID: String) -> some PHView {
        AtomText(props: TextProps(text: text, size: 12, color: "secondary"), common: AtomCommon(testID: testID, paddingX: 4))
    }

    static func loading(testID: String) -> some PHView {
        AtomSpinner(props: SpinnerProps(size: "regular"), common: AtomCommon(testID: testID, fillWidth: true, frameAlign: "center"))
    }

    /// A list row on one line: what a click opens (the name and its marks),
    /// then the controls, which keep their own clicks.
    static func listRow<Lead: PHView, Controls: PHView>(
        testID: String, hint: String, onOpen: @escaping () -> Void,
        @PHViewBuilder lead: @escaping () -> Lead, @PHViewBuilder controls: @escaping () -> Controls
    ) -> some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 8, group: true), common: AtomCommon(testID: testID, fillWidth: true, paddingX: 12, paddingY: 6)) {
            AtomPressArea(props: PressAreaProps(pointer: true), common: AtomCommon(hint: hint), onPress: onOpen, onLongPress: {}) {
                AtomStack(props: StackProps(axis: "h", spacing: 8)) {
                    lead()
                    AtomSpacer(props: SpacerProps(minLength: 8))
                }
            }
            controls()
        }
    }

    /// The warning mark after a row's name.
    static func flag(_ text: String, testID: String) -> some PHView {
        AtomIcon(props: IconProps(name: PHIcon.exclamationmarkTriangleFill.name, size: 11, color: "orange"), common: AtomCommon(testID: testID, label: text, help: text))
    }

    static func fixButton(name: String, testID: String, disabled: Bool, action: @escaping () -> Void) -> some PHView {
        AtomButton(
            props: ButtonProps(style: "automatic", disabled: disabled, controlSize: "small"),
            common: AtomCommon(testID: testID, help: "Open a task whose agent fixes \(name)"),
            action: action
        ) {
            AtomLabel(props: LabelProps(text: "Fix", icon: PHIcon.wandAndStars.name))
        }
    }

    /// A row's switch; its label names what it turns on.
    static func enabledToggle(isOn: Bool, name: String, noun: String, testID: String, onToggle: @escaping () -> Void) -> some PHView {
        AtomToggle(
            props: ToggleProps(isOn: isOn, size: "mini"),
            common: AtomCommon(
                testID: testID, label: "\(name) enabled",
                help: isOn ? "Turn the \(noun) off in Playhouse sessions" : "Turn the \(noun) on in Playhouse sessions"
            ),
            onToggle: onToggle
        )
    }

    /// A row's "…" menu.
    static func actionsMenu(name: String, testID: String, items: [[MenuProps.Item]], onMenu: @escaping (String) -> Void) -> some PHView {
        AtomMenu(
            props: MenuProps(icon: PHIcon.ellipsis.name, size: 13, weight: "semibold", items: items),
            common: AtomCommon(testID: testID, label: "Actions for \(name)", help: "More actions for \(name)", width: 24, height: 24),
            onMenu: onMenu
        )
    }

    /// A chip in a row's hint.
    static func badge(_ text: String, icon: PHIcon, color: String, testID: String? = nil) -> some PHView {
        AtomStack(props: StackProps(fill: color, fillOpacity: 0.12, capsule: true), common: AtomCommon(testID: testID, paddingX: 6, paddingY: 2)) {
            AtomLabel(props: LabelProps(text: text, icon: icon.name, size: 10, weight: "medium", color: color, lineLimit: 1))
        }
    }

    /// A line of a row's hint.
    static func detail(_ text: String, color: String = "secondary", wrap: Bool = true, testID: String) -> some PHView {
        AtomText(props: TextProps(text: text, size: 11, color: color, wrap: wrap ? true : nil), common: AtomCommon(testID: testID))
    }

    /// What dims the list under an open panel.
    static var dimming: some PHView {
        AtomStack(props: StackProps(fill: "black", fillOpacity: 0.18), common: AtomCommon(fillWidth: true, fillHeight: true)) { PHEmptyView() }
    }

    /// Where an open panel sits over the list.
    static func panelSlot<Content: PHView>(@PHViewBuilder content: @escaping () -> Content) -> some PHView {
        AtomStack(common: AtomCommon(paddingX: 20, paddingTop: 20), content: content)
    }

    static func panelIcon(_ icon: PHIcon) -> some PHView {
        AtomIcon(props: IconProps(name: icon.name, size: 17, color: "accent"))
    }

    static func panelTitle(_ text: String, testID: String) -> some PHView {
        AtomText(props: TextProps(text: text, size: 17, weight: "semibold"), common: AtomCommon(testID: testID))
    }

    /// A picker with its title before it, the way a native picker shows its label.
    static func picker(
        _ title: String, style: String? = nil, options: [SegmentedProps.Option], selected: String, disabled: Bool = false,
        testID: String, onChange: @escaping (String) -> Void
    ) -> some PHView {
        AtomStack(props: StackProps(axis: "h")) {
            AtomText(props: TextProps(text: title, color: disabled ? "tertiary" : nil), common: AtomCommon(decorative: true))
            AtomSegmented(
                props: SegmentedProps(options: options, selected: selected, disabled: disabled ? true : nil, style: style),
                common: AtomCommon(testID: testID, label: title),
                onChange: onChange
            )
        }
    }

    /// A titled field of a form: its title over its control.
    static func field<Content: PHView>(_ title: String, @PHViewBuilder content: @escaping () -> Content) -> some PHView {
        AtomStack(props: StackProps(axis: "v", spacing: 4, align: "leading")) {
            AtomText(props: TextProps(text: title, size: 11, weight: "semibold"))
            content()
        }
    }

    /// The panel footer's error or read-only note.
    static func footerMessage(_ text: String, color: String, testID: String?) -> some PHView {
        AtomText(props: TextProps(text: text, size: 12, color: color), common: AtomCommon(testID: testID))
    }

    /// A panel footer's Cancel, Save or Create.
    static func panelButton(
        _ title: String, testID: String, help: String, shortcut: String, prominent: Bool = false, disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some PHView {
        AtomButton(
            props: ButtonProps(style: prominent ? "prominent" : "automatic", disabled: disabled ? true : nil, shortcut: shortcut),
            common: AtomCommon(testID: testID, help: help),
            action: action
        ) {
            AtomText(props: TextProps(text: title))
        }
    }
}
