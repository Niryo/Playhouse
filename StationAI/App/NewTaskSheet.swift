import AppKit
import SwiftUI

struct NewTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) private var defaultParentFolderPath = ""
    @State private var parentFolderURL: URL?
    @State private var repositories: [RepositoryWorktreeSpec] = []
    @State private var contextFolders: [URL] = []
    @State private var suggestedRepositories: [URL] = []
    @State private var repositorySearch = ""
    @State private var lastSelectedRepositoryPaths: [String] = []
    @State private var didOverrideRepositoryDefault = false
    @State private var keyboardHighlightedRepositoryPath: String?
    @State private var editingRepositoryField: EditableRepositoryField?
    @State private var hoveredRepositoryTag: String?
    @FocusState private var focusedRepositoryField: EditableRepositoryField?
    @State private var isChoosingInitialParent = false
    @State private var createError: String?

    private enum EditableRepositoryField: Hashable {
        case branch(Int)
        case branchFrom(Int)
        case mergeTarget(Int)
    }

    let onCreate: ([RepositoryWorktreeSpec], [URL]) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Create a task")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("Choose the folders Codex should use as context. You can include multiple repositories in one task.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Repositories and folders")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(action: browseForFolders) {
                        Label("Browse…", systemImage: "folder")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonHoverPointer()
                    .help("Browse folders to add repositories or context folders")
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("browse-workspace-roots-button")
                }
                if let parentFolderURL {
                    HStack(spacing: 5) {
                        Image(systemName: "folder.badge.gearshape").foregroundStyle(.secondary)
                        Text("Suggestions from \(parentFolderURL.path)")
                            .lineLimit(1).help(parentFolderURL.path)
                        Spacer(minLength: 0)
                        Button("Change…", action: chooseInitialParent)
                        .buttonHoverPointer()
                        .help("Change suggestion folder").buttonStyle(.link)
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Button("Choose a suggestion folder…", action: chooseInitialParent)
                    .buttonHoverPointer()
                    .help("Choose a suggestion folder")
                        .buttonStyle(.link)
                }

            ForEach(repositories.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.tint)
                        Text(URL(fileURLWithPath: repositories[index].repositoryPath).lastPathComponent)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("selected-repository-\(index)")
                        Spacer(minLength: 2)
                        editableRepositoryTag(
                            label: "branch",
                            value: repositories[index].branch ?? "auto",
                            identifier: "repository-branch-tag-\(index)",
                            textFieldIdentifier: "repository-branch-\(index)",
                            field: .branch(index),
                            text: branchBinding(at: index),
                            minimumWidth: 150
                        )
                        editableRepositoryTag(
                            label: "from",
                            value: repositories[index].branchFrom ?? "default",
                            identifier: "repository-branch-from-tag-\(index)",
                            textFieldIdentifier: "repository-branch-from-\(index)",
                            field: .branchFrom(index),
                            text: branchFromBinding(at: index),
                            minimumWidth: 105
                        )
                        editableRepositoryTag(
                            label: "merge into",
                            value: repositories[index].mergeTarget ?? "default",
                            identifier: "repository-merge-target-tag-\(index)",
                            textFieldIdentifier: "repository-merge-target-\(index)",
                            field: .mergeTarget(index),
                            text: mergeTargetBinding(at: index),
                            minimumWidth: 110
                        )
                        Button { repositories.remove(at: index) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonHoverPointer()
                        .help("Remove repository")
                            .buttonStyle(.plain).accessibilityLabel("Remove repository")
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                ForEach(contextFolders, id: \.standardizedFileURL.path) { folder in
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill").foregroundStyle(.secondary)
                        Text(folder.lastPathComponent).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(folder.path).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button { contextFolders.removeAll { $0.standardizedFileURL.path == folder.standardizedFileURL.path } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonHoverPointer()
                        .help("Remove \(folder.lastPathComponent)")
                            .buttonStyle(.plain).accessibilityLabel("Remove \(folder.lastPathComponent)")
                    }
                }

                TextField(repositorySearchPlaceholder, text: $repositorySearch)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("workspace-repository-search")
                    .onChange(of: repositorySearch) { _, value in
                        keyboardHighlightedRepositoryPath = nil
                        if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            didOverrideRepositoryDefault = true
                        }
                    }
                    .onKeyPress(.downArrow) {
                        moveRepositoryHighlight(direction: 1)
                    }
                    .onKeyPress(.upArrow) {
                        moveRepositoryHighlight(direction: -1)
                    }
                    .onKeyPress(.return) {
                        if let path = keyboardHighlightedRepositoryPath,
                           let repository = matchingRepositorySuggestions.first(where: { $0.path == path }) {
                            selectRepository(repository)
                            return .handled
                        }

                        let query = repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
                        if query.isEmpty {
                            restoreLastSelectedRepositories()
                        } else if let candidate = matchingRepositorySuggestions.first {
                            selectRepository(candidate)
                        }
                        return .handled
                    }
                if !repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let availableRepositories = matchingRepositorySuggestions
                    if suggestedRepositories.isEmpty {
                        ProgressView("Finding repositories…")
                            .font(.system(size: 10))
                            .controlSize(.small)
                    } else if availableRepositories.isEmpty {
                        Text("No matching repositories. Use Browse to add a folder.").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(availableRepositories, id: \.path) { repository in
                                    Button {
                                        selectRepository(repository)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(repository.lastPathComponent).font(.system(size: 11, weight: .medium))
                                            Text(repository.path).font(.system(size: 9)).foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(7)
                                        .background(keyboardHighlightedRepositoryPath == repository.path ? Color.accentColor.opacity(0.16) : .clear)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonHoverPointer()
                                    .help("Select repository")
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("repository-suggestion-\(repository.lastPathComponent)")
                                }
                            }
                        }
                        .frame(maxHeight: 92)
                        .clipped()
                        .accessibilityIdentifier("repository-suggestions-list")
                        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                if let createError {
                    Label(createError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("task-create-error")
                }
                if repositories.isEmpty && contextFolders.isEmpty {
                    Text("Select a repository for an isolated worktree, or browse to add a folder.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonHoverPointer()
                .help("Cancel task creation")
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("cancel-task-button")

                Button("Done") {
                    do {
                        try onCreate(repositories, contextFolders)
                        try WorkspaceSettingsManager().setLastSelectedRepositories(repositories.map(\.repositoryPath))
                        dismiss()
                    } catch {
                        createError = error.localizedDescription
                    }
                }
                .buttonHoverPointer()
                .help("Done")
                .buttonStyle(.borderedProminent)
                .tint(WorkspaceTheme.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(repositories.isEmpty && contextFolders.isEmpty)
                .accessibilityIdentifier("create-task-button")
            }
        }
        .padding(24)
        .frame(width: 560, height: 570)
        .background(WorkspaceTheme.windowBackground)
        .onAppear {
            parentFolderURL = WorkspaceSettingsManager().defaultParentFolderURL
            lastSelectedRepositoryPaths = WorkspaceSettingsManager().lastSelectedRepositories
            if parentFolderURL == nil {
                chooseInitialParent()
            } else {
            }
        }
        .task(id: parentFolderURL?.path) {
            guard let parentFolderURL else { suggestedRepositories = []; return }
            suggestedRepositories = (try? await WorkspaceManager().suggestedRepositories(parentPath: parentFolderURL.path).map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }) ?? []
        }
    }

    private var repositorySearchPlaceholder: String {
        guard !lastSelectedRepositoryPaths.isEmpty else { return "Enter a repository name to search…" }
        let names = lastSelectedRepositoryPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        return "Last used: \(names.joined(separator: ", ")) — press ↵ to reuse"
    }

    private var matchingRepositorySuggestions: [URL] {
        let query = repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return suggestedRepositories.filter { candidate in
            !repositories.contains(where: { URL(fileURLWithPath: $0.repositoryPath).standardizedFileURL.path == candidate.standardizedFileURL.path }) &&
            (candidate.lastPathComponent.localizedCaseInsensitiveContains(query) || candidate.path.localizedCaseInsensitiveContains(query))
        }
    }

    private func restoreLastSelectedRepositories() {
        guard !didOverrideRepositoryDefault, repositories.isEmpty else { return }
        repositories = lastSelectedRepositoryPaths.compactMap { path in
            let marker = URL(fileURLWithPath: path).appendingPathComponent(".git")
            return FileManager.default.fileExists(atPath: marker.path) ? repositorySpec(for: path) : nil
        }
    }

    private func moveRepositoryHighlight(direction: Int) -> KeyPress.Result {
        let options = matchingRepositorySuggestions
        guard !options.isEmpty else { return .ignored }
        let currentIndex = options.firstIndex(where: { $0.path == keyboardHighlightedRepositoryPath })
        let nextIndex: Int
        if let currentIndex {
            nextIndex = (currentIndex + direction + options.count) % options.count
        } else {
            nextIndex = direction > 0 ? 0 : options.count - 1
        }
        keyboardHighlightedRepositoryPath = options[nextIndex].path
        return .handled
    }

    private func selectRepository(_ repository: URL) {
        didOverrideRepositoryDefault = true
        repositories.append(repositorySpec(for: repository.path))
        repositorySearch = ""
        keyboardHighlightedRepositoryPath = nil
    }

    private func chooseInitialParent() {
        guard !isChoosingInitialParent else { return }
        isChoosingInitialParent = true
        let panel = NSOpenPanel()
        panel.title = "Choose default parent folder"
        panel.message = "StationAI will suggest Git repositories found below this folder."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = parentFolderURL ?? FileManager.default.homeDirectoryForCurrentUser
        panel.begin { response in
            DispatchQueue.main.async {
                isChoosingInitialParent = false
                guard response == .OK, let selected = panel.url else {
                    if parentFolderURL == nil { dismiss() }
                    return
                }
                let normalized = selected.standardizedFileURL
                do {
                    try WorkspaceSettingsManager().setDefaultParentFolder(normalized.path)
                    defaultParentFolderPath = normalized.path
                } catch {
                    if parentFolderURL == nil { dismiss() }
                    return
                }
                parentFolderURL = normalized
            }
        }
    }

    private func branchBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { repositories.indices.contains(index) ? (repositories[index].branch ?? "auto") : "" },
            set: { if repositories.indices.contains(index) { repositories[index].branch = $0 == "auto" ? nil : $0 } }
        )
    }

    private func branchFromBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { repositories.indices.contains(index) ? (repositories[index].branchFrom ?? "") : "" },
            set: { if repositories.indices.contains(index) { repositories[index].branchFrom = $0.isEmpty ? nil : $0 } }
        )
    }

    private func mergeTargetBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { repositories.indices.contains(index) ? (repositories[index].mergeTarget ?? "") : "" },
            set: { if repositories.indices.contains(index) { repositories[index].mergeTarget = $0.isEmpty ? nil : $0 } }
        )
    }

    @ViewBuilder
    private func editableRepositoryTag(
        label: String,
        value: String,
        identifier: String,
        textFieldIdentifier: String,
        field: EditableRepositoryField,
        text: Binding<String>,
        minimumWidth: CGFloat
    ) -> some View {
        if editingRepositoryField == field {
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: minimumWidth, maxWidth: 190)
                .focused($focusedRepositoryField, equals: field)
                .accessibilityIdentifier(textFieldIdentifier)
                .onSubmit {
                    editingRepositoryField = nil
                    focusedRepositoryField = nil
                }
        } else {
            Button {
                editingRepositoryField = field
                DispatchQueue.main.async { focusedRepositoryField = field }
            } label: {
                HStack(spacing: 4) {
                    Text(label).foregroundStyle(.secondary)
                    Text(value.isEmpty ? "default" : value)
                        .font(.system(size: 9, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "pencil")
                        .font(.system(size: 8, weight: .medium))
                        .opacity(hoveredRepositoryTag == identifier ? 0.75 : 0.35)
                }
                .font(.system(size: 9, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(WorkspaceTheme.panelBackground, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonHoverPointer()
            .buttonStyle(.plain)
            .onHover { isHovering in hoveredRepositoryTag = isHovering ? identifier : nil }
            .help("Edit \(label == "from" ? "branch starting point" : "branch name")")
            .accessibilityIdentifier(identifier)
            .accessibilityLabel("Edit \(label == "from" ? "branch starting point" : "branch name"): \(value)")
        }
    }

    private func browseForFolders() {
        let panel = NSOpenPanel()
        panel.title = "Add repositories or folders"
        panel.message = "Git repositories are added as worktrees; other folders are added as context."
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = parentFolderURL
        panel.begin { response in
            guard response == .OK else { return }
            DispatchQueue.main.async {
                for selected in panel.urls {
                    let folder = selected.standardizedFileURL
                    let marker = folder.appendingPathComponent(".git")
                    if FileManager.default.fileExists(atPath: marker.path) {
                        if !repositories.contains(where: { URL(fileURLWithPath: $0.repositoryPath).standardizedFileURL.path == folder.path }) {
                            repositories.append(repositorySpec(for: folder.path))
                        }
                    } else if !contextFolders.contains(where: { $0.standardizedFileURL.path == folder.path }) {
                        contextFolders.append(folder)
                    }
                }
            }
        }
    }

    private func repositorySpec(for path: String) -> RepositoryWorktreeSpec {
        RepositoryWorktreeSpec(repositoryPath: path, branch: nil, branchFrom: nil, mergeTarget: nil)
    }
}

struct WorkspaceRootsEditor: View {
    @Environment(\.dismiss) private var dismiss
    let parentFolderURL: URL?
    let initialRoots: [URL]
    let repositoryWorktrees: [RepositoryWorktreeRecord]
    let onSave: ([URL]) -> Void
    @State private var roots: [URL]

    init(parentFolderURL: URL?, initialRoots: [URL], repositoryWorktrees: [RepositoryWorktreeRecord] = [], onSave: @escaping ([URL]) -> Void) {
        self.parentFolderURL = parentFolderURL
        self.initialRoots = initialRoots
        self.repositoryWorktrees = repositoryWorktrees
        self.onSave = onSave
        _roots = State(initialValue: initialRoots)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit working folders")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
            Text("Changes apply to the next Codex turn. The first folder is used as the working directory.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            WorkspaceRootSelector(
                parentFolderURL: parentFolderURL,
                roots: $roots,
                displayNames: Dictionary(uniqueKeysWithValues: repositoryWorktrees.map {
                    ($0.worktreePath, "\(URL(fileURLWithPath: $0.repositoryPath).lastPathComponent) · \($0.branch)")
                })
            )
            Label("Codex has full machine and network access; this list sets task context only.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                .buttonHoverPointer()
                .help("Cancel workspace folder changes")
                    .keyboardShortcut(.cancelAction)
                Button("Save folders") {
                    onSave(roots)
                    dismiss()
                }
                .buttonHoverPointer()
                .help("Save workspace folders")
                .buttonStyle(.borderedProminent)
                .disabled(roots.isEmpty)
                .accessibilityIdentifier("save-workspace-roots-button")
            }
        }
        .padding(24)
        .frame(width: 560, height: 620)
    }
}
