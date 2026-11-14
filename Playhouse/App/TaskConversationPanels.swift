import AppKit
import SwiftData
import SwiftUI

extension TaskConversationView {
    var collapsedTaskSidebar: some View {
        VStack(spacing: 8) {
            Button {
                setTaskSidebarCollapsed(false)
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
            }
            .buttonHoverPointer()
            .buttonStyle(.plain)
            .nativeHelp("Show sidebar")
            .accessibilityLabel("Show sidebar")
            .accessibilityIdentifier("show-task-sidebar-button")

            if !changeInventory.unviewed.isEmpty {
                Text("\(changeInventory.unviewed.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Changes to review: \(changeInventory.unviewed.count)")
                    .accessibilityIdentifier("collapsed-task-sidebar-count")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 12)
        .frame(width: Self.collapsedSidebarWidth)
        .frame(maxHeight: .infinity)
        .background(WorkspaceTheme.panelBackground.opacity(0.62))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-sidebar-collapsed")
    }

    var expandedTaskSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    setTaskSidebarCollapsed(true)
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 24)
                }
                .buttonHoverPointer()
                .buttonStyle(.plain)
                .nativeHelp("Hide sidebar")
                .accessibilityLabel("Hide sidebar")
                .accessibilityIdentifier("hide-task-sidebar-button")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 6)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            // Plugins lead the sidebar's sections, above Changes.
            PluginSlot(placement: .conversationSidebar, props: pluginProps, actions: pluginActions, open: { openConversationPlugin = $0 }, add: startPluginTask)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            changesSectionHeader

            if isChangesSectionCollapsed {
                Spacer(minLength: 0)
            } else {
                changesSectionContent
            }

            Spacer(minLength: 0)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            sidebarCommandRow
        }
        .frame(width: Self.expandedSidebarWidth)
        .frame(maxHeight: .infinity)
        .background(WorkspaceTheme.panelBackground.opacity(0.62))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-sidebar")
    }

    /// The Changes section's header; collapsing hides its lists so later sidebar sections
    /// can share the column, and the pending count stays visible while it's collapsed.
    var changesSectionHeader: some View {
        HStack(spacing: 6) {
            Button {
                toggleChangesSection()
            } label: {
                Image(systemName: isChangesSectionCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 24)
                    // A plain button only hit-tests drawn pixels; the full frame keeps the target usable.
                    .contentShape(Rectangle())
            }
            .buttonHoverPointer()
            .buttonStyle(.plain)
            .nativeHelp(isChangesSectionCollapsed ? "Expand changes" : "Collapse changes")
            .accessibilityLabel(isChangesSectionCollapsed ? "Expand changes" : "Collapse changes")
            .accessibilityValue(isChangesSectionCollapsed ? "Collapsed" : "Expanded")
            .accessibilityIdentifier("toggle-workspace-changes-section-button")
            Text("Changes")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityIdentifier("workspace-changes-title")
                .onTapGesture { toggleChangesSection() }
            if isChangesSectionCollapsed && !changeInventory.unviewed.isEmpty {
                Text("\(changeInventory.unviewed.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Changes to review: \(changeInventory.unviewed.count)")
                    .accessibilityIdentifier("collapsed-workspace-changes-section-count")
            }
            Spacer(minLength: 0)
                .contentShape(Rectangle())
                .onTapGesture { toggleChangesSection() }
            Button {
                Task { await refreshWorkspaceChanges() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonHoverPointer()
            .buttonStyle(.plain)
            .nativeHelp("Refresh workspace changes")
            .accessibilityLabel("Refresh workspace changes")
            .accessibilityIdentifier("refresh-workspace-changes-button")
            .disabled(!hasLoadedChanges)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-changes-section-header")
    }

    @ViewBuilder
    var changesSectionContent: some View {
        if let changesError {
            VStack(alignment: .leading, spacing: 8) {
                Label("Couldn't read Git changes", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                Text(changesError)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") {
                    Task { await refreshWorkspaceChanges() }
                }
                .buttonHoverPointer()
                .nativeHelp("Retry")
                .font(.system(size: 11, weight: .medium))
                .accessibilityIdentifier("retry-workspace-changes-button")
            }
            .padding(12)
            .accessibilityIdentifier("workspace-changes-error")
        } else if !hasLoadedChanges {
            ProgressView("Checking folders…")
                .controlSize(.small)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("workspace-changes-loading")
        } else if changeInventory.isEmpty && !changeInventory.mergingRepositories.isEmpty {
            mergeInProgressNotice
                .padding(15)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if changeInventory.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                Text("No changes")
                    .font(.system(size: 12, weight: .medium))
                Text("Changes in Git repositories under this task's folders will appear here.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(15)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("workspace-changes-empty")
        } else if changeInventory.count > Self.maxRenderedChangeCount {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                Text("Too many changes to list")
                    .font(.system(size: 12, weight: .medium))
                Text(tooManyChangesMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(15)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // An explicit label: a combined element of these texts reads back with an empty label.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Too many changes to list. \(tooManyChangesMessage)")
            .accessibilityIdentifier("workspace-changes-too-many")
        } else {
            ScrollView {
                // Lazy so off-screen rows stay out of the view tree; every row carries AppKit tooltip views.
                LazyVStack(alignment: .leading, spacing: 15) {
                    if !changeInventory.mergingRepositories.isEmpty {
                        mergeInProgressNotice
                            .padding(.horizontal, 14)
                    }
                    changeSection(title: "Viewed", entries: changeInventory.viewed)
                    changeSection(title: "Changes", entries: changeInventory.unviewed)
                }
                .padding(.vertical, 12)
                .hoverRevealScrollers()
            }
            .accessibilityIdentifier("workspace-changes-list")
        }
    }

    /// A Viewed row always shows the reviewed work from the branch base; only a change made
    /// after that review is measured from the saved snapshot.

    var conversationPanel: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                if task.authoringPluginID != nil {
                    HStack {
                        Button(action: saveAndBack) {
                            Image(systemName: "chevron.backward")
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .buttonHoverPointer()
                        .nativeHelp("Back to Kanban")
                        .accessibilityLabel("Back to Kanban board")
                        .accessibilityIdentifier("back-to-board-button")
                        Text("Plugin editor")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer()
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 15)
                } else {
                    conversationHeader
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)

                safetyNotice

                // An agent's conversation covers this one; laying out the hidden
                // transcript underneath it would only cost time.
                if selectedSubagent == nil {
                    conversation
                } else {
                    Spacer(minLength: 0)
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)

                if isReadOnly {
                    Label("Archived conversation · read only", systemImage: "lock.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .accessibilityIdentifier("archived-conversation-read-only")
                } else {
                    if task.status == .done {
                        // A Done task keeps its conversation; a follow-up reopens it in fresh worktrees.
                        Label(archivedFollowUpHint, systemImage: "archivebox")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                            .accessibilityIdentifier("archived-conversation-follow-up-hint")
                    }
                    ComposerDraftScope { composer }
                }
            }
            .accessibilityHidden(selectedSubagent != nil)
            // The final answer folds this turn's activity, agents included, into
            // Worked for, even while an agent's conversation covers the transcript.
            .onChange(of: hasCompletedAssistantResponse) { _, hasCompletedResponse in
                if hasCompletedResponse {
                    isActivityExpanded = false
                }
            }
            // A turn in flight shows its progress instead of burying it behind
            // "Working for". Settling folds the section away again whether the
            // turn answered, was stopped, or was interrupted, so the result
            // reads cleanly. A collapse the reader performs mid-turn stays
            // collapsed, because this fires on the active/settled transition
            // rather than on each message or activity update.
            //
            // `initial` is for a task opened while its turn already runs; the
            // first evaluation still reads the default `isResponding`, so the
            // expansion actually lands when `loadHistory` raises it.
            //
            // One provider difference rides on `hasCompletedAssistantResponse`
            // rather than on this rule: Claude persists `final_answer` on its
            // answer, while a Codex `agentMessage` read back from history does
            // not, so between a Codex final answer and its turn completion a
            // task reopened from persisted history keeps the section open where
            // Claude's would have folded. The window's own stream marks the
            // phase for both, so this only shows on a reload inside that window.
            .onChange(of: isDisplayingActiveResponse, initial: true) { _, isActive in
                isActivityExpanded = isActive
            }

            if isDiffPresented {
                fileDiffOverlay
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }

            if let selectedSubagent {
                subagentConversation(selectedSubagent)
                    .transition(.move(edge: .trailing))
                    .zIndex(2)
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.24), value: isDiffPresented)
        .onExitCommand {
            if isDiffPresented { closeDiff() }
        }
    }

    var fileDiffOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Button(action: closeDiff) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonHoverPointer()
                .buttonStyle(.plain)
                .nativeHelp("Close diff")
                .accessibilityLabel("Close diff")
                .accessibilityIdentifier("close-workspace-diff-button")

                if let selectedChange {
                    Image(systemName: changeSymbol(for: selectedChange.status))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(changeColor(for: selectedChange.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedChange.path)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("workspace-diff-title")
                        Text("\(repositoryLabel(selectedChange.repository)) · \(diffBaselineLabel(selectedChange))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("workspace-diff-source")
                    }
                } else {
                    Text("File diff")
                        .font(.system(size: 12, weight: .semibold))
                }

                Spacer(minLength: 0)
                if selectedDiff?.isText == true {
                    Text(isMonacoReady ? "Side-by-side" : "Starting editor")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("workspace-diff-editor-status")
                        .accessibilityValue(monacoStartupDescription)
                    if isMonacoReady {
                        Text(diffHighlightStatus)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(diffChangeCount.map { $0 > 0 ? Color.green : Color.secondary } ?? Color.secondary)
                            .accessibilityIdentifier("workspace-diff-highlight-status")
                    }
                }
                Text("READ ONLY")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceTheme.windowBackground)

            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(height: 1)

            Group {
                if isLoadingDiff {
                    ProgressView("Loading file diff…")
                        .controlSize(.small)
                        .accessibilityIdentifier("workspace-diff-loading")
                } else if let diffError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(diffError)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .accessibilityIdentifier("workspace-diff-error")
                } else if let selectedDiff, selectedDiff.isText {
                    if let monacoError {
                        VStack(spacing: 9) {
                            Text(monacoError)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Reload editor") {
                                isMonacoReady = false
                                diffChangeCount = nil
                                self.monacoError = nil
                                // Clearing the diff first takes the shared editor out of the
                                // view tree; resetting alone can't replace a hosted NSView.
                                self.selectedDiff = nil
                                MonacoDiffWebViewHost.shared.reset()
                                if let selectedChange { openDiff(selectedChange) }
                            }
                            .buttonHoverPointer()
                            .nativeHelp("Reload editor")
                            .font(.system(size: 11, weight: .medium))
                        }
                        .padding(24)
                    } else {
                        ZStack {
                            MonacoDiffEditor(
                                diff: selectedDiff,
                                theme: colorScheme == .dark ? "vs-dark" : "vs",
                                isReady: $isMonacoReady,
                                loadError: $monacoError,
                                diffChangeCount: $diffChangeCount,
                                presentation: $monacoPresentation
                            )
                            .accessibilityIdentifier("workspace-diff-editor")

                            if !isMonacoReady {
                                ProgressView("Starting Monaco…")
                                    .controlSize(.small)
                                    .padding(12)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                    .accessibilityIdentifier("workspace-diff-editor-loading")
                            }
                        }
                    }
                } else if let selectedDiff {
                    VStack(spacing: 9) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text(selectedDiff.message ?? "This file can't be shown as a text diff.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("workspace-diff-unsupported")
                    }
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WorkspaceTheme.inputBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WorkspaceTheme.windowBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-diff-overlay")
        .background(EscapeKeyMonitor(onEscape: closeDiff).frame(width: 0, height: 0))
    }


    var conversationHeader: some View {
        HStack(spacing: 12) {
            Button(action: saveAndBack) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonHoverPointer()
            .buttonStyle(.plain)
            .nativeHelp("Back to Kanban")
            .accessibilityLabel("Back to Kanban board")
            .accessibilityIdentifier("back-to-board-button")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if isGeneratingTitle || task.title == "Generating title…" {
                        HStack(spacing: 7) {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityIdentifier("task-title-generating-loader")
                            Text("Generating title…")
                        }
                        .accessibilityIdentifier("task-title-generating")
                    } else {
                        HStack(spacing: 6) {
                            Text(task.title)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                                .accessibilityIdentifier("task-view-title")

                            // The task title becomes the pull request title, so it can be copied as-is.
                            Button(action: copyTaskTitle) {
                                Image(systemName: didCopyTaskTitle ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11, weight: .medium))
                                    .frame(width: 22, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonHoverPointer()
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .nativeHelp("Copy title")
                            .accessibilityLabel(didCopyTaskTitle ? "Title copied" : "Copy title")
                            .accessibilityIdentifier("task-view-title-copy-button")
                        }
                    }

                    Spacer(minLength: 8)

                    if !task.isStandaloneChat {
                        repositoryBadges
                    }
                }

                if !task.isStandaloneChat {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(task.status.accent)
                            .frame(width: 6, height: 6)
                        Text(task.status.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("task-header-status")
                    if let statusMessage = task.statusMessage, !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.system(size: 10))
                            .foregroundStyle(task.status == .blocked ? Color.red : Color.secondary)
                            .lineLimit(3)
                            .accessibilityIdentifier("task-status-message")
                    }
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspaceTheme.windowBackground.opacity(0.96))
    }

    func copyTaskTitle() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(task.title, forType: .string)
        didCopyTaskTitle = true
        let token = UUID()
        taskTitleCopyFeedbackToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if taskTitleCopyFeedbackToken == token { didCopyTaskTitle = false }
        }
    }

    var repositoryBadges: some View {
        let suggestedRepositoryPaths = suggestedRepositories.map(\.path)
        let attachedRepositoryPaths = task.repositoryWorktrees.map(\.repositoryPath)
        return RepositoryChipsView(
            model: RepositoryChipsModel(repositoryPaths: attachedRepositoryPaths, readOnly: isReadOnly),
            actions: RepositoryChipsActions(
                edit: { path in
                    guard let repository = task.repositoryWorktrees.first(where: { $0.repositoryPath == path }) else { return }
                    repositoryBeingEdited = repository
                    resetRepositoryEdits(to: repository)
                    editingRepositoryField = nil
                },
                remove: { path in
                    guard let repository = task.repositoryWorktrees.first(where: { $0.repositoryPath == path }) else { return }
                    removeConversationRepository(repository)
                },
                add: {
                    if isShowingRepositoryPicker { isShowingRepositoryPicker = false } else { showRepositoryPicker() }
                }
            ),
            isPickerPresented: $isShowingRepositoryPicker,
            editingPath: Binding(
                get: { repositoryBeingEdited?.repositoryPath },
                set: { if $0 == nil { repositoryBeingEdited = nil } }
            ),
            // The popover content only refreshes with this view, so key it to the suggestions it lists.
            picker: { repositoryPicker.id(suggestedRepositoryPaths + recentRepositoryPaths) },
            settings: { chip in
                if let repository = task.repositoryWorktrees.first(where: { $0.repositoryPath == chip.path }) {
                    repositorySettingsPopover(repository, name: chip.name)
                }
            }
        )
        .onAppear { loadRecentRepositories() }
        .onChange(of: attachedRepositoryPaths) { _, _ in loadRecentRepositories() }
        .onChange(of: repositorySearch) { _, value in
            repositorySuggestionIndex = 0
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                didOverrideRepositoryDefault = true
            }
        }
    }


    var safetyNotice: some View {
        let additionalFolders = workspaceRootURLs.filter { url in
            !task.repositoryWorktrees.contains {
                URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path == url.path
            }
        }
        return Group {
            if !additionalFolders.isEmpty {
                let folderLabels = additionalFolders.map(\.lastPathComponent)
                let folderSummary = "Working in: " + folderLabels.joined(separator: " · ")
                let fullFolderSummary = "Working in: " + additionalFolders.map(\.path).joined(separator: " · ")
                Text(folderSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(fullFolderSummary)
                    .accessibilityIdentifier("working-folders-summary")
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 28)
                    .padding(.top, 12)
            }
        }
    }
}
