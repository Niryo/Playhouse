import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

extension TaskConversationView {
    package var composerModel: ComposerModel {
        let reason = startImplementingUnavailableReason
        let primary: ComposerModel.Primary
        if composerSchedule != nil, canSchedule {
            let label = isExistingConversation ? "Schedule message" : "Schedule task"
            primary = .init(kind: "schedule", disabled: isScheduleSendDisabled, help: composerSchedule.map { "Schedule: \($0.summary())" } ?? label, label: label, value: composerSchedule?.summary() ?? "", testID: "send-message-button")
        // Stop works from the moment a message is sent: a turn that is still launching is
        // stopped before it starts. Once clicked it gives way to Continue at once. While the
        // draft has content, Send takes Stop's place and does what Return does.
        } else if !isPausingResponse, isDisplayingActiveResponse
            || (providerTurnIsActive && userInputRequest == nil && providerPendingUserInputRequest == nil) {
            if hasSubmittableDraft {
                primary = .init(kind: "send", disabled: false, help: isResponding ? "Queue this follow-up for after the current turn" : "Send message", label: "Send message", value: "", testID: "send-message-button")
            } else {
                primary = .init(kind: "stop", disabled: false, help: "Pause \(provider.displayName) response", label: "Stop response", value: "", testID: "pause-response-button")
            }
        } else if hasPausedResponse {
            primary = .init(kind: "continue", disabled: isStopLandingOnOwnSend, help: "Continue \(provider.displayName) response", label: "Continue response", value: "", testID: "continue-response-button")
        } else if composerSchedule != nil, canSchedule {
            primary = .init(kind: "schedule", disabled: isScheduleSendDisabled, help: composerSchedule.map { "Schedule: \($0.summary())" } ?? "Schedule task", label: "Schedule task", value: composerSchedule?.summary() ?? "", testID: "send-message-button")
        } else {
            primary = .init(kind: "send", disabled: isSendDisabled, help: "Send message", label: "Send message", value: "", testID: "send-message-button")
        }
        return ComposerModel(
            prefix: "",
            draft: draft,
            placeholder: isEnteringGoal ? "Set a goal to keep pursuing" : (isResponding || activeGoal != nil ? "Ask for follow-up changes" : "Message…"),
            enabled: !isReadOnly && !isPreparingSubmittedMessage,
            autofocus: isNewTask,
            focused: isComposerFocused,
            focusRequest: composerDraft.focusRequest,
            editorHelp: isReadOnly
                ? "Archived conversation, read-only."
                : (isResponding ? "Press Return to queue this follow-up. Press Command-Return to steer the active turn, or use a queued row's Steer action."
                    : (isLoadingHistory ? "Composer unavailable while conversation history loads." : "")),
            skills: !hasTaskSidebar,
            attach: .init(disabled: isReadOnly || isPreparingSubmittedMessage, help: "Attach images"),
            plan: .init(on: conversationMode == .plan, help: conversationMode == .plan ? "Turn off Plan mode" : "Plan before making changes"),
            // The standalone chat already pages its own context.
            optimizedContext: task.isStandaloneChat ? nil : .init(
                on: conversationContextMode == .optimized,
                help: conversationContextMode == .optimized
                    ? "Turn off optimized context: follow-ups resume the whole conversation"
                    : "Optimized context: each follow-up starts a fresh session with your messages and the last answer, and the agent reads more on demand"
            ),
            goal: provider.supportsGoals
                ? .init(on: isEnteringGoal, help: isEnteringGoal ? "Stop entering a goal" : "Set a goal to keep pursuing")
                : nil,
            startImplementing: canShowStartImplementing ? .init(
                disabled: workspaceRootURLs.isEmpty || isLoadingHistory || isPreparingSubmittedMessage,
                help: reason ?? "Switch to Code mode and start implementing this plan",
                value: reason ?? (workspaceRootURLs.isEmpty ? "Unavailable" : "Available"),
                unavailableReason: reason,
                reasonColor: colorScheme == .dark ? "orange" : "#2E4FAD",
                reasonDisabled: isReadOnly
            ) : nil,
            provider: providerMenu,
            model: isAwaitingProviderInstall ? nil : .init(
                name: selectedModelName,
                effort: selectedEffort.title,
                label: "Model: \(selectedModelName), effort: \(selectedEffort.title)",
                open: isModelPickerPresented,
                models: modelOptions.map { option in
                    .init(id: option.id, title: option.name, checked: pickerModelID == option.id || (pickerModelID.isEmpty && option.isDefault), icon: nil, help: "Select \(option.name)", testID: "model-option-\(option.id)")
                },
                effortChoices: pickerEffortChoices.map { .init(value: $0.rawValue, label: $0.title) },
                selectedEffort: pickerEffort.rawValue
            ),
            schedule: canSchedule ? .init(
                on: composerSchedule != nil || savedSchedule != nil,
                help: composerSchedule != nil || savedSchedule != nil ? "Change the schedule" : "Schedule this task",
                open: isSchedulePopoverPresented
            ) : nil,
            // The standalone chat asks on a side page while it keeps its own turn going.
            parallelSend: task.isStandaloneChat && !task.isParallelChatBubble && !isReadOnly ? .init(
                disabled: !hasSubmittableDraft || isPreparingSubmittedMessage || isEnteringGoal,
                help: "Send in parallel: ask on a new page in a bubble beside the chat, while you keep chatting here"
            ) : nil,
            primary: primary
        )
    }

    /// The context this conversation's placements hand a plugin. Read it only inside
    /// a `PluginPropsScope`: the composer placement reads the draft.
    package func pluginProps(_ plugin: PluginRecord) -> [String: PluginValue] {
        let selection = composerDraft.selection
        return PluginContext.props(
            plugin: plugin, appearance: pluginAppearance, task: PluginTaskContext(task: task),
            composer: PluginComposerContext(draft: composerDraft.text, selectionLocation: selection.location, selectionLength: selection.length),
            workspace: PluginWorkspaceContext(
                revision: workspaceRevision,
                // Closing the diff keeps `selectedChange` for its dismissal animation.
                openDiff: isDiffPresented ? selectedChange.map { .init(repository: $0.repository, path: $0.path, group: $0.group.rawValue) } : nil,
                sidebarCollapsed: isTaskSidebarShownCollapsed
            )
        )
    }

    package var pluginActions: PluginUIActions {
        PluginUIActions(
            close: { openConversationPlugin = nil },
            openTask: { id in
                openConversationPlugin = nil
                onOpenTask(id, "")
            },
            composer: isReadOnly ? nil : { edit in applyPluginComposerEdit(edit) },
            openDiff: { openDiff($0) },
            refreshWorkspace: { Task { await refreshWorkspaceChanges() } },
            confirm: { PluginManagement.confirm($0) },
            setMode: isReadOnly ? nil : { mode in
                if mode == "goal" { enterGoal() } else { enterPlanMode() }
            },
            openSkills: { openSkillsPage(focus: $0) },
            editPlugin: { PluginManagement.edit($0, registry: pluginRegistry) },
            willDeletePlugin: { await PluginManagement.prepareDelete($0, registry: pluginRegistry) }
        )
    }

    /// A plugin's `Playhouse.ui.composer` call, applied to the draft and its selection.
    package func applyPluginComposerEdit(_ edit: PluginComposerEdit) {
        let text = draft as NSString
        let location = min(max(0, composerDraft.selection.location), text.length)
        let length = min(max(0, composerDraft.selection.length), text.length - location)
        switch edit {
        case .setDraft(let value):
            draft = value
            composerDraft.selection = NSRange(location: (value as NSString).length, length: 0)
        case .insertText(let value):
            draft = text.replacingCharacters(in: NSRange(location: location + length, length: 0), with: value)
            composerDraft.selection = NSRange(location: location + length + (value as NSString).length, length: 0)
        case .replaceSelection(let value):
            draft = text.replacingCharacters(in: NSRange(location: location, length: length), with: value)
            composerDraft.selection = NSRange(location: location, length: (value as NSString).length)
        case .focus:
            break
        }
        composerDraft.focusRequest += 1
    }

    /// An Add Plugin mode placeholder was pressed: the new task's agent builds a
    /// plugin for that placement, and the mode ends.
    package func startPluginTask(_ placement: PluginPlacement) {
        NotificationCenter.default.post(name: .playhouseStartPluginCreation, object: placement)
    }


    package var composerActions: ComposerActions {
        ComposerActions(
            change: { draft = $0 },
            submit: submitDraft,
            steer: {
                // A turn that is still launching takes the steer as soon as it starts.
                if isResponding {
                    steerCurrentTurn()
                }
            },
            focusChange: { isComposerFocused = $0 },
            pasteImage: { image in
                do { try addImageData(image) }
                catch { errorMessage = error.localizedDescription }
            },
            selectionChange: { composerDraft.selection = $0 },
            openSkills: { openSkillsPage(focus: nil) },
            attach: chooseAttachments,
            togglePlan: {
                if conversationMode == .plan { setConversationMode(.code) } else { enterPlanMode() }
            },
            toggleOptimizedContext: { if !isReadOnly { toggleOptimizedContext() } },
            toggleGoal: {
                if isEnteringGoal {
                    isEnteringGoal = false
                } else {
                    enterGoal()
                    draft = ""
                }
            },
            startImplementing: startImplementingPlan,
            showRepositoryPicker: showRepositoryPicker,
            provider: { id in
                if id.hasPrefix("install:"), let option = ConversationProvider(rawValue: String(id.dropFirst("install:".count))) {
                    installProvider(option)
                } else if let option = ConversationProvider(rawValue: id) {
                    switchProvider(to: option)
                }
            },
            toggleModelPicker: {
                if isModelPickerPresented {
                    commitModelPickerSelection()
                    isModelPickerPresented = false
                } else {
                    pickerModelID = selectedModelID
                    pickerEffort = selectedEffort
                    isModelPickerPresented = true
                }
            },
            dismissModelPicker: {
                if isModelPickerPresented { commitModelPickerSelection() }
                isModelPickerPresented = false
            },
            selectModel: { id in
                if let option = modelOptions.first(where: { $0.id == id }) { selectPickerModel(option) }
            },
            selectEffort: { value in
                if let effort = ConversationEffort(rawValue: value) { pickerEffort = effort }
            },
            toggleSchedule: {
                if isSchedulePopoverPresented {
                    isSchedulePopoverPresented = false
                } else {
                    scheduleDraft = composerSchedule ?? savedSchedule ?? defaultScheduleDraft(kind: .once)
                    isSchedulePopoverPresented = true
                }
            },
            dismissSchedule: { isSchedulePopoverPresented = false },
            sendInParallel: sendDraftInParallel,
            primary: {
                switch composerModel.primary.kind {
                case "stop": pauseResponse()
                case "continue": continueResponse()
                case "schedule": confirmSchedule()
                default: submitDraft()
                }
            }
        )
    }

    /// Whether the draft has something Return or Send would hand off.
    package var hasSubmittableDraft: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pendingImages.isEmpty
    }

    /// The Send in parallel button: the draft leaves the composer for a parallel bubble, whose
    /// turn the app's bubble store follows, so it keeps running if this chat closes.
    package func sendDraftInParallel() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageDataURLs = pendingImages.map(\.dataURL)
        guard !text.isEmpty || !imageDataURLs.isEmpty, !isPreparingSubmittedMessage else { return }
        draftAutosaveTask?.cancel()
        draftAutosaveTask = nil
        composerDraft.settledText = ""
        draft = ""
        pendingImages = []
        isComposerFocused = true
        ParallelChatBubbleStore.shared.send(text: text, imageDataURLs: imageDataURLs, using: conversationManager) {
            // A send no bubble took leaves its question to send again, unless a new one was typed.
            if draft.isEmpty, pendingImages.isEmpty { draft = text }
        }
    }

    /// Return and the Send button: a running turn queues the draft as a follow-up.
    package func submitDraft() {
        if composerSchedule != nil, canSchedule {
            confirmSchedule()
        } else if isResponding {
            queueDraftForAfterTurn()
        } else {
            sendOrSchedule()
        }
    }



    // MARK: Scheduling

    /// The hint for choosing when the task runs. For a task that isn't scheduled yet, Done only
    /// arms Send's schedule mode and Send saves the schedule; for a task that is already
    /// scheduled, Done saves the edited schedule at once.
    package var scheduleHint: some PHView {
        let validation = scheduleDraft.validationMessage()
        return AtomStack(props: StackProps(axis: "v", spacing: 12, align: "leading"), common: AtomCommon(width: 300, paddingX: 18, paddingY: 13)) {
            if !isExistingConversation {
                AtomSegmented(
                    fitContent: false,
                    selection: PHBinding(
                        get: { scheduleDraft.kind },
                        set: { kind in
                            scheduleDraft.kind = kind
                            if kind == .recurring, scheduleDraft.title.isEmpty, !Self.placeholderTitles.contains(task.title) {
                                scheduleDraft.title = task.title
                            }
                        }
                    ),
                    options: [.once, .recurring], label: { $0 == .once ? "Once" : "Recurring" },
                    common: AtomCommon(testID: "schedule-kind-picker", label: "Schedule")
                )
            } else {
                AtomText(
                    props: TextProps(text: "One-time message", weight: "medium", textStyle: "caption"),
                    common: AtomCommon(testID: "schedule-one-time-only")
                )
            }

            if scheduleDraft.kind == .recurring && !isExistingConversation {
                AtomTextField(
                    props: TextFieldProps(text: scheduleDraft.title, placeholder: "Title"),
                    common: AtomCommon(testID: "schedule-title-field"),
                    onChange: { scheduleDraft.title = $0 }, onSubmit: confirmScheduleHint, focus: $isScheduleTitleFocused
                )
                AtomStack(props: StackProps(axis: "h", spacing: 8)) {
                    AtomSegmented(
                        style: "menu", selection: $scheduleDraft.preset,
                        options: TaskRecurrence.Preset.allCases, label: { $0.label },
                        common: AtomCommon(testID: "schedule-repeat-picker", label: "Repeat")
                    )
                    if scheduleDraft.preset == .weekly {
                        AtomSegmented(
                            style: "menu", selection: $scheduleDraft.weekday,
                            options: Array(1...7), label: { Calendar.current.weekdaySymbols[$0 - 1] },
                            common: AtomCommon(testID: "schedule-weekday-picker", label: "Day")
                        )
                    }
                    AtomSpacer(props: SpacerProps(minLength: 0))
                    if scheduleDraft.preset == .hourly {
                        AtomSegmented(
                            style: "menu", selection: $scheduleDraft.minute,
                            options: [0, 15, 30, 45], label: { String(format: ":%02d", $0) },
                            common: AtomCommon(testID: "schedule-minute-picker", label: "Minute")
                        )
                    } else {
                        AtomDatePicker(
                            props: DatePickerProps(date: scheduleDraft.time.timeIntervalSince1970, components: "time"),
                            common: AtomCommon(testID: "schedule-time-picker", label: "Time", fixedSize: true),
                            onChange: { scheduleDraft.time = Date(timeIntervalSince1970: $0) }
                        )
                    }
                }
            } else {
                AtomDatePicker(
                    props: DatePickerProps(date: scheduleDraft.fireAt.timeIntervalSince1970, min: Date.now.timeIntervalSince1970),
                    common: AtomCommon(testID: "schedule-date-picker", label: "Run at"),
                    onChange: { scheduleDraft.fireAt = Date(timeIntervalSince1970: $0) }
                )
            }

            AtomText(
                props: TextProps(text: validation ?? scheduleDraft.summary(), color: validation == nil ? "secondary" : "red", textStyle: "caption"),
                common: AtomCommon(testID: "schedule-summary")
            )

            AtomStack(props: StackProps(axis: "h")) {
                if composerSchedule != nil || savedSchedule != nil {
                    AtomButton(props: ButtonProps(style: "automatic"), common: AtomCommon(help: isExistingConversation ? "Cancel the scheduled message; it stays in the composer" : "Stop scheduling; Send runs the task now"), action: removeSchedule) { AtomText(props: TextProps(text: "Remove")) }
                    .accessibilityIdentifier("schedule-remove-button")
                }
                AtomSpacer()
                AtomButton(props: ButtonProps(style: "prominent", disabled: validation != nil), action: confirmScheduleHint) { AtomText(props: TextProps(text: "Done")) }
                    .shortcutHelp(savedSchedule != nil ? "Save this schedule" : "Use this schedule; Send then schedules the task", shortcut: "default")
                    .accessibilityIdentifier("schedule-done-button")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("schedule-hint")
        .onAppear {
            if scheduleDraft.kind == .recurring { isScheduleTitleFocused = true }
        }
    }

    package static let placeholderTitles: Set<String> = ["Untitled task", "Generating title…"]
    package func useSkill(_ skill: SkillRecord) {
        let token = skill.invocationToken
        let rest = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.hasPrefix(token + " "), rest != token {
            draft = rest.isEmpty ? token + " " : token + " " + rest
        }
        isShowingSkills = false
        composerDraft.focusRequest += 1
    }

    /// The skill gallery as a modal card centered over the task, about as wide
    /// as the composer, over a dimmed backdrop that blocks the task under it.
    /// In the standalone chat sidebar, `skillsPageWindowWidth` widens the
    /// backdrop from the chat's leading edge across the board beside the main sidebar,
    /// so the card centers in that board, and `SkillsPageShowingKey` tells the board it is open.
    package var skillsPage: some PHView {
        SkillsPageWindowFrame {
            PHGeometryReader { geometry in
                AtomStack(props: StackProps(axis: "z"), common: AtomCommon(width: Double(geometry.size.width), height: Double(geometry.size.height))) {
                    if isShowingSkills {
                        AtomStack(
                            props: StackProps(fill: "black", fillOpacity: 0.28, hitSurface: true),
                            common: AtomCommon(fillWidth: true, fillHeight: true, decorative: true)
                        ) {}
                            .onTapGesture {}
                            // no-pointer: the modal backdrop only blocks clicks.
                            .transition(.opacity)
                        AtomStack(
                            props: StackProps(cornerRadius: 14, stroke: "primary", strokeOpacity: 0.1,
                                              clip: true, shadow: 28, shadowOpacity: 0.3, shadowY: 10),
                            common: AtomCommon(
                                width: Double(max(0, min(Self.skillsPageWidth, geometry.size.width - 48))),
                                height: Double(max(0, min(Self.skillsPageMaxHeight, geometry.size.height - 64)))
                            )
                        ) {
                            SkillsPageView(
                                task: task, manager: conversationManager, focus: skillsFocus, onUse: useSkill,
                                onFixTask: { taskID, prompt in
                                    isShowingSkills = false
                                    onOpenTask(taskID, prompt)
                                }
                            ) {
                                isShowingSkills = false
                                composerDraft.focusRequest += 1
                            }
                            .id(skillsPresentation)
                        }
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }
                }
            }
        }
        .allowsHitTesting(isShowingSkills)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: isShowingSkills)
        .preference(key: SkillsPageShowingKey.self, value: isShowingSkills)
    }

    /// The Skills modal's width: a narrow column centered over the conversation.
    package static let skillsPageWidth: CGFloat = 403
    package static let skillsPageMaxHeight: CGFloat = 760

    /// Summarizes how the selected provider's native configuration differs, so a
    /// switch doesn't silently change which skills or MCP servers are available.

    package var workspaceRootURLs: [URL] {
        task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    /// Whether no provider is installed, so the composer offers only the Install AI provider button.
    package var isAwaitingProviderInstall: Bool {
        !providerInstallStatuses.isEmpty && installedProviders.isEmpty
    }

    /// The installed providers, and an Add entry for each missing one. With none installed the
    /// menu becomes the Install AI provider button, listing the providers to install.
    package var providerMenu: ComposerModel.ProviderMenu {
        let installing = installingProvider.map { "Installing \($0.displayName)…" }
        let installItems = missingProviders.map { option in
            ComposerModel.Item(
                id: "install:\(option.rawValue)", title: installedProviders.isEmpty ? option.displayName : "Add \(option.displayName)",
                checked: false, icon: PHIcon.arrowDownCircle.name,
                help: "Install \(ConversationProviderInstaller.productName(option)) with its official installer",
                testID: "conversation-provider-install-\(option.rawValue)"
            )
        }
        if isAwaitingProviderInstall {
            let title = installing ?? "Install AI provider"
            return .init(
                title: title, value: "none", label: title,
                help: "Install an AI provider to run this task", enabled: installingProvider == nil,
                items: [], installItems: installItems, color: "accent"
            )
        }
        // Before the daemon answers every provider is listed, as is the task's own if it was uninstalled.
        let switchable = providerInstallStatuses.isEmpty
            ? ConversationProvider.allCases.filter(isProviderOffered)
            : ConversationProvider.allCases.filter { installedProviders.contains($0) || $0 == provider }
        return .init(
            title: installing ?? provider.displayName,
            value: provider.rawValue,
            label: "Provider: \(provider.displayName)",
            help: providerMenuHelp,
            enabled: canSwitchProvider && installingProvider == nil,
            items: switchable.map { option in
                .init(id: option.rawValue, title: option.displayName, checked: option == provider, icon: nil, help: "Run this task's next turns with \(option.displayName)", testID: "conversation-provider-\(option.rawValue)")
            },
            installItems: installItems
        )
    }

    /// Provider-owning operations run in the bridge daemon, not in this window.
    package var conversationManager: RemoteConversationManager {
        RemoteConversationManager(daemon: conversationRuntime.client, runtime: conversationRuntime.model, modelContext: modelContext)
    }

    package var workspaceManager: WorkspaceManager {
        WorkspaceManager(taskManager: BoardTaskManager(modelContext: modelContext))
    }
}
