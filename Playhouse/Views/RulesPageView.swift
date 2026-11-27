import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

// MARK: - Rules

/// The instruction files agents follow on every turn: each repository's
/// AGENTS.md, CLAUDE.md and `.claude/rules`, the user's global ones, and the
/// organization's managed CLAUDE.md. Like skills, each rule is shared with the
/// provider that would not read it on its own.
package struct RulesSectionView: PHView {
    package enum Panel {
        case editing(RuleRecord, String)
        case creating
    }

    package let task: any ConversationSubject
    package let manager: RemoteConversationManager
    @PHBinding package var isPresentingPanel: Bool
    package let onFixTask: (UUID, String) -> Void

    /// The section the list last scrolled to, and how many times it has.
    @PHState private var scrollTarget: String?
    @PHState private var scrollRequest = 0
    @PHState private var catalog: RuleCatalog?
    @PHState private var search = ""
    @PHState private var errorMessage: String?
    @PHState private var panel: Panel?
    @PHState private var pendingDelete: RuleRecord?
    @PHState private var pendingLink: RuleRecord?
    /// A toggle shows its new state at once; the daemon's answer settles it.
    @PHState private var enabledOverrides: [String: Bool] = [:]
    @PHState private var isFixing = false

    private static let panelAnimation = PHAnimation.spring(response: 0.34, dampingFraction: 0.9)

    /// A rule's name is a path, so a repository rule is told apart by its
    /// repository, and one named by a full path uses its short ID.
    package static func key(_ rule: RuleRecord) -> String {
        if rule.scope == .repo, let repository = rule.repositoryPath {
            return URL(fileURLWithPath: repository).lastPathComponent + ":" + rule.name
        }
        return rule.name.hasPrefix("/") ? rule.id : rule.name
    }

    package var body: some PHView {
        PHVStack(alignment: .leading, spacing: 0) {
            PHHStack(spacing: 8) {
                SkillsPageSearchField(text: search, placeholder: "Search rules", testID: "rules-search") { search = $0 }
                AtomButton(
                    props: ButtonProps(style: "bordered", controlSize: "small"),
                    common: AtomCommon(testID: "new-rule-button", help: "Create a rule that both Claude and Codex follow"),
                    action: { setPanel(.creating) }
                ) {
                    AtomLabel(props: LabelProps(text: "New Rule", icon: PHIcon.plus.name))
                }
            }
            .padding(.horizontal, 20)
            PHHStack(spacing: 8) {
                SkillsPageAnchorBar(testID: "rules-tab-picker", anchorPrefix: "rules-anchor", anchors: anchors, onJump: jump)
                PHSpacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            if let errorMessage {
                PHText(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("rules-error")
            }
            PHDivider()
            PHScrollViewReader { proxy in
                PHScrollView {
                    PHVStack(alignment: .leading, spacing: 18) {
                        content
                        PHText("Rules are the instruction files an agent follows on every turn. Hover one for its details, or click it to open it. Turning a rule on or off reaches Claude on its next turn, and a Codex conversation the next time its thread starts.")
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
                    phWithAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(scrollTarget, anchor: .top) }
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
            isPresented: PHBinding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { rule in
            PHButton("Delete", role: .destructive) { perform { try await manager.deleteRules(taskID: task.id, ruleIDs: [rule.id]) } }
                .buttonHoverPointer()
                .nativeHelp("Delete the rule file from disk")
                .accessibilityIdentifier("confirm-delete-rule")
            PHButton("Cancel", role: .cancel) {}
                .buttonHoverPointer()
                .nativeHelp("Keep the rule")
        } message: { rule in
            PHText("This removes \(rule.filePath) from disk for both Claude and Codex.")
        }
        .confirmationDialog(
            "Make \(pendingLink?.name ?? "rule") available outside Playhouse?",
            isPresented: PHBinding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
            presenting: pendingLink
        ) { rule in
            PHButton("Create Link") { perform { _ = try await manager.linkRule(taskID: task.id, ruleID: rule.id, linked: true) } }
                .buttonHoverPointer()
                .nativeHelp("Write a symlink so both CLIs read the rule on their own")
                .accessibilityIdentifier("confirm-link-rule")
            PHButton("Cancel", role: .cancel) {}
                .buttonHoverPointer()
                .nativeHelp("Keep sharing the rule only in Playhouse sessions")
        } message: { rule in
            PHText(rule.scope == .repo
                 ? "Playhouse writes a symlink inside the repository, so the claude and codex CLIs read the rule outside Playhouse too. Commit it to share it with teammates."
                 : "Playhouse writes a symlink in your home folder, so the claude and codex CLIs read the rule outside Playhouse too.")
        }
    }

    private func setPanel(_ value: Panel?) {
        phWithAnimation(Self.panelAnimation) { panel = value }
        isPresentingPanel = value != nil
    }

    private var panels: some PHView {
        PHZStack {
            if panel != nil {
                PHColor.black.opacity(0.18).ignoresSafeArea().transition(.opacity).zIndex(0)
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
            SkillsPageAnchor(value: "repo", label: "Repo", count: (catalog?.repositories ?? []).reduce(0) { $0 + filtered($1.rules).count }),
            SkillsPageAnchor(value: "global", label: "Global", count: filtered(catalog?.global ?? []).count),
            SkillsPageAnchor(value: "managed", label: "Managed", count: filtered(catalog?.managed ?? []).count),
        ]
    }

    @PHViewBuilder
    private var content: some PHView {
        if let catalog {
            let counts = Dictionary(uniqueKeysWithValues: anchors.map { ($0.value, $0) })
            group(counts["repo"]!, intro: "Rules in the task's repositories: AGENTS.md, CLAUDE.md, CLAUDE.local.md and .claude/rules. Playhouse shares each one with the agent that would not read it on its own.") {
                if catalog.repositories.isEmpty {
                    emptyState("This task has no repositories.", identifier: "rules-empty-repo")
                }
                PHForEach(catalog.repositories, id: \.rootPath) { section in
                    let shown = filtered(section.rules)
                    PHText(section.name)
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
            PHProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("rules-loading")
        }
    }

    /// One of the list's sections, which its anchor scrolls to.
    private func group<Content: PHView>(_ anchor: SkillsPageAnchor, intro: String, @PHViewBuilder content: () -> Content) -> some PHView {
        PHVStack(alignment: .leading, spacing: 8) {
            SkillsPageGroupHeader(label: anchor.label, count: anchor.count, intro: intro, introTestID: "rules-intro-\(anchor.value)")
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(anchor.value)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(anchor.label)
        .accessibilityIdentifier("rules-group-\(anchor.value)")
    }

    @PHViewBuilder
    private func rows(_ rules: [RuleRecord]) -> some PHView {
        if !rules.isEmpty {
            SkillsPageCard {
                PHForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                    if index > 0 { AtomDivider() }
                    row(rule)
                }
            }
        }
    }

    private func emptyState(_ text: String, identifier: String) -> some PHView {
        PHText(text).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 4).accessibilityIdentifier(identifier)
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
        return "Playhouse shares it with " + ConversationProvider.names(rule.sharedWith) + "."
    }

    /// A rule on one line: its name, a mark when it has a problem, its Fix,
    /// switch and actions. Its details show in a hint while the pointer rests on it.
    private func row(_ rule: RuleRecord) -> some PHView {
        let key = Self.key(rule)
        return AtomPopover(props: PopoverProps(isPresented: false, arrowEdge: "trailing", width: 320, inset: 12, hover: true), onDismiss: {}) {
            PHHStack(alignment: .center, spacing: 8) {
                PHHStack(alignment: .center, spacing: 8) {
                    // Who follows the rule leads its name, like a skill's row.
                    if let mark = SkillsPageModel.providerMark(Set(rule.providers), testID: "rule-provider-\(key)") {
                        ProviderMarkIcon(mark: mark)
                    }
                    PHText(rule.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityIdentifier("rule-name-\(key)")
                    if rule.issue != nil {
                        PHImage(icon: .exclamationmarkTriangleFill)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .nativeHelp("Problem")
                            .accessibilityLabel("Problem")
                            .accessibilityIdentifier("rule-problem-\(key)")
                    }
                    PHSpacer(minLength: 8)
                }
                .overlay {
                    PHPressArea(onClick: { openEditor(rule) }, onLongPress: {})
                }
                .buttonHoverPointer()
                .accessibilityHint(rule.summary)
                if rule.issue != nil, rule.editable {
                    PHButton { fix(rule) } label: { PHLabel("Fix", icon: .wandAndStars) }
                        .controlSize(.small)
                        .disabled(isFixing)
                        .buttonHoverPointer()
                        .nativeHelp("Open a task whose agent fixes \(rule.name)")
                        .accessibilityIdentifier("rule-fix-\(key)")
                }
                if rule.scope != .managed {
                    PHToggle("Enabled", isOn: PHBinding(get: { isEnabled(rule) }, set: { setEnabled(rule, $0) }))
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
    private func hint(_ rule: RuleRecord, key: String) -> some PHView {
        PHVStack(alignment: .leading, spacing: 6) {
            PHText(rule.name).font(.system(size: 13, weight: .semibold))
            if !rule.summary.isEmpty {
                PHText(rule.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rule-summary-\(key)")
            }
            PHHStack(spacing: 4) {
                if !rule.paths.isEmpty {
                    badge(rule.paths.joined(separator: ", "), icon: .scope, color: .purple)
                        .accessibilityIdentifier("rule-paths-\(key)")
                }
                // Linked when Playhouse's symlinks make it work outside Playhouse;
                // a file both CLIs already read needs no link.
                if rule.availableOutsidePlayhouse, rule.locations.contains(where: \.isSymlink) {
                    badge("Linked", icon: .link, color: .blue)
                        .accessibilityIdentifier("rule-linked-\(key)")
                } else if rule.availableOutsidePlayhouse {
                    badge("Both CLIs", icon: .checkmarkSeal, color: .blue)
                        .accessibilityIdentifier("rule-native-\(key)")
                }
            }
            if let issue = rule.issue {
                PHText(issue)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rule-issue-\(key)")
            }
            if !isEnabled(rule), !rule.alwaysOnFor.isEmpty {
                PHText("\(ConversationProvider.names(rule.alwaysOnFor)) still \(rule.alwaysOnFor.count == 1 ? "reads" : "read") this file itself, so turning it off applies to the other agents only.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rule-always-on-\(key)")
            } else if let note = Self.sharedNote(rule) {
                PHText(note).font(.system(size: 11)).foregroundStyle(.secondary).accessibilityIdentifier("rule-shared-\(key)")
            }
            PHText(rule.locations.map(\.layout.displayName).joined(separator: " · ") + " · " + ByteCountFormatter.string(fromByteCount: Int64(rule.byteCount), countStyle: .file))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("rule-location-\(key)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rule-hint-\(key)")
    }

    private func badge(_ text: String, icon: PHIcon, color: PHColor) -> some PHView {
        PHLabel(text, icon: icon)
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: PHCapsule())
    }

    private func actions(_ rule: RuleRecord, key: String) -> some PHView {
        PHMenu {
            PHButton(rule.editable ? "Edit…" : "View…") { openEditor(rule) }
                .help(rule.editable ? "Edit the rule file" : "Read the rule file")
                .accessibilityIdentifier("rule-edit-\(key)")
            PHButton("Reveal in Finder") { Platform.services.revealInFileBrowser([URL(fileURLWithPath: rule.filePath)]) }
                .help("Show the rule file in Finder")
                .accessibilityIdentifier("rule-reveal-\(key)")
            if rule.editable {
                PHDivider()
                if rule.locations.contains(where: \.isSymlink) {
                    PHButton("Remove Outside Link") {
                        perform { _ = try await manager.linkRule(taskID: task.id, ruleID: rule.id, linked: false) }
                    }
                    .help("Remove the symlink; Playhouse sessions still share the rule")
                    .accessibilityIdentifier("rule-unlink-\(key)")
                } else if rule.linkable {
                    PHButton("Make Available Outside Playhouse…") { pendingLink = rule }
                        .help("Write a symlink so the claude and codex CLIs read the rule on their own")
                        .accessibilityIdentifier("rule-link-\(key)")
                }
                PHDivider()
                PHButton("Delete…", role: .destructive) { pendingDelete = rule }
                    .help("Delete the rule file from disk")
                    .accessibilityIdentifier("rule-delete-\(key)")
            }
        } label: {
            PHImage(icon: .ellipsis)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(PHRectangle())
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

    package init(task: any ConversationSubject, manager: RemoteConversationManager, isPresentingPanel: PHBinding<Bool>, onFixTask: @escaping (UUID, String) -> Void) {
        self.task = task
        self.manager = manager
        _isPresentingPanel = isPresentingPanel
        self.onFixTask = onFixTask
    }
}

/// Opens a rule file as written, with a tab that previews it as Markdown.
private struct RuleEditorPanel: PHView {
    let rule: RuleRecord
    let onClose: () -> Void
    let onSave: (String) async throws -> Void
    @PHState private var content: String
    @PHState private var tab = SkillDocumentTab.edit
    @PHState private var errorMessage: String?
    @PHState private var isSaving = false

    init(rule: RuleRecord, content: String, onClose: @escaping () -> Void, onSave: @escaping (String) async throws -> Void) {
        self.rule = rule
        self.onClose = onClose
        self.onSave = onSave
        _content = PHState(initialValue: content)
    }

    var body: some PHView {
        SkillPanel(identifier: "rule-editor-panel") {
            PHHStack(alignment: .center, spacing: 10) {
                PHImage(icon: .listBulletRectangle)
                    .font(.title2)
                    .foregroundStyle(.tint)
                PHVStack(alignment: .leading, spacing: 2) {
                    PHText(rule.name)
                        .font(.title2.weight(.semibold))
                        .accessibilityIdentifier("rule-editor-name")
                    PHText(rule.filePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("rule-editor-location")
                }
                PHSpacer()
                SkillDocumentTabPicker(tab: $tab, identifier: "rule-editor-tab-picker")
            }
        } content: {
            switch tab {
            case .edit: PHNativeTextEditor(text: $content, identifier: "rule-editor", isEditable: rule.editable)
            case .preview: SkillMarkdownPreview(markdown: content, identifier: "rule-editor-preview")
            }
        } footer: {
            PHHStack {
                if let errorMessage {
                    PHText(errorMessage).foregroundStyle(.red).font(.callout).accessibilityIdentifier("rule-editor-error")
                } else if !rule.editable {
                    PHText("Your organization manages this file, so it is read-only.").font(.callout).foregroundStyle(.secondary)
                }
                PHSpacer()
                PHButton(rule.editable ? "Cancel" : "Close", action: onClose)
                    .buttonHoverPointer()
                    .shortcutHelp(rule.editable ? "Discard changes" : "Close the rule", shortcut: "cancel")
                    .accessibilityIdentifier("rule-editor-cancel")
                if rule.editable {
                    PHButton("Save") { save() }
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

private struct NewRulePanel: PHView {
    enum Form: String, CaseIterable, Identifiable {
        case shared = "Shared instructions"
        case topic = "Topic rule"
        package var id: String { rawValue }
    }

    let roots: [RuleRepositorySection]
    let onClose: () -> Void
    /// Name (nil for AGENTS.md), path globs, instructions, scope, and the repository root.
    let onCreate: (String?, [String], String, RuleScope, String?) async throws -> Void
    @PHState private var form = Form.shared
    @PHState private var name = ""
    @PHState private var paths = ""
    @PHState private var instructions = ""
    /// "global", or the root path of one of the task's repositories.
    @PHState private var destination = "global"
    @PHState private var tab = SkillDocumentTab.edit
    @PHState private var errorMessage: String?
    @PHState private var isSaving = false

    private var target: String {
        switch (destination == "global", form) {
        case (true, .shared): "~/.agents/AGENTS.md, which Playhouse shares with both Claude and Codex."
        case (false, .shared): "the repository's AGENTS.md, which both Claude and Codex read."
        case (true, .topic): "Claude's rules folder; Playhouse shares it with Codex."
        case (false, .topic): "the repository's .claude/rules; Playhouse shares it with Codex."
        }
    }

    var body: some PHView {
        SkillPanel(identifier: "new-rule-panel") {
            PHVStack(alignment: .leading, spacing: 12) {
                PHText("New Rule").font(.headline)
                // The controls get their own rows so the panel fits the narrow modal.
                PHVStack(alignment: .leading, spacing: 8) {
                    PHPicker("Kind", selection: $form) {
                        PHForEach(Form.allCases) { form in PHText(form.rawValue).tag(form) }
                    }
                    .buttonHoverPointer()
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .accessibilityIdentifier("new-rule-form")
                    PHPicker("Save to", selection: $destination) {
                        PHText("Global").tag("global")
                        PHForEach(roots, id: \.rootPath) { root in PHText(root.name).tag(root.rootPath) }
                    }
                    .buttonHoverPointer()
                    .fixedSize()
                    .accessibilityIdentifier("new-rule-scope")
                }
                PHText("Saved as " + target)
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("new-rule-target")
                if form == .topic {
                    PHTextField("rule-name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Name")
                        .accessibilityIdentifier("new-rule-name")
                    PHTextField("Only for matching files, such as src/**/*.ts (optional, comma separated)", text: $paths)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Paths")
                        .accessibilityIdentifier("new-rule-paths")
                }
            }
        } content: {
            PHVStack(alignment: .leading, spacing: 6) {
                PHHStack {
                    PHText("Instructions").font(.subheadline.weight(.semibold))
                    PHSpacer()
                    SkillDocumentTabPicker(tab: $tab, identifier: "new-rule-tab-picker")
                }
                switch tab {
                case .edit: PHNativeTextEditor(text: $instructions, identifier: "new-rule-body", isEditable: true)
                case .preview: SkillMarkdownPreview(markdown: instructions, identifier: "new-rule-preview")
                }
            }
        } footer: {
            PHHStack {
                if let errorMessage {
                    PHText(errorMessage).foregroundStyle(.red).font(.callout).accessibilityIdentifier("new-rule-error")
                }
                PHSpacer()
                PHButton("Cancel", action: onClose)
                    .buttonHoverPointer()
                    .shortcutHelp("Close without creating a rule", shortcut: "cancel")
                    .accessibilityIdentifier("new-rule-cancel")
                PHButton("Create") { create() }
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
