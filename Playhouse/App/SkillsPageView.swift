import AppKit
import SwiftUI

/// What a Skills page opened from the composer's `/` menu shows first: a skill's
/// editor, an MCP server's editor, or an MCP server's sign-in with one agent.
enum SkillsPageFocus: Equatable {
    case skill(id: String)
    case mcpServer(id: String)
    case mcpSignIn(name: String, provider: ConversationProvider)
}

/// The task's skill gallery, agent rules and MCP servers: its repositories'
/// skills, instruction files and servers, the user's global ones, and the ones
/// that came with each provider. Every skill, rule or server a user adds works with both Claude and Codex,
/// so the page shows where it lives and who can use it rather than which
/// provider owns it. The header, the tabs and the skill gallery are composed of
/// plugin atoms (`SkillsPageHeader`, `SkillsPageTabs` and `SkillGalleryView`); this view owns their
/// state, the confirmations and the editor panels, and the Rules and MCP lists.
struct SkillsPageView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case skills
        case rules
        case mcp
        var id: String { rawValue }
    }

    let task: any ConversationSubject
    let manager: RemoteConversationManager
    let onUse: (SkillRecord) -> Void
    /// Opens the task an agent repairs skills in, with the prompt it should send.
    let onFixTask: (UUID, String) -> Void
    let onClose: () -> Void

    @State private var kind: Kind
    /// What the page opens first; dropped once opened or once the user picks another tab,
    /// so returning to a tab doesn't open it again.
    @State private var focus: SkillsPageFocus?
    /// A rule's editor or New Rule panel is open over the Rules list.
    @State private var isPresentingRulePanel = false
    /// A server's editor is open over the MCP list.
    @State private var isPresentingMcpPanel = false
    /// The group the list last scrolled to, and how many times it has, so
    /// choosing the same anchor again scrolls back to it.
    @State private var scrollTarget: String?
    @State private var scrollRequest = 0
    @State private var catalog: SkillCatalog?
    @State private var search = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    /// The editor or New Skill panel over the gallery; one state, so they can never both be open.
    @State private var panel: Panel?
    @State private var pendingDelete: [SkillRecord] = []
    @State private var pendingLink: SkillRecord?
    /// A toggle shows its new state at once; the daemon's answer settles it.
    @State private var enabledOverrides: [String: Bool] = [:]
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var isFixing = false

    enum Panel {
        case editing(EditingSkill)
        case creating
    }

    struct EditingSkill: Identifiable {
        let skill: SkillRecord
        /// SKILL.md exactly as it is on disk.
        let content: String
        var id: String { skill.id }
    }

    private static let panelAnimation = Animation.spring(response: 0.34, dampingFraction: 0.9)

    init(
        task: any ConversationSubject, manager: RemoteConversationManager, focus: SkillsPageFocus? = nil,
        onUse: @escaping (SkillRecord) -> Void, onFixTask: @escaping (UUID, String) -> Void, onClose: @escaping () -> Void
    ) {
        self.task = task
        self.manager = manager
        _focus = State(initialValue: focus)
        self.onUse = onUse
        self.onFixTask = onFixTask
        self.onClose = onClose
        switch focus {
        case .mcpServer, .mcpSignIn: _kind = State(initialValue: .mcp)
        case .skill, nil: _kind = State(initialValue: .skills)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkillsPageHeader(model: model, actions: actions)
            Divider()
            SkillsPageTabs(model: model, actions: actions)
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
            selection: isSelecting ? selection : nil, enabledOverrides: enabledOverrides,
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
            newSkill: { withAnimation(Self.panelAnimation) { panel = .creating } },
            fixSelected: { fix(selectedSkills.filter(SkillsPageModel.isFixable)) },
            deleteSelected: { pendingDelete = selectedSkills },
            endSelection: endSelection,
            press: { withSkill($0, click) },
            longPress: { withSkill($0, beginSelection) },
            fix: { withSkill($0) { fix([$0]) } },
            toggle: { withSkill($0) { setEnabled($0, !isEnabled($0)) } },
            use: { withSkill($0, onUse) },
            menu: { id, item in withSkill(id) { menu($0, item) } }
        )
    }

    /// Runs a row action on the skill it names, if the catalog still has it.
    private func withSkill(_ id: String, _ action: (SkillRecord) -> Void) {
        if let skill = catalog?.skill(id: id) { action(skill) }
    }

    private var skillsBody: some View {
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
                isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
                presenting: pendingDelete
            ) { skills in
                Button("Delete", role: .destructive) {
                    perform {
                        try await manager.deleteSkills(taskID: task.id, skillIDs: skills.map(\.id))
                        selection.subtract(skills.map(\.id))
                        if selection.isEmpty { isSelecting = false }
                    }
                }
                .buttonHoverPointer()
                .nativeHelp("Delete the skill folders from disk")
                .accessibilityIdentifier("confirm-delete-skill")
                Button("Cancel", role: .cancel) {}
                    .buttonHoverPointer()
                    .nativeHelp("Keep the skills")
            } message: { skills in
                Text(skills.count == 1
                     ? "This removes \(skills[0].folderPath ?? skills[0].name) from disk for both Claude and Codex."
                     : "This removes \(skills.map(\.name).joined(separator: ", ")) from disk for both Claude and Codex.")
            }
            .confirmationDialog(
                "Make \(pendingLink?.name ?? "skill") available outside Playhouse?",
                isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
                presenting: pendingLink
            ) { skill in
                Button("Create Link") { perform { _ = try await manager.linkSkill(taskID: task.id, skillID: skill.id, linked: true) } }
                    .buttonHoverPointer()
                    .nativeHelp("Write a symlink so both CLIs find the skill on their own")
                    .accessibilityIdentifier("confirm-link-skill")
                Button("Cancel", role: .cancel) {}
                    .buttonHoverPointer()
                    .nativeHelp("Keep sharing the skill only in Playhouse sessions")
            } message: { skill in
                Text(skill.scope == .repo
                     ? "Playhouse writes a symlink inside the repository, so the claude and codex CLIs find the skill outside Playhouse too. Commit it to share it with teammates."
                     : "Playhouse writes a symlink in your home folder, so the claude and codex CLIs find the skill outside Playhouse too.")
            }
    }

    private var isPresentingPanel: Bool { panel != nil }

    /// The editor and New Skill panels slide up over the gallery as modals.
    private var panels: some View {
        ZStack {
            if isPresentingPanel {
                // Blocks clicks on the gallery under the panel's margins.
                Color.black.opacity(0.18)
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
                EmptyView()
            }
        }
    }

    /// Scrolls the list to a group: repo, global or builtin.
    private func jump(_ group: String) {
        scrollTarget = group
        scrollRequest += 1
    }

    private func closePanel() {
        withAnimation(Self.panelAnimation) { panel = nil }
    }

    private var selectedSkills: [SkillRecord] {
        (catalog?.allSkills ?? []).filter { selection.contains($0.id) }
    }

    private func endSelection() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isSelecting = false
            selection.removeAll()
        }
    }

    private func isEnabled(_ skill: SkillRecord) -> Bool { enabledOverrides[skill.id] ?? skill.enabled }

    private func beginSelection(with skill: SkillRecord) {
        guard skill.editable else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
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
            withAnimation(Self.panelAnimation) { panel = .editing(EditingSkill(skill: skill, content: content)) }
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
        case "edit": openEditor(skill)
        case "reveal":
            if let folder = skill.folderPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
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
struct SkillPanel<Header: View, Content: View, Footer: View>: View {
    let identifier: String
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkspaceTheme.panelBackground)
            Divider()
            content
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceTheme.windowBackground)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
        .shadow(color: .black.opacity(0.25), radius: 18, y: -2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// The two views of a skill's Markdown in its panel: the text to edit, and how it reads.
enum SkillDocumentTab: String, CaseIterable, Identifiable {
    case edit = "Edit"
    case preview = "Preview"
    var id: String { rawValue }
}

struct SkillDocumentTabPicker: View {
    @Binding var tab: SkillDocumentTab
    let identifier: String

    var body: some View {
        Picker("View", selection: $tab) {
            ForEach(SkillDocumentTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .nativeHelp("Edit the Markdown, or preview how it reads")
        .accessibilityIdentifier(identifier)
    }
}

/// Opens SKILL.md itself, frontmatter and all, for editing, with a tab that
/// previews it as rendered Markdown.
private struct SkillEditorPanel: View {
    let skill: SkillRecord
    let onClose: () -> Void
    let onSave: (String) async throws -> Void
    @State private var content: String
    @State private var tab = SkillDocumentTab.edit
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(editing: SkillsPageView.EditingSkill, onClose: @escaping () -> Void, onSave: @escaping (String) async throws -> Void) {
        skill = editing.skill
        self.onClose = onClose
        self.onSave = onSave
        _content = State(initialValue: editing.content)
    }

    private var readOnly: Bool { !skill.editable }

    var body: some View {
        SkillPanel(identifier: "skill-editor-panel") {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name)
                        .font(.title2.weight(.semibold))
                        .accessibilityIdentifier("skill-editor-name")
                    if let folder = skill.folderPath {
                        Text(folder + "/SKILL.md")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("skill-editor-location")
                    }
                }
                Spacer()
                SkillDocumentTabPicker(tab: $tab, identifier: "skill-editor-tab-picker")
            }
        } content: {
            switch tab {
            case .edit:
                SkillTextEditor(text: $content, identifier: "skill-editor", isEditable: !readOnly)
            case .preview:
                SkillMarkdownPreview(markdown: content, identifier: "skill-editor-preview")
            }
        } footer: {
            HStack {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout).accessibilityIdentifier("skill-editor-error")
                } else if readOnly {
                    Text("\(skill.name) comes with its provider and is read-only.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(readOnly ? "Close" : "Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .buttonHoverPointer()
                    .nativeHelp(readOnly ? "Close the skill" : "Discard changes")
                    .accessibilityIdentifier("skill-editor-cancel")
                if !readOnly {
                    Button("Save") { save() }
                        .keyboardShortcut("s", modifiers: .command)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)
                        .buttonHoverPointer()
                        .nativeHelp("Save SKILL.md (⌘S)")
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

private struct NewSkillPanel: View {
    let roots: [SkillRepositorySection]
    let onClose: () -> Void
    let onCreate: (SkillManifest, SkillScope, String?) async throws -> Void
    @State private var manifest = SkillManifest(name: "", description: "", body: "")
    /// "global", or the root path of one of the task's repositories.
    @State private var destination = "global"
    /// A repository skill kept in Playhouse's store rather than in the repository.
    @State private var isPrivate = false
    @State private var tab = SkillDocumentTab.edit
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        SkillPanel(identifier: "new-skill-panel") {
            VStack(alignment: .leading, spacing: 12) {
                Text("New Skill").font(.headline)
                // The controls get their own row so the panel fits the narrow modal.
                HStack {
                    Picker("Save to", selection: $destination) {
                        Text("Global (~/.agents/skills)").tag("global")
                        ForEach(roots, id: \.rootPath) { root in Text(root.name).tag(root.rootPath) }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("new-skill-scope")
                    if destination != "global" {
                        Toggle("Private", isOn: $isPrivate)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .nativeHelp("Keep the skill out of the repository: Playhouse stores it and shares it only with this repository's sessions")
                            .accessibilityIdentifier("new-skill-private")
                    }
                }
                Text(destination != "global" && isPrivate
                     ? "Private: Playhouse stores the skill itself and writes nothing into the repository or its worktrees. Claude and Codex sessions on this repository use it like any other skill. The name uses lowercase letters, digits, and hyphens."
                     : "Saved in the open Agent Skills layout (.agents/skills). Playhouse shares it with both Claude and Codex. The name uses lowercase letters, digits, and hyphens.")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("new-skill-destination-note")
                TextField("skill-name", text: $manifest.name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Name")
                    .accessibilityIdentifier("new-skill-name")
                TextField("When should the agent use this skill?", text: $manifest.description, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Description")
                    .accessibilityIdentifier("new-skill-description")
            }
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Instructions").font(.subheadline.weight(.semibold))
                    Spacer()
                    SkillDocumentTabPicker(tab: $tab, identifier: "new-skill-tab-picker")
                }
                switch tab {
                case .edit:
                    SkillTextEditor(text: $manifest.body, identifier: "new-skill-body", isEditable: true)
                case .preview:
                    SkillMarkdownPreview(markdown: manifest.body, identifier: "new-skill-preview")
                }
            }
        } footer: {
            HStack {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout).accessibilityIdentifier("new-skill-error")
                }
                Spacer()
                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .buttonHoverPointer()
                    .nativeHelp("Close without creating a skill")
                    .accessibilityIdentifier("new-skill-cancel")
                Button("Create") { create() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
                    .buttonHoverPointer()
                    .nativeHelp("Create the skill (⌘S)")
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

/// A skill's Markdown as it reads: any frontmatter as a small table of its
/// entries, then headings, lists, quotes, code, and paragraphs.
struct SkillMarkdownPreview: View {
    let markdown: String
    let identifier: String

    private enum Block {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(String)
        case numbered(String, String)
        case quote(String)
        case code(String)
        case rule
    }

    var body: some View {
        let (frontmatter, blocks) = Self.parse(markdown)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !frontmatter.isEmpty {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(Array(frontmatter.enumerated()), id: \.offset) { _, entry in
                            GridRow {
                                Text(entry.key).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(entry.value).font(.callout).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("\(identifier)-frontmatter")
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(for: block) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverRevealScrollers()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Self.inline(text)
                .font(level == 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, 4)
        case .paragraph(let text):
            Self.inline(text)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) { Text("•"); Self.inline(text) }
                .padding(.leading, 8)
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) { Text(number).monospacedDigit(); Self.inline(text) }
                .padding(.leading, 8)
        case .quote(let text):
            Self.inline(text)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3) }
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        case .rule:
            Divider()
        }
    }

    private static func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    private static func parse(_ markdown: String) -> (frontmatter: [(key: String, value: String)], blocks: [Block]) {
        var frontmatter: [(key: String, value: String)] = []
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if let split = SkillFrontmatter.split(markdown) {
            frontmatter = SkillFrontmatter.entries(split.header).map { ($0.key, $0.value) }
            lines = Array(split.lines[split.bodyStart...])
        }
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let finished = code {
                    blocks.append(.code(finished.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            if line.isEmpty {
                flush()
            } else if let hashes = line.firstIndex(where: { $0 != "#" }), hashes != line.startIndex,
                      line.distance(from: line.startIndex, to: hashes) <= 6, line[hashes] == " " {
                flush()
                blocks.append(.heading(level: line.distance(from: line.startIndex, to: hashes),
                                       text: line[hashes...].trimmingCharacters(in: .whitespaces)))
            } else if ["---", "***", "___"].contains(line) {
                flush()
                blocks.append(.rule)
            } else if let marker = ["- ", "* ", "+ "].first(where: line.hasPrefix) {
                flush()
                blocks.append(.bullet(String(line.dropFirst(marker.count))))
            } else if let dot = line.firstIndex(of: "."), dot != line.startIndex,
                      line[..<dot].allSatisfy(\.isNumber), line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.numbered(String(line[...dot]), line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix(">") {
                flush()
                blocks.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        if let unfinished = code { blocks.append(.code(unfinished.joined(separator: "\n"))) }
        return (frontmatter, blocks)
    }
}

/// A plain-text editor for a skill's instructions. SwiftUI's `TextEditor`
/// applies the system's smart dashes and quotes, which would turn Markdown's
/// `---` into an em dash.
struct SkillTextEditor: NSViewRepresentable {
    @Binding var text: String
    let identifier: String
    var isEditable = true

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .bezelBorder
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isEditable = isEditable
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier(identifier)
        HoverRevealScrollers.install(on: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        guard textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
