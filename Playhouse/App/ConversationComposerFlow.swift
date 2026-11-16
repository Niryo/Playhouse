import AppKit
import SwiftData
import SwiftUI

extension TaskConversationView {
    // MARK: @ mentions

    var mentionHandles: Set<String> { Set(mentionCatalog?.items.map(\.handle) ?? []) }

    /// The mention being typed before the caret, whether or not its menu was dismissed.
    var typedMention: (location: Int, query: String)? {
        guard !isReadOnly, isComposerEditing, composerDraft.selection.length == 0 else { return nil }
        return MentionText.activeQuery(in: draft, caret: composerDraft.selection.location)
    }

    /// The mention whose menu is open.
    var activeMention: (location: Int, query: String)? {
        guard let typed = typedMention, typed.location != dismissedMentionLocation else { return nil }
        return typed
    }

    var mentionSuggestions: [MentionItem] {
        guard let active = activeMention, let mentionCatalog else { return [] }
        return Array(mentionCatalog.suggestions(query: active.query).prefix(80))
    }

    @ViewBuilder
    var mentionMenu: some View {
        if let active = activeMention {
            let items = mentionSuggestions
            ComposerMentionMenu(
                query: active.query,
                items: items,
                showsRecent: active.query.isEmpty && !(mentionCatalog?.recent.isEmpty ?? true),
                isLoading: mentionCatalog == nil,
                selectedIndex: min(mentionSelection, max(items.count - 1, 0)),
                select: { insertMention($0, at: active) }
            )
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 14)
            .padding(.bottom, 8)
        }
    }

    /// The `@` mentions a sent message's visible text names: those its context block lists,
    /// or, for a message shown before its turn recorded one, those the catalog knows.
    func messageMentions(_ message: ConversationMessage, visibleText: String) -> [(handle: String, range: NSRange)] {
        guard visibleText.contains("@") else { return [] }
        let listed = MentionText.contextHandles(in: message.text)
        return MentionText.handles(in: visibleText, known: listed.isEmpty ? mentionHandles : listed)
    }

    func loadMentions() async {
        guard !isLoadingMentions else { return }
        isLoadingMentions = true
        defer { isLoadingMentions = false }
        if let catalog = try? await conversationManager.mentions(taskID: task.id) {
            mentionCatalog = catalog
        }
    }

    /// The open menu's keys: the arrows move the highlight, Return or Tab inserts it, Escape closes the menu.
    func handleMentionKey(_ key: ChatEditorKey) -> Bool {
        guard let active = activeMention else { return false }
        let items = mentionSuggestions
        switch key {
        case .up:
            mentionSelection = max(0, min(mentionSelection, items.count - 1) - 1)
        case .down:
            mentionSelection = min(max(items.count - 1, 0), mentionSelection + 1)
        case .accept:
            guard !items.isEmpty else { return false }
            insertMention(items[min(mentionSelection, items.count - 1)], at: active)
        case .dismiss:
            dismissedMentionLocation = active.location
        }
        return true
    }

    /// Replaces the typed `@query` with the item's `@handle` and a space.
    func insertMention(_ item: MentionItem, at active: (location: Int, query: String)) {
        let length = (("@" + active.query) as NSString).length
        mentionEdit = ChatEditorEdit(
            id: (mentionEdit?.id ?? 0) + 1,
            range: NSRange(location: active.location, length: length),
            text: "@" + item.handle + " "
        )
        mentionSelection = 0
    }
    func userInputForm(_ request: ConversationUserInputRequest) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("A few questions")
                .font(.system(size: 17, weight: .semibold))
                .accessibilityIdentifier("ai-question-form-title")
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 9) {
                    if !question.header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(question.header.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .accessibilityIdentifier("ai-question-header-\(question.id)")
                    }
                    // Providers write questions in Markdown, as they do replies, so they share the reply
                    // renderer and size. The renderer sizes only bold, italic and code runs; plain text takes this font.
                    assistantMarkdownContent(question.question)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(WorkspaceTheme.conversationText)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("ai-question-text-\(question.id)")
                    if question.options.isEmpty {
                        Group {
                            if question.isSecret {
                                SecureField("Answer", text: Binding(
                                    get: { userInputAnswers[question.id]?.first ?? "" },
                                    set: { userInputAnswers[question.id] = [$0] }
                                ))
                            } else {
                                TextField("Your answer", text: Binding(
                                    get: { userInputAnswers[question.id]?.first ?? "" },
                                    set: { userInputAnswers[question.id] = [$0] }
                                ))
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 15))
                        .controlSize(.large)
                        .accessibilityIdentifier("ai-question-answer-\(question.id)")
                    } else {
                        ForEach(question.options) { option in
                            let isSelected = (userInputAnswers[question.id] ?? []).first == option.label
                            VStack(alignment: .leading, spacing: 2) {
                                Button {
                                    userInputAnswers[question.id] = [option.label]
                                    userInputOtherSelected.remove(question.id)
                                } label: {
                                    Label(option.label, systemImage: isSelected ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 15))
                                }
                                .buttonHoverPointer()
                                .nativeHelp("Select answer: \(option.label)")
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("ai-question-option-\(question.id)-\(option.label)")
                                .accessibilityValue(isSelected ? "selected" : "not selected")
                                if let description = option.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                                    Text(description)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        // Aligns with the option label, past the radio symbol.
                                        .padding(.leading, 24)
                                        .accessibilityIdentifier("ai-question-option-description-\(question.id)-\(option.label)")
                                }
                            }
                        }
                        if question.allowsOther {
                            Button {
                                userInputAnswers[question.id] = []
                                userInputOtherSelected.insert(question.id)
                            } label: {
                                Label("Other", systemImage: userInputOtherSelected.contains(question.id) ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 15))
                            }
                            .buttonHoverPointer()
                            .nativeHelp("Select a free-text answer")
                            .buttonStyle(.plain)
                            .accessibilityValue(userInputOtherSelected.contains(question.id) ? "selected" : "not selected")
                            TextField("Other answer", text: Binding(
                                get: { userInputOther[question.id] ?? "" },
                                set: {
                                    userInputOther[question.id] = $0
                                    userInputAnswers[question.id] = []
                                    userInputOtherSelected.insert(question.id)
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 15))
                            .controlSize(.large)
                        }
                    }
                }
            }
            Button("Submit answers") {
                Task { @MainActor in await submitUserInput(request) }
            }
            .buttonHoverPointer()
            .nativeHelp("Submit answers")
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(request.questions.contains { question in
                    let selections = userInputAnswers[question.id] ?? []
                    return selections.isEmpty && (!userInputOtherSelected.contains(question.id) || (userInputOther[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                })
                .accessibilityIdentifier("submit-ai-answers-button")
        }
        .padding(16)
        .frame(maxWidth: 720, alignment: .leading)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    func submitUserInput(_ request: ConversationUserInputRequest) async {
        var answers: [String: [String]] = [:]
        for question in request.questions {
            var values = userInputAnswers[question.id] ?? []
            if userInputOtherSelected.contains(question.id), let other = userInputOther[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty {
                values = [other]
            }
            answers[question.id] = values
        }
        isResponding = true
        errorMessage = nil
        // After a restart the answer runs as a whole recovery turn before this
        // call returns, so hide the answered card meanwhile. Marking it answered
        // now keeps a history refresh during the call from bringing it back.
        userInputRequest = nil
        answeredUserInputRequestIDs.insert(request.id)
        // A recovery turn streams its redacted reply before history hides it.
        var streamedRecoveryFinals: [String] = []
        do {
            let accepted = try await conversationManager.answerUserInput(
                taskID: task.id,
                request: request,
                answers: answers,
                modelID: selectedModelID.isEmpty ? nil : selectedModelID,
                onUpdate: { update in
                    if update.type == "assistant_final", let text = update.text, !text.isEmpty {
                        streamedRecoveryFinals.append(text)
                    }
                    guard update.type == "user_input", let nextRequest = update.userInputRequest else { return }
                    showUserInputRequest(nextRequest)
                }
            )
            guard accepted else {
                answeredUserInputRequestIDs.remove(request.id)
                isResponding = false
                if userInputRequest == nil { userInputRequest = request }
                errorMessage = "\(provider.displayName) couldn't accept those answers. Please check the responses and try again."
                return
            }
            answeredUserInputRequestIDs.insert(request.id)
            userInputRequest = nil
            userInputAnswers = [:]
            userInputOther = [:]
            userInputOtherSelected = []
            await loadConversation()
            // This window keeps showing the safe reply it streamed; a reload shows it hidden.
            if let finalText = streamedRecoveryFinals.last,
               let index = messages.lastIndex(where: { $0.role == .assistant }),
               messages[index].text == Self.hiddenRecoveryReplyText {
                streamedRecoveryReplies[messages[index].id] = finalText
                showStreamedRecoveryReplies()
            }
        } catch {
            // A failed answer keeps its saved question for retry; a new question the
            // turn raised meanwhile is already showing.
            answeredUserInputRequestIDs.remove(request.id)
            if userInputRequest == nil,
               let saved = try? await conversationManager.history(taskID: task.id).pendingUserInputRequest,
               saved.threadID == task.activeConversationID {
                userInputRequest = saved
            }
            isResponding = conversationRuntime.isTurnActive(threadID: request.threadID)
            errorMessage = error.localizedDescription
        }
    }
    func defaultScheduleDraft(kind: TaskScheduleKind) -> ComposerSchedule {
        var draft = ComposerSchedule()
        draft.kind = kind
        if kind == .recurring, !Self.placeholderTitles.contains(task.title) { draft.title = task.title }
        return draft
    }

    func confirmScheduleHint() {
        guard scheduleDraft.validationMessage() == nil else { return }
        isSchedulePopoverPresented = false
        composerDraft.focusRequest += 1
        let schedule = scheduleDraft
        guard let boardTask = task as? BoardTask, boardTask.scheduleKind != nil, canSchedule else {
            composerSchedule = schedule
            return
        }
        // Done on a task that is already scheduled saves the edit at once, so leaving the
        // conversation keeps it. A task that hasn't started saves its draft as the prompt, as Send
        // would. An existing conversation with an empty composer only moves its scheduled
        // message; with a draft, Done arms Send to schedule that draft in its place.
        let isEmptyDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty
        if isExistingConversation && !isEmptyDraft {
            composerSchedule = schedule
            return
        }
        if !isExistingConversation { composerSchedule = schedule }
        var request = schedule.request(
            prompt: isEmptyDraft ? "" : draft,
            imageDataURLs: isEmptyDraft ? [] : pendingImages.map(\.dataURL),
            mode: conversationMode,
            modelID: selectedModelID.isEmpty ? nil : selectedModelID
        )
        request.keepsPayload = isEmptyDraft
        let taskID = boardTask.id
        if !isEmptyDraft { draftAutosaveTask?.cancel() }
        isSavingSchedule = true
        Task { @MainActor in
            defer { isSavingSchedule = false }
            do {
                _ = try await BoardTaskManager(modelContext: modelContext).setSchedule(taskID, request)
                if !isEmptyDraft { composerDraft.settledText = draft }
                PlayhouseDiagnostics.record("ui.task.schedule_edited", fields: ["taskID": taskID.uuidString, "kind": schedule.kind.rawValue])
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Remove turns scheduling off. A schedule already saved on the task is cleared too, and an
    /// existing conversation's scheduled message returns to an empty composer as its draft.
    func removeSchedule() {
        composerSchedule = nil
        isSchedulePopoverPresented = false
        composerDraft.focusRequest += 1
        guard let boardTask = task as? BoardTask, boardTask.scheduleKind != nil else { return }
        let taskID = boardTask.id
        let restoresDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pendingImages.isEmpty
        let typedDraft = draft
        let typedImages = pendingImages.map(\.dataURL)
        if !restoresDraft { draftAutosaveTask?.cancel() }
        isSavingSchedule = true
        Task { @MainActor in
            defer { isSavingSchedule = false }
            do {
                let manager = BoardTaskManager(modelContext: modelContext)
                // Save a typed draft first so clearing the schedule keeps it rather than putting
                // the cancelled message back in its place.
                if !restoresDraft {
                    _ = try await manager.saveDraft(taskID, prompt: typedDraft, imageDataURLs: typedImages)
                    composerDraft.settledText = typedDraft
                }
                let record = try await manager.clearSchedule(taskID)
                if restoresDraft, draft.isEmpty, let prompt = record.savedPrompt {
                    draft = prompt
                    composerDraft.settledText = prompt
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Send's action. A schedule armed in the hint schedules the task; with the schedule removed
    /// in the hint, the task runs now as usual.
    func sendOrSchedule() {
        if composerSchedule != nil, canSchedule {
            confirmSchedule()
            return
        }
        // Sending a one-time task ends its schedule in the shared send path. A recurring
        // template becomes an ordinary task first, since a template never runs itself.
        guard let boardTask = task as? BoardTask, boardTask.isRecurringScheduleTemplate, canSchedule else {
            sendMessage()
            return
        }
        Task { @MainActor in
            do {
                _ = try await BoardTaskManager(modelContext: modelContext).clearSchedule(boardTask.id)
                sendMessage()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func confirmSchedule() {
        guard let schedule = composerSchedule, !isScheduleSendDisabled else { return }
        if let message = schedule.validationMessage() {
            // The chosen time passed while the composer was open.
            errorMessage = message
            scheduleDraft = schedule
            isSchedulePopoverPresented = true
            return
        }
        draftAutosaveTask?.cancel()
        let prompt = draft
        let request = schedule.request(
            prompt: prompt,
            imageDataURLs: pendingImages.map(\.dataURL),
            mode: conversationMode,
            modelID: selectedModelID.isEmpty ? nil : selectedModelID
        )
        let taskID = task.id
        let existingConversation = isExistingConversation
        isSavingSchedule = true
        Task { @MainActor in
            defer { isSavingSchedule = false }
            do {
                _ = try await BoardTaskManager(modelContext: modelContext).setSchedule(taskID, request)
                composerDraft.settledText = draft
                if existingConversation {
                    draft = ""
                    pendingImages = []
                    _ = try await BoardTaskManager(modelContext: modelContext).saveDraft(taskID, prompt: "", imageDataURLs: [])
                    composerSchedule = nil
                }
                PlayhouseDiagnostics.record("ui.task.scheduled", fields: ["taskID": taskID.uuidString, "kind": schedule.kind.rawValue])
                // A one-time task waits on the board, so the daemon names it now as a first send would.
                if schedule.kind == .once {
                    do {
                        try await conversationManager.nameScheduledTask(taskID: taskID)
                    } catch {
                        PlayhouseDiagnostics.record("ui.task.schedule_title.failed", fields: PlayhouseDiagnostics.errorFields(error).merging(["taskID": taskID.uuidString]) { _, new in new })
                    }
                }
                if !existingConversation { onBack() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func sendMessage(overrideText: String? = nil) {
        guard !isApplyingSavedRepositories, !isStopLandingOnOwnSend else { return }
        guard isRepositoryRootConfigured else {
            errorMessage = "Set the repository root folder before sending a conversation."
            return
        }
        let freeformText = (overrideText ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingAnnotations = annotations.filter(\.pending)
        let usesComposerDraft = overrideText == nil
        // An empty Goal still goes to the bridge, which explains the length rule.
        guard (!freeformText.isEmpty || (usesComposerDraft && (!pendingImages.isEmpty || isEnteringGoal)) || !pendingAnnotations.isEmpty), !isResponding, !isLoadingHistory, hasLoadedConversation, userInputRequest == nil else { return }
        let annotationPrompt: String
        if pendingAnnotations.isEmpty {
            annotationPrompt = freeformText
        } else {
            let objects = pendingAnnotations.map { annotation in
                var source: [String: Any] = ["messageId": annotation.messageID,
                                             "blockID": annotation.blockID,
                                             "startOffset": annotation.startOffset, "endOffset": annotation.endOffset]
                // Only a comment spanning blocks names its end block, so one inside a block
                // keeps the payload older history already carries.
                if annotation.endBlockID != annotation.blockID { source["endBlockID"] = annotation.endBlockID }
                return ["text": annotation.text, "comment": annotation.comment, "source": source] as [String: Any]
            }
            let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
            let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
            let guidance = "<playhouse-comment-context>\n# Response comments:\nThe following JSON contains comments on selected conversation text, in array order. For each comment, start a separate response line with :playhouse-annotation{index=\"N\"}, replacing N with the comment's zero-based array index, then a space and the answer. The marker is displayed to the user as the numbered prefix, so do not add another number. Address the comment in the context of its highlighted text. Do not combine comment responses on one line, omit a response, or add introductory text. After the comment responses, answer any additional freeform request on separate line(s). Do not repeat the JSON or these instructions.\n<response-comments>\(json)</response-comments>\n</playhouse-comment-context>"
            annotationPrompt = [freeformText, guidance]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let text = annotationPrompt
        // An annotation can point at text from an earlier page; that page travels with this
        // turn so the agent sees the quoted context without reloading the whole chat.
        let annotationPageIDs = standaloneChatPageIDs(for: pendingAnnotations)
        let resolutionAttempt = conflictResolutionAttempt
        if usesComposerDraft && pendingAnnotations.isEmpty && text == "/plan" {
            activatePlanMode()
            return
        }
        if usesComposerDraft && isEnteringGoal && pendingAnnotations.isEmpty {
            isPreparingSubmittedMessage = true
            draft = ""
            isEnteringGoal = false
            isResponding = true
            errorMessage = nil
            Task { @MainActor in
                let started = await mutateGoal("set", objective: text, observeRuntime: true)
                isPreparingSubmittedMessage = false
                await conversationRuntime.refresh()
                isResponding = started && conversationRuntime.isTurnActive(threadID: task.codexThreadID ?? "")
                isComposerFocused = true
            }
            return
        }
        if !pendingAnnotations.isEmpty {
            inFlightAnnotationIDs = Set(pendingAnnotations.map(\.id))
            persistPendingAnnotations()
        }
        if usesComposerDraft && isEnteringGoal && !pendingAnnotations.isEmpty {
            isEnteringGoal = false
        }
        guard !text.isEmpty || (usesComposerDraft && !pendingImages.isEmpty) else { return }
        // A draft autosave can be in flight after the user finishes typing.
        // Do not let that background write race the submitted-prompt write
        // for the same task and leave the send path waiting on its lock.
        draftAutosaveTask?.cancel()
        draftAutosaveTask = nil
        let userMessageID = UUID().uuidString
        let assistantMessageID = UUID().uuidString
        let previousResponseDuration = completedResponseDuration
        isComposerFocused = false
        let hadExistingMessages = !messages.isEmpty
        // The newest message shown before this send; a failed send's prompt counts as delivered
        // only when the conversation has it after this point.
        let sendAnchorID = messages.last?.id
        messages.append(ConversationMessage(id: userMessageID, role: .user, text: text,
                                         imageDataURLs: usesComposerDraft ? pendingImages.map(\.dataURL) : []))
        if !hadExistingMessages {
            messages.append(ConversationMessage(id: assistantMessageID, role: .assistant, text: ""))
        }
        isResponding = true
        let startedAt = Date()
        responseStartedAt = startedAt
        completedResponseDuration = nil
        WorkspaceSettings.preferencesStore.set(startedAt, forKey: responseStartedAtDefaultsKey)
        WorkspaceSettings.preferencesStore.removeObject(forKey: completedResponseDurationDefaultsKey)
        if usesComposerDraft {
            composerDraft.settledText = ""
            draft = ""
        }
        let imageDataURLs = usesComposerDraft ? pendingImages.map(\.dataURL) : []
        if usesComposerDraft { pendingImages = [] }
        // Question IDs can repeat across turns.
        answeredUserInputRequestIDs.removeAll()
        let wasPausedBeforeSend = hasPausedResponse
        hasPausedResponse = false
        isPausingResponse = false
        sendGeneration += 1
        let generation = sendGeneration
        errorMessage = nil
        actionNotice = nil
        activities = []
        isPreparingSubmittedMessage = true
        let statusBeforeSubmission = task.status
        sendsInFlight += 1
        sendsAwaitingDispatch += 1

        Task { @MainActor in
            var awaitsDispatch = true
            defer { if awaitsDispatch { sendsAwaitingDispatch -= 1 } }
            // However the send ends, its comments leave the in-flight set: a completed turn has
            // already marked them sent, and any it did not send stay pending in the saved draft.
            defer { releaseInFlightAnnotations(pendingAnnotations) }
            defer {
                sendsInFlight -= 1
                settleLocalStopIfDone()
            }
            let saved = await saveDraftAndGenerateTitle(
                status: .inProgress,
                prompt: text,
                generateTitle: false,
                reserveTitleForSend: true,
                sendsComposerDraft: usesComposerDraft
            )
            isPreparingSubmittedMessage = false
            guard saved else {
                if resolutionAttempt > 0 {
                    conflictResolutionAttempt = 0
                    onConflictResolutionChecked(false)
                }
                messages.removeAll { $0.id == userMessageID || $0.id == assistantMessageID }
                if usesComposerDraft {
                    draft = freeformText
                    pendingImages = imageDataURLs.compactMap { dataURL in
                        guard let image = Self.image(fromDataURL: dataURL) else { return nil }
                        return PendingImage(dataURL: dataURL, image: image)
                    }
                    persistDraft()
                }
                isResponding = false
                hasPausedResponse = false
                responseStartedAt = nil
                WorkspaceSettings.preferencesStore.removeObject(forKey: responseStartedAtDefaultsKey)
                completedResponseDuration = previousResponseDuration
                if let previousResponseDuration {
                    WorkspaceSettings.preferencesStore.set(previousResponseDuration, forKey: completedResponseDurationDefaultsKey)
                } else {
                    WorkspaceSettings.preferencesStore.removeObject(forKey: completedResponseDurationDefaultsKey)
                }
                return
            }
            followedTurnStreams += 1
            defer { followedTurnStreams -= 1 }
            do {
                _ = try await conversationManager.setEffort(taskID: task.id, effort: selectedEffort)
                awaitsDispatch = false
                sendsAwaitingDispatch -= 1
                _ = try await conversationManager.send(taskID: task.id, text: text, imageDataURLs: imageDataURLs, mode: conversationMode, modelID: selectedModelID.isEmpty ? nil : selectedModelID, statusBeforeSubmission: statusBeforeSubmission, contextPageIDs: annotationPageIDs, onTurnStarting: {
                    // A turn the user already stopped, or one a newer send replaced, starts
                    // only to be stopped.
                    if sendGeneration == generation, !isPausingResponse { isResponding = true }
                }, onUpdate: { update in
                    applyStreamedUpdate(update, assistantMessageID: assistantMessageID, pendingAnnotations: pendingAnnotations)
                }, onUserInput: { request in
                    showUserInputRequest(request)
                })
                flushStreamedTextDeltas()
                if messages.first(where: { $0.id == assistantMessageID })?.text.isEmpty == true {
                    messages.removeAll { $0.id == assistantMessageID }
                }
                // A turn that finished despite a late stop has nothing left to continue.
                if sendGeneration == generation { hasPausedResponse = false }
                isComposerFocused = true
                if resolutionAttempt > 0 {
                    do {
                        switch try await BoardTaskManager(modelContext: modelContext).verifyPullRequestResolution(task.id) {
                        case .resolved:
                            conflictResolutionAttempt = 0
                            onConflictResolutionChecked(true)
                        case .stillConflicted where resolutionAttempt == 1:
                            conflictResolutionAttempt = 2
                            isResponding = false
                            sendMessage(overrideText: PlayhouseSentMessage.pullRequestConflictsRetry)
                            return
                        case .stillConflicted:
                            conflictResolutionAttempt = 0
                            onConflictResolutionChecked(false)
                            errorMessage = "The PR still has conflicts after two turns. Review the PR and try again."
                        case .inconclusive:
                            conflictResolutionAttempt = 0
                            onConflictResolutionChecked(false)
                            errorMessage = "GitHub hasn't confirmed that the PR is conflict-free at the pushed head. Try again after its merge check finishes."
                        }
                    } catch {
                        conflictResolutionAttempt = 0
                        onConflictResolutionChecked(false)
                        errorMessage = error.localizedDescription
                    }
                }
            } catch {
                // Text that streamed before the failure is part of what the window showed.
                flushStreamedTextDeltas()
                if task.authoringPluginID != nil, error is DaemonClientError {
                    pluginBridgeRecoveryError = error.localizedDescription
                }
                if resolutionAttempt > 0 {
                    conflictResolutionAttempt = 0
                    onConflictResolutionChecked(false)
                }
                let stoppedBeforeStart = ConversationTurnLaunch.isStoppedBeforeStart(error)
                guard sendGeneration == generation else {
                    // A newer send owns the composer. A message stopped before the agent
                    // started on it never joined the conversation.
                    if stoppedBeforeStart {
                        messages.removeAll { $0.id == userMessageID || $0.id == assistantMessageID }
                    }
                    return
                }
                responseStartedAt = nil
                WorkspaceSettings.preferencesStore.removeObject(forKey: responseStartedAtDefaultsKey)
                if !stoppedBeforeStart,
                   isPausingResponse || conversationRuntime.wasLastTurnInterrupted(threadID: task.activeConversationID ?? "") {
                    hasPausedResponse = true
                } else if !stoppedBeforeStart, let deliveredHistory = await historyIfSendReachedConversation(text, after: sendAnchorID) {
                    // The send failed after its prompt was saved to the conversation (for example,
                    // Codex exited after the turn started). Returning it to the composer would save
                    // it as an unsent draft and prefix it to the next message.
                    applyHistoryMessages(deliveredHistory)
                    // The comments went out with the prompt, so they are sent, not pending.
                    let deliveredIDs = Set(pendingAnnotations.map(\.id))
                    for index in annotations.indices where deliveredIDs.contains(annotations[index].id) {
                        annotations[index].pending = false
                    }
                    errorMessage = error.localizedDescription
                } else {
                    messages.removeAll { $0.id == userMessageID || $0.id == assistantMessageID }
                    if usesComposerDraft {
                        // A steer stopped with this message may have returned to the composer already.
                        draft = [freeformText, draft].filter { !$0.isEmpty }.joined(separator: "\n")
                        pendingImages = imageDataURLs.compactMap { dataURL in
                            guard let image = Self.image(fromDataURL: dataURL) else { return nil }
                            return PendingImage(dataURL: dataURL, image: image)
                        }
                        persistDraft()
                    }
                    // A stop before the agent started is what the user asked for: the message
                    // is back in the composer and the conversation is where it was before it,
                    // still resumable when this was the Continue of an earlier stopped turn.
                    if stoppedBeforeStart {
                        hasPausedResponse = wasPausedBeforeSend
                        // The daemon returned the stopped prompt to the saved draft. One the
                        // user never typed (Continue) is not a draft: save the composer as it is.
                        if !usesComposerDraft { persistDraft() }
                    } else {
                        errorMessage = error.localizedDescription
                    }
                }
                isComposerFocused = true
            }

            guard sendGeneration == generation else { return }
            isResponding = false
            // A daemon restart can end this window's send stream while the provider turn
            // continues. Refreshing history reconnects the editor to that turn.
            if let recoveryError = pluginBridgeRecoveryError, errorMessage == recoveryError {
                followHistory()
            }
        }
    }

    /// How long streamed text may wait before it is shown. A provider streams a
    /// delta every few tokens, and every change to `messages` re-renders the whole
    /// transcript, so deltas are applied together at most this often.
    static let streamedTextApplyInterval: UInt64 = 50_000_000

    /// Applies one update of a turn this window streams: its own send, or a running turn it
    /// watches (a CLI send, a schedule, or a turn the daemon reattached after a restart).
    func applyStreamedUpdate(_ update: ConversationUpdate, assistantMessageID: String, pendingAnnotations: [ConversationAnnotation] = []) {
        if update.type == "text_delta" {
            guard let delta = update.text else { return }
            bufferStreamedTextDelta(delta, messageID: assistantMessageID)
            return
        }
        // Every other update applies after the text that streamed before it.
        flushStreamedTextDeltas()
        switch update.type {
        case "assistant_final":
            guard let text = update.text else { return }
            if let messageIndex = messages.lastIndex(where: { $0.role == .assistant }),
               messages[messageIndex].asyncQuestions == nil {
                messages[messageIndex].text = text
                messages[messageIndex].phase = "final_answer"
            } else {
                messages.append(ConversationMessage(
                    id: UUID().uuidString,
                    role: .assistant,
                    text: text,
                    phase: "final_answer"
                ))
            }
        case "assistant_progress":
            guard let itemID = update.itemID, let text = update.text else { return }
            if let index = messages.firstIndex(where: { $0.id == itemID }) {
                messages[index].text = text
                messages[index].phase = update.phase
                messages[index].asyncQuestions = update.asyncQuestions
            } else if let placeholderIndex = messages.firstIndex(where: { $0.id == assistantMessageID }) {
                messages.insert(ConversationMessage(
                    id: itemID,
                    role: .assistant,
                    text: text,
                    phase: update.phase,
                    asyncQuestions: update.asyncQuestions
                ), at: placeholderIndex)
            } else {
                messages.append(ConversationMessage(
                    id: itemID,
                    role: .assistant,
                    text: text,
                    phase: update.phase,
                    asyncQuestions: update.asyncQuestions
                ))
            }
            if let placeholderIndex = messages.firstIndex(where: { $0.id == assistantMessageID }) {
                messages[placeholderIndex].text = ""
            }
        case "activity":
            guard let activity = update.activity else { return }
            if provider == .claude, activity.isContextCompaction {
                ConversationActivity.upsertCompaction(activity, into: &activities)
            } else if let index = activities.firstIndex(where: { $0.id == activity.id }) {
                activities[index] = activity
            } else {
                activities.append(activity)
            }
        case "chat_page_updated":
            refreshChatPageStatus()
        case "diff":
            break
        case "history", "completed":
            guard let history = update.history else { return }
            var mergedMessages = history.messages
            if update.type == "completed" {
                for liveMessage in messages where !liveMessage.text.isEmpty {
                    if let persistedIndex = mergedMessages.firstIndex(where: { $0.id == liveMessage.id }) {
                        if mergedMessages[persistedIndex].text.isEmpty {
                            mergedMessages[persistedIndex] = liveMessage
                        }
                        continue
                    }
                    // A sent message is persisted with its mention block, which the live copy lacks.
                    let alreadyPersisted = mergedMessages.contains {
                        $0.role == liveMessage.role && MentionText.sameUserText($0.text, liveMessage.text)
                    }
                    if !alreadyPersisted {
                        mergedMessages.append(liveMessage)
                    }
                }
            }
            applyHistoryMessages(history, mergedMessages)
            answeredAsyncQuestionIDs = Set(history.answeredAsyncQuestionIDs)
            activities = history.activities
            if update.type == "completed" {
                let sentIDs = Set(pendingAnnotations.map(\.id))
                for index in annotations.indices where sentIDs.contains(annotations[index].id) {
                    annotations[index].pending = false
                }
                if let responseStartedAt {
                    let duration = Self.elapsedSeconds(since: responseStartedAt, now: Date())
                    completedResponseDuration = duration
                    WorkspaceSettings.preferencesStore.set(duration, forKey: completedResponseDurationDefaultsKey)
                    WorkspaceSettings.preferencesStore.removeObject(forKey: responseStartedAtDefaultsKey)
                }
                let finalAnswer = history.messages.last { (message: ConversationMessage) -> Bool in
                    message.role == .assistant && message.phase == "final_answer"
                }
                let completedTurnID: String? = finalAnswer?.turnID ?? history.messages.last?.turnID
                if let completedTurnID {
                    collapsedProgressTurnIDs.insert(completedTurnID)
                }
                Task { await refreshWorkspaceChanges() }
            }
        case "queue_changed":
            refreshQueuedMessages()
        case "steered_message":
            let steered = update.message ?? ""
            // The provider echoes a steer with its mention block, which the local copy lacks.
            if let index = unechoedLocalSteers.firstIndex(where: { MentionText.sameUserText($0, steered) }) {
                unechoedLocalSteers.remove(at: index)
            } else {
                unconfirmedStreamedSteers.append(steered)
                messages.append(ConversationMessage(id: UUID().uuidString, role: .user, text: steered, imageDataURLs: update.imageDataURLs ?? []))
            }
            if let message = update.message, MentionText.sameUserText(draft, message) { draft = "" }
        case "action_notice":
            actionNotice = update.message
        default:
            break
        }
    }
    func queueDraftForAfterTurn() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageDataURLs = pendingImages.map(\.dataURL)
        guard !text.isEmpty || !imageDataURLs.isEmpty else { return }
        do {
            _ = try conversationManager.queueMessage(taskID: task.id, text: text, imageDataURLs: imageDataURLs)
            clearHandedOffDraft()
            refreshQueuedMessages()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func removeQueuedMessage(_ message: QueuedConversationMessage) {
        do {
            try conversationManager.removeQueuedMessage(taskID: task.id, messageID: message.id)
            refreshQueuedMessages()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Steers the active turn with a queued follow-up. Its row leaves the queue and its bubble
    /// joins the transcript at once; the daemon and the provider catch up in the background.
    func steerQueuedMessage(_ message: QueuedConversationMessage) {
        guard !steeringQueuedMessageIDs.contains(message.id) else { return }
        steeringQueuedMessageIDs.insert(message.id)
        let steer = PendingLocalSteer(text: message.text, imageDataURLs: message.imageDataURLs ?? [])
        showLocalSteer(steer)
        errorMessage = nil
        deliverSteerInOrder {
            defer { steeringQueuedMessageIDs.remove(message.id) }
            do {
                let outcome = try await conversationManager.steerQueuedMessage(taskID: task.id, messageID: message.id)
                settleLocalSteer(steer, delivered: outcome.accepted)
                refreshQueuedMessages()
                guard !outcome.accepted else { return }
                // The turn ended first, so the follow-up runs as a turn of its own.
                if let history = try? await conversationManager.history(taskID: task.id, messageLimit: Self.historyPageSize) {
                    applyHistoryMessages(history)
                    activities = history.activities
                    answeredAsyncQuestionIDs = Set(history.answeredAsyncQuestionIDs)
                }
            } catch {
                settleLocalSteer(steer, delivered: false)
                refreshQueuedMessages()
                // The message it steered was stopped first: the follow-up stays in the queue, needing action.
                if !ConversationTurnLaunch.isStoppedBeforeStart(error) { errorMessage = error.localizedDescription }
            }
        }
    }

    /// Steers the active turn with the composer's draft. The message shows in the transcript
    /// and the composer clears at once; the daemon and the provider catch up in the background.
    func steerCurrentTurn() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        let imageDataURLs = images.map(\.dataURL)
        guard !text.isEmpty || !imageDataURLs.isEmpty else { return }
        let steer = PendingLocalSteer(text: text, imageDataURLs: imageDataURLs)
        showLocalSteer(steer)
        clearHandedOffDraft()
        errorMessage = nil
        deliverSteerInOrder {
            do {
                let accepted = try await conversationManager.steer(taskID: task.id, text: text, imageDataURLs: imageDataURLs)
                settleLocalSteer(steer, delivered: accepted)
                guard !accepted else { return }
                // The turn ended first, so the message runs as a turn of its own.
                _ = try await conversationManager.queueMissedSteer(taskID: task.id, text: text, imageDataURLs: imageDataURLs)
                refreshQueuedMessages()
                if let history = try? await conversationManager.history(taskID: task.id, messageLimit: Self.historyPageSize) {
                    applyHistoryMessages(history)
                    activities = history.activities
                }
            } catch {
                // Nothing took the message, so it returns to the composer.
                settleLocalSteer(steer, delivered: false)
                draft = [text, draft].filter { !$0.isEmpty }.joined(separator: "\n")
                if pendingImages.isEmpty { pendingImages = images }
                persistDraft()
                refreshQueuedMessages()
                // A stop of the message it steered is what the user asked for, not a failure.
                if !ConversationTurnLaunch.isStoppedBeforeStart(error) { errorMessage = error.localizedDescription }
            }
        }
    }

    func retryQueuedMessage(_ message: QueuedConversationMessage) {
        Task { @MainActor in
            do {
                let retried = try await conversationManager.retryQueuedMessage(taskID: task.id, messageID: message.id, onUserInput: { request in
                    showUserInputRequest(request)
                })
                guard retried else {
                    throw BridgeCommandError(code: "operation_failed", message: "The queued follow-up still needs your attention.")
                }
                let history = try await conversationManager.history(taskID: task.id, messageLimit: Self.historyPageSize)
                applyHistoryMessages(history)
                activities = history.activities
                answeredAsyncQuestionIDs = Set(history.answeredAsyncQuestionIDs)
                refreshQueuedMessages()
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func addImageData(_ data: Data) throws {
        let wasOversizedInput = data.count > 10_000_000
        let bitmap = wasOversizedInput
            ? Self.thumbnailBitmap(from: data)
            : NSBitmapImageRep(data: data)
        guard let bitmap else {
            throw BridgeCommandError(code: "invalid_argument", message: "Choose up to 8 valid images that fit within 10 MB after encoding.")
        }
        try addImage(bitmap, preferJPEG: wasOversizedInput)
    }
}
