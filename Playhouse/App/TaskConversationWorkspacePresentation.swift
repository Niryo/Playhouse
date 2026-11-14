import AppKit
import SwiftData
import SwiftUI

extension TaskConversationView {
    func setTerminalPresented(_ presented: Bool) {
        if presented { terminalSession.startIfNeeded(taskID: task.id, workspaceManager: workspaceManager) }
        withAnimation(.easeOut(duration: 0.22)) { isTerminalPresented = presented }
    }

    /// The panel's left border; dragging it left widens the terminal and right narrows it.
    func terminalResizeHandle(width: CGFloat, available: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 17)
                    .contentShape(Rectangle())
                    .hoverCursor(.resizeLeftRight)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if terminalResizeStartWidth == nil {
                                    // Held for the whole drag, so the pointer can leave the thin border.
                                    NSCursor.resizeLeftRight.push()
                                }
                                let start = terminalResizeStartWidth ?? width
                                terminalResizeStartWidth = start
                                terminalPanelWidth = Double(TerminalPanelLayout.clampedWidth(
                                    start - value.translation.width, available: available
                                ))
                            }
                            .onEnded { _ in
                                if terminalResizeStartWidth != nil { NSCursor.pop() }
                                terminalResizeStartWidth = nil
                            }
                    )
                    .onDisappear {
                        // A panel closed mid-drag may never end the gesture.
                        if terminalResizeStartWidth != nil {
                            NSCursor.pop()
                            terminalResizeStartWidth = nil
                        }
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Resize terminal")
                    .accessibilityValue("\(Int(width.rounded())) points")
                    .accessibilityIdentifier("terminal-resize-handle")
            }
    }

    static let expandedSidebarWidth: CGFloat = 232
    static let collapsedSidebarWidth: CGFloat = 38

    /// The width the terminal panel can float over: the conversation, beside the sidebar and its divider.
    func conversationWidth(in containerWidth: CGFloat) -> CGFloat {
        containerWidth - (isTaskSidebarShownCollapsed ? Self.collapsedSidebarWidth : Self.expandedSidebarWidth) - 1
    }

    /// Why this task can't open a terminal yet, shared with the CLI's `task terminal`.
    var terminalUnavailableReason: String? {
        TaskTerminalLaunch.unavailableReason(for: task.repositoryWorktrees)
    }

    /// Quick actions for the task, right-aligned along the bottom of the sidebar.
    var sidebarCommandRow: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            PluginSlot(placement: .conversationToolbar, props: pluginProps, actions: pluginActions, open: { openConversationPlugin = $0 }, add: startPluginTask)
            Button {
                setTerminalPresented(!isTerminalPresented)
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
                    .foregroundStyle(terminalUnavailableReason != nil && !isTerminalPresented
                        ? Color.secondary.opacity(0.35)
                        : (isTerminalPresented ? WorkspaceTheme.accent : Color.secondary))
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isTerminalPresented ? WorkspaceTheme.accent.opacity(0.14) : Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .buttonHoverPointer()
            .disabled(terminalUnavailableReason != nil && !isTerminalPresented)
            .nativeHelp(terminalUnavailableReason ?? (isTerminalPresented ? "Hide the terminal" : "Open a terminal in this task's worktree"))
            .accessibilityLabel(isTerminalPresented ? "Hide terminal" : "Open terminal")
            .accessibilityValue(isTerminalPresented ? "Shown" : "Hidden")
            .accessibilityIdentifier("toggle-terminal-button")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-command-row")
    }

    @ViewBuilder
    var taskSidebar: some View {
        if isTaskSidebarShownCollapsed {
            collapsedTaskSidebar
        } else {
            expandedTaskSidebar
        }
    }

    func setTaskSidebarCollapsed(_ collapsed: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            isTaskSidebarCollapsed = collapsed
        }
    }

    func toggleChangesSection() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isChangesSectionCollapsed.toggle()
        }
    }
    func diffBaselineLabel(_ entry: WorkspaceChangeEntry) -> String {
        entry.group == .unviewed && entry.hasViewedSnapshot ? "Since last viewed" : "Since branch base"
    }

    var mergeInProgressMessage: String {
        "Changes in \(changeInventory.mergingRepositories.map(repositoryLabel).joined(separator: ", ")) are hidden until the merge is committed or aborted."
    }

    var tooManyChangesMessage: String {
        "\(changeInventory.count) changed files is more than the \(Self.maxRenderedChangeCount) this list shows. Check for files that should be ignored, such as build output."
    }

    /// Shown in place of a repository's files while it has a merge open, since the merge stages
    /// everything the merged branch brought in.
    /// Composed only of plugin atoms (Plugins/Atoms).
    var mergeInProgressNotice: some View {
        // An explicit label: a combined element of these texts reads back with an empty label.
        AtomPanel(props: PanelProps(spacing: 8, fillOpacity: 0, align: "center"), common: AtomCommon(fillWidth: true, padding: 0)) {
            AtomIcon(props: IconProps(name: "arrow.triangle.merge", size: 20, color: "secondary"))
            AtomText(props: TextProps(text: "Merge in progress", size: 12, weight: "medium"))
            AtomText(props: TextProps(text: mergeInProgressMessage, size: 10, color: "secondary"))
        }
        .multilineTextAlignment(.center)
        .accessibilitySummary("Merge in progress. \(mergeInProgressMessage)", id: "workspace-changes-merge-in-progress")
    }

    func changeSection(title: String, entries: [WorkspaceChangeEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: title == "Viewed" ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(title == "Viewed" ? .green : .secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier(title == "Viewed" ? "viewed-changes-title" : "unviewed-changes-title")
                Text("\(entries.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if title == "Viewed" {
                    Image(systemName: isViewedSectionExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else if !entries.isEmpty {
                    Button {
                        Task { await markAllViewed() }
                    } label: {
                        Image(systemName: "checklist.checked")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 18)
                    }
                    .buttonStyle(.plain)
                    .buttonHoverPointer()
                    .nativeHelp("Mark all as viewed")
                    .accessibilityLabel("Mark all as viewed")
                    .accessibilityIdentifier("mark-all-viewed-button")
                }
            }
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
            .onTapGesture {
                if title == "Viewed" { isViewedSectionExpanded.toggle() }
            }
            // Without a container, the section identifier replaces the title's own.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(title == "Viewed" ? "viewed-changes-section" : "unviewed-changes-section")

            if title == "Viewed" && !isViewedSectionExpanded {
                EmptyView()
            } else if entries.isEmpty {
                Text("No files")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 31)
                    .padding(.vertical, 3)
            } else {
                let groups = repositoryGroups(entries)
                ForEach(groups, id: \.repository) { repositoryGroup in
                    if Set(changeInventory.unviewed.map(\.repository) + changeInventory.viewed.map(\.repository)).count > 1 {
                        Text(repositoryLabel(repositoryGroup.repository))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.leading, 17)
                            .padding(.top, 4)
                            .accessibilityIdentifier("workspace-repository-\(repositoryGroup.repository.hashValue)")
                    }
                    ForEach(repositoryGroup.entries) { entry in
                        HStack(spacing: 2) {
                            Button {
                                openDiff(entry)
                            } label: {
                                HStack(spacing: 7) {
                                Image(systemName: changeSymbol(for: entry.status))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(changeColor(for: entry.status))
                                    .frame(width: 12)
                                Text(entry.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(entry.isUncommitted ? Color.green : Color.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text(statusBadge(for: entry))
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(changeColor(for: entry.status))
                            }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                                .background(selectedChange?.id == entry.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonHoverPointer()
                            .buttonStyle(.plain)
                            .nativeHelp("View \(entry.group.displayName) diff for \(entry.path)")
                            .accessibilityLabel("\(entry.path), \(entry.status), \(entry.group.displayName)")
                            // The button is one accessibility element, so the name's color is reported here.
                            .accessibilityValue(entry.isUncommitted ? "Uncommitted, green" : "Committed, primary")
                            .accessibilityIdentifier("workspace-change-\(entry.group.rawValue)-\(entry.path)")
                            if entry.group == .unviewed {
                                Button {
                                    Task { await markViewed(entry) }
                                } label: {
                                    Image(systemName: "checkmark.circle")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, height: 22)
                                }
                                .buttonStyle(.plain)
                                .buttonHoverPointer()
                                .nativeHelp("Mark as viewed")
                                .accessibilityLabel("Mark \(entry.path) as viewed")
                                .accessibilityIdentifier("mark-viewed-\(entry.path)")
                            } else {
                                Button {
                                    Task { await markUnviewed(entry) }
                                } label: {
                                    Image(systemName: "arrow.uturn.backward.circle")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, height: 22)
                                }
                                .buttonStyle(.plain)
                                .buttonHoverPointer()
                                .nativeHelp("Mark as unviewed")
                                .accessibilityLabel("Mark \(entry.path) as unviewed")
                                .accessibilityIdentifier("mark-unviewed-\(entry.path)")
                            }
                        }
                        .padding(.horizontal, 7)
                    }
                }
            }
        }
    }

    func repositoryGroups(_ entries: [WorkspaceChangeEntry]) -> [ChangeRepositoryGroup] {
        Dictionary(grouping: entries, by: \.repository)
            .keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { repository in
                ChangeRepositoryGroup(repository: repository, entries: entries.filter { $0.repository == repository })
            }
    }

    func repositoryLabel(_ path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.suffix(2).joined(separator: "/")
    }

    func statusBadge(for entry: WorkspaceChangeEntry) -> String {
        if entry.statusCode == "??" { return "U" }
        if entry.statusCode.contains("R") { return "R" }
        if entry.statusCode.contains("A") { return "A" }
        if entry.statusCode.contains("D") { return "D" }
        if entry.status == "conflict" { return "!" }
        return "M"
    }

    func changeSymbol(for status: String) -> String {
        switch status {
        case "added", "untracked": "plus.square.fill"
        case "deleted": "minus.square.fill"
        case "renamed", "copied": "arrow.turn.up.right"
        case "conflict": "exclamationmark.triangle.fill"
        default: "doc.text"
        }
    }

    func changeColor(for status: String) -> Color {
        switch status {
        case "added", "untracked": .green
        case "deleted", "conflict": .red
        case "renamed", "copied": .orange
        default: .secondary
        }
    }
    func openDiff(_ entry: WorkspaceChangeEntry) {
        selectedChange = entry
        selectedDiff = nil
        isLoadingDiff = true
        diffError = nil
        monacoError = nil
        isMonacoReady = false
        monacoPresentation = nil
        diffChangeCount = nil
        withAnimation(.easeInOut(duration: 0.24)) {
            isDiffPresented = true
        }

        Task {
            do {
                let diff = try await workspaceManager.diff(
                    for: task.id,
                    repository: entry.repository,
                    path: entry.path,
                    group: entry.group.rawValue
                )
                guard selectedChange?.id == entry.id else { return }
                selectedDiff = diff
            } catch {
                guard selectedChange?.id == entry.id else { return }
                diffError = error.localizedDescription
            }
            if selectedChange?.id == entry.id { isLoadingDiff = false }
        }
    }

    func closeDiff() {
        withAnimation(.easeInOut(duration: 0.24)) {
            isDiffPresented = false
        }
    }

    func markViewed(_ entry: WorkspaceChangeEntry) async {
        do {
            try await workspaceManager.markViewed(for: task.id, repository: entry.repository, path: entry.path)
            await refreshWorkspaceChanges()
        } catch {
            changesError = error.localizedDescription
        }
    }

    func markUnviewed(_ entry: WorkspaceChangeEntry) async {
        do {
            try await workspaceManager.markUnviewed(for: task.id, repository: entry.repository, path: entry.path)
            await refreshWorkspaceChanges()
        } catch {
            changesError = error.localizedDescription
        }
    }

    func markAllViewed() async {
        do {
            _ = try await workspaceManager.markAllViewed(for: task.id)
            await refreshWorkspaceChanges()
        } catch {
            changesError = error.localizedDescription
        }
    }

    func refreshWorkspaceChanges() async {
        guard !isLoadingChanges else {
            changesNeedRefresh = true
            return
        }
        isLoadingChanges = true
        defer {
            isLoadingChanges = false
            hasLoadedChanges = true
        }

        repeat {
            changesNeedRefresh = false
            do {
                let inventory = try await workspaceManager.changes(for: task.id)
                changeInventory = inventory
                changesError = nil
                if let selectedChange {
                    if let current = (inventory.unviewed + inventory.viewed).first(where: { $0.id == selectedChange.id }) {
                        self.selectedChange = current
                        if isDiffPresented {
                            do {
                                let diff = try await workspaceManager.diff(
                                    for: task.id,
                                    repository: current.repository,
                                    path: current.path,
                                    group: current.group.rawValue
                                )
                                if self.selectedChange?.id == current.id {
                                    selectedDiff = diff
                                    diffError = nil
                                }
                            } catch {
                                if self.selectedChange?.id == current.id {
                                    selectedDiff = nil
                                    diffError = error.localizedDescription
                                }
                            }
                        }
                    } else {
                        self.selectedChange = nil
                        selectedDiff = nil
                        diffError = "This file no longer has a Git change."
                    }
                }
            } catch {
                changesError = error.localizedDescription
            }
        } while changesNeedRefresh
    }
    func showRepositoryPicker() {
        isShowingRepositoryPicker = true
        loadRecentRepositories()
        if suggestedRepositories.isEmpty { loadSuggestedRepositories() }
    }

    func repositorySettingsPopover(_ repository: RepositoryWorktreeRecord, name: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(name).font(.system(size: 15, weight: .semibold))
                .allowsHitTesting(false)
                .accessibilityIdentifier("conversation-repository-settings-title")
            VStack(alignment: .leading, spacing: 8) {
                repositoryDetailRow("Branch name", value: $editedBranch, field: "branch", placeholder: "auto", identifier: "conversation-repository-branch", repository: repository)
                repositoryDetailRow("Branch from", value: $editedBranchFrom, field: "from", placeholder: "default", identifier: "conversation-repository-branch-from", repository: repository)
                repositoryDetailRow("Merge to", value: $editedMergeTarget, field: "to", placeholder: "default", identifier: "conversation-repository-merge-target", repository: repository)
            }
            if !repository.isPending {
                Text("Settings are locked after the task starts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("conversation-repository-settings-locked")
            }
        }
        .font(.system(size: 13))
        .padding(18)
        .frame(width: 360, alignment: .leading)
        // A click anywhere outside the field being edited dismisses the edit unsaved.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { cancelRepositoryFieldEdit(repository) }
        )
    }

    var repositoryPicker: some View {
        let available = pickerRepositories
        return RepositoryPickerView(
            model: RepositoryPickerModel(
                parentFolder: WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath)?.path,
                isChoosingParent: isChoosingRepositoryParent,
                placeholder: repositorySearchPlaceholder,
                search: repositorySearch,
                isListingRecent: isShowingRecentRepositories,
                repositories: available,
                highlighted: repositorySuggestionIndex,
                focusesSearch: isNewTask,
                canSubmit: isUsingSavedRepositoryDefault || available.indices.contains(repositorySuggestionIndex),
                canReplace: !task.repositoryWorktrees.isEmpty
            ),
            actions: RepositoryPickerActions(
                chooseParent: { chooseRepositoryParentFolder() },
                search: { repositorySearch = $0 },
                arrow: { direction in
                    let available = pickerRepositories
                    guard !available.isEmpty else { return }
                    didOverrideRepositoryDefault = true
                    repositorySuggestionIndex = direction == "down"
                        ? min(repositorySuggestionIndex + 1, available.count - 1)
                        : max(repositorySuggestionIndex - 1, 0)
                },
                submit: {
                    let available = pickerRepositories
                    if isUsingSavedRepositoryDefault {
                        let savedRepositories = validLastSelectedRepositoryURLs
                        guard !savedRepositories.isEmpty else { return }
                        selectRepositories(savedRepositories)
                    } else if available.indices.contains(repositorySuggestionIndex) {
                        selectRepositorySuggestion(available[repositorySuggestionIndex])
                    }
                },
                select: { path in
                    guard let repository = pickerRepositories.first(where: { $0.path == path }) else { return }
                    selectRepositorySuggestion(repository)
                },
                replace: { path in
                    guard let repository = pickerRepositories.first(where: { $0.path == path }) else { return }
                    replaceRepositories(with: repository)
                }
            )
        )
    }

    func replaceRepositories(with repository: URL) {
        didOverrideRepositoryDefault = true
        isShowingRepositoryPicker = false
        repositorySearch = ""
        Task { @MainActor in
            do {
                let path = repository.standardizedFileURL.path
                _ = try await WorkspaceManager(
                    taskManager: BoardTaskManager(modelContext: modelContext)
                ).replaceRepositories([path], on: task.id)
                repositoryBeingEdited = nil
                errorMessage = nil
                if FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path) {
                    try WorkspaceSettingsManager().setLastSelectedRepositories([path])
                }
                loadRecentRepositories()
                await refreshWorkspaceChanges()
            } catch {
                errorMessage = "Couldn't replace repositories: \(error.localizedDescription)"
                isShowingRepositoryPicker = true
            }
        }
    }

    var repositorySearchPlaceholder: String {
        guard isNewTask, !lastSelectedRepositoryPaths.isEmpty else { return "Search repositories…" }
        let names = lastSelectedRepositoryPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        return "\(names.joined(separator: ", ")) ↵"
    }

    var isUsingSavedRepositoryDefault: Bool {
        isNewTask && task.repositoryWorktrees.isEmpty &&
        repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !didOverrideRepositoryDefault && !lastSelectedRepositoryPaths.isEmpty
    }

    var validLastSelectedRepositoryURLs: [URL] {
        lastSelectedRepositoryPaths.compactMap { path in
            let repository = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let gitMarker = repository.appendingPathComponent(".git")
            return FileManager.default.fileExists(atPath: gitMarker.path) ? repository : nil
        }
    }

    /// Before anything is typed the picker offers recently used repositories, newest first;
    /// typing switches to searching every repository under the suggestion folder.
    var isShowingRecentRepositories: Bool {
        repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !recentRepositoryPaths.isEmpty
    }

    var pickerRepositories: [URL] {
        isShowingRecentRepositories
            ? recentRepositoryPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            : availableRepositorySuggestions
    }

    var availableRepositorySuggestions: [URL] {
        suggestedRepositories.filter { candidate in
            !task.repositoryWorktrees.contains(where: { URL(fileURLWithPath: $0.repositoryPath).standardizedFileURL.path == candidate.standardizedFileURL.path }) &&
            (repositorySearch.isEmpty || candidate.lastPathComponent.localizedCaseInsensitiveContains(repositorySearch) || candidate.path.localizedCaseInsensitiveContains(repositorySearch))
        }
    }

    func selectRepositorySuggestion(_ repository: URL) {
        didOverrideRepositoryDefault = true
        selectRepositories([repository])
    }

    func selectRepositories(
        _ repositories: [URL],
        reopenPickerOnError: Bool = true,
        isApplyingDefault: Bool = false
    ) {
        isShowingRepositoryPicker = false
        repositorySearch = ""
        if isApplyingDefault { isApplyingSavedRepositories = true }
        Task { @MainActor in
            defer {
                if isApplyingDefault { isApplyingSavedRepositories = false }
            }
            do {
                var selectedPaths = task.repositoryWorktrees.map { $0.repositoryPath }
                var repositoriesToAdd: [String] = []
                let manager = BoardTaskManager(modelContext: modelContext)
                for repository in repositories {
                    let path = repository.standardizedFileURL.path
                    guard !selectedPaths.contains(path) else { continue }
                    selectedPaths.append(path)
                    repositoriesToAdd.append(path)
                }
                if !repositoriesToAdd.isEmpty {
                    _ = try await manager.addRepositories(task.id, repositoryPaths: repositoriesToAdd)
                }
                let availablePaths = selectedPaths.filter { path in
                    FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path)
                }
                try WorkspaceSettingsManager().setLastSelectedRepositories(availablePaths)
                loadRecentRepositories()
                await refreshWorkspaceChanges()
            } catch {
                errorMessage = "Couldn't add repository: \(error.localizedDescription)"
                isShowingRepositoryPicker = reopenPickerOnError
            }
        }
    }

    func loadRecentRepositories() {
        guard !task.isStandaloneChat else { return }
        recentRepositoryPaths = (try? WorkspaceManager(
            taskManager: BoardTaskManager(modelContext: modelContext)
        ).recentRepositorySuggestions(for: task.id)) ?? []
    }

    func loadSuggestedRepositories() {
        guard let parent = WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath) else { return }
        Task {
            suggestedRepositories = (try? await WorkspaceManager().suggestedRepositories(parentPath: parent.path).map {
                URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
            }) ?? []
        }
    }

    func chooseRepositoryParentFolder(showRepositoryPickerWhenFinished: Bool = true) {
        guard !isChoosingRepositoryParent else { return }
        isShowingRepositoryPicker = false
        let panel = NSOpenPanel()
        panel.title = "Choose repository root folder"
        panel.message = "Playhouse will search below this folder for repositories. A root folder is required before sending conversations."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        isChoosingRepositoryParent = true
        panel.begin { response in
            DispatchQueue.main.async {
                isChoosingRepositoryParent = false
                guard response == .OK, let selected = panel.url else {
                    isShowingRepositoryPicker = showRepositoryPickerWhenFinished
                    return
                }
                let path = selected.standardizedFileURL.path
                do {
                    try WorkspaceSettingsManager().setDefaultParentFolder(path)
                    defaultParentFolderPath = path
                    loadSuggestedRepositories()
                    isShowingRepositoryPicker = showRepositoryPickerWhenFinished
                } catch {
                    errorMessage = "Couldn't set the repository suggestion folder: \(error.localizedDescription)"
                    isShowingRepositoryPicker = showRepositoryPickerWhenFinished
                }
            }
        }
    }
}
