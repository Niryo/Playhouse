import AppKit
import SwiftUI

// MARK: - Rules

/// The instruction files agents follow on every turn: each repository's
/// AGENTS.md, CLAUDE.md and `.claude/rules`, the user's global ones, and the
/// organization's managed CLAUDE.md. Like skills, each rule is shared with the
/// provider that would not read it on its own.
struct RulesSectionView: View {
    enum Panel {
        case editing(RuleRecord, String)
        case creating
    }

    let task: any ConversationSubject
    let manager: RemoteConversationManager
    @Binding var isPresentingPanel: Bool
    let onFixTask: (UUID, String) -> Void

    /// The section the list last scrolled to, and how many times it has.
    @State private var scrollTarget: String?
    @State private var scrollRequest = 0
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
            HStack(spacing: 8) {
                SkillsPageSearchField(text: search, placeholder: "Search rules", testID: "rules-search") { search = $0 }
                AtomButton(
                    props: ButtonProps(style: "bordered", controlSize: "small"),
                    common: AtomCommon(testID: "new-rule-button", help: "Create a rule that both Claude and Codex follow"),
                    action: { setPanel(.creating) }
                ) {
                    AtomLabel(props: LabelProps(text: "New Rule", icon: "plus"))
                }
            }
            .padding(.horizontal, 20)
            HStack(spacing: 8) {
                SkillsPageAnchorBar(testID: "rules-tab-picker", anchorPrefix: "rules-anchor", anchors: anchors, onJump: jump)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("rules-error")
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        content
                        Text("Rules are the instruction files an agent follows on every turn. Hover one for its details, or click it to open it. Turning a rule on or off reaches Claude on its next turn, and a Codex conversation the next time its thread starts.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .accessibilityIdentifier("rules-provider-timing")
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hoverRevealScrollers()
                }
                .onChange(of: scrollRequest) {
                    guard let scrollTarget else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(scrollTarget, anchor: .top) }
                }
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
                    jump(record.scope == .global ? "global" : "repo")
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

    private func jump(_ section: String) {
        scrollTarget = section
        scrollRequest += 1
    }

    private var anchors: [SkillsPageAnchor] {
        [
            SkillsPageAnchor(value: "repo", label: "Repo", count: (catalog?.repositories ?? []).reduce(0) { $0 + filtered($1.rules).count }),
            SkillsPageAnchor(value: "global", label: "Global", count: filtered(catalog?.global ?? []).count),
            SkillsPageAnchor(value: "managed", label: "Managed", count: filtered(catalog?.managed ?? []).count),
        ]
    }

    @ViewBuilder
    private var content: some View {
        if let catalog {
            let counts = Dictionary(uniqueKeysWithValues: anchors.map { ($0.value, $0) })
            group(counts["repo"]!, intro: "Rules in the task's repositories: AGENTS.md, CLAUDE.md, CLAUDE.local.md and .claude/rules. Playhouse shares each one with the agent that would not read it on its own.") {
                if catalog.repositories.isEmpty {
                    emptyState("This task has no repositories.", identifier: "rules-empty-repo")
                }
                ForEach(catalog.repositories, id: \.rootPath) { section in
                    let shown = filtered(section.rules)
                    Text(section.name)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 4)
                        .accessibilityIdentifier("rules-repo-section-\(section.name)")
                    if shown.isEmpty {
                        emptyState(section.rules.isEmpty ? "No rules in \(section.name)." : "No matching rules.", identifier: "rules-empty-\(section.name)")
                    }
                    rows(shown)
                }
            }
            let global = filtered(catalog.global)
            group(counts["global"]!, intro: "Your rules for every repository. New global rules go in ~/.agents/AGENTS.md, which Playhouse shares with both agents, like ~/.agents/skills.") {
                if global.isEmpty { emptyState(catalog.global.isEmpty ? "No global rules." : "No matching rules.", identifier: "rules-empty-global") }
                rows(global)
            }
            let managed = filtered(catalog.managed)
            group(counts["managed"]!, intro: "Your organization's managed CLAUDE.md. Claude Code always follows it, and it can't be edited or turned off here.") {
                if managed.isEmpty { emptyState(catalog.managed.isEmpty ? "No managed rules on this Mac." : "No matching rules.", identifier: "rules-empty-managed") }
                rows(managed)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("rules-loading")
        }
    }

    /// One of the list's sections, which its anchor scrolls to.
    private func group<Content: View>(_ anchor: SkillsPageAnchor, intro: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SkillsPageGroupHeader(label: anchor.label, count: anchor.count, intro: intro, introTestID: "rules-intro-\(anchor.value)")
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(anchor.value)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(anchor.label)
        .accessibilityIdentifier("rules-group-\(anchor.value)")
    }

    @ViewBuilder
    private func rows(_ rules: [RuleRecord]) -> some View {
        if !rules.isEmpty {
            SkillsPageCard {
                ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                    if index > 0 { AtomDivider() }
                    row(rule)
                }
            }
        }
    }

    private func emptyState(_ text: String, identifier: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4).accessibilityIdentifier(identifier)
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

    /// A rule on one line: its name, a mark when it has a problem, its Fix,
    /// switch and actions. Its details show in a hint while the pointer rests on it.
    private func row(_ rule: RuleRecord) -> some View {
        let key = Self.key(rule)
        return AtomPopover(props: PopoverProps(isPresented: false, arrowEdge: "trailing", width: 320, inset: 12, hover: true), onDismiss: {}) {
            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    // Who follows the rule leads its name, like a skill's row.
                    if let mark = SkillsPageModel.providerMark(Set(rule.providers), testID: "rule-provider-\(key)") {
                        ProviderMarkIcon(mark: mark)
                    }
                    Text(rule.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("rule-name-\(key)")
                    if rule.issue != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .nativeHelp("Problem")
                            .accessibilityLabel("Problem")
                            .accessibilityIdentifier("rule-problem-\(key)")
                    }
                    Spacer(minLength: 8)
                }
                .overlay {
                    PressAreaView(showsPointingHand: true, onClick: { openEditor(rule) }, onLongPress: {})
                }
                .accessibilityHint(rule.summary)
                if rule.issue != nil, rule.editable {
                    Button { fix(rule) } label: { Label("Fix", systemImage: "wand.and.stars") }
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
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("rule-row-\(key)")
        } content: {
            hint(rule, key: key)
        }
    }

    /// A rule's details: its summary, what it applies to, any problem, and where it lives.
    private func hint(_ rule: RuleRecord, key: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(rule.name).font(.system(size: 13, weight: .semibold))
            if !rule.summary.isEmpty {
                Text(rule.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rule-summary-\(key)")
            }
            HStack(spacing: 4) {
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
            }
            if let issue = rule.issue {
                Text(issue)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rule-issue-\(key)")
            }
            if !isEnabled(rule), !rule.alwaysOnFor.isEmpty {
                Text("\(rule.alwaysOnFor.map(\.displayName).joined(separator: " and ")) still reads this file itself, so turning it off applies to the other agent only.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rule-always-on-\(key)")
            } else if let note = Self.sharedNote(rule) {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).accessibilityIdentifier("rule-shared-\(key)")
            }
            Text(rule.locations.map(\.layout.displayName).joined(separator: " · ") + " · " + ByteCountFormatter.string(fromByteCount: Int64(rule.byteCount), countStyle: .file))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("rule-location-\(key)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rule-hint-\(key)")
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
                    .buttonHoverPointer()
                    .shortcutHelp(rule.editable ? "Discard changes" : "Close the rule", shortcut: "cancel")
                    .accessibilityIdentifier("rule-editor-cancel")
                if rule.editable {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)
                        .buttonHoverPointer()
                        .shortcutHelp("Save the rule", shortcut: AppShortcut.save)
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
                Text("New Rule").font(.headline)
                // The controls get their own rows so the panel fits the narrow modal.
                VStack(alignment: .leading, spacing: 8) {
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
                    .buttonHoverPointer()
                    .shortcutHelp("Close without creating a rule", shortcut: "cancel")
                    .accessibilityIdentifier("new-rule-cancel")
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                    .buttonHoverPointer()
                    .shortcutHelp("Create the rule", shortcut: AppShortcut.save)
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
