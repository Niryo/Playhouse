import AppKit
import SwiftUI

/// The task's skill gallery: its repositories' skills, the user's global
/// skills, and the ones that came with each provider. Every skill a user adds
/// works with both Claude and Codex, so the page shows where a skill lives and
/// who can use it rather than which provider owns it.
struct SkillsPageView: View {
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
        var manifest: SkillManifest
        var id: String { skill.id }
    }

    private static let panelAnimation = Animation.spring(response: 0.34, dampingFraction: 0.9)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
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
                 : "Click a skill to edit it, or press and hold to select several. Turning a skill on or off reaches Claude on its next turn, and a Codex conversation the next time its thread starts.")
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
        .background(WorkspaceTheme.windowBackground)
        .overlay { panels }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills-page")
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

    /// The editor and New Skill panels slide up over the gallery, like the gallery over the conversation.
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
                SkillEditorPanel(editing: editing, onClose: closePanel) { manifest in
                    let record = try await manager.updateSkill(
                        taskID: task.id, skillID: editing.skill.id, description: manifest.description,
                        body: manifest.body, fields: Self.editedFields(manifest.fields)
                    )
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
                        fields: manifest.fields.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty },
                        scope: scope, root: root
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

    /// Every editable field is sent, so one the user cleared is removed from SKILL.md.
    private static func editedFields(_ fields: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: SkillManifest.optionalKeys.map { ($0, fields[$0] ?? "") })
    }

    private func closePanel() {
        withAnimation(Self.panelAnimation) { panel = nil }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.07), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(isPresentingPanel || isSelecting ? nil : .cancelAction)
            .buttonHoverPointer()
            .nativeHelp("Close Skills and return to the conversation")
            .accessibilityLabel("Close Skills")
            .accessibilityIdentifier("skills-back-button")

            Text("Skills")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("skills-title")

            Picker("Skill source", selection: $tab) {
                ForEach(Tab.allCases) { tab in Text(tab.rawValue).tag(tab) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 260)
            .accessibilityIdentifier("skills-tab-picker")

            Spacer()

            if isSelecting {
                selectionActions
            } else {
                TextField("Search skills", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .accessibilityIdentifier("skills-search")

                Button("Select") { withAnimation(.easeInOut(duration: 0.15)) { isSelecting = true } }
                    .buttonHoverPointer()
                    .nativeHelp("Select several skills to delete them or fix them with an agent")
                    .accessibilityIdentifier("skills-select-button")

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
            .contentShape(Rectangle())
            // A press and hold starts selecting; a click edits, or selects while selecting. Only
            // the skill's own text takes them: a held click on a control, such as the actions
            // menu while it tracks, must not start selecting.
            .gesture(
                LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in beginSelection(with: skill) }
                    .exclusively(before: TapGesture().onEnded { click(skill) })
            )
            .hoverCursor(opensOnClick ? .pointingHand : .arrow)
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
            guard let manifest = try await manager.skillManifest(taskID: task.id, skillID: skill.id) else { return }
            withAnimation(Self.panelAnimation) { panel = .editing(EditingSkill(skill: skill, manifest: manifest)) }
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
                    .help("Edit the skill's details and instructions")
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
                Button("Select") { beginSelection(with: skill) }
                    .buttonHoverPointer()
                    .help("Select this skill and others to act on them together")
                    .accessibilityIdentifier("skill-begin-select-\(skill.name)")
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
private struct SkillPanel<Header: View, Content: View, Footer: View>: View {
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

/// The parsed SKILL.md header: the skill's name, when to use it, and the
/// optional Agent Skills fields both providers accept.
private struct SkillHeaderForm: View {
    @Binding var manifest: SkillManifest
    let nameEditable: Bool
    let readOnly: Bool
    let location: String?
    let identifierPrefix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                if nameEditable {
                    TextField("skill-name", text: $manifest.name)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.semibold))
                        .accessibilityLabel("Name")
                        .accessibilityIdentifier("\(identifierPrefix)-name")
                } else {
                    Text(manifest.name)
                        .font(.title2.weight(.semibold))
                        .textSelection(.enabled)
                        .accessibilityIdentifier("\(identifierPrefix)-name")
                }
                Spacer()
            }
            if let location {
                Text(location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("\(identifierPrefix)-location")
            }
            labeled("Description") {
                TextField("When should the agent use this skill?", text: $manifest.description, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .disabled(readOnly)
                    .accessibilityIdentifier("\(identifierPrefix)-description")
            }
            HStack(alignment: .top, spacing: 12) {
                field("License", key: "license", placeholder: "For example, MIT")
                field("Compatibility", key: "compatibility", placeholder: "For example, needs git and network access")
                field("Allowed tools", key: "allowed-tools", placeholder: "For example, Bash(git:*) Read")
            }
        }
    }

    private func labeled<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            field()
        }
    }

    private func field(_ title: String, key: String, placeholder: String) -> some View {
        labeled(title) {
            TextField(placeholder, text: Binding(
                get: { manifest.fields[key] ?? "" },
                set: { manifest.fields[key] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .disabled(readOnly)
            .accessibilityLabel(title)
            .accessibilityIdentifier("\(identifierPrefix)-field-\(key)")
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SkillEditorPanel: View {
    let skill: SkillRecord
    let onClose: () -> Void
    let onSave: (SkillManifest) async throws -> Void
    @State private var manifest: SkillManifest
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(editing: SkillsPageView.EditingSkill, onClose: @escaping () -> Void, onSave: @escaping (SkillManifest) async throws -> Void) {
        skill = editing.skill
        self.onClose = onClose
        self.onSave = onSave
        _manifest = State(initialValue: editing.manifest)
    }

    private var readOnly: Bool { !skill.editable }

    var body: some View {
        SkillPanel(identifier: "skill-editor-panel") {
            SkillHeaderForm(
                manifest: $manifest, nameEditable: false, readOnly: readOnly,
                location: skill.folderPath.map { $0 + "/SKILL.md" }, identifierPrefix: "skill-editor"
            )
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions").font(.subheadline.weight(.semibold))
                SkillTextEditor(text: $manifest.body, identifier: "skill-editor", isEditable: !readOnly)
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
                try await onSave(manifest)
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
                SkillHeaderForm(manifest: $manifest, nameEditable: true, readOnly: false, location: nil, identifierPrefix: "new-skill")
            }
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions").font(.subheadline.weight(.semibold))
                SkillTextEditor(text: $manifest.body, identifier: "new-skill-body", isEditable: true)
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

/// A plain-text editor for a skill's instructions. SwiftUI's `TextEditor`
/// applies the system's smart dashes and quotes, which would turn Markdown's
/// `---` into an em dash.
private struct SkillTextEditor: NSViewRepresentable {
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
