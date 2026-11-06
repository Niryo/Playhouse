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
    let onBack: () -> Void

    @State private var tab: Tab = .repo
    @State private var catalog: SkillCatalog?
    @State private var search = ""
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var editing: EditingSkill?
    @State private var isCreating = false
    @State private var pendingDelete: SkillRecord?
    @State private var pendingLink: SkillRecord?

    struct EditingSkill: Identifiable {
        let skill: SkillRecord
        var content: String
        var id: String { skill.id }
    }

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
            Text("Turning a skill on or off reaches Claude on its next turn, and a Codex conversation the next time its thread starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .accessibilityIdentifier("skills-provider-timing")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) { content }
                    .padding(20)
            }
            .accessibilityIdentifier("skills-list")
        }
        .background(WorkspaceTheme.windowBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills-page")
        .task { await reload() }
        .sheet(item: $editing) { editing in
            SkillEditorSheet(editing: editing) { content in
                _ = try await manager.updateSkill(taskID: task.id, skillID: editing.skill.id, content: content)
                await reload()
            }
        }
        .sheet(isPresented: $isCreating) {
            NewSkillSheet(roots: catalog?.repositories ?? []) { name, description, body, scope, root in
                let record = try await manager.createSkill(
                    taskID: task.id, name: name, description: description, body: body, scope: scope, root: root
                )
                tab = record.scope == .global ? .global : .repo
                await reload()
            }
        }
        .alert(
            "Delete \(pendingDelete?.name ?? "skill")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { skill in
            Button("Delete", role: .destructive) { perform { try await manager.deleteSkill(taskID: task.id, skillID: skill.id) } }
                .buttonHoverPointer()
                .nativeHelp("Delete the skill folder from disk")
                .accessibilityIdentifier("confirm-delete-skill")
            Button("Cancel", role: .cancel) {}
                .buttonHoverPointer()
                .nativeHelp("Keep the skill")
        } message: { skill in
            Text("This removes \(skill.folderPath ?? skill.name) from disk for both Claude and Codex.")
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

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .buttonHoverPointer()
            .nativeHelp("Return to the conversation")
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

            TextField("Search skills", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .accessibilityIdentifier("skills-search")

            Button { isCreating = true } label: { Label("New Skill", systemImage: "plus") }
                .buttonHoverPointer()
                .nativeHelp("Create a skill that both Claude and Codex can use")
                .accessibilityIdentifier("new-skill-button")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
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

    private func row(_ skill: SkillRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
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
            Spacer()
            Toggle("Enabled", isOn: Binding(
                get: { skill.enabled },
                set: { enabled in perform { _ = try await manager.setSkillEnabled(taskID: task.id, skillID: skill.id, enabled: enabled) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .nativeHelp(skill.enabled ? "Turn the skill off in Playhouse sessions" : "Turn the skill on in Playhouse sessions")
            .accessibilityLabel("\(skill.name) enabled")
            .accessibilityIdentifier("skill-toggle-\(skill.name)")

            Button("Use") { onUse(skill) }
                .disabled(!skill.enabled || skill.providers.isEmpty)
                .buttonHoverPointer()
                .nativeHelp("Insert /\(skill.name) into the message")
                .accessibilityIdentifier("skill-use-\(skill.name)")

            actions(skill)
        }
        .padding(12)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8))
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

    private func actions(_ skill: SkillRecord) -> some View {
        Menu {
            if skill.editable {
                Button("Edit…") {
                    perform {
                        let content = try await manager.skillContent(taskID: task.id, skillID: skill.id) ?? ""
                        editing = EditingSkill(skill: skill, content: content)
                    }
                }
                .buttonHoverPointer()
                .help("Edit SKILL.md")
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
                Button("Delete…", role: .destructive) { pendingDelete = skill }
                    .buttonHoverPointer()
                    .help("Delete the skill from disk")
                    .accessibilityIdentifier("skill-delete-\(skill.name)")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .buttonHoverPointer()
        .nativeHelp("More actions for \(skill.name)")
        .accessibilityLabel("Actions for \(skill.name)")
        .accessibilityIdentifier("skill-actions-\(skill.name)")
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task { @MainActor in
            do {
                try await operation()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            await reload()
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
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct SkillEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var editing: SkillsPageView.EditingSkill
    let onSave: (String) async throws -> Void
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit \(editing.skill.name)").font(.headline)
            Text(editing.skill.folderPath.map { $0 + "/SKILL.md" } ?? "")
                .font(.caption).foregroundStyle(.secondary)
            SkillTextEditor(text: $editing.content, identifier: "skill-editor")
                .frame(minWidth: 640, minHeight: 360)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout).accessibilityIdentifier("skill-editor-error")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonHoverPointer()
                    .nativeHelp("Discard changes")
                    .accessibilityIdentifier("skill-editor-cancel")
                Button("Save") {
                    isSaving = true
                    Task { @MainActor in
                        defer { isSaving = false }
                        do {
                            try await onSave(editing.content)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
                .buttonHoverPointer()
                .nativeHelp("Save SKILL.md")
                .accessibilityIdentifier("skill-editor-save")
            }
        }
        .padding(20)
    }
}

private struct NewSkillSheet: View {
    @Environment(\.dismiss) private var dismiss
    let roots: [SkillRepositorySection]
    let onCreate: (String, String, String, SkillScope, String?) async throws -> Void
    @State private var name = ""
    @State private var description = ""
    @State private var instructions = ""
    /// "global", or the root path of one of the task's repositories.
    @State private var destination = "global"
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Skill").font(.headline)
            Text("Saved in the open Agent Skills layout (.agents/skills). Playhouse shares it with both Claude and Codex.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Name (for example, release-notes)", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("new-skill-name")
            TextField("When should the agent use this skill?", text: $description)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("new-skill-description")
            Picker("Save to", selection: $destination) {
                Text("Global (~/.agents/skills)").tag("global")
                ForEach(roots, id: \.rootPath) { root in Text(root.name).tag(root.rootPath) }
            }
            .accessibilityIdentifier("new-skill-scope")
            Text("Instructions").font(.subheadline)
            SkillTextEditor(text: $instructions, identifier: "new-skill-body")
                .frame(minWidth: 560, minHeight: 200)
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout).accessibilityIdentifier("new-skill-error")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonHoverPointer()
                    .nativeHelp("Close without creating a skill")
                    .accessibilityIdentifier("new-skill-cancel")
                Button("Create") {
                    isSaving = true
                    Task { @MainActor in
                        defer { isSaving = false }
                        do {
                            let scope: SkillScope = destination == "global" ? .global : .repo
                            try await onCreate(
                                name.trimmingCharacters(in: .whitespaces), description, instructions,
                                scope, scope == .repo ? destination : nil
                            )
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
                .buttonHoverPointer()
                .nativeHelp("Create the skill")
                .accessibilityIdentifier("new-skill-create")
            }
        }
        .padding(20)
    }
}

/// A plain-text editor for SKILL.md. SwiftUI's `TextEditor` applies the
/// system's smart dashes and quotes, which would turn frontmatter's `---` into
/// an em dash and break the skill for both providers.
private struct SkillTextEditor: NSViewRepresentable {
    @Binding var text: String
    let identifier: String

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
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityIdentifier(identifier)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
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
