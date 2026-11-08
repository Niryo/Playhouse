import AppKit
import SwiftUI

/// The task's skill gallery, agent rules and MCP servers: its repositories'
/// skills, instruction files and servers, the user's global ones, and the ones
/// that came with each provider. Every skill, rule or server a user adds works with both Claude and Codex,
/// so the page shows where it lives and who can use it rather than which
/// provider owns it.
struct SkillsPageView: View {
    enum Kind: String, CaseIterable, Identifiable {
        case skills = "Skills"
        case rules = "Rules"
        case mcp = "MCP"
        var id: String { rawValue }
    }

    enum Tab: String, CaseIterable, Identifiable {
        case repo = "Repo"
        case global = "Global"
        case builtin = "Built-in"
        var id: String { rawValue }
    }

    let task: any ConversationSubject
    let manager: RemoteConversationManager
    let onUse: (SkillRecord) -> Void
    /// Opens the task an agent repairs skills in, with the prompt it should send.
    let onFixTask: (UUID, String) -> Void
    let onClose: () -> Void

    @State private var kind: Kind = .skills
    /// A rule's editor or New Rule panel is open over the Rules list.
    @State private var isPresentingRulePanel = false
    /// A server's editor is open over the MCP list.
    @State private var isPresentingMcpPanel = false
    @State private var tab: Tab = .repo
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch kind {
            case .skills: skillsBody
            case .rules: RulesSectionView(task: task, manager: manager, isPresentingPanel: $isPresentingRulePanel, onFixTask: onFixTask)
            case .mcp: McpServersSectionView(task: task, manager: manager, isPresentingPanel: $isPresentingMcpPanel, onFixTask: onFixTask)
            }
        }
        .background(WorkspaceTheme.windowBackground)
        .overlay { if kind == .skills { panels } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills-page")
    }

    @ViewBuilder
    private var skillsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("skills-error")
            }
            Text(isSelecting
                 ? "Click skills to select them. Built-in skills can't be selected."
                 : "Click a skill to open it, or press and hold one to select several. Turning a skill on or off reaches Claude on its next turn, and a Codex conversation the next time its thread starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .accessibilityIdentifier("skills-provider-timing")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) { content }
                    .padding(20)
            }
            .accessibilityIdentifier("skills-list")
        }
        .task { await reload() }
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

    private func closePanel() {
        withAnimation(Self.panelAnimation) { panel = nil }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(isPresentingPanel || isPresentingRulePanel || isPresentingMcpPanel || isSelecting ? nil : .cancelAction)
            .buttonHoverPointer()
            .nativeHelp("Back to the conversation")
            .accessibilityLabel("Back to the conversation")
            .accessibilityIdentifier("skills-back-button")

            Text("Skills, Rules & MCP")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("skills-title")

            Picker("Show", selection: $kind) {
                ForEach(Kind.allCases) { kind in Text(kind.rawValue).tag(kind) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(isSelecting || isPresentingPanel || isPresentingRulePanel || isPresentingMcpPanel)
            .nativeHelp("Show skills, the rule files agents follow on every turn, or the MCP servers that give them tools")
            .accessibilityIdentifier("skills-kind-picker")

            if kind == .skills {
                Picker("Skill source", selection: $tab) {
                    ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                .accessibilityIdentifier("skills-tab-picker")
            }

            Spacer()

            if kind != .skills {
                EmptyView()
            } else if isSelecting {
                selectionActions
            } else {
                TextField("Search skills", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .accessibilityIdentifier("skills-search")

                Button { withAnimation(Self.panelAnimation) { panel = .creating } } label: { Label("New Skill", systemImage: "plus") }
                    .buttonHoverPointer()
                    .nativeHelp("Create a skill that both Claude and Codex can use")
                    .accessibilityIdentifier("new-skill-button")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var selectedSkills: [SkillRecord] {
        (catalog?.allSkills ?? []).filter { selection.contains($0.id) }
    }

    private var selectionActions: some View {
        let selected = selectedSkills
        let fixable = selected.filter(Self.isFixable)
        return HStack(spacing: 8) {
            Text(selected.count == 1 ? "1 selected" : "\(selected.count) selected")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityIdentifier("skills-selection-count")
            Button { fix(fixable) } label: { Label("Fix with Agent", systemImage: "wand.and.stars") }
                .disabled(fixable.isEmpty || isFixing)
                .buttonHoverPointer()
                .nativeHelp("Open a task whose agent fixes the selected conflicting or invalid skills")
                .accessibilityIdentifier("skills-fix-selected")
            Button(role: .destructive) { pendingDelete = selected } label: { Label("Delete", systemImage: "trash") }
                .disabled(selected.isEmpty)
                .buttonHoverPointer()
                .nativeHelp("Delete the selected skills from disk")
                .accessibilityIdentifier("skills-delete-selected")
            Button("Done") { endSelection() }
                .keyboardShortcut(isPresentingPanel ? nil : .cancelAction)
                .buttonHoverPointer()
                .nativeHelp("Stop selecting skills")
                .accessibilityIdentifier("skills-selection-done")
        }
    }

    private func endSelection() {
        withAnimation(.easeInOut(duration: 0.15)) {
            isSelecting = false
            selection.removeAll()
        }
    }

    @ViewBuilder
    private var content: some View {
        if catalog == nil {
            ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("skills-loading")
        } else {
            switch tab {
            case .repo:
                Text("Skills in the task's repositories. They live in .agents/skills or .claude/skills, and Playhouse shares each one with both Claude and Codex.")
                    .font(.callout).foregroundStyle(.secondary)
                if catalog?.repositories.isEmpty != false {
                    emptyState("This task has no repositories.", identifier: "skills-empty-repo")
                }
                ForEach(catalog?.repositories ?? [], id: \.rootPath) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.name)
                            .font(.headline)
                            .padding(.top, 6)
                            .accessibilityIdentifier("skills-repo-section-\(section.name)")
                        let skills = filtered(section.skills)
                        if skills.isEmpty {
                            emptyState(section.skills.isEmpty ? "No skills in \(section.name)." : "No matching skills.",
                                       identifier: "skills-empty-\(section.name)")
                        }
                        ForEach(skills) { row($0) }
                    }
                }
            case .global:
                Text("Your skills for every repository, from ~/.agents/skills and Claude's and Codex's own skill folders.")
                    .font(.callout).foregroundStyle(.secondary)
                let skills = filtered(catalog?.global ?? [])
                if skills.isEmpty { emptyState("No global skills.", identifier: "skills-empty-global") }
                ForEach(skills) { row($0) }
            case .builtin:
                Text("Skills and commands that come with each provider. Each one works only with the provider it ships with.")
                    .font(.callout).foregroundStyle(.secondary)
                if isLoading { ProgressView().controlSize(.small).accessibilityIdentifier("skills-builtin-loading") }
                let skills = filtered(catalog?.builtin ?? [])
                if skills.isEmpty, !isLoading { emptyState("No built-in skills found.", identifier: "skills-empty-builtin") }
                ForEach(skills) { row($0) }
            }
        }
    }

    private func emptyState(_ text: String, identifier: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .accessibilityIdentifier(identifier)
    }

    private func filtered(_ skills: [SkillRecord]) -> [SkillRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return skills }
        return skills.filter { $0.name.lowercased().contains(query) || $0.description.lowercased().contains(query) }
    }

    private static func isFixable(_ skill: SkillRecord) -> Bool {
        skill.editable && (skill.conflict || skill.issue != nil)
    }

    private func isEnabled(_ skill: SkillRecord) -> Bool { enabledOverrides[skill.id] ?? skill.enabled }

    private func row(_ skill: SkillRecord) -> some View {
        let isSelected = selection.contains(skill.id)
        let opensOnClick = isSelecting ? skill.editable : skill.folderPath != nil
        return HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                if isSelecting, skill.editable {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .accessibilityLabel(isSelected ? "Selected" : "Not selected")
                        .accessibilityIdentifier("skill-select-\(skill.name)")
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(.body.weight(.semibold))
                            .accessibilityIdentifier("skill-name-\(skill.name)")
                        ForEach(ConversationProvider.allCases) { provider in
                            if skill.providers.contains(provider) {
                                badge(provider.displayName, systemImage: "checkmark", color: .green)
                                    .accessibilityIdentifier("skill-provider-\(skill.name)-\(provider.rawValue)")
                            }
                        }
                        if skill.availableOutsidePlayhouse {
                            badge("Linked", systemImage: "link", color: .blue)
                                .accessibilityIdentifier("skill-linked-\(skill.name)")
                        }
                        if skill.conflict {
                            badge("Conflict", systemImage: "exclamationmark.triangle", color: .orange)
                                .accessibilityIdentifier("skill-conflict-\(skill.name)")
                        } else if skill.issue != nil {
                            badge("Invalid", systemImage: "exclamationmark.triangle", color: .red)
                                .accessibilityIdentifier("skill-invalid-\(skill.name)")
                        }
                    }
                    if !skill.description.isEmpty {
                        Text(skill.description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .accessibilityIdentifier("skill-description-\(skill.name)")
                    }
                    if let issue = skill.issue {
                        Text(issue).font(.caption).foregroundStyle(.orange).accessibilityIdentifier("skill-issue-\(skill.name)")
                    }
                    Text(skill.locations.map(\.layout.displayPath).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("skill-location-\(skill.name)")
                }
                Spacer(minLength: 8)
            }
            // A press and hold starts selecting; a click opens the skill, or selects while
            // selecting. Only the skill's own text takes them: a held click on a control, such
            // as the actions menu while it tracks, must not start selecting.
            .overlay {
                SkillRowPressArea(
                    showsPointingHand: opensOnClick,
                    onClick: { click(skill) },
                    onLongPress: { beginSelection(with: skill) }
                )
            }
            if !isSelecting {
                if Self.isFixable(skill) {
                    Button { fix([skill]) } label: { Label("Fix with Agent", systemImage: "wand.and.stars") }
                        .controlSize(.small)
                        .disabled(isFixing)
                        .buttonHoverPointer()
                        .nativeHelp("Open a task whose agent fixes \(skill.name)")
                        .accessibilityIdentifier("skill-fix-\(skill.name)")
                }
                Toggle("Enabled", isOn: Binding(get: { isEnabled(skill) }, set: { setEnabled(skill, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .buttonHoverPointer()
                    .nativeHelp(isEnabled(skill) ? "Turn the skill off in Playhouse sessions" : "Turn the skill on in Playhouse sessions")
                    .accessibilityLabel("\(skill.name) enabled")
                    .accessibilityIdentifier("skill-toggle-\(skill.name)")

                Button("Use") { onUse(skill) }
                    .controlSize(.small)
                    .disabled(!isEnabled(skill) || skill.providers.isEmpty)
                    .buttonHoverPointer()
                    .nativeHelp("Insert /\(skill.name) into the message")
                    .accessibilityIdentifier("skill-use-\(skill.name)")

                actions(skill)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor.opacity(0.12) : WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.clear))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skill-row-\(skill.name)")
    }

    private func badge(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }

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

    private func actions(_ skill: SkillRecord) -> some View {
        Menu {
            if skill.editable {
                Button("Edit…") { openEditor(skill) }
                    .buttonHoverPointer()
                    .help("Edit the skill's SKILL.md")
                    .accessibilityIdentifier("skill-edit-\(skill.name)")
            }
            if let folder = skill.folderPath {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
                    .buttonHoverPointer()
                    .help("Show the skill folder in Finder")
                    .accessibilityIdentifier("skill-reveal-\(skill.name)")
            }
            if skill.editable {
                Divider()
                if skill.scope == .repo {
                    Button("Move to Global") {
                        perform { _ = try await manager.moveSkill(taskID: task.id, skillID: skill.id, scope: .global, root: nil) }
                    }
                    .buttonHoverPointer()
                    .help("Make the skill available in every repository")
                    .accessibilityIdentifier("skill-move-global-\(skill.name)")
                }
                ForEach(catalog?.repositories ?? [], id: \.rootPath) { section in
                    if skill.scope == .global || skill.rootPath != section.rootPath {
                        Button("Move to \(section.name)") {
                            perform { _ = try await manager.moveSkill(taskID: task.id, skillID: skill.id, scope: .repo, root: section.rootPath) }
                        }
                        .buttonHoverPointer()
                        .help("Keep the skill only in \(section.name)")
                        .accessibilityIdentifier("skill-move-repo-\(skill.name)-\(section.name)")
                    }
                }
                Divider()
                if skill.locations.contains(where: \.isSymlink) {
                    Button("Remove Outside Link") {
                        perform { _ = try await manager.linkSkill(taskID: task.id, skillID: skill.id, linked: false) }
                    }
                    .buttonHoverPointer()
                    .help("Remove the symlink Playhouse wrote; Playhouse sessions still share the skill")
                    .accessibilityIdentifier("skill-unlink-\(skill.name)")
                } else if !skill.availableOutsidePlayhouse, !skill.conflict {
                    Button("Make Available Outside Playhouse…") { pendingLink = skill }
                        .buttonHoverPointer()
                        .help("Write a symlink so the claude and codex CLIs find the skill on their own")
                        .accessibilityIdentifier("skill-link-\(skill.name)")
                }
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = [skill] }
                    .buttonHoverPointer()
                    .help("Delete the skill from disk")
                    .accessibilityIdentifier("skill-delete-\(skill.name)")
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
        .nativeHelp("More actions for \(skill.name)")
        .accessibilityLabel("Actions for \(skill.name)")
        .accessibilityIdentifier("skill-actions-\(skill.name)")
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
private enum SkillDocumentTab: String, CaseIterable, Identifiable {
    case edit = "Edit"
    case preview = "Preview"
    var id: String { rawValue }
}

private struct SkillDocumentTabPicker: View {
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
    @State private var tab = SkillDocumentTab.edit
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        SkillPanel(identifier: "new-skill-panel") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("New Skill").font(.headline)
                    Spacer()
                    Picker("Save to", selection: $destination) {
                        Text("Global (~/.agents/skills)").tag("global")
                        ForEach(roots, id: \.rootPath) { root in Text(root.name).tag(root.rootPath) }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("new-skill-scope")
                }
                Text("Saved in the open Agent Skills layout (.agents/skills). Playhouse shares it with both Claude and Codex. The name uses lowercase letters, digits, and hyphens.")
                    .font(.callout).foregroundStyle(.secondary)
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
                let scope: SkillScope = destination == "global" ? .global : .repo
                var submitted = manifest
                submitted.name = manifest.name.trimmingCharacters(in: .whitespaces)
                try await onCreate(submitted, scope, scope == .repo ? destination : nil)
                onClose()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// A skill's Markdown as it reads: any frontmatter as a small table of its
/// entries, then headings, lists, quotes, code, and paragraphs.
private struct SkillMarkdownPreview: View {
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

/// A skill row's text area. AppKit's own mouse tracking tells a click from a
/// press and hold: SwiftUI's long-press gesture raced against a tap could stay
/// tracking after a click opened the editor, and the window then ignored every
/// click until it was minimized.
struct SkillRowPressArea: NSViewRepresentable {
    let showsPointingHand: Bool
    let onClick: () -> Void
    let onLongPress: () -> Void

    func makeNSView(context: Context) -> PressView { PressView() }

    func updateNSView(_ view: PressView, context: Context) {
        view.onClick = onClick
        view.onLongPress = onLongPress
        if view.showsPointingHand != showsPointingHand {
            view.showsPointingHand = showsPointingHand
            view.window?.invalidateCursorRects(for: view)
        }
    }

    final class PressView: NSView {
        static let holdDuration: TimeInterval = 0.45
        var onClick: () -> Void = {}
        var onLongPress: () -> Void = {}
        var showsPointingHand = false

        override func isAccessibilityElement() -> Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            if showsPointingHand { addCursorRect(bounds, cursor: .pointingHand) }
        }

        /// Tracks the press to its mouse-up here, so no gesture state outlives it.
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let deadline = Date(timeIntervalSinceNow: Self.holdDuration)
            var held = false
            while true {
                let next = window.nextEvent(
                    matching: [.leftMouseUp, .leftMouseDragged],
                    until: held ? .distantFuture : deadline,
                    inMode: .eventTracking,
                    dequeue: true
                )
                guard let next else {
                    held = true
                    onLongPress()
                    continue
                }
                guard next.type == .leftMouseUp else { continue }
                if !held, bounds.contains(convert(next.locationInWindow, from: nil)) { onClick() }
                return
            }
        }
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

// MARK: - Rules

/// The instruction files agents follow on every turn: each repository's
/// AGENTS.md, CLAUDE.md and `.claude/rules`, the user's global ones, and the
/// organization's managed CLAUDE.md. Like skills, each rule is shared with the
/// provider that would not read it on its own.
private struct RulesSectionView: View {
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
            }
            .accessibilityIdentifier("rules-list")
        }
        .overlay { panels }
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.name)
                            .font(.headline)
                            .padding(.top, 6)
                            .accessibilityIdentifier("rules-repo-section-\(section.name)")
                        if section.rules.isEmpty {
                            emptyState("No rules in \(section.name).", identifier: "rules-empty-\(section.name)")
                        }
                        ForEach(section.rules) { row($0) }
                    }
                }
            case .global:
                Text("Your rules for every repository. New global rules go in ~/.agents/AGENTS.md, which Playhouse shares with both agents, like ~/.agents/skills.")
                    .font(.callout).foregroundStyle(.secondary)
                if catalog.global.isEmpty { emptyState("No global rules.", identifier: "rules-empty-global") }
                ForEach(catalog.global) { row($0) }
            case .managed:
                Text("Your organization's managed CLAUDE.md. Claude Code always follows it, and it can't be edited or turned off here.")
                    .font(.callout).foregroundStyle(.secondary)
                if catalog.managed.isEmpty { emptyState("No managed rules on this Mac.", identifier: "rules-empty-managed") }
                ForEach(catalog.managed) { row($0) }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity).accessibilityIdentifier("rules-loading")
        }
    }

    private func emptyState(_ text: String, identifier: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding(.vertical, 6).accessibilityIdentifier(identifier)
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
                SkillRowPressArea(showsPointingHand: true, onClick: { openEditor(rule) }, onLongPress: {})
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
