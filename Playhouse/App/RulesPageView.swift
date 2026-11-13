import AppKit
import SwiftUI

// MARK: - Rules

/// The instruction files agents follow on every turn: each repository's
/// AGENTS.md, CLAUDE.md and `.claude/rules`, the user's global ones, and the
/// organization's managed CLAUDE.md. Like skills, each rule is shared with the
/// provider that would not read it on its own.
struct RulesSectionView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case repo = "Repo"
        case global = "Global"
        case managed = "Managed"
        var id: String { rawValue }
    }

    enum Panel {
        case editing(RuleRecord, String)
        case creating
    }

    let task: any ConversationSubject
    let manager: RemoteConversationManager
    @Binding var isPresentingPanel: Bool
    let onFixTask: (UUID, String) -> Void

    @State private var tab: Tab = .repo
    @State private var catalog: RuleCatalog?
    @State private var search = ""
    @State private var errorMessage: String?
    @State private var panel: Panel?
    @State private var pendingDelete: RuleRecord?
    @State private var pendingLink: RuleRecord?
    /// A toggle shows its new state at once; the daemon's answer settles it.
    @State private var enabledOverrides: [String: Bool] = [:]
    @State private var isFixing = false

    private static let panelAnimation = Animation.spring(response: 0.34, dampingFraction: 0.9)

    /// A rule's name is a path, so a repository rule is told apart by its
    /// repository, and one named by a full path uses its short ID.
    static func key(_ rule: RuleRecord) -> String {
        if rule.scope == .repo, let repository = rule.repositoryPath {
            return URL(fileURLWithPath: repository).lastPathComponent + ":" + rule.name
        }
        return rule.name.hasPrefix("/") ? rule.id : rule.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Picker("Rule source", selection: $tab) {
                    ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .accessibilityIdentifier("rules-tab-picker")
                Spacer()
                AtomTextField(props: TextFieldProps(text: search, placeholder: "Search rules"), common: AtomCommon(testID: "rules-search", width: 200)) { search = $0 }
                Button { setPanel(.creating) } label: { Label("New Rule", systemImage: "plus") }
                    .buttonHoverPointer()
                    .nativeHelp("Create a rule that both Claude and Codex follow")
                    .accessibilityIdentifier("new-rule-button")
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
                    .accessibilityIdentifier("rules-error")
            }
            Text("Rules are the instruction files an agent follows on every turn. Click one to open it. Turning a rule on or off reaches Claude on its next turn, and a Codex conversation the next time its thread starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .accessibilityIdentifier("rules-provider-timing")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) { content }
                    .padding(20)
                    .hoverRevealScrollers()
            }
            .accessibilityIdentifier("rules-list")
        }
        // Takes hits only while a panel is open (see McpServersSectionView).
        .overlay { panels.allowsHitTesting(panel != nil) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rules-page")
        .task { await reload() }
        .alert(
            "Delete \(pendingDelete?.name ?? "rule")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { rule in
            Button("Delete", role: .destructive) { perform { try await manager.deleteRules(taskID: task.id, ruleIDs: [rule.id]) } }
                .buttonHoverPointer()
                .nativeHelp("Delete the rule file from disk")
                .accessibilityIdentifier("confirm-delete-rule")
            Button("Cancel", role: .cancel) {}
                .buttonHoverPointer()
                .nativeHelp("Keep the rule")
        } message: { rule in
            Text("This removes \(rule.filePath) from disk for both Claude and Codex.")
        }
        .confirmationDialog(
            "Make \(pendingLink?.name ?? "rule") available outside Playhouse?",
            isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
            presenting: pendingLink
        ) { rule in
            Button("Create Link") { perform { _ = try await manager.linkRule(taskID: task.id, ruleID: rule.id, linked: true) } }
                .buttonHoverPointer()
                .nativeHelp("Write a symlink so both CLIs read the rule on their own")
                .accessibilityIdentifier("confirm-link-rule")
            Button("Cancel", role: .cancel) {}
                .buttonHoverPointer()
                .nativeHelp("Keep sharing the rule only in Playhouse sessions")
        } message: { rule in
            Text(rule.scope == .repo
                 ? "Playhouse writes a symlink inside the repository, so the claude and codex CLIs read the rule outside Playhouse too. Commit it to share it with teammates."
                 : "Playhouse writes a symlink in your home folder, so the claude and codex CLIs read the rule outside Playhouse too.")
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
            case .editing(let rule, let content):
                RuleEditorPanel(rule: rule, content: content, onClose: { setPanel(nil) }) { edited in
                    let record = try await manager.updateRuleContent(taskID: task.id, ruleID: rule.id, content: edited)
                    catalog = catalog?.replacing(record)
                    await reload()
                }
                .id(rule.id)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .transition(.move(edge: .bottom))
                .zIndex(1)
            case .creating:
                NewRulePanel(roots: catalog?.repositories ?? [], onClose: { setPanel(nil) }) { name, paths, body, scope, root in
                    let record = try await manager.createRule(taskID: task.id, name: name, paths: paths, body: body, scope: scope, root: root)
                    tab = record.scope == .global ? .global : .repo
                    search = ""
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
            switch tab {
            case .repo:
                Text("Rules in the task's repositories: AGENTS.md, CLAUDE.md, CLAUDE.local.md and .claude/rules. Playhouse shares each one with the agent that would not read it on its own.")
                    .font(.callout).foregroundStyle(.secondary)
                if catalog.repositories.isEmpty {
                    emptyState("This task has no repositories.", identifier: "rules-empty-repo")
                }
                ForEach(catalog.repositories, id: \.rootPath) { section in
                    let shown = filtered(section.rules)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.name)
                            .font(.headline)
                            .padding(.top, 6)
                            .accessibilityIdentifier("rules-repo-section-\(section.name)")
                        if shown.isEmpty {
                            emptyState(section.rules.isEmpty ? "No rules in \(section.name)." : "No matching rules.", identifier: "rules-empty-\(section.name)")
                        }
                        ForEach(shown) { row($0) }
                    }
                }
            case .global:
                let shown = filtered(catalog.global)
                Text("Your rules for every repository. New global rules go in ~/.agents/AGENTS.md, which Playhouse shares with both agents, like ~/.agents/skills.")
                    .font(.callout).foregroundStyle(.secondary)
                if shown.isEmpty { emptyState(catalog.global.isEmpty ? "No global rules." : "No matching rules.", identifier: "rules-empty-global") }
                ForEach(shown) { row($0) }
            case .managed:
                let shown = filtered(catalog.managed)
                Text("Your organization's managed CLAUDE.md. Claude Code always follows it, and it can't be edited or turned off here.")
                    .font(.callout).foregroundStyle(.secondary)
                if shown.isEmpty { emptyState(catalog.managed.isEmpty ? "No managed rules on this Mac." : "No matching rules.", identifier: "rules-empty-managed") }
                ForEach(shown) { row($0) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("rules-loading")
        }
    }

    private func emptyState(_ text: String, identifier: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding(.vertical, 6).accessibilityIdentifier(identifier)
    }

    /// The rules whose path or summary contains the search, like the Skills search.
    private func filtered(_ rules: [RuleRecord]) -> [RuleRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return rules }
        return rules.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.summary.localizedCaseInsensitiveContains(query) }
    }

    private func isEnabled(_ rule: RuleRecord) -> Bool { enabledOverrides[rule.id] ?? rule.enabled }

    /// Who Playhouse hands the rule to, because they don't read it themselves.
    private static func sharedNote(_ rule: RuleRecord) -> String? {
        guard !rule.sharedWith.isEmpty else { return nil }
        return "Playhouse shares it with " + rule.sharedWith.map(\.displayName).joined(separator: " and ") + "."
    }

    private func row(_ rule: RuleRecord) -> some View {
        let key = Self.key(rule)
        return HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(rule.name)
                            .font(.body.weight(.semibold))
                            .accessibilityIdentifier("rule-name-\(key)")
                        ForEach([ConversationProvider.claude, .codex]) { provider in
                            if rule.providers.contains(provider) {
                                badge(provider.displayName, systemImage: "checkmark", color: .green)
                                    .accessibilityIdentifier("rule-provider-\(key)-\(provider.rawValue)")
                            }
                        }
                        if !rule.paths.isEmpty {
                            badge(rule.paths.joined(separator: ", "), systemImage: "scope", color: .purple)
                                .accessibilityIdentifier("rule-paths-\(key)")
                        }
                        // Linked when Playhouse's symlinks make it work outside Playhouse;
                        // a file both CLIs already read needs no link.
                        if rule.availableOutsidePlayhouse, rule.locations.contains(where: \.isSymlink) {
                            badge("Linked", systemImage: "link", color: .blue)
                                .accessibilityIdentifier("rule-linked-\(key)")
                        } else if rule.availableOutsidePlayhouse {
                            badge("Both CLIs", systemImage: "checkmark.seal", color: .blue)
                                .accessibilityIdentifier("rule-native-\(key)")
                        }
                        if rule.issue != nil {
                            badge("Problem", systemImage: "exclamationmark.triangle", color: .orange)
                                .accessibilityIdentifier("rule-problem-\(key)")
                        }
                    }
                    if !rule.summary.isEmpty {
                        Text(rule.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .accessibilityIdentifier("rule-summary-\(key)")
                    }
                    if let issue = rule.issue {
                        Text(issue).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("rule-issue-\(key)")
                    }
                    if !isEnabled(rule), !rule.alwaysOnFor.isEmpty {
                        Text("\(rule.alwaysOnFor.map(\.displayName).joined(separator: " and ")) still reads this file itself, so turning it off applies to the other agent only.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("rule-always-on-\(key)")
                    } else if let note = Self.sharedNote(rule) {
                        Text(note).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("rule-shared-\(key)")
                    }
                    Text(rule.locations.map(\.layout.displayName).joined(separator: " · ") + " · " + ByteCountFormatter.string(fromByteCount: Int64(rule.byteCount), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("rule-location-\(key)")
                }
                Spacer(minLength: 8)
            }
            .overlay {
                PressAreaView(showsPointingHand: true, onClick: { openEditor(rule) }, onLongPress: {})
            }
            if rule.issue != nil, rule.editable {
                Button { fix(rule) } label: { Label("Fix with Agent", systemImage: "wand.and.stars") }
                    .controlSize(.small)
                    .disabled(isFixing)
                    .buttonHoverPointer()
                    .nativeHelp("Open a task whose agent fixes \(rule.name)")
                    .accessibilityIdentifier("rule-fix-\(key)")
            }
            if rule.scope != .managed {
                Toggle("Enabled", isOn: Binding(get: { isEnabled(rule) }, set: { setEnabled(rule, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .buttonHoverPointer()
                    .nativeHelp(isEnabled(rule) ? "Turn the rule off in Playhouse sessions" : "Turn the rule on in Playhouse sessions")
                    .accessibilityLabel("\(rule.name) enabled")
                    .accessibilityIdentifier("rule-toggle-\(key)")
            }
            actions(rule, key: key)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rule-row-\(key)")
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

    private func actions(_ rule: RuleRecord, key: String) -> some View {
        Menu {
            Button(rule.editable ? "Edit…" : "View…") { openEditor(rule) }
                .buttonHoverPointer()
                .help(rule.editable ? "Edit the rule file" : "Read the rule file")
                .accessibilityIdentifier("rule-edit-\(key)")
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rule.filePath)]) }
                .buttonHoverPointer()
                .help("Show the rule file in Finder")
                .accessibilityIdentifier("rule-reveal-\(key)")
            if rule.editable {
                Divider()
                if rule.locations.contains(where: \.isSymlink) {
                    Button("Remove Outside Link") {
                        perform { _ = try await manager.linkRule(taskID: task.id, ruleID: rule.id, linked: false) }
                    }
                    .buttonHoverPointer()
                    .help("Remove the symlink; Playhouse sessions still share the rule")
                    .accessibilityIdentifier("rule-unlink-\(key)")
                } else if rule.linkable {
                    Button("Make Available Outside Playhouse…") { pendingLink = rule }
                        .buttonHoverPointer()
                        .help("Write a symlink so the claude and codex CLIs read the rule on their own")
                        .accessibilityIdentifier("rule-link-\(key)")
                }
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = rule }
                    .buttonHoverPointer()
                    .help("Delete the rule file from disk")
                    .accessibilityIdentifier("rule-delete-\(key)")
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
        .nativeHelp("More actions for \(rule.name)")
        .accessibilityLabel("Actions for \(rule.name)")
        .accessibilityIdentifier("rule-actions-\(key)")
    }

    private func openEditor(_ rule: RuleRecord) {
        perform(reloading: false) {
            let content = try await manager.ruleContent(taskID: task.id, ruleID: rule.id)
            setPanel(.editing(rule, content))
        }
    }

    private func setEnabled(_ rule: RuleRecord, _ enabled: Bool) {
        enabledOverrides[rule.id] = enabled
        Task { @MainActor in
            do {
                let record = try await manager.setRuleEnabled(taskID: task.id, ruleID: rule.id, enabled: enabled)
                catalog = catalog?.replacing(record)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            if enabledOverrides[rule.id] == enabled { enabledOverrides[rule.id] = nil }
        }
    }

    private func fix(_ rule: RuleRecord) {
        guard !isFixing else { return }
        isFixing = true
        Task { @MainActor in
            defer { isFixing = false }
            do {
                let created = try await manager.fixRules(taskID: task.id, ruleIDs: [rule.id])
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
            catalog = try await manager.rules(taskID: task.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Opens a rule file as written, with a tab that previews it as Markdown.
private struct RuleEditorPanel: View {
    let rule: RuleRecord
    let onClose: () -> Void
    let onSave: (String) async throws -> Void
    @State private var content: String
    @State private var tab = SkillDocumentTab.edit
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(rule: RuleRecord, content: String, onClose: @escaping () -> Void, onSave: @escaping (String) async throws -> Void) {
        self.rule = rule
        self.onClose = onClose
        self.onSave = onSave
        _content = State(initialValue: content)
    }

    var body: some View {
        SkillPanel(identifier: "rule-editor-panel") {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name)
                        .font(.title2.weight(.semibold))
                        .accessibilityIdentifier("rule-editor-name")
                    Text(rule.filePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("rule-editor-location")
                }
                Spacer()
                SkillDocumentTabPicker(tab: $tab, identifier: "rule-editor-tab-picker")
            }
        } content: {
            switch tab {
            case .edit: SkillTextEditor(text: $content, identifier: "rule-editor", isEditable: rule.editable)
            case .preview: SkillMarkdownPreview(markdown: content, identifier: "rule-editor-preview")
            }
        } footer: {
            HStack {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout).accessibilityIdentifier("rule-editor-error")
                } else if !rule.editable {
                    Text("Your organization manages this file, so it is read-only.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(rule.editable ? "Cancel" : "Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .buttonHoverPointer()
                    .nativeHelp(rule.editable ? "Discard changes" : "Close the rule")
                    .accessibilityIdentifier("rule-editor-cancel")
                if rule.editable {
                    Button("Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)
                        .buttonHoverPointer()
                        .nativeHelp("Save the rule (⌘S)")
                        .accessibilityIdentifier("rule-editor-save")
                }
            }
        }
    }

    private func save() {
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await onSave(content)
                onClose()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct NewRulePanel: View {
    enum Form: String, CaseIterable, Identifiable {
        case shared = "Shared instructions"
        case topic = "Topic rule"
        var id: String { rawValue }
    }

    let roots: [RuleRepositorySection]
    let onClose: () -> Void
    /// Name (nil for AGENTS.md), path globs, instructions, scope, and the repository root.
    let onCreate: (String?, [String], String, RuleScope, String?) async throws -> Void
    @State private var form = Form.shared
    @State private var name = ""
    @State private var paths = ""
    @State private var instructions = ""
    /// "global", or the root path of one of the task's repositories.
    @State private var destination = "global"
    @State private var tab = SkillDocumentTab.edit
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var target: String {
        switch (destination == "global", form) {
        case (true, .shared): "~/.agents/AGENTS.md, which Playhouse shares with both Claude and Codex."
        case (false, .shared): "the repository's AGENTS.md, which both Claude and Codex read."
        case (true, .topic): "Claude's rules folder; Playhouse shares it with Codex."
        case (false, .topic): "the repository's .claude/rules; Playhouse shares it with Codex."
        }
    }

    var body: some View {
        SkillPanel(identifier: "new-rule-panel") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("New Rule").font(.headline)
                    Spacer()
                    Picker("Kind", selection: $form) {
                        ForEach(Form.allCases) { form in Text(form.rawValue).tag(form) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityIdentifier("new-rule-form")
                    Picker("Save to", selection: $destination) {
                        Text("Global").tag("global")
                        ForEach(roots, id: \.rootPath) { root in Text(root.name).tag(root.rootPath) }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("new-rule-scope")
                }
                Text("Saved as " + target)
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("new-rule-target")
                if form == .topic {
                    TextField("rule-name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Name")
                        .accessibilityIdentifier("new-rule-name")
                    TextField("Only for matching files, such as src/**/*.ts (optional, comma separated)", text: $paths)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Paths")
                        .accessibilityIdentifier("new-rule-paths")
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Instructions").font(.subheadline.weight(.semibold))
                    Spacer()
                    SkillDocumentTabPicker(tab: $tab, identifier: "new-rule-tab-picker")
                }
                switch tab {
                case .edit: SkillTextEditor(text: $instructions, identifier: "new-rule-body", isEditable: true)
                case .preview: SkillMarkdownPreview(markdown: instructions, identifier: "new-rule-preview")
                }
            }
        } footer: {
            HStack {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout).accessibilityIdentifier("new-rule-error")
                }
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .buttonHoverPointer()
                    .nativeHelp("Close without creating a rule")
                    .accessibilityIdentifier("new-rule-cancel")
                Button("Create") { create() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                    .buttonHoverPointer()
                    .nativeHelp("Create the rule (⌘S)")
                    .accessibilityIdentifier("new-rule-create")
            }
        }
    }

    private func create() {
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                let scope: RuleScope = destination == "global" ? .global : .repo
                let globs = form == .topic ? paths.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } : []
                try await onCreate(form == .topic ? name.trimmingCharacters(in: .whitespaces) : nil, globs, instructions, scope, scope == .repo ? destination : nil)
                onClose()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
