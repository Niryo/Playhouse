import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

extension TaskConversationView {
    package var collapsedTaskSidebar: some PHView {
        AtomStack(
            props: StackProps(spacing: 8, group: true, fill: "panel", fillOpacity: 0.62),
            common: AtomCommon(testID: "task-sidebar-collapsed", width: Double(Self.collapsedSidebarWidth), fillHeight: true, paddingTop: 12)
        ) {
            AtomButton(
                props: ButtonProps(shortcut: AppShortcut.sidebar),
                common: AtomCommon(testID: "show-task-sidebar-button", label: "Show sidebar", help: "Show sidebar", width: 26, height: 24)
            ) {
                setTaskSidebarCollapsed(false)
            } content: {
                AtomIcon(props: IconProps(name: PHIcon.sidebarLeft.name, size: 12, weight: "medium"))
            }

            // Inline sidebar plugins (the built-in Changes) show their rail form here.
            PluginInlineSlot(placement: .conversationSidebar, props: pluginProps, actions: pluginActions)
            AtomSpacer(props: SpacerProps(minLength: 0))
            // The command row's Skills button stays reachable while the sidebar is collapsed.
            AtomStack(common: AtomCommon(paddingBottom: 6)) { sidebarSkillsButton }
        }
    }

    package var expandedTaskSidebar: some PHView {
        AtomStack(
            props: StackProps(spacing: 0, align: "leading", group: true, fill: "panel", fillOpacity: 0.62),
            common: AtomCommon(testID: "task-sidebar", width: Double(Self.expandedSidebarWidth), fillHeight: true)
        ) {
            AtomStack(props: StackProps(axis: "h", spacing: 8), common: AtomCommon(paddingX: 10, paddingTop: 12, paddingBottom: 6)) {
                AtomButton(
                    props: ButtonProps(shortcut: AppShortcut.sidebar),
                    common: AtomCommon(testID: "hide-task-sidebar-button", label: "Hide sidebar", help: "Hide sidebar", width: 22, height: 24)
                ) {
                    setTaskSidebarCollapsed(true)
                } content: {
                    AtomIcon(props: IconProps(name: PHIcon.sidebarLeft.name, size: 12, weight: "medium"))
                }
                AtomSpacer(props: SpacerProps(minLength: 0))
            }

            panelRule(opacity: 0.07)

            // Plugins lead the sidebar's sections, above the inline ones such as Changes.
            AtomStack(common: AtomCommon(paddingX: 10, paddingTop: 8)) {
                PluginSlot(placement: .conversationSidebar, props: pluginProps, actions: pluginActions, open: { openConversationPlugin = $0 }, add: startPluginTask)
            }

            // Inline plugins (the built-in Changes) render their own sections in the column.
            PluginInlineSlot(placement: .conversationSidebar, props: pluginProps, actions: pluginActions)

            AtomSpacer(props: SpacerProps(minLength: 0))

            panelRule(opacity: 0.07)

            sidebarCommandRow
        }
    }

    /// A full-width one-point line in the primary color at `opacity`.
    private func panelRule(opacity: Double) -> some PHView {
        AtomStack(props: StackProps(fill: "primary", fillOpacity: opacity), common: AtomCommon(height: 1, fillWidth: true)) {}
    }

    package var conversationPanel: some PHView {
        AtomStack(props: StackProps(axis: "z", align: "leading", clip: true)) {
            AtomStack(props: StackProps(spacing: 0)) {
                if task.authoringPluginID != nil {
                    AtomStack(props: StackProps(axis: "h"), common: AtomCommon(paddingX: 26, paddingY: 15)) {
                        AtomButton(
                            props: ButtonProps(shortcut: AppShortcut.back),
                            common: AtomCommon(testID: "back-to-board-button", label: "Back to Kanban board", help: "Back to Kanban", width: 28, height: 28),
                            action: saveAndBack
                        ) {
                            AtomIcon(props: IconProps(name: PHIcon.chevronBackward.name))
                        }
                        AtomText(props: TextProps(text: "Plugin editor", size: 13, weight: "bold"), common: AtomCommon(fillWidth: true))
                        AtomSpacer()
                    }
                } else if !task.isStandaloneChat || task.isParallelChatBubble {
                    conversationHeader
                }

                // The standalone chat beside the board has no header: the sidebar's Chat entry names and hides it.
                if !task.isStandaloneChat || task.isParallelChatBubble {
                    panelRule(opacity: 0.07)
                }

                safetyNotice

                // An agent's conversation covers this one; laying out the hidden
                // transcript underneath it would only cost time.
                if selectedSubagent == nil {
                    conversation
                } else {
                    AtomSpacer(props: SpacerProps(minLength: 0))
                }

                // With the plus on it, the overlay draws this line itself, broken around the plus.
                AtomOverlay {
                    panelRule(opacity: showsNewChatPageButton ? 0 : Self.conversationDividerOpacity)
                } overlay: {
                    newChatPageRuleButton
                }
                // Above the composer, so the plus's lower half still takes clicks.
                .zIndex(1)

                if isReadOnly {
                    AtomLabel(
                        props: LabelProps(text: "Archived conversation · read only", icon: PHIcon.lockFill.name, size: 11, weight: "medium", color: "secondary"),
                        common: AtomCommon(testID: "archived-conversation-read-only", fillWidth: true, frameAlign: "center", paddingY: 18)
                    )
                } else {
                    if task.status == .done {
                        // A Done task keeps its conversation; a follow-up reopens it in fresh worktrees.
                        AtomLabel(
                            props: LabelProps(text: archivedFollowUpHint, icon: PHIcon.archivebox.name, size: 11, weight: "medium", color: "secondary"),
                            common: AtomCommon(testID: "archived-conversation-follow-up-hint", fillWidth: true, frameAlign: "center", paddingTop: 8)
                        )
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
        .animation(.easeInOut(duration: 0.24), value: isDiffPresented)
        .onExitCommand {
            if isDiffPresented { closeDiff() }
        }
    }

    package var fileDiffOverlay: some PHView {
        AtomStack(props: StackProps(axis: "z")) {
            // Escape closes the diff wherever focus is; the monitor takes no room.
            AtomStack(common: AtomCommon(width: 0, height: 0)) { PHEscapeKeyMonitor(onEscape: closeDiff) }

            AtomStack(
                props: StackProps(spacing: 0, group: true, fill: "window"),
                common: AtomCommon(testID: "workspace-diff-overlay", fillWidth: true, fillHeight: true, frameAlign: "center")
            ) {
                fileDiffHeader

                panelRule(opacity: 0.09)

                AtomStack(props: StackProps(fill: "input"), common: AtomCommon(fillWidth: true, fillHeight: true, frameAlign: "center")) {
                    fileDiffContent
                }
            }
        }
    }

    private var fileDiffHeader: some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 11, fill: "window"), common: AtomCommon(fillWidth: true, paddingX: 18, paddingY: 10)) {
            AtomButton(common: AtomCommon(testID: "close-workspace-diff-button", label: "Close diff", help: "Close diff", width: 26, height: 26), action: closeDiff) {
                AtomIcon(props: IconProps(name: PHIcon.xmark.name, size: 11, weight: "semibold"))
            }

            if let selectedChange {
                AtomIcon(props: IconProps(name: changeSymbol(for: selectedChange.status), size: 11, weight: "medium", color: WorkspaceChangeStyle.colorName(for: selectedChange.status)))
                AtomStack(props: StackProps(spacing: 2, align: "leading")) {
                    AtomText(
                        props: TextProps(text: selectedChange.path, size: 12, weight: "semibold", design: "monospaced", lineLimit: 1, truncation: "middle"),
                        common: AtomCommon(testID: "workspace-diff-title")
                    )
                    AtomText(
                        props: TextProps(text: "\(repositoryLabel(selectedChange.repository)) · \(diffBaselineLabel(selectedChange))", size: 10, color: "secondary"),
                        common: AtomCommon(testID: "workspace-diff-source")
                    )
                }
            } else {
                AtomText(props: TextProps(text: "File diff", size: 12, weight: "semibold"))
            }

            AtomSpacer(props: SpacerProps(minLength: 0))
            if selectedDiff?.isText == true {
                AtomText(
                    props: TextProps(text: isMonacoReady ? "Side-by-side" : "Starting editor", size: 10, weight: "medium", color: "secondary"),
                    common: AtomCommon(testID: "workspace-diff-editor-status", value: monacoStartupDescription)
                )
                if isMonacoReady {
                    AtomText(
                        props: TextProps(text: diffHighlightStatus, size: 10, weight: "medium", color: (diffChangeCount ?? 0) > 0 ? "green" : "secondary"),
                        common: AtomCommon(testID: "workspace-diff-highlight-status")
                    )
                }
            }
            AtomStack(props: StackProps(fill: "primary", fillOpacity: 0.06, capsule: true), common: AtomCommon(paddingX: 7, paddingY: 4)) {
                AtomText(props: TextProps(text: "READ ONLY", size: 9, weight: "semibold", design: "rounded", color: "secondary", tracking: 0.5))
            }
        }
    }

    /// A small spinner over its secondary caption, as a labelled native progress view draws.
    private func labelledSpinner(_ title: String) -> some PHView {
        AtomStack(props: StackProps(spacing: 4)) {
            AtomSpinner()
            AtomText(props: TextProps(text: title, size: 11, color: "secondary"))
        }
    }

    @PHViewBuilder
    private var fileDiffContent: some PHView {
        if isLoadingDiff {
            AtomStack(props: StackProps(combine: true), common: AtomCommon(testID: "workspace-diff-loading")) {
                labelledSpinner("Loading file diff…")
            }
        } else if let diffError {
            AtomStack(props: StackProps(spacing: 8), common: AtomCommon(testID: "workspace-diff-error", padding: 24)) {
                AtomIcon(props: IconProps(name: PHIcon.exclamationmarkTriangleFill.name, color: "orange"))
                AtomText(props: TextProps(text: diffError, size: 12, color: "secondary", align: "center"))
            }
        } else if let selectedDiff, selectedDiff.isText {
            if let monacoError {
                AtomStack(props: StackProps(spacing: 9), common: AtomCommon(padding: 24)) {
                    AtomText(props: TextProps(text: monacoError, size: 12, color: "secondary", align: "center"))
                    AtomButton(props: ButtonProps(style: "automatic"), common: AtomCommon(help: "Reload editor")) {
                        isMonacoReady = false
                        diffChangeCount = nil
                        self.monacoError = nil
                        // Clearing the diff first takes the shared editor out of the
                        // view tree; resetting alone can't replace a hosted NSView.
                        self.selectedDiff = nil
                        NativeViews.factory.resetDiffEditor()
                        if let selectedChange { openDiff(selectedChange) }
                    } content: {
                        AtomText(props: TextProps(text: "Reload editor", size: 11, weight: "medium"))
                    }
                }
            } else {
                AtomStack(props: StackProps(axis: "z")) {
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
                        AtomStack(
                            props: StackProps(combine: true, cornerRadius: 8, material: "regular"),
                            common: AtomCommon(testID: "workspace-diff-editor-loading", padding: 12)
                        ) {
                            labelledSpinner("Starting Monaco…")
                        }
                    }
                }
            }
        } else if let selectedDiff {
            AtomStack(props: StackProps(spacing: 9), common: AtomCommon(padding: 24)) {
                AtomIcon(props: IconProps(name: PHIcon.docTextMagnifyingglass.name, size: 22, color: "secondary"))
                AtomText(
                    props: TextProps(text: selectedDiff.message ?? "This file can't be shown as a text diff.", size: 12, color: "secondary", align: "center"),
                    common: AtomCommon(testID: "workspace-diff-unsupported")
                )
            }
        }
    }


    package var conversationHeader: some PHView {
        let backLabel = task.isParallelChatBubble ? "Back to the bubble" : "Back to Kanban board"
        return AtomStack(
            props: StackProps(axis: "h", spacing: 12, fill: "window", fillOpacity: 0.96),
            common: AtomCommon(fillWidth: true, paddingX: 26, paddingY: 15)
        ) {
            AtomButton(
                props: ButtonProps(shortcut: AppShortcut.back),
                common: AtomCommon(testID: "back-to-board-button", label: backLabel, help: task.isParallelChatBubble ? backLabel : "Back to Kanban", width: 28, height: 28),
                action: saveAndBack
            ) {
                AtomIcon(props: IconProps(name: PHIcon.chevronBackward.name, size: 13, weight: "semibold"))
            }

            AtomStack(props: StackProps(spacing: 4, align: "leading"), common: AtomCommon(fillWidth: true)) {
                AtomStack(props: StackProps(axis: "h", spacing: 8)) {
                    if isGeneratingTitle || task.title == "Generating title…" {
                        AtomStack(props: StackProps(axis: "h", spacing: 7), common: AtomCommon(testID: "task-title-generating")) {
                            AtomSpinner(common: AtomCommon(testID: "task-title-generating-loader"))
                            AtomText(props: TextProps(text: "Generating title…"))
                        }
                    } else {
                        AtomText(
                            props: TextProps(text: task.title, size: 14, weight: "semibold", lineLimit: 1, selectable: true),
                            common: AtomCommon(testID: "task-view-title")
                        )
                    }
                }

                if !task.isStandaloneChat {
                    AtomStack(props: StackProps(axis: "h", spacing: 6), common: AtomCommon(testID: "task-header-status")) {
                        AtomStack(props: StackProps(fill: AtomColor.hex(task.status.accent), capsule: true), common: AtomCommon(width: 6, height: 6, decorative: true)) {}
                        AtomText(props: TextProps(text: task.status.rawValue, size: 11, weight: "medium", color: "secondary"))
                    }
                    if let statusMessage = task.statusMessage, !statusMessage.isEmpty {
                        AtomText(
                            props: TextProps(text: statusMessage, size: 10, color: task.status == .blocked ? "red" : "secondary", lineLimit: 3),
                            common: AtomCommon(testID: "task-status-message")
                        )
                    }
                }
            }

            AtomSpacer(props: SpacerProps(minLength: 0))

            if !task.isStandaloneChat {
                // The title column takes whatever is left, so the chips (with a
                // branch each when a repository repeats) aren't squeezed first.
                AtomStack(common: AtomCommon(layoutPriority: 1)) { repositoryBadges }
            }
        }
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
                AtomStack(common: AtomCommon(fillWidth: true, frameAlign: "center", paddingX: 28, paddingTop: 12)) {
                    AtomStack(common: AtomCommon(maxWidth: 820, frameAlign: "leading")) {
                        // Reads as the full paths, while the line shows only the folder names.
                        AtomStack(props: StackProps(summary: true), common: AtomCommon(testID: "working-folders-summary", label: fullFolderSummary)) {
                            AtomText(props: TextProps(text: folderSummary, size: 10, color: "secondary", lineLimit: 2, selectable: true))
                        }
                    }
                }
            }
        }
    }
}
