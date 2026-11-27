import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

extension TaskConversationView {
    package var collapsedTaskSidebar: some PHView {
        PHVStack(spacing: 8) {
            PHButton {
                setTaskSidebarCollapsed(false)
            } label: {
                PHImage(icon: .sidebarLeft)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 24)
            }
            .plainButtonHoverPointer()
            .buttonStyle(.plain)
            .shortcutHelp("Show sidebar", shortcut: AppShortcut.sidebar)
            .accessibilityLabel("Show sidebar")
            .accessibilityIdentifier("show-task-sidebar-button")

            // Inline sidebar plugins (the built-in Changes) show their rail form here.
            PluginInlineSlot(placement: .conversationSidebar, props: pluginProps, actions: pluginActions)
            PHSpacer(minLength: 0)
            // The command row's Skills button stays reachable while the sidebar is collapsed.
            sidebarSkillsButton
                .padding(.bottom, 6)
        }
        .padding(.top, 12)
        .frame(width: Self.collapsedSidebarWidth)
        .frame(maxHeight: .infinity)
        .background(WorkspaceTheme.panelBackground.opacity(0.62))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-sidebar-collapsed")
    }

    package var expandedTaskSidebar: some PHView {
        PHVStack(alignment: .leading, spacing: 0) {
            PHHStack(spacing: 8) {
                PHButton {
                    setTaskSidebarCollapsed(true)
                } label: {
                    PHImage(icon: .sidebarLeft)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 24)
                }
                .plainButtonHoverPointer()
                .buttonStyle(.plain)
                .shortcutHelp("Hide sidebar", shortcut: AppShortcut.sidebar)
                .accessibilityLabel("Hide sidebar")
                .accessibilityIdentifier("hide-task-sidebar-button")
                PHSpacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 6)

            PHRectangle()
                .fill(PHColor.primary.opacity(0.07))
                .frame(height: 1)

            // Plugins lead the sidebar's sections, above the inline ones such as Changes.
            PluginSlot(placement: .conversationSidebar, props: pluginProps, actions: pluginActions, open: { openConversationPlugin = $0 }, add: startPluginTask)
                .padding(.horizontal, 10)
                .padding(.top, 8)

            // Inline plugins (the built-in Changes) render their own sections in the column.
            PluginInlineSlot(placement: .conversationSidebar, props: pluginProps, actions: pluginActions)

            PHSpacer(minLength: 0)

            PHRectangle()
                .fill(PHColor.primary.opacity(0.07))
                .frame(height: 1)

            sidebarCommandRow
        }
        .frame(width: Self.expandedSidebarWidth)
        .frame(maxHeight: .infinity)
        .background(WorkspaceTheme.panelBackground.opacity(0.62))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-sidebar")
    }

    package var conversationPanel: some PHView {
        PHZStack(alignment: .leading) {
            PHVStack(spacing: 0) {
                if task.authoringPluginID != nil {
                    PHHStack {
                        PHButton(action: saveAndBack) {
                            PHImage(icon: .chevronBackward)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.plain)
                        .plainButtonHoverPointer()
                        .shortcutHelp("Back to Kanban", shortcut: AppShortcut.back)
                        .accessibilityLabel("Back to Kanban board")
                        .accessibilityIdentifier("back-to-board-button")
                        PHText("Plugin editor")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        PHSpacer()
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 15)
                } else if !task.isStandaloneChat || task.isParallelChatBubble {
                    conversationHeader
                }

                // The standalone chat beside the board has no header: the sidebar's Chat entry names and hides it.
                if !task.isStandaloneChat || task.isParallelChatBubble {
                    PHRectangle()
                        .fill(PHColor.primary.opacity(0.07))
                        .frame(height: 1)
                }

                safetyNotice

                // An agent's conversation covers this one; laying out the hidden
                // transcript underneath it would only cost time.
                if selectedSubagent == nil {
                    conversation
                } else {
                    PHSpacer(minLength: 0)
                }

                // With the plus on it, the overlay draws this line itself, broken around the plus.
                PHRectangle()
                    .fill(PHColor.primary.opacity(showsNewChatPageButton ? 0 : Self.conversationDividerOpacity))
                    .frame(height: 1)
                    .overlay { newChatPageRuleButton }
                    // Above the composer, so the plus's lower half still takes clicks.
                    .zIndex(1)

                if isReadOnly {
                    PHLabel("Archived conversation · read only", icon: .lockFill)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .accessibilityIdentifier("archived-conversation-read-only")
                } else {
                    if task.status == .done {
                        // A Done task keeps its conversation; a follow-up reopens it in fresh worktrees.
                        PHLabel(archivedFollowUpHint, icon: .archivebox)
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

    package var fileDiffOverlay: some PHView {
        PHVStack(spacing: 0) {
            PHHStack(spacing: 11) {
                PHButton(action: closeDiff) {
                    PHImage(icon: .xmark)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(PHRectangle())
                }
                .plainButtonHoverPointer()
                .buttonStyle(.plain)
                .nativeHelp("Close diff")
                .accessibilityLabel("Close diff")
                .accessibilityIdentifier("close-workspace-diff-button")

                if let selectedChange {
                    PHImage(icon: PHIcon(named: changeSymbol(for: selectedChange.status)))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(changeColor(for: selectedChange.status))
                    PHVStack(alignment: .leading, spacing: 2) {
                        PHText(selectedChange.path)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("workspace-diff-title")
                        PHText("\(repositoryLabel(selectedChange.repository)) · \(diffBaselineLabel(selectedChange))")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("workspace-diff-source")
                    }
                } else {
                    PHText("File diff")
                        .font(.system(size: 12, weight: .semibold))
                }

                PHSpacer(minLength: 0)
                if selectedDiff?.isText == true {
                    PHText(isMonacoReady ? "Side-by-side" : "Starting editor")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("workspace-diff-editor-status")
                        .accessibilityValue(monacoStartupDescription)
                    if isMonacoReady {
                        PHText(diffHighlightStatus)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(diffChangeCount.map { $0 > 0 ? PHColor.green : PHColor.secondary } ?? PHColor.secondary)
                            .accessibilityIdentifier("workspace-diff-highlight-status")
                    }
                }
                PHText("READ ONLY")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(PHColor.primary.opacity(0.06), in: PHCapsule())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceTheme.windowBackground)

            PHRectangle()
                .fill(PHColor.primary.opacity(0.09))
                .frame(height: 1)

            PHGroup {
                if isLoadingDiff {
                    PHProgressView("Loading file diff…")
                        .controlSize(.small)
                        .accessibilityIdentifier("workspace-diff-loading")
                } else if let diffError {
                    PHVStack(spacing: 8) {
                        PHImage(icon: .exclamationmarkTriangleFill)
                            .foregroundStyle(.orange)
                        PHText(diffError)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .accessibilityIdentifier("workspace-diff-error")
                } else if let selectedDiff, selectedDiff.isText {
                    if let monacoError {
                        PHVStack(spacing: 9) {
                            PHText(monacoError)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            PHButton("Reload editor") {
                                isMonacoReady = false
                                diffChangeCount = nil
                                self.monacoError = nil
                                // Clearing the diff first takes the shared editor out of the
                                // view tree; resetting alone can't replace a hosted NSView.
                                self.selectedDiff = nil
                                NativeViews.factory.resetDiffEditor()
                                if let selectedChange { openDiff(selectedChange) }
                            }
                            .buttonHoverPointer()
                            .nativeHelp("Reload editor")
                            .font(.system(size: 11, weight: .medium))
                        }
                        .padding(24)
                    } else {
                        PHZStack {
                            PHNativeDiffEditor(
                                diff: selectedDiff,
                                theme: colorScheme == .dark ? "vs-dark" : "vs",
                                isReady: $isMonacoReady,
                                loadError: $monacoError,
                                diffChangeCount: $diffChangeCount,
                                presentation: $monacoPresentation
                            )
                            .accessibilityIdentifier("workspace-diff-editor")

                            if !isMonacoReady {
                                PHProgressView("Starting Monaco…")
                                    .controlSize(.small)
                                    .padding(12)
                                    .phMaterialBackground(.regular, in: PHRoundedRectangle(cornerRadius: 8))
                                    .accessibilityIdentifier("workspace-diff-editor-loading")
                            }
                        }
                    }
                } else if let selectedDiff {
                    PHVStack(spacing: 9) {
                        PHImage(icon: .docTextMagnifyingglass)
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        PHText(selectedDiff.message ?? "This file can't be shown as a text diff.")
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
        .background(PHEscapeKeyMonitor(onEscape: closeDiff).frame(width: 0, height: 0))
    }


    package var conversationHeader: some PHView {
        let backLabel = task.isParallelChatBubble ? "Back to the bubble" : "Back to Kanban board"
        return PHHStack(spacing: 12) {
            PHButton(action: saveAndBack) {
                PHImage(icon: .chevronBackward)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(PHRectangle())
            }
            .plainButtonHoverPointer()
            .buttonStyle(.plain)
            .shortcutHelp(task.isParallelChatBubble ? backLabel : "Back to Kanban", shortcut: AppShortcut.back)
            .accessibilityLabel(backLabel)
            .accessibilityIdentifier("back-to-board-button")

            PHVStack(alignment: .leading, spacing: 4) {
                PHHStack(spacing: 8) {
                    if isGeneratingTitle || task.title == "Generating title…" {
                        PHHStack(spacing: 7) {
                            PHProgressView()
                                .controlSize(.small)
                                .accessibilityIdentifier("task-title-generating-loader")
                            PHText("Generating title…")
                        }
                        .accessibilityIdentifier("task-title-generating")
                    } else {
                        PHText(task.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("task-view-title")
                    }

                }

                if !task.isStandaloneChat {
                    PHHStack(spacing: 6) {
                        PHCircle()
                            .fill(task.status.accent)
                            .frame(width: 6, height: 6)
                        PHText(task.status.rawValue)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("task-header-status")
                    if let statusMessage = task.statusMessage, !statusMessage.isEmpty {
                        PHText(statusMessage)
                            .font(.system(size: 10))
                            .foregroundStyle(task.status == .blocked ? PHColor.red : PHColor.secondary)
                            .lineLimit(3)
                            .accessibilityIdentifier("task-status-message")
                    }
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)

            PHSpacer(minLength: 0)

            if !task.isStandaloneChat {
                // The title column takes whatever is left, so the chips (with a
                // branch each when a repository repeats) aren't squeezed first.
                repositoryBadges
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspaceTheme.windowBackground.opacity(0.96))
    }

    package var repositoryBadges: some PHView {
        let suggestedRepositoryPaths = suggestedRepositories.map(\.path)
        let attachedRepositoryPaths = task.repositoryWorktrees.map(\.repositoryPath)
        return RepositoryChipsView(
            model: RepositoryChipsModel(records: task.repositoryWorktrees, readOnly: isReadOnly),
            actions: RepositoryChipsActions(
                edit: { key in
                    guard let repository = task.repositoryWorktrees.record(chipKey: key) else { return }
                    repositoryBeingEditedKey = key
                    resetRepositoryEdits(to: repository)
                    editingRepositoryField = nil
                    newWorktreeBranch = ""
                    resolveRepositoryDefaults(repository)
                },
                remove: { key in
                    guard let repository = task.repositoryWorktrees.record(chipKey: key) else { return }
                    removeConversationRepository(repository)
                },
                add: {
                    if isShowingRepositoryPicker { isShowingRepositoryPicker = false } else { showRepositoryPicker() }
                }
            ),
            isPickerPresented: $isShowingRepositoryPicker,
            editingPath: PHBinding(
                get: { repositoryBeingEdited == nil ? nil : repositoryBeingEditedKey },
                set: { if $0 == nil { repositoryBeingEditedKey = nil } }
            ),
            addShortcut: AppShortcut.repositoryPicker,
            // The popover content only refreshes with this view, so key it to the suggestions it lists.
            picker: { repositoryPicker.id(suggestedRepositoryPaths + recentRepositoryPaths) },
            settings: { chip in
                if let repository = task.repositoryWorktrees.record(chipKey: chip.id) {
                    repositorySettingsPopover(repository, name: chip.title)
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


    package var safetyNotice: some PHView {
        let additionalFolders = workspaceRootURLs.filter { url in
            !task.repositoryWorktrees.contains {
                URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path == url.path
            }
        }
        return PHGroup {
            if !additionalFolders.isEmpty {
                let folderLabels = additionalFolders.map(\.lastPathComponent)
                let folderSummary = "Working in: " + folderLabels.joined(separator: " · ")
                let fullFolderSummary = "Working in: " + additionalFolders.map(\.path).joined(separator: " · ")
                PHText(folderSummary)
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
