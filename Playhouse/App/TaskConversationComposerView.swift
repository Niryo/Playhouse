import AppKit
import SwiftData
import SwiftUI

extension TaskConversationView {
    var composerModel: ComposerModel {
        let reason = startImplementingUnavailableReason
        let primary: ComposerModel.Primary
        if isDisplayingActiveResponse
            || (providerTurnIsActive && userInputRequest == nil && providerPendingUserInputRequest == nil) {
            primary = .init(kind: "stop", disabled: isPausingResponse || !canPauseResponse, help: "Pause \(provider.displayName) response", label: "Stop response", value: "", testID: "pause-response-button")
        } else if hasPausedResponse {
            primary = .init(kind: "continue", disabled: false, help: "Continue \(provider.displayName) response", label: "Continue response", value: "", testID: "continue-response-button")
        } else if composerSchedule != nil, canSchedule {
            primary = .init(kind: "schedule", disabled: isScheduleSendDisabled, help: composerSchedule.map { "Schedule: \($0.summary())" } ?? "Schedule task", label: "Schedule task", value: composerSchedule?.summary() ?? "", testID: "send-message-button")
        } else {
            primary = .init(kind: "send", disabled: isSendDisabled, help: "Send message", label: "Send message", value: "", testID: "send-message-button")
        }
        var modeItems: [ComposerModel.Item] = []
        if provider.supportsGoals {
            modeItems.append(.init(id: "goal", title: "Goal", checked: false, icon: "scope", help: "Set a goal to keep pursuing", testID: "conversation-mode-goal"))
        }
        modeItems += ConversationMode.allCases.map { mode in
            .init(id: "mode:\(mode.rawValue)", title: mode.title, checked: conversationMode == mode, icon: nil, help: "Switch to \(mode.title) mode", testID: "conversation-mode-\(mode.rawValue)")
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
            modeMenu: .init(
                text: isEnteringGoal ? "Goal" : (conversationMode == .plan ? "Plan" : nil),
                badgeIcon: isEnteringGoal ? "scope" : nil,
                active: isEnteringGoal || conversationMode == .plan,
                label: isEnteringGoal ? "Goal" : "Conversation mode: \(conversationMode.title)",
                items: modeItems
            ),
            startImplementing: canShowStartImplementing ? .init(
                disabled: workspaceRootURLs.isEmpty || isLoadingHistory || isPreparingSubmittedMessage,
                help: reason ?? "Switch to Code mode and start implementing this plan",
                value: reason ?? (workspaceRootURLs.isEmpty ? "Unavailable" : "Available"),
                unavailableReason: reason,
                reasonColor: colorScheme == .dark ? "orange" : "#2E4FAD",
                reasonDisabled: isReadOnly
            ) : nil,
            provider: .init(
                title: provider.displayName,
                value: provider.rawValue,
                label: "Provider: \(provider.displayName)",
                help: providerMenuHelp,
                enabled: canSwitchProvider,
                items: ConversationProvider.allCases.map { option in
                    .init(id: option.rawValue, title: option.displayName, checked: option == provider, icon: nil, help: "Run this task's next turns with \(option.displayName)", testID: "conversation-provider-\(option.rawValue)")
                }
            ),
            model: .init(
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
                on: composerSchedule != nil,
                help: composerSchedule != nil ? "Change the schedule" : "Schedule this task",
                open: isSchedulePopoverPresented
            ) : nil,
            primary: primary
        )
    }

    /// The context this conversation's placements hand a plugin. Read it only inside
    /// a `PluginPropsScope`: the composer placement reads the draft.
    func pluginProps(_ plugin: PluginRecord) -> [String: PluginValue] {
        let selection = composerDraft.selection
        return PluginContext.props(
            plugin: plugin, appearance: pluginAppearance, task: PluginTaskContext(task: task),
            composer: PluginComposerContext(draft: composerDraft.text, selectionLocation: selection.location, selectionLength: selection.length)
        )
    }

    var pluginActions: PluginUIActions {
        PluginUIActions(
            close: { openConversationPlugin = nil },
            openTask: { id in
                openConversationPlugin = nil
                onOpenTask(id, "")
            },
            composer: isReadOnly ? nil : { edit in applyPluginComposerEdit(edit) }
        )
    }

    /// A plugin's `Playhouse.ui.composer` call, applied to the draft and its selection.
    func applyPluginComposerEdit(_ edit: PluginComposerEdit) {
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
    func startPluginTask(_ placement: PluginPlacement) {
        NotificationCenter.default.post(name: .playhouseStartPluginCreation, object: placement)
    }


    var composerActions: ComposerActions {
        ComposerActions(
            change: { draft = $0 },
            submit: {
                if isResponding {
                    queueDraftForAfterTurn()
                } else {
                    sendOrSchedule()
                }
            },
            steer: {
                if isResponding, isConversationTurnActive {
                    steerCurrentTurn()
                }
            },
            focusChange: { isComposerFocused = $0 },
            pasteImage: { image in
                do { try addImageData(image) }
                catch { errorMessage = error.localizedDescription }
            },
            selectionChange: { composerDraft.selection = $0 },
            openSkills: {
                skillsPresentation += 1
                isShowingSkills = true
            },
            modeMenu: { id in
                if id == "goal" {
                    isEnteringGoal = true
                    draft = ""
                } else if let mode = ConversationMode(rawValue: String(id.dropFirst("mode:".count))) {
                    isEnteringGoal = false
                    setConversationMode(mode)
                }
            },
            startImplementing: startImplementingPlan,
            showRepositoryPicker: showRepositoryPicker,
            provider: { id in
                if let option = ConversationProvider(rawValue: id) { switchProvider(to: option) }
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
                    scheduleDraft = composerSchedule ?? defaultScheduleDraft(kind: .once)
                    isSchedulePopoverPresented = true
                }
            },
            dismissSchedule: { isSchedulePopoverPresented = false },
            primary: {
                switch composerModel.primary.kind {
                case "stop": pauseResponse()
                case "continue": continueResponse()
                case "schedule": confirmSchedule()
                default: sendOrSchedule()
                }
            }
        )
    }



    // MARK: Scheduling

    /// The hint for choosing when the task runs. Done only arms Send's schedule mode; the
    /// schedule is saved when Send is pressed.
    var scheduleHint: some View {
        let validation = scheduleDraft.validationMessage()
        return VStack(alignment: .leading, spacing: 12) {
            Picker("Schedule", selection: Binding(
                get: { scheduleDraft.kind },
                set: { kind in
                    scheduleDraft.kind = kind
                    if kind == .recurring, scheduleDraft.title.isEmpty, !Self.placeholderTitles.contains(task.title) {
                        scheduleDraft.title = task.title
                    }
                }
            )) {
                Text("Once").tag(TaskScheduleKind.once)
                Text("Recurring").tag(TaskScheduleKind.recurring)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("schedule-kind-picker")

            if scheduleDraft.kind == .recurring {
                TextField("Title", text: $scheduleDraft.title)
                    .textFieldStyle(.roundedBorder)
                    .focused($isScheduleTitleFocused)
                    .onSubmit(confirmScheduleHint)
                    .accessibilityIdentifier("schedule-title-field")
                HStack(spacing: 8) {
                    Picker("Repeat", selection: $scheduleDraft.preset) {
                        ForEach(TaskRecurrence.Preset.allCases, id: \.self) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("schedule-repeat-picker")
                    if scheduleDraft.preset == .weekly {
                        Picker("Day", selection: $scheduleDraft.weekday) {
                            ForEach(1...7, id: \.self) { day in
                                Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("schedule-weekday-picker")
                    }
                    Spacer(minLength: 0)
                    if scheduleDraft.preset == .hourly {
                        Picker("Minute", selection: $scheduleDraft.minute) {
                            ForEach([0, 15, 30, 45], id: \.self) { minute in
                                Text(String(format: ":%02d", minute)).tag(minute)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("schedule-minute-picker")
                    } else {
                        DatePicker("Time", selection: $scheduleDraft.time, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.field)
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityIdentifier("schedule-time-picker")
                    }
                }
            } else {
                DatePicker("Run at", selection: $scheduleDraft.fireAt, in: Date.now..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .accessibilityIdentifier("schedule-date-picker")
            }

            Text(validation ?? scheduleDraft.summary())
                .font(.caption)
                .foregroundStyle(validation == nil ? Color.secondary : Color.red)
                .accessibilityIdentifier("schedule-summary")

            HStack {
                if composerSchedule != nil {
                    Button("Remove") {
                        composerSchedule = nil
                        isSchedulePopoverPresented = false
                        composerDraft.focusRequest += 1
                    }
                    .buttonHoverPointer()
                    .nativeHelp("Stop scheduling; Send runs the task now")
                    .accessibilityIdentifier("schedule-remove-button")
                }
                Spacer()
                Button("Done", action: confirmScheduleHint)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validation != nil)
                    .buttonHoverPointer()
                    .nativeHelp("Use this schedule; Send then schedules the task")
                    .accessibilityIdentifier("schedule-done-button")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(width: 300)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("schedule-hint")
        .onAppear {
            if scheduleDraft.kind == .recurring { isScheduleTitleFocused = true }
        }
    }

    static let placeholderTitles: Set<String> = ["Untitled task", "Generating title…"]
    func useSkill(_ skill: SkillRecord) {
        let token = skill.invocationToken
        let rest = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.hasPrefix(token + " "), rest != token {
            draft = rest.isEmpty ? token + " " : token + " " + rest
        }
        isShowingSkills = false
        composerDraft.focusRequest += 1
    }

    /// The skill gallery as a full page that slides in from the trailing side
    /// over the task, and back out when it closes. In the standalone chat sidebar,
    /// `skillsPageWindowWidth` widens it from the sidebar's leading edge across the
    /// whole window, and `SkillsPageShowingKey` tells the board it is open.
    var skillsPage: some View {
        SkillsPageWindowFrame {
            ZStack {
                if isShowingSkills {
                    SkillsPageView(
                        task: task, manager: conversationManager, onUse: useSkill,
                        onFixTask: { taskID, prompt in
                            isShowingSkills = false
                            onOpenTask(taskID, prompt)
                        }
                    ) {
                        isShowingSkills = false
                        composerDraft.focusRequest += 1
                    }
                    .id(skillsPresentation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .shadow(color: .black.opacity(0.25), radius: 16, x: -4)
                    .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .allowsHitTesting(isShowingSkills)
        .animation(.spring(response: 0.34, dampingFraction: 0.92), value: isShowingSkills)
        .preference(key: SkillsPageShowingKey.self, value: isShowingSkills)
    }

    /// Summarizes how the selected provider's native configuration differs, so a
    /// switch doesn't silently change which skills or MCP servers are available.

    var workspaceRootURLs: [URL] {
        task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    /// Provider-owning operations run in the bridge daemon, not in this window.
    var conversationManager: RemoteConversationManager {
        RemoteConversationManager(daemon: conversationRuntime.client, runtime: conversationRuntime, modelContext: modelContext)
    }

    var workspaceManager: WorkspaceManager {
        WorkspaceManager(taskManager: BoardTaskManager(modelContext: modelContext))
    }
}
