import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// What a Skills page opened from the composer's `/` menu shows first: a skill's
/// editor, an MCP server's editor, or an MCP server's sign-in with one agent.
package enum SkillsPageFocus: Equatable {
    case skill(id: String)
    case mcpServer(id: String)
    case mcpSignIn(name: String, provider: ConversationProvider)
}

/// The task's skill gallery, agent rules and MCP servers: its repositories'
/// skills, instruction files and servers, the user's global ones, and the ones
/// that came with each provider. Every skill, rule or server a user adds works with both Claude and Codex,
/// so the page shows where it lives and who can use it rather than which
/// provider owns it. The header (with the tabs) and the skill gallery are composed of
/// plugin atoms (`SkillsPageHeader` and `SkillGalleryView`); this view owns their
/// state, the confirmations and the editor panels, and the Rules and MCP lists.
package struct SkillsPageView: PHView {
    package enum Kind: String, CaseIterable, Identifiable {
        case skills
        case rules
        case mcp
        package var id: String { rawValue }
    }

    package let task: any ConversationSubject
    package let manager: RemoteConversationManager
    package let onUse: (SkillRecord) -> Void
    /// Opens the task an agent repairs skills in, with the prompt it should send.
    package let onFixTask: (UUID, String) -> Void
    package let onClose: () -> Void

    @PHState private var kind: Kind
    /// What the page opens first; dropped once opened or once the user picks another tab,
    /// so returning to a tab doesn't open it again.
    @PHState private var focus: SkillsPageFocus?
    /// A rule's editor or New Rule panel is open over the Rules list.
    @PHState private var isPresentingRulePanel = false
    /// A server's editor is open over the MCP list.
    @PHState private var isPresentingMcpPanel = false
    /// The group the list last scrolled to, and how many times it has, so
    /// choosing the same anchor again scrolls back to it.
    @PHState private var scrollTarget: String?
    @PHState private var scrollRequest = 0
    @PHState private var catalog: SkillCatalog?
    @PHState private var search = ""
    @PHState private var errorMessage: String?
    @PHState private var isLoading = false
    /// The editor or New Skill panel over the gallery; one state, so they can never both be open.
    @PHState private var panel: Panel?
    @PHState private var pendingDelete: [SkillRecord] = []
    @PHState private var pendingLink: SkillRecord?
    /// Enable or Disable shows its new state at once; the daemon's answer settles it.
    @PHState private var enabledOverrides: [String: Bool] = [:]
    /// Groups showing only their header. Built-in starts so: users rarely need it.
    @PHState private var collapsedGroups: Set<String> = ["builtin"]
    @PHState private var isSelecting = false
    @PHState private var selection = Set<String>()
    @PHState private var isFixing = false

    package enum Panel {
        case editing(EditingSkill)
        case creating
    }

    package struct EditingSkill: Identifiable {
        package let skill: SkillRecord
        /// SKILL.md exactly as it is on disk.
        package let content: String
        package var id: String { skill.id }

        package init(skill: SkillRecord, content: String) {
            self.skill = skill
            self.content = content
        }
    }

    private static let panelAnimation = PHAnimation.spring(response: 0.34, dampingFraction: 0.9)

    package init(
        task: any ConversationSubject, manager: RemoteConversationManager, focus: SkillsPageFocus? = nil,
        onUse: @escaping (SkillRecord) -> Void, onFixTask: @escaping (UUID, String) -> Void, onClose: @escaping () -> Void
    ) {
        self.task = task
        self.manager = manager
        _focus = PHState(initialValue: focus)
        self.onUse = onUse
        self.onFixTask = onFixTask
        self.onClose = onClose
        switch focus {
        case .mcpServer, .mcpSignIn: _kind = PHState(initialValue: .mcp)
        case .skill, nil: _kind = PHState(initialValue: .skills)
        }
    }

    package var body: some PHView {
        PHVStack(alignment: .leading, spacing: 0) {
            SkillsPageHeader(model: model, actions: actions)
            PHDivider()
            switch kind {
            case .skills: skillsBody
            case .rules: RulesSectionView(task: task, manager: manager, isPresentingPanel: $isPresentingRulePanel, onFixTask: onFixTask)
            case .mcp:
                McpServersSectionView(task: task, manager: manager, isPresentingPanel: $isPresentingMcpPanel, onFixTask: onFixTask, focus: focus)
            }
        }
        .background(WorkspaceTheme.windowBackground)
        // A closed panel's removal transition can leave the overlay catching clicks, so it
        // takes hits only while a panel is open (see McpServersSectionView).
        .overlay { if kind == .skills { panels.allowsHitTesting(isPresentingPanel) } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills-page")
    }

    private var model: SkillsPageModel {
        SkillsPageModel(
            catalog: catalog, kind: kind.rawValue, scrollTo: scrollTarget, scrollRequest: scrollRequest, search: search,
            selection: isSelecting ? selection : nil, enabledOverrides: enabledOverrides, collapsedGroups: collapsedGroups,
            isLoadingBuiltins: isLoading, isFixing: isFixing, error: errorMessage,
            panelOpen: isPresentingPanel || isPresentingRulePanel || isPresentingMcpPanel
        )
    }

    private var actions: SkillsPageActions {
        SkillsPageActions(
            back: onClose,
            selectKind: { if let kind = Kind(rawValue: $0) { self.kind = kind; focus = nil } },
            jump: jump,
            search: { search = $0 },
            newSkill: { phWithAnimation(Self.panelAnimation) { panel = .creating } },
            fixSelected: { fix(selectedSkills.filter(SkillsPageModel.isFixable)) },
            deleteSelected: { pendingDelete = selectedSkills },
            endSelection: endSelection,
            press: { withSkill($0, click) },
            longPress: { withSkill($0, beginSelection) },
            fix: { withSkill($0) { fix([$0]) } },
            toggleGroup: { group in
                phWithAnimation(.easeInOut(duration: 0.18)) {
                    if collapsedGroups.remove(group) == nil { collapsedGroups.insert(group) }
                }
            },
            menu: { id, item in withSkill(id) { menu($0, item) } }
        )
    }

    /// Runs a row action on the skill it names, if the catalog still has it.
    private func withSkill(_ id: String, _ action: (SkillRecord) -> Void) {
        if let skill = catalog?.skill(id: id) { action(skill) }
    }

    private var skillsBody: some PHView {
        SkillGalleryView(model: model, actions: actions)
            .task {
                await reload()
                if case .skill(let id) = focus {
                    focus = nil
                    if let skill = catalog?.skill(id: id), skill.folderPath != nil { openEditor(skill) }
                }
            }
            .alert(
                pendingDelete.count == 1 ? "Delete \(pendingDelete[0].name)?" : "Delete \(pendingDelete.count) skills?",
                isPresented: PHBinding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
                presenting: pendingDelete
            ) { skills in
                PHButton("Delete", role: .destructive) {
                    perform {
                        try await manager.deleteSkills(taskID: task.id, skillIDs: skills.map(\.id))
                        selection.subtract(skills.map(\.id))
                        if selection.isEmpty { isSelecting = false }
                    }
                }
                .buttonHoverPointer()
                .nativeHelp("Delete the skill folders from disk")
                .accessibilityIdentifier("confirm-delete-skill")
                PHButton("Cancel", role: .cancel) {}
                    .buttonHoverPointer()
                    .nativeHelp("Keep the skills")
            } message: { skills in
                PHText(skills.count == 1
                     ? "This removes \(skills[0].folderPath ?? skills[0].name) from disk for both Claude and Codex."
                     : "This removes \(skills.map(\.name).joined(separator: ", ")) from disk for both Claude and Codex.")
            }
            .confirmationDialog(
                "Make \(pendingLink?.name ?? "skill") available outside Playhouse?",
                isPresented: PHBinding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
                presenting: pendingLink
            ) { skill in
                PHButton("Create Link") { perform { _ = try await manager.linkSkill(taskID: task.id, skillID: skill.id, linked: true) } }
                    .buttonHoverPointer()
                    .nativeHelp("Write a symlink so both CLIs find the skill on their own")
                    .accessibilityIdentifier("confirm-link-skill")
                PHButton("Cancel", role: .cancel) {}
                    .buttonHoverPointer()
                    .nativeHelp("Keep sharing the skill only in Playhouse sessions")
            } message: { skill in
                PHText(skill.scope == .repo
                     ? "Playhouse writes a symlink inside the repository, so the claude and codex CLIs find the skill outside Playhouse too. Commit it to share it with teammates."
                     : "Playhouse writes a symlink in your home folder, so the claude and codex CLIs find the skill outside Playhouse too.")
            }
    }

    private var isPresentingPanel: Bool { panel != nil }

    /// The editor and New Skill panels slide up over the gallery as modals.
    private var panels: some PHView {
        PHZStack {
            if isPresentingPanel {
                // Blocks clicks on the gallery under the panel's margins.
                PHColor.black.opacity(0.18)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(0)
            }
            switch panel {
            case .editing(let editing):
                SkillEditorPanel(editing: editing, onClose: closePanel) { content in
                    let record = try await manager.updateSkillContent(taskID: task.id, skillID: editing.skill.id, content: content)
                    catalog = catalog?.replacing(record)
                    await reload()
                }
                .id(editing.id)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .transition(.move(edge: .bottom))
                .zIndex(1)
            case .creating:
                NewSkillPanel(roots: catalog?.repositories ?? [], onClose: closePanel) { manifest, scope, root in
                    let record = try await manager.createSkill(
                        taskID: task.id, name: manifest.name, description: manifest.description, body: manifest.body,
                        fields: [:], scope: scope, root: root
                    )
                    jump(record.scope == .global ? "global" : "repo")
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

    /// Scrolls the list to a group: repo, global or builtin, expanding it.
    private func jump(_ group: String) {
        collapsedGroups.remove(group)
        scrollTarget = group
        scrollRequest += 1
    }

    private func closePanel() {
        phWithAnimation(Self.panelAnimation) { panel = nil }
    }

    private var selectedSkills: [SkillRecord] {
        (catalog?.allSkills ?? []).filter { selection.contains($0.id) }
    }

    private func endSelection() {
        phWithAnimation(.easeInOut(duration: 0.15)) {
            isSelecting = false
            selection.removeAll()
        }
    }

    private func isEnabled(_ skill: SkillRecord) -> Bool { enabledOverrides[skill.id] ?? skill.enabled }

    private func beginSelection(with skill: SkillRecord) {
        guard skill.editable else { return }
        phWithAnimation(.easeInOut(duration: 0.15)) {
            isSelecting = true
            selection.insert(skill.id)
        }
    }

    private func click(_ skill: SkillRecord) {
        if isSelecting {
            guard skill.editable else { return }
            if selection.remove(skill.id) == nil { selection.insert(skill.id) }
        } else if skill.folderPath != nil {
            openEditor(skill)
        }
    }

    private func openEditor(_ skill: SkillRecord) {
        perform(reloading: false) {
            guard let content = try await manager.skillContent(taskID: task.id, skillID: skill.id) else { return }
            phWithAnimation(Self.panelAnimation) { panel = .editing(EditingSkill(skill: skill, content: content)) }
        }
    }

    private func setEnabled(_ skill: SkillRecord, _ enabled: Bool) {
        enabledOverrides[skill.id] = enabled
        Task { @MainActor in
            do {
                let record = try await manager.setSkillEnabled(taskID: task.id, skillID: skill.id, enabled: enabled)
                catalog = catalog?.replacing(record)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            if enabledOverrides[skill.id] == enabled { enabledOverrides[skill.id] = nil }
        }
    }

    /// Opens a task whose agent fixes the skills, then shows its conversation.
    private func fix(_ skills: [SkillRecord]) {
        guard !skills.isEmpty, !isFixing else { return }
        isFixing = true
        Task { @MainActor in
            defer { isFixing = false }
            do {
                let created = try await manager.fixSkills(taskID: task.id, skillIDs: skills.map(\.id))
                errorMessage = nil
                onFixTask(created.task.id, created.prompt)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Runs the actions menu's item, by its id (see `SkillsPageModel.MenuItem`).
    private func menu(_ skill: SkillRecord, _ item: String) {
        switch item {
        case "use":
            if isEnabled(skill), !skill.providers.isEmpty { onUse(skill) }
        case "toggle": setEnabled(skill, !isEnabled(skill))
        case "edit": openEditor(skill)
        case "reveal":
            if let folder = skill.folderPath { Platform.services.revealInFileBrowser([URL(fileURLWithPath: folder)]) }
        case "move-global":
            perform { _ = try await manager.moveSkill(taskID: task.id, skillID: skill.id, scope: .global, root: nil) }
        case "unlink":
            perform { _ = try await manager.linkSkill(taskID: task.id, skillID: skill.id, linked: false) }
        case "link": pendingLink = skill
        case "delete": pendingDelete = [skill]
        default:
            if item.hasPrefix("move-private:") {
                let root = String(item.dropFirst("move-private:".count))
                perform { _ = try await manager.moveSkill(taskID: task.id, skillID: skill.id, scope: .privateRepo, root: root) }
                return
            }
            guard item.hasPrefix("move-repo:") else { return }
            let root = String(item.dropFirst("move-repo:".count))
            perform { _ = try await manager.moveSkill(taskID: task.id, skillID: skill.id, scope: .repo, root: root) }
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

    /// File-backed skills load at once. Claude Code's built-ins come from a
    /// short provider session, so they follow when it answers.
    private func reload() async {
        do {
            let quick = try await manager.skills(taskID: task.id, includeBundled: false)
            if catalog == nil { catalog = quick }
            isLoading = true
            defer { isLoading = false }
            catalog = (try? await manager.skills(taskID: task.id, includeBundled: true)) ?? quick
            let known = Set(catalog?.allSkills.map(\.id) ?? [])
            selection.formIntersection(known)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Editor and New Skill panels

/// A card that slides up over the gallery, sized to the window rather than a fixed sheet.
package struct SkillPanel<Header: PHView, Content: PHView, Footer: PHView>: PHView {
    package let identifier: String
    @PHViewBuilder package let header: Header
    @PHViewBuilder package let content: Content
    @PHViewBuilder package let footer: Footer

    package var body: some PHView {
        PHVStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkspaceTheme.panelBackground)
            PHDivider()
            content
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            PHDivider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceTheme.windowBackground)
        .clipShape(PHUnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
        .phShadow(color: .black.opacity(0.25), radius: 18, y: -2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    package init(identifier: String, @PHViewBuilder header: () -> Header, @PHViewBuilder content: () -> Content, @PHViewBuilder footer: () -> Footer) {
        self.identifier = identifier
        self.header = header()
        self.content = content()
        self.footer = footer()
    }
}

/// The two views of a skill's Markdown in its panel: the text to edit, and how it reads.
package enum SkillDocumentTab: String, CaseIterable, Identifiable {
    case edit = "Edit"
    case preview = "Preview"
    package var id: String { rawValue }
}

package struct SkillDocumentTabPicker: PHView {
    @PHBinding package var tab: SkillDocumentTab
    package let identifier: String

    package var body: some PHView {
        PHPicker("View", selection: $tab) {
            PHForEach(SkillDocumentTab.allCases) { tab in PHText(tab.rawValue).tag(tab) }
        }
        .buttonHoverPointer()
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .nativeHelp("Edit the Markdown, or preview how it reads")
        .accessibilityIdentifier(identifier)
    }

    package init(tab: PHBinding<SkillDocumentTab>, identifier: String) {
        _tab = tab
        self.identifier = identifier
    }
}

/// Opens SKILL.md itself, frontmatter and all, for editing, with a tab that
/// previews it as rendered Markdown.
private struct SkillEditorPanel: PHView {
    let skill: SkillRecord
    let onClose: () -> Void
    let onSave: (String) async throws -> Void
    @PHState private var content: String
    @PHState private var tab = SkillDocumentTab.edit
    @PHState private var errorMessage: String?
    @PHState private var isSaving = false

    init(editing: SkillsPageView.EditingSkill, onClose: @escaping () -> Void, onSave: @escaping (String) async throws -> Void) {
        skill = editing.skill
        self.onClose = onClose
        self.onSave = onSave
        _content = PHState(initialValue: editing.content)
    }

    private var readOnly: Bool { !skill.editable }

    var body: some PHView {
        SkillPanel(identifier: "skill-editor-panel") {
            PHHStack(alignment: .center, spacing: 10) {
                PHImage(icon: .sparkles)
                    .font(.title2)
                    .foregroundStyle(.tint)
                PHVStack(alignment: .leading, spacing: 2) {
                    PHText(skill.name)
                        .font(.title2.weight(.semibold))
                        .accessibilityIdentifier("skill-editor-name")
                    if let folder = skill.folderPath {
                        PHText(folder + "/SKILL.md")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("skill-editor-location")
                    }
                }
                PHSpacer()
                SkillDocumentTabPicker(tab: $tab, identifier: "skill-editor-tab-picker")
            }
        } content: {
            switch tab {
            case .edit:
                PHNativeTextEditor(text: $content, identifier: "skill-editor", isEditable: !readOnly)
            case .preview:
                SkillMarkdownPreview(markdown: content, identifier: "skill-editor-preview")
            }
        } footer: {
            PHHStack {
                if let errorMessage {
                    PHText(errorMessage).foregroundStyle(.red).font(.callout).accessibilityIdentifier("skill-editor-error")
                } else if readOnly {
                    PHText("\(skill.name) comes with its provider and is read-only.").font(.callout).foregroundStyle(.secondary)
                }
                PHSpacer()
                PHButton(readOnly ? "Close" : "Cancel", action: onClose)
                    .buttonHoverPointer()
                    .shortcutHelp(readOnly ? "Close the skill" : "Discard changes", shortcut: "cancel")
                    .accessibilityIdentifier("skill-editor-cancel")
                if !readOnly {
                    PHButton("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)
                        .buttonHoverPointer()
                        .shortcutHelp("Save SKILL.md", shortcut: AppShortcut.save)
                        .accessibilityIdentifier("skill-editor-save")
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

private struct NewSkillPanel: PHView {
    let roots: [SkillRepositorySection]
    let onClose: () -> Void
    let onCreate: (SkillManifest, SkillScope, String?) async throws -> Void
    @PHState private var manifest = SkillManifest(name: "", description: "", body: "")
    /// "global", or the root path of one of the task's repositories.
    @PHState private var destination = "global"
    /// A repository skill kept in Playhouse's store rather than in the repository.
    @PHState private var isPrivate = false
    @PHState private var tab = SkillDocumentTab.edit
    @PHState private var errorMessage: String?
    @PHState private var isSaving = false

    var body: some PHView {
        SkillPanel(identifier: "new-skill-panel") {
            PHVStack(alignment: .leading, spacing: 12) {
                PHText("New Skill").font(.headline)
                // Save to and the Private switch each get their own row so the panel fits the narrow modal.
                PHVStack(alignment: .leading, spacing: 8) {
                    PHPicker("Save to", selection: $destination) {
                        PHText("Global (~/.agents/skills)").tag("global")
                        PHForEach(roots, id: \.rootPath) { root in PHText(root.name).tag(root.rootPath) }
                    }
                    .buttonHoverPointer()
                    .fixedSize()
                    .accessibilityIdentifier("new-skill-scope")
                    if destination != "global" {
                        PHToggle("Private", isOn: $isPrivate)
                            .buttonHoverPointer()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .nativeHelp("Keep the skill out of the repository: Playhouse stores it and shares it only with this repository's sessions")
                            .accessibilityIdentifier("new-skill-private")
                    }
                }
                PHText(destination != "global" && isPrivate
                     ? "Private: Playhouse stores the skill itself and writes nothing into the repository or its worktrees. Claude and Codex sessions on this repository use it like any other skill. The name uses lowercase letters, digits, and hyphens."
                     : "Saved in the open Agent Skills layout (.agents/skills). Playhouse shares it with both Claude and Codex. The name uses lowercase letters, digits, and hyphens.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("new-skill-destination-note")
                PHTextField("skill-name", text: $manifest.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name")
                    .accessibilityIdentifier("new-skill-name")
                PHTextField("When should the agent use this skill?", text: $manifest.description, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Description")
                    .accessibilityIdentifier("new-skill-description")
            }
        } content: {
            PHVStack(alignment: .leading, spacing: 6) {
                PHHStack {
                    PHText("Instructions").font(.subheadline.weight(.semibold))
                    PHSpacer()
                    SkillDocumentTabPicker(tab: $tab, identifier: "new-skill-tab-picker")
                }
                switch tab {
                case .edit:
                    PHNativeTextEditor(text: $manifest.body, identifier: "new-skill-body", isEditable: true)
                case .preview:
                    SkillMarkdownPreview(markdown: manifest.body, identifier: "new-skill-preview")
                }
            }
        } footer: {
            PHHStack {
                if let errorMessage {
                    PHText(errorMessage).foregroundStyle(.red).font(.callout).accessibilityIdentifier("new-skill-error")
                }
                PHSpacer()
                PHButton("Cancel", action: onClose)
                    .buttonHoverPointer()
                    .shortcutHelp("Close without creating a skill", shortcut: "cancel")
                    .accessibilityIdentifier("new-skill-cancel")
                PHButton("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                    .buttonHoverPointer()
                    .shortcutHelp("Create the skill", shortcut: AppShortcut.save)
                    .accessibilityIdentifier("new-skill-create")
            }
        }
    }

    private func create() {
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                let scope: SkillScope = destination == "global" ? .global : isPrivate ? .privateRepo : .repo
                var submitted = manifest
                submitted.name = manifest.name.trimmingCharacters(in: .whitespaces)
                try await onCreate(submitted, scope, scope == .global ? nil : destination)
                onClose()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A skill's or rule's Markdown as it reads, in a scrolling panel: a Markdown atom that shows
/// any frontmatter as a small table of its entries, then the formatted instructions.
package struct SkillMarkdownPreview: PHView {
    package let markdown: String
    package let identifier: String

    package var body: some PHView {
        AtomScroll(props: ScrollProps(inset: 16)) {
            AtomMarkdown(
                props: MarkdownProps(text: markdown, selectable: true, frontmatter: "table"),
                common: AtomCommon(testID: identifier, fillWidth: true)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceTheme.panelBackground, in: PHRoundedRectangle(cornerRadius: 6))
    }

    package init(markdown: String, identifier: String) {
        self.markdown = markdown
        self.identifier = identifier
    }
}
