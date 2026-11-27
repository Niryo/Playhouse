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
        AtomOverlay(common: AtomCommon(testID: "rules-page")) {
            AtomStack(props: StackProps(axis: "v", spacing: 0, align: "leading")) {
                AtomStack(props: StackProps(axis: "h", spacing: 8), common: AtomCommon(paddingX: 20)) {
                    SkillsPageSearchField(text: search, placeholder: "Search rules", testID: "rules-search") { search = $0 }
                    AtomButton(
                        props: ButtonProps(style: "bordered", controlSize: "small"),
                        common: AtomCommon(testID: "new-rule-button", help: "Create a rule that both Claude and Codex follow"),
                        action: { setPanel(.creating) }
                    ) {
                        AtomLabel(props: LabelProps(text: "New Rule", icon: PHIcon.plus.name))
                    }
                }
                AtomStack(props: StackProps(axis: "h", spacing: 8), common: AtomCommon(paddingX: 20, paddingY: 12)) {
                    SkillsPageAnchorBar(testID: "rules-tab-picker", anchorPrefix: "rules-anchor", anchors: anchors, onJump: jump)
                    AtomSpacer()
                }
                if let errorMessage {
                    CatalogRows.pageError(errorMessage, testID: "rules-error")
                }
                AtomDivider()
                AtomScroll(props: ScrollProps(spacing: 18, inset: 20, scrollTo: scrollTarget, scrollRequest: scrollRequest), common: AtomCommon(testID: "rules-list")) {
                    content
                    CatalogRows.footnote(
                        "Rules are the instruction files an agent follows on every turn. Hover one for its details, or click it to open it. Turning a rule on or off reaches Claude on its next turn, and a Codex conversation the next time its thread starts.",
                        testID: "rules-provider-timing"
                    )
                }
            }
        } overlay: {
            // Takes hits only while a panel is open (see McpServersSectionView).
            panels.allowsHitTesting(panel != nil)
        }
        .task { await reload() }
        // ATOM-GAP: an alert's and a confirmation dialog's actions and message must be native
        // Buttons and Text (the system dialog reads them), and ButtonProps has no cancel role.
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
        AtomStack(props: StackProps(axis: "z")) {
            if panel != nil {
                CatalogRows.dimming.ignoresSafeArea().transition(.opacity).zIndex(0)
            }
            switch panel {
            case .editing(let rule, let content):
                CatalogRows.panelSlot {
                    RuleEditorPanel(rule: rule, content: content, onClose: { setPanel(nil) }) { edited in
                        let record = try await manager.updateRuleContent(taskID: task.id, ruleID: rule.id, content: edited)
                        catalog = catalog?.replacing(record)
                        await reload()
                    }
                    .id(rule.id)
                }
                .transition(.move(edge: .bottom))
                .zIndex(1)
            case .creating:
                CatalogRows.panelSlot {
                    NewRulePanel(roots: catalog?.repositories ?? [], onClose: { setPanel(nil) }) { name, paths, body, scope, root in
                        let record = try await manager.createRule(taskID: task.id, name: name, paths: paths, body: body, scope: scope, root: root)
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
                    AtomText(props: TextProps(text: section.name, size: 12, weight: "semibold"), common: AtomCommon(paddingX: 4))
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
            CatalogRows.loading(testID: "rules-loading")
        }
    }

    /// One of the list's sections, which its anchor scrolls to.
    private func group<Content: PHView>(_ anchor: SkillsPageAnchor, intro: String, @PHViewBuilder content: @escaping () -> Content) -> some PHView {
        AtomStack(
            props: StackProps(axis: "v", spacing: 8, align: "leading", group: true, scrollID: anchor.value),
            common: AtomCommon(testID: "rules-group-\(anchor.value)", label: anchor.label, fillWidth: true)
        ) {
            SkillsPageGroupHeader(label: anchor.label, count: anchor.count, intro: intro, introTestID: "rules-intro-\(anchor.value)")
            content()
        }
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
        CatalogRows.note(text, testID: identifier)
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
            CatalogRows.listRow(testID: "rule-row-\(key)", hint: rule.summary, onOpen: { openEditor(rule) }) {
                // Who follows the rule leads its name, like a skill's row.
                if let mark = SkillsPageModel.providerMark(Set(rule.providers), testID: "rule-provider-\(key)") {
                    ProviderMarkIcon(mark: mark)
                }
                AtomText(props: TextProps(text: rule.name, size: 13, weight: "medium", lineLimit: 1, truncation: "middle"), common: AtomCommon(testID: "rule-name-\(key)"))
                if rule.issue != nil {
                    CatalogRows.flag("Problem", testID: "rule-problem-\(key)")
                }
            } controls: {
                if rule.issue != nil, rule.editable {
                    CatalogRows.fixButton(name: rule.name, testID: "rule-fix-\(key)", disabled: isFixing) { fix(rule) }
                }
                if rule.scope != .managed {
                    CatalogRows.enabledToggle(
                        isOn: isEnabled(rule), name: rule.name, noun: "rule", testID: "rule-toggle-\(key)",
                        onToggle: { setEnabled(rule, !isEnabled(rule)) }
                    )
                }
                actions(rule, key: key)
            }
        } content: {
            hint(rule, key: key)
        }
    }

    /// A rule's details: its summary, what it applies to, any problem, and where it lives.
    private func hint(_ rule: RuleRecord, key: String) -> some PHView {
        AtomStack(props: StackProps(axis: "v", spacing: 6, align: "leading", group: true), common: AtomCommon(testID: "rule-hint-\(key)")) {
            AtomText(props: TextProps(text: rule.name, size: 13, weight: "semibold"))
            if !rule.summary.isEmpty {
                AtomText(props: TextProps(text: rule.summary, size: 12, color: "secondary", wrap: true), common: AtomCommon(testID: "rule-summary-\(key)"))
            }
            AtomStack(props: StackProps(axis: "h", spacing: 4)) {
                if !rule.paths.isEmpty {
                    CatalogRows.badge(rule.paths.joined(separator: ", "), icon: .scope, color: "purple", testID: "rule-paths-\(key)")
                }
                // Linked when Playhouse's symlinks make it work outside Playhouse;
                // a file both CLIs already read needs no link.
                if rule.availableOutsidePlayhouse, rule.locations.contains(where: \.isSymlink) {
                    CatalogRows.badge("Linked", icon: .link, color: "blue", testID: "rule-linked-\(key)")
                } else if rule.availableOutsidePlayhouse {
                    CatalogRows.badge("Both CLIs", icon: .checkmarkSeal, color: "blue", testID: "rule-native-\(key)")
                }
            }
            if let issue = rule.issue {
                CatalogRows.detail(issue, color: "orange", testID: "rule-issue-\(key)")
            }
            if !isEnabled(rule), !rule.alwaysOnFor.isEmpty {
                CatalogRows.detail(
                    "\(ConversationProvider.names(rule.alwaysOnFor)) still \(rule.alwaysOnFor.count == 1 ? "reads" : "read") this file itself, so turning it off applies to the other agents only.",
                    color: "orange", testID: "rule-always-on-\(key)"
                )
            } else if let note = Self.sharedNote(rule) {
                CatalogRows.detail(note, wrap: false, testID: "rule-shared-\(key)")
            }
            AtomText(
                props: TextProps(
                    text: rule.locations.map(\.layout.displayName).joined(separator: " · ") + " · " + ByteCountFormatter.string(fromByteCount: Int64(rule.byteCount), countStyle: .file),
                    size: 10, color: "tertiary", wrap: true
                ),
                common: AtomCommon(testID: "rule-location-\(key)")
            )
        }
    }

    private func actions(_ rule: RuleRecord, key: String) -> some PHView {
        var items = [[
            MenuProps.Item(id: "edit", title: rule.editable ? "Edit…" : "View…", help: rule.editable ? "Edit the rule file" : "Read the rule file", testID: "rule-edit-\(key)"),
            MenuProps.Item(id: "reveal", title: "Reveal in Finder", help: "Show the rule file in Finder", testID: "rule-reveal-\(key)"),
        ]]
        if rule.editable {
            if rule.locations.contains(where: \.isSymlink) {
                items.append([MenuProps.Item(
                    id: "unlink", title: "Remove Outside Link", help: "Remove the symlink; Playhouse sessions still share the rule", testID: "rule-unlink-\(key)"
                )])
            } else if rule.linkable {
                items.append([MenuProps.Item(
                    id: "link", title: "Make Available Outside Playhouse…",
                    help: "Write a symlink so the claude and codex CLIs read the rule on their own", testID: "rule-link-\(key)"
                )])
            }
            items.append([MenuProps.Item(id: "delete", title: "Delete…", destructive: true, help: "Delete the rule file from disk", testID: "rule-delete-\(key)")])
        }
        return CatalogRows.actionsMenu(name: rule.name, testID: "rule-actions-\(key)", items: items) { choice in
            switch choice {
            case "edit": openEditor(rule)
            case "reveal": Platform.services.revealInFileBrowser([URL(fileURLWithPath: rule.filePath)])
            case "unlink": perform { _ = try await manager.linkRule(taskID: task.id, ruleID: rule.id, linked: false) }
            case "link": pendingLink = rule
            case "delete": pendingDelete = rule
            default: break
            }
        }
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
            AtomStack(props: StackProps(axis: "h", spacing: 10, align: "center")) {
                AtomIcon(props: IconProps(name: PHIcon.listBulletRectangle.name, color: "accent", textStyle: "title2"))
                AtomStack(props: StackProps(axis: "v", spacing: 2, align: "leading")) {
                    AtomText(props: TextProps(text: rule.name, weight: "semibold", textStyle: "title2"))
                        .accessibilityIdentifier("rule-editor-name")
                    AtomText(props: TextProps(text: rule.filePath, color: "secondary", lineLimit: 1, truncation: "middle", selectable: true, textStyle: "caption"))
                        .accessibilityIdentifier("rule-editor-location")
                }
                AtomSpacer()
                SkillDocumentTabPicker(tab: $tab, identifier: "rule-editor-tab-picker")
            }
        } content: {
            switch tab {
            case .edit: PHNativeTextEditor(text: $content, identifier: "rule-editor", isEditable: rule.editable)
            case .preview: SkillMarkdownPreview(markdown: content, identifier: "rule-editor-preview")
            }
        } footer: {
            AtomStack(props: StackProps(axis: "h")) {
                if let errorMessage {
                    AtomText(props: TextProps(text: errorMessage, color: "red", textStyle: "callout")).accessibilityIdentifier("rule-editor-error")
                } else if !rule.editable {
                    AtomText(props: TextProps(text: "Your organization manages this file, so it is read-only.", color: "secondary", textStyle: "callout"))
                }
                AtomSpacer()
                AtomButton(props: ButtonProps(style: "automatic"), action: onClose) { AtomText(props: TextProps(text: rule.editable ? "Cancel" : "Close")) }
                    .shortcutHelp(rule.editable ? "Discard changes" : "Close the rule", shortcut: "cancel")
                    .accessibilityIdentifier("rule-editor-cancel")
                if rule.editable {
                    AtomButton(props: ButtonProps(style: "prominent", disabled: isSaving), action: { save() }) { AtomText(props: TextProps(text: "Save")) }
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
            AtomStack(props: StackProps(axis: "v", spacing: 12, align: "leading")) {
                AtomText(props: TextProps(text: "New Rule", textStyle: "headline"))
                // The controls get their own rows so the panel fits the narrow modal.
                AtomStack(props: StackProps(axis: "v", spacing: 8, align: "leading")) {
                    AtomSegmented(
                        showsLabel: true, selection: $form, options: Form.allCases, label: { $0.rawValue },
                        common: AtomCommon(testID: "new-rule-form", label: "Kind")
                    )
                    AtomSegmented(
                        style: "menu", showsLabel: true, selection: $destination,
                        options: ["global"] + roots.map(\.rootPath),
                        label: { path in roots.first(where: { $0.rootPath == path })?.name ?? "Global" },
                        common: AtomCommon(testID: "new-rule-scope", label: "Save to")
                    )
                }
                AtomText(props: TextProps(text: "Saved as " + target, color: "secondary", textStyle: "callout"))
                    .accessibilityIdentifier("new-rule-target")
                if form == .topic {
                    AtomTextField(
                        props: TextFieldProps(text: name, placeholder: "rule-name"),
                        common: AtomCommon(testID: "new-rule-name", label: "Name"), onChange: { name = $0 }
                    )
                    AtomTextField(
                        props: TextFieldProps(text: paths, placeholder: "Only for matching files, such as src/**/*.ts (optional, comma separated)"),
                        common: AtomCommon(testID: "new-rule-paths", label: "Paths"), onChange: { paths = $0 }
                    )
                }
            }
        } content: {
            AtomStack(props: StackProps(axis: "v", spacing: 6, align: "leading")) {
                AtomStack(props: StackProps(axis: "h")) {
                    AtomText(props: TextProps(text: "Instructions", weight: "semibold", textStyle: "subheadline"))
                    AtomSpacer()
                    SkillDocumentTabPicker(tab: $tab, identifier: "new-rule-tab-picker")
                }
                switch tab {
                case .edit: PHNativeTextEditor(text: $instructions, identifier: "new-rule-body", isEditable: true)
                case .preview: SkillMarkdownPreview(markdown: instructions, identifier: "new-rule-preview")
                }
            }
        } footer: {
            AtomStack(props: StackProps(axis: "h")) {
                if let errorMessage {
                    AtomText(props: TextProps(text: errorMessage, color: "red", textStyle: "callout")).accessibilityIdentifier("new-rule-error")
                }
                AtomSpacer()
                AtomButton(props: ButtonProps(style: "automatic"), action: onClose) { AtomText(props: TextProps(text: "Cancel")) }
                    .shortcutHelp("Close without creating a rule", shortcut: "cancel")
                    .accessibilityIdentifier("new-rule-cancel")
                AtomButton(props: ButtonProps(style: "prominent", disabled: isSaving), action: { create() }) { AtomText(props: TextProps(text: "Create")) }
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
