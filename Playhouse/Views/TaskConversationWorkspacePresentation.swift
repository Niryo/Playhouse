import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

extension TaskConversationView {
    package func setTerminalPresented(_ presented: Bool) {
        if presented { terminalSession.startIfNeeded(taskID: task.id, workspaceManager: workspaceManager) }
        phWithAnimation(.easeOut(duration: 0.22)) { isTerminalPresented = presented }
    }

    /// The panel's left border; dragging it left widens the terminal and right narrows it.
    package func terminalResizeHandle(width: CGFloat, available: CGFloat) -> some PHView {
        AtomOverlay {
            AtomStack(props: StackProps(fill: "primary", fillOpacity: 0.08), common: AtomCommon(width: 1, fillHeight: true)) {
                PHEmptyView()
            }
        } overlay: {
            // The handle holds the resize cursor for the whole drag, and ends it when a panel
            // closed mid-drag takes the handle away.
            AtomResizeHandle(
                common: AtomCommon(testID: "terminal-resize-handle", label: "Resize terminal", value: "\(Int(width.rounded())) points", width: 17),
                onDrag: { translation in
                    let start = terminalResizeStartWidth ?? width
                    terminalResizeStartWidth = start
                    terminalPanelWidth = Double(TerminalPanelLayout.clampedWidth(start - CGFloat(translation), available: available))
                },
                onDragEnd: { terminalResizeStartWidth = nil }
            )
        }
    }

    package static let expandedSidebarWidth: CGFloat = 232
    package static let collapsedSidebarWidth: CGFloat = 38

    /// The width the terminal panel can float over: the conversation, beside the sidebar and its divider.
    package func conversationWidth(in containerWidth: CGFloat) -> CGFloat {
        containerWidth - (isTaskSidebarShownCollapsed ? Self.collapsedSidebarWidth : Self.expandedSidebarWidth) - 1
    }

    /// Why this task can't open a terminal yet, shared with the CLI's `task terminal`.
    package var terminalUnavailableReason: String? {
        TaskTerminalLaunch.unavailableReason(for: task.repositoryWorktrees)
    }

    /// Quick actions for the task, right-aligned along the bottom of the sidebar.
    package var sidebarCommandRow: some PHView {
        let unavailable = terminalUnavailableReason != nil && !isTerminalPresented
        return AtomStack(
            props: StackProps(axis: "h", spacing: 4, group: true),
            common: AtomCommon(testID: "sidebar-command-row", paddingX: 10, paddingY: 6)
        ) {
            AtomSpacer(props: SpacerProps(minLength: 0))
            PluginSlot(placement: .conversationToolbar, props: pluginProps, actions: pluginActions, open: { openConversationPlugin = $0 }, add: startPluginTask)
            sidebarSkillsButton
            AtomButton(
                props: ButtonProps(disabled: unavailable, shortcut: AppShortcut.terminal),
                common: AtomCommon(
                    testID: "toggle-terminal-button",
                    label: isTerminalPresented ? "Hide terminal" : "Open terminal",
                    value: isTerminalPresented ? "Shown" : "Hidden",
                    help: terminalUnavailableReason ?? (isTerminalPresented ? "Hide the terminal" : "Open a terminal in this task's worktree")
                ),
                action: { setTerminalPresented(!isTerminalPresented) }
            ) {
                sidebarToolIcon(.terminal, isActive: isTerminalPresented, dimmed: unavailable)
            }
        }
    }

    /// Opens the Skills, Rules & MCP page; beside the terminal button, styled like it.
    package var sidebarSkillsButton: some PHView {
        AtomButton(
            props: ButtonProps(shortcut: AppShortcut.skills),
            common: AtomCommon(testID: "open-skills-button", label: "Skills", help: "Skills, Rules & MCP"),
            action: { openSkillsPage(focus: nil) }
        ) {
            sidebarToolIcon(.sparkles, isActive: isShowingSkills)
        }
    }

    /// A sidebar command's symbol: accent on a faint accent tile while its panel shows,
    /// faded while it can't be used.
    private func sidebarToolIcon(_ icon: PHIcon, isActive: Bool, dimmed: Bool = false) -> some PHView {
        AtomStack(
            props: StackProps(fill: isActive ? "themeAccent" : "clear", fillOpacity: isActive ? 0.14 : nil, cornerRadius: 5),
            common: AtomCommon(width: 26, height: 24)
        ) {
            AtomIcon(
                props: IconProps(name: icon.name, size: 12, weight: "medium", color: isActive && !dimmed ? "themeAccent" : "secondary"),
                common: AtomCommon(opacity: dimmed ? 0.35 : nil)
            )
        }
    }

    @PHViewBuilder
    package var taskSidebar: some PHView {
        if isTaskSidebarShownCollapsed {
            collapsedTaskSidebar
        } else {
            expandedTaskSidebar
        }
    }

    package func setTaskSidebarCollapsed(_ collapsed: Bool) {
        phWithAnimation(.easeInOut(duration: 0.18)) {
            isTaskSidebarCollapsed = collapsed
        }
    }

    package func diffBaselineLabel(_ entry: WorkspaceChangeEntry) -> String {
        entry.group == .unviewed && entry.hasViewedSnapshot ? "Since last viewed" : "Since branch base"
    }

    package func repositoryLabel(_ path: String) -> String {
        WorkspaceChangeStyle.repositoryLabel(path)
    }

    package func changeSymbol(for status: String) -> String {
        WorkspaceChangeStyle.symbol(for: status)
    }

    package func changeColor(for status: String) -> PHAnyShapeStyle {
        AtomColor.style(WorkspaceChangeStyle.colorName(for: status)) ?? PHAnyShapeStyle(.secondary)
    }

    package func openDiff(_ entry: WorkspaceChangeEntry) {
        selectedChange = entry
        selectedDiff = nil
        isLoadingDiff = true
        diffError = nil
        monacoError = nil
        isMonacoReady = false
        monacoPresentation = nil
        diffChangeCount = nil
        phWithAnimation(.easeInOut(duration: 0.24)) {
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

    package func closeDiff() {
        phWithAnimation(.easeInOut(duration: 0.24)) {
            isDiffPresented = false
        }
    }

    /// The task's folders may have changed: tells the sidebar's inline plugins (the
    /// Changes plugin rescans on `workspace.revision`) and refreshes the open diff.
    package func refreshWorkspaceChanges() async {
        workspaceRevision &+= 1
        // Only an open diff needs the window's own rescan; the sidebar's plugins rescan on the revision.
        guard selectedChange != nil, isDiffPresented else { return }
        guard !isRefreshingOpenDiff else {
            openDiffNeedsRefresh = true
            return
        }
        isRefreshingOpenDiff = true
        defer { isRefreshingOpenDiff = false }

        repeat {
            openDiffNeedsRefresh = false
            guard let selectedChange,
                  let inventory = try? await workspaceManager.changes(for: task.id) else { continue }
            guard let current = (inventory.unviewed + inventory.viewed).first(where: { $0.id == selectedChange.id }) else {
                self.selectedChange = nil
                selectedDiff = nil
                diffError = "This file no longer has a Git change."
                continue
            }
            self.selectedChange = current
            guard isDiffPresented else { continue }
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
        } while openDiffNeedsRefresh
    }
    package func showRepositoryPicker() {
        isShowingRepositoryPicker = true
        loadRecentRepositories()
        if suggestedRepositories.isEmpty { loadSuggestedRepositories() }
    }

    package func repositorySettingsPopover(_ repository: RepositoryWorktreeRecord, name: String) -> some PHView {
        return AtomOverlay(props: OverlayProps(behind: true, group: false)) {
            AtomStack(
                props: StackProps(spacing: 14, align: "leading"),
                common: AtomCommon(width: 360, frameAlign: "leading", paddingX: 18, paddingY: 18)
            ) {
                AtomText(
                    props: TextProps(text: name, size: 15, weight: "semibold"),
                    common: AtomCommon(testID: "conversation-repository-settings-title", passThrough: true)
                )
                AtomStack(props: StackProps(spacing: 8, align: "leading")) {
                    repositoryDetailRow("Branch name", value: $editedBranch, field: "branch", placeholder: "auto", identifier: "conversation-repository-branch", repository: repository)
                    repositoryDetailRow("Branch from", value: $editedBranchFrom, field: "from", placeholder: "default", identifier: "conversation-repository-branch-from", repository: repository)
                    repositoryDetailRow("Merge to", value: $editedMergeTarget, field: "to", placeholder: "default", identifier: "conversation-repository-merge-target", repository: repository)
                    if let number = repository.pullRequestNumber {
                        repositoryPullRequestRow(repository, number: number)
                    }
                }
                if !repository.isPending {
                    AtomText(
                        props: TextProps(text: "Settings are locked after the task starts.", size: 11, color: "secondary"),
                        common: AtomCommon(testID: "conversation-repository-settings-locked", passThrough: true)
                    )
                }
                if !isReadOnly {
                    AtomDivider()
                    // Another worktree of this repository, on its own branch, for a separate pull request.
                    AtomStack(props: StackProps(spacing: 6, align: "leading")) {
                        AtomText(props: TextProps(text: "Another worktree", size: 11, weight: "semibold", color: "secondary"), common: AtomCommon(passThrough: true))
                        AtomStack(props: StackProps(axis: "h", spacing: 8)) {
                            AtomTextField(
                                props: TextFieldProps(text: newWorktreeBranch, placeholder: "Branch (auto)", size: 13),
                                common: AtomCommon(testID: "conversation-repository-new-worktree-branch"),
                                onChange: { newWorktreeBranch = $0 },
                                onSubmit: { addConversationWorktree(repository) }
                            )
                            AtomButton(
                                props: ButtonProps(style: "automatic", disabled: isAddingWorktree),
                                common: AtomCommon(
                                    testID: "conversation-repository-add-worktree-button", label: "Add worktree",
                                    help: "Add another worktree of \(name) on its own branch"
                                ),
                                action: { addConversationWorktree(repository) }
                            ) {
                                if isAddingWorktree {
                                    AtomSpinner(props: SpinnerProps(size: "small"))
                                } else {
                                    AtomText(props: TextProps(text: "Add worktree", size: 13))
                                }
                            }
                        }
                    }
                }
            }
        } overlay: {
            // Clicking an empty area dismisses an edit without taking focus from the fields.
            AtomStack(
                props: StackProps(fill: "clear", hitSurface: true),
                common: AtomCommon(fillWidth: true, fillHeight: true, decorative: true)
            ) {}
            .onTapGesture { cancelRepositoryFieldEdit(repository) }
            // no-pointer: a click in otherwise empty space dismisses the edit.
        }
    }

    package var repositoryPicker: some PHView {
        let available = pickerRepositories
        return RepositoryPickerView(
            model: RepositoryPickerModel(
                parentFolder: WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath)?.path,
                isChoosingParent: repositoryParentPanel != nil,
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

    package func replaceRepositories(with repository: URL) {
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

    package var repositorySearchPlaceholder: String {
        guard isNewTask, !lastSelectedRepositoryPaths.isEmpty else { return "Search repositories…" }
        let names = lastSelectedRepositoryPaths.map { URL(fileURLWithPath: $0).lastPathComponent }
        return "\(names.joined(separator: ", ")) ↵"
    }

    package var isUsingSavedRepositoryDefault: Bool {
        isNewTask && task.repositoryWorktrees.isEmpty &&
        repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !didOverrideRepositoryDefault && !lastSelectedRepositoryPaths.isEmpty
    }

    package var validLastSelectedRepositoryURLs: [URL] {
        lastSelectedRepositoryPaths.compactMap { path in
            let repository = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            let gitMarker = repository.appendingPathComponent(".git")
            return FileManager.default.fileExists(atPath: gitMarker.path) ? repository : nil
        }
    }

    /// Before anything is typed the picker offers recently used repositories, newest first;
    /// typing switches to searching every repository under the suggestion folder.
    package var isShowingRecentRepositories: Bool {
        repositorySearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !recentRepositoryPaths.isEmpty
    }

    package var pickerRepositories: [URL] {
        isShowingRecentRepositories
            ? recentRepositoryPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            : availableRepositorySuggestions
    }

    package var availableRepositorySuggestions: [URL] {
        suggestedRepositories.filter { candidate in
            !task.repositoryWorktrees.contains(where: { URL(fileURLWithPath: $0.repositoryPath).standardizedFileURL.path == candidate.standardizedFileURL.path }) &&
            (repositorySearch.isEmpty || candidate.lastPathComponent.localizedCaseInsensitiveContains(repositorySearch) || candidate.path.localizedCaseInsensitiveContains(repositorySearch))
        }
    }

    package func selectRepositorySuggestion(_ repository: URL) {
        didOverrideRepositoryDefault = true
        selectRepositories([repository])
    }

    package func selectRepositories(
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

    package func loadRecentRepositories() {
        guard !task.isStandaloneChat else { return }
        recentRepositoryPaths = (try? WorkspaceManager(
            taskManager: BoardTaskManager(modelContext: modelContext)
        ).recentRepositorySuggestions(for: task.id)) ?? []
    }

    package func loadSuggestedRepositories() {
        guard let parent = WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath) else { return }
        Task {
            let repositories = (try? await WorkspaceManager().suggestedRepositories(parentPath: parent.path).map {
                URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
            }) ?? []
            // Loads can finish out of order; a slower one for a folder since replaced must not
            // overwrite the current folder's list.
            guard WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath)?.path == parent.path else { return }
            suggestedRepositories = repositories
        }
    }

    package func chooseRepositoryParentFolder() {
        if let openPanel = repositoryParentPanel {
            // The panel doesn't block the window, so the window can come back over it (a click on
            // the window, or the picker's popover closing). Bring it back to the front; if it never
            // showed, drop it so this click opens a new one.
            if openPanel.isVisible {
                openPanel.bringToFront()
                return
            }
            repositoryParentPanel = nil
        }
        let closesPicker = isShowingRepositoryPicker
        isShowingRepositoryPicker = false
        let startingDirectory = WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath)
        // Held until the panel opens, so the picker reads as choosing and a newer request replaces it.
        let pending = PendingFileChooserPanel()
        repositoryParentPanel = pending
        Task { @MainActor in
            // The closing popover hands the key window back to the conversation window, which
            // would cover a panel opened meanwhile, so open it once the picker has gone.
            if closesPicker { try? await Task.sleep(for: .milliseconds(300)) }
            guard repositoryParentPanel === pending else { return }
            var panel: (any FileChooserPanel)?
            panel = SuggestionsFolderPrompt.chooseFolder(startingAt: startingDirectory) { selected in
                DispatchQueue.main.async {
                    // A panel replaced by a newer one reports nothing.
                    guard let panel, repositoryParentPanel === panel else { return }
                    repositoryParentPanel = nil
                    guard let selected else {
                        isShowingRepositoryPicker = true
                        return
                    }
                    let path = selected.standardizedFileURL.path
                    do {
                        try WorkspaceSettingsManager().setDefaultParentFolder(path)
                        // Changing the folder clears and reloads the suggestions (`TaskConversationView`).
                        defaultParentFolderPath = path
                        isShowingRepositoryPicker = true
                    } catch {
                        errorMessage = "Couldn't set the repository suggestion folder: \(error.localizedDescription)"
                        isShowingRepositoryPicker = true
                    }
                }
            }
            repositoryParentPanel = panel
        }
    }
}

/// Stands for an open panel that hasn't opened yet.
private final class PendingFileChooserPanel: FileChooserPanel {
    var isVisible: Bool { false }
    func bringToFront() {}
}
