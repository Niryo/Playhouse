import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

extension TaskConversationView {

    @PHViewBuilder
    package var activityDisclosureButtonLabel: some PHView {
        if isDisplayingActiveResponse, let responseStartedAt {
            PHTimelineView(.periodic(from: responseStartedAt, by: 1)) { timeline in
                activityDisclosureContents(
                    workingFor: Self.durationLabel(Self.elapsedSeconds(since: responseStartedAt, now: timeline.date))
                )
            }
        } else {
            activityDisclosureContents(
                workedFor: completedResponseDuration.map(Self.durationLabel) ?? (hasCompletedAssistantResponse ? "" : nil)
            )
        }
    }

    package func activityDisclosureContents(workingFor: String? = nil, workedFor: String? = nil) -> some PHView {
        return AtomStack(props: StackProps(axis: "h", spacing: 7, hitSurface: true), common: AtomCommon(fillWidth: true)) {
            if let workingFor {
                AtomText(
                    props: TextProps(text: "Working for \(workingFor)", size: 12, weight: "medium", color: "accent"),
                    common: AtomCommon(testID: "codex-working-duration")
                )
            } else if let workedFor {
                AtomText(
                    props: TextProps(text: workedFor.isEmpty ? "Worked for" : "Worked for \(workedFor)", size: 12, weight: "medium", color: "secondary"),
                    common: AtomCommon(testID: "codex-worked-duration")
                )
            } else {
                AtomText(props: TextProps(text: "Codex activity", size: 12, weight: "medium", color: "secondary"))
            }
            AtomIcon(
                props: IconProps(name: (isActivityExpanded ? PHIcon.chevronDown : PHIcon.chevronRight).name, size: 9, weight: "semibold"),
                common: AtomCommon(testID: "codex-activity-chevron")
            )
        }
    }

    @PHViewBuilder
    package func messageBubble(_ message: ConversationMessage) -> some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 0, align: "top"), common: AtomCommon(fillWidth: true, frameAlign: "center")) {
            if message.role == .assistant {
                if message.asyncQuestions == nil &&
                    Self.displayableAssistantText(message.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isResponding {
                    PHEmptyView()
                } else if message.asyncQuestions != nil {
                    asyncQuestionBubble(message)
                } else {
                    assistantBubble(message)
                }
                // The standalone chat's replies run to the edge its questions end at; the
                // room that leaves beside the transcript holds the chat's page labels.
                AtomSpacer(props: SpacerProps(minLength: task.isStandaloneChat ? 0 : 70))
            } else {
                AtomSpacer(props: SpacerProps(minLength: task.isStandaloneChat ? 40 : 70))
                userBubble(message)
            }
        }
    }

    package func asyncQuestionKey(messageID: String, index: Int) -> String {
        "\(messageID):\(index)"
    }

    package func asyncQuestionWasAnswered(_ message: ConversationMessage) -> Bool {
        answeredAsyncQuestionIDs.contains(message.id)
            || queuedMessages.contains { $0.asyncQuestionItemID == message.id }
    }

    package func asyncQuestionBubble(_ message: ConversationMessage) -> some PHView {
        let questions = message.asyncQuestions ?? []
        let answered = asyncQuestionWasAnswered(message)
        let hasEmptyAnswer = questions.enumerated().contains { index, _ in
            let key = asyncQuestionKey(messageID: message.id, index: index)
            return (asyncQuestionAnswers[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return AtomStack(
            props: StackProps(spacing: 12, align: "leading", group: true, fill: "panel", cornerRadius: 17),
            common: AtomCommon(testID: "async-question-\(message.id)", maxWidth: 620, frameAlign: "leading", paddingX: 15, paddingY: 15)
        ) {
            AtomText(props: TextProps(text: assistantLabel(for: message), size: 11, weight: "semibold", color: "secondary"))
            PHForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                let answerKey = asyncQuestionKey(messageID: message.id, index: index)
                AtomStack(props: StackProps(spacing: 8, align: "leading")) {
                    AtomText(props: TextProps(text: question.title, size: 15, weight: "semibold"))
                    if let options = question.options, !options.isEmpty {
                        if !answered && !isReadOnly {
                            PHForEach(Array(options.enumerated()), id: \.offset) { optionIndex, option in
                                let isChosen = asyncQuestionAnswers[answerKey] == option
                                AtomButton(
                                    common: AtomCommon(
                                        testID: "async-question-option-\(message.id)-\(index)-\(optionIndex)",
                                        value: isChosen ? "selected" : "not selected",
                                        help: "Choose this answer for \(question.title)",
                                        fillWidth: true
                                    ),
                                    action: { asyncQuestionAnswers[answerKey] = option }
                                ) {
                                    AtomLabel(props: LabelProps(text: option, icon: (isChosen ? PHIcon.largecircleFillCircle : PHIcon.circle).name))
                                }
                            }
                            let answer = asyncQuestionAnswers[answerKey] ?? ""
                            AtomTextField(
                                props: TextFieldProps(text: options.contains(answer) ? "" : answer, placeholder: "Other answer"),
                                common: AtomCommon(testID: "async-question-other-\(message.id)-\(index)"),
                                onChange: { asyncQuestionAnswers[answerKey] = $0 }
                            )
                        } else {
                            PHForEach(Array(options.enumerated()), id: \.offset) { _, option in
                                AtomText(props: TextProps(text: option, size: 13, color: "secondary"))
                            }
                        }
                    } else if !answered && !isReadOnly {
                        AtomTextField(
                            props: TextFieldProps(text: asyncQuestionAnswers[answerKey] ?? "", placeholder: "Your answer"),
                            common: AtomCommon(testID: "async-question-answer-\(message.id)-\(index)"),
                            onChange: { asyncQuestionAnswers[answerKey] = $0 }
                        )
                    }
                }
            }
            if answered {
                AtomText(props: TextProps(text: answeredAsyncQuestionIDs.contains(message.id) ? "Answered" : "Pending", size: 12, color: "secondary"))
            } else if !isReadOnly {
                AtomButton(
                    props: ButtonProps(style: "prominent", disabled: isSubmittingLiveMessage || isLoadingHistory || hasEmptyAnswer),
                    common: AtomCommon(testID: "submit-async-questions-\(message.id)", help: "Send your answers to \(provider.displayName)"),
                    action: { submitAsyncQuestions(message) }
                ) {
                    AtomText(props: TextProps(text: "Send answers"))
                }
            }
        }
    }

    package func submitAsyncQuestions(_ message: ConversationMessage) {
        guard let questions = message.asyncQuestions, !questions.isEmpty else { return }
        let answers = questions.indices.map { asyncQuestionAnswers[asyncQuestionKey(messageID: message.id, index: $0)] ?? "" }
        let priorAssistantMessages = Dictionary(
            uniqueKeysWithValues: messages
                .filter { $0.role == .assistant }
                .map { ($0.id, $0.text) }
        )
        isSubmittingLiveMessage = true
        Task { @MainActor in
            defer { isSubmittingLiveMessage = false }
            do {
                let result = try await conversationManager.answerAsyncQuestion(taskID: task.id, question: message, answers: answers)
                if !result.queued { answeredAsyncQuestionIDs.insert(message.id) }
                if let history = result.history {
                    applyHistoryMessages(history)
                    activities = history.activities
                    answeredAsyncQuestionIDs = Set(history.answeredAsyncQuestionIDs)
                } else if result.queued {
                    refreshQueuedMessages()
                } else {
                    var settledHistory: ConversationHistory?
                    for _ in 0..<50 {
                        if let history = try? await conversationManager.history(taskID: task.id, messageLimit: Self.historyPageSize),
                           history.messages.contains(where: { candidate in
                               candidate.role == .assistant &&
                               candidate.asyncQuestions == nil &&
                               !candidate.text.isEmpty &&
                               priorAssistantMessages[candidate.id] != candidate.text
                           }) {
                            settledHistory = history
                            break
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    if let settledHistory {
                        applyHistoryMessages(settledHistory)
                        activities = settledHistory.activities
                        answeredAsyncQuestionIDs = Set(settledHistory.answeredAsyncQuestionIDs)
                    } else {
                        messages.append(ConversationMessage(id: UUID().uuidString, role: .user, text: result.text))
                    }
                }
                errorMessage = nil
            } catch { errorMessage = error.localizedDescription }
        }
    }

    package func assistantBubble(_ message: ConversationMessage) -> some PHView {
        let displayText = Self.displayableAssistantText(message.text)
        let accessibilityText = displayText.count <= 1_000 && !displayText.isEmpty
            ? displayText
            : "Response from \((message.provider ?? provider).displayName)"
        let responseAnnotations = responseAnnotationReferences(for: message)
        return AssistantReplyHoverScope { isHovering in
            AtomStack(props: StackProps(spacing: 6, align: "leading"), common: AtomCommon(maxWidth: 620, frameAlign: "leading")) {
                AtomStack(props: StackProps(axis: "h", spacing: 6)) {
                    if let createdAt = message.createdAt {
                        messageTime(createdAt, messageID: message.id)
                    }
                    AtomText(
                        props: TextProps(text: assistantLabel(for: message), size: 11, weight: "semibold", color: "secondary"),
                        common: AtomCommon(testID: "assistant-provider-\(message.id)")
                    )
                    if !displayText.isEmpty {
                        CopyMessageButton(markdown: displayText, messageID: message.id, isRevealed: isHovering)
                    }
                }

                deferredImagesPlaceholder(for: message)
                PHForEach(Array(transcriptImageDataURLs(for: message).enumerated()), id: \.offset) { index, dataURL in
                    if let image = Self.chatImage(fromDataURL: dataURL, messageID: message.id, index: index) {
                        chatImageButton(image, messageID: message.id, index: index, maxWidth: 520, maxHeight: 420)
                    }
                }
                if !displayText.isEmpty {
                    AtomStack(
                        props: StackProps(align: "leading", group: true, fill: "panel", cornerRadius: 17, textSize: 16, textColor: "text"),
                        common: AtomCommon(testID: "assistant-message-\(message.id)", label: accessibilityText, paddingX: 15, paddingY: 11)
                    ) {
                        assistantMarkdown(displayText, messageID: message.id, responseAnnotations: responseAnnotations)
                    }
                }
            }
        }
    }

    /// A message's send time, under a user bubble and before an assistant's provider label.
    private func messageTime(_ createdAt: Date, messageID: String) -> some PHView {
        AtomText(
            props: TextProps(text: createdAt.formatted(.dateTime.hour().minute()), size: 10, color: "tertiary"),
            common: AtomCommon(testID: "message-time-\(messageID)")
        )
    }

    /// An attached image, which opens at full size.
    private func chatImageButton(_ image: PHPlatformImage, messageID: String, index: Int, maxWidth: Double, maxHeight: Double) -> some PHView {
        AtomButton(
            common: AtomCommon(testID: "chat-image-\(messageID)-\(index)", label: "Open attached image", help: "Open image at full size"),
            action: { selectedChatImage = image }
        ) {
            AtomImage(
                platformImage: image, cornerRadius: 12,
                common: AtomCommon(maxWidth: maxWidth, maxHeight: maxHeight)
            )
        }
    }

    /// A message's images: its own, or those read since its history page deferred them.
    package func transcriptImageDataURLs(for message: ConversationMessage) -> [String] {
        guard message.imageDataURLs.isEmpty, message.imagesDeferred == true else { return message.imageDataURLs }
        return deferredMessageImages[Self.deferredImageKey(message)] ?? []
    }

    package static func deferredImageKey(_ message: ConversationMessage) -> String {
        "\(message.turnID ?? "")/\(message.id)"
    }

    /// Stands in for images the history page left out, and reads them once its row is rendered.
    @PHViewBuilder
    package func deferredImagesPlaceholder(for message: ConversationMessage) -> some PHView {
        if message.imageDataURLs.isEmpty, message.imagesDeferred == true,
           deferredMessageImages[Self.deferredImageKey(message)] == nil {
            AtomStack(
                props: StackProps(axis: "h", spacing: 8, fill: "panel", cornerRadius: 12, summary: true),
                common: AtomCommon(testID: "deferred-chat-image-\(message.id)", label: "Loading attached image", width: 220, height: 96)
            ) {
                AtomSpinner(props: SpinnerProps(size: "small"))
                AtomText(props: TextProps(text: "Loading image…", size: 12, color: "secondary"))
            }
            .onAppear { requestDeferredImages(for: message) }
        }
    }

    /// Queues a message whose placeholder was rendered. Rows that render together are read with one request.
    package func requestDeferredImages(for message: ConversationMessage) {
        let key = Self.deferredImageKey(message)
        guard deferredMessageImages[key] == nil, !deferredImageLoads.contains(key) else { return }
        let startsRead = deferredImageRequests.isEmpty
        guard deferredImageRequests.insert(key).inserted, startsRead else { return }
        // Not the row's own task: a row scrolled away mid-read must not drop the others' images.
        Task { @MainActor in
            await Task.yield()
            await loadRequestedDeferredImages()
        }
    }

    package func loadRequestedDeferredImages() async {
        let waiting = conversationMessages.filter {
            let key = Self.deferredImageKey($0)
            return deferredImageRequests.contains(key) && deferredMessageImages[key] == nil
        }
        let keys = Set(waiting.map(Self.deferredImageKey))
        deferredImageRequests.removeAll()
        guard !waiting.isEmpty else { return }
        deferredImageLoads.formUnion(keys)
        defer { deferredImageLoads.subtract(keys) }
        // A failed read leaves the placeholders up; they ask again when next rendered.
        guard let images = try? await conversationManager.messageImages(
            taskID: task.id, messageIDs: Array(Set(waiting.map(\.id)))
        ) else { return }
        for message in waiting {
            let entries = images.filter { $0.id == message.id }
            let match = entries.first(where: { $0.turnID == message.turnID }) ?? (entries.count == 1 ? entries.first : nil)
            deferredMessageImages[Self.deferredImageKey(message)] = match?.imageDataURLs ?? []
        }
    }

    package func userBubble(_ message: ConversationMessage) -> some PHView {
        let isPlayhouseSent = message.isPlayhouseSent
        let accessibleText = isPlayhouseSent ? PlayhouseSentMessage.displayText(message.text) : Self.displayableUserText(message.text)
        return AtomStack(props: StackProps(axis: "z", align: "topLeading")) {
            AtomStack(
                props: StackProps(spacing: 8, align: "trailing", group: true),
                common: AtomCommon(
                    testID: isPlayhouseSent ? "playhouse-message-\(message.id)" : "user-message-\(message.id)",
                    label: accessibleText.isEmpty ? "Attached image" : accessibleText,
                    maxWidth: 620, frameAlign: "trailing"
                )
            ) {
                deferredImagesPlaceholder(for: message)
                PHForEach(Array(transcriptImageDataURLs(for: message).enumerated()), id: \.offset) { index, dataURL in
                    if let image = Self.chatImage(fromDataURL: dataURL, messageID: message.id, index: index) {
                        chatImageButton(image, messageID: message.id, index: index, maxWidth: 260, maxHeight: 220)
                    }
                }
                let visibleText = accessibleText
                if isPlayhouseSent {
                    AtomLabel(
                        props: LabelProps(text: PlayhouseSentMessage.senderLabel(message.text), icon: PHIcon.gearshapeTwo.name, size: 10, weight: "medium", color: "secondary"),
                        common: AtomCommon(testID: "playhouse-message-label-\(message.id)")
                    )
                }
                let mentions = isPlayhouseSent ? [] : messageMentions(message, visibleText: visibleText)
                if !visibleText.isEmpty {
                    let userMessageRange: (ConversationTextSource) -> NSRange? = { source in
                        source.blockID == 0 && source.endBlockID == 0
                            ? NSRange(location: source.startOffset, length: source.endOffset - source.startOffset) : nil
                    }
                    let highlightedRanges = annotations.filter { $0.messageID == message.id }.compactMap { userMessageRange($0.source) }
                    let chatRanges = sideChatRanges(messageID: message.id, rangeOf: userMessageRange)
                    let fullText = AtomStack(common: AtomCommon(fixedHeight: true)) {
                        PHNativeSelectableText(
                            text: visibleText,
                            highlightedRanges: highlightedRanges,
                            mentionRanges: mentions.map(\.range),
                            chatRanges: chatRanges,
                            onHighlightClick: { range, bounds in
                                reopenHighlight(range, bounds: bounds, messageID: message.id, anchorID: 0, rangeOf: userMessageRange)
                            },
                            textColor: isPlayhouseSent ? .secondaryLabelColor : .labelColor,
                            onSelection: { range, selectedText, bounds in
                                currentTextSelection = selectedText.isEmpty ? nil : AnnotationSelection(
                                    messageID: message.id, anchorID: 0, blockID: 0, startOffset: range.location,
                                    endBlockID: 0, endOffset: NSMaxRange(range), text: selectedText, bounds: bounds
                                )
                            }
                        )
                    }
                    // The border never takes clicks, so the selection hint above stays clickable.
                    AtomStack(
                        props: StackProps(
                            fill: isPlayhouseSent ? "primary" : "input", fillOpacity: isPlayhouseSent ? 0.04 : nil, cornerRadius: 10,
                            stroke: "primary", strokeOpacity: isPlayhouseSent ? 0.18 : 0.2, strokeWidth: 1, dash: isPlayhouseSent ? [4, 3] : nil
                        ),
                        common: AtomCommon(paddingX: 16, paddingY: 11)
                    ) {
                        // Anchored on the text like assistant blocks; as a ZStack sibling of the
                        // bubble the hint's popover ignored clicks on its controls.
                        AtomOverlay(props: OverlayProps(align: "topLeading")) {
                            PHGroup {
                                // The preview cannot draw comments or side chats, so a message carrying
                                // either always shows the selectable text that does.
                                if isPlayhouseSent && highlightedRanges.isEmpty && chatRanges.isEmpty {
                                    CollapsibleAutomaticMessageText(
                                        text: visibleText,
                                        messageID: message.id,
                                        isExpanded: PHBinding(
                                            get: { expandedAutomaticMessageTexts.contains(message.text) },
                                            set: { expanded in
                                                if expanded { expandedAutomaticMessageTexts.insert(message.text) }
                                                else { expandedAutomaticMessageTexts.remove(message.text) }
                                            }
                                        ),
                                        fullText: fullText
                                    )
                                } else {
                                    fullText
                                }
                            }
                        } overlay: {
                            selectionHint(messageID: message.id, anchorID: 0, raisedBy: 16)
                        }
                    }
                }
                if let createdAt = message.createdAt {
                    messageTime(createdAt, messageID: message.id)
                }
            }
        }
    }

    package static func displayableAssistantText(_ text: String) -> String {
        // Runs for every assistant row on every transcript pass: most replies have no
        // plan tags and no surrounding whitespace, so skip building copies for them.
        // A byte scan for the tags' "<", because a substring search costs more here
        // than the replacements it would skip.
        let whitespace = CharacterSet.whitespacesAndNewlines
        if !text.utf8.contains(UInt8(ascii: "<")),
           text.unicodeScalars.first.map({ !whitespace.contains($0) }) ?? true,
           text.unicodeScalars.last.map({ !whitespace.contains($0) }) ?? true {
            return text
        }
        return text
            .replacingOccurrences(of: "<proposed_plan>", with: "")
            .replacingOccurrences(of: "</proposed_plan>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    package static func displayableUserText(_ text: String) -> String {
        let text = MentionText.displayText(text)
        let commentEnvelopeStart = text.range(of: "<playhouse-comment-context>")
            ?? text.range(of: "<playhouse-annotation-context>")
        let commentEnvelopeEnd = commentEnvelopeStart.flatMap { envelope in
            text.range(of: "</playhouse-comment-context>", range: envelope.upperBound..<text.endIndex)
                ?? text.range(of: "</playhouse-annotation-context>", range: envelope.upperBound..<text.endIndex)
        }
        if let envelope = commentEnvelopeStart, commentEnvelopeEnd != nil,
           Self.containsSerializedAnnotations(text) {
            return String(text[..<envelope.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let legacyHeader = "# Response annotations:\nThe following JSON contains comments on selected conversation text, in array order."
        if let header = text.range(of: legacyHeader), Self.containsSerializedAnnotations(text) {
            return String(text[..<header.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let commentHeader = "# Response comments:\nThe following JSON contains comments on selected conversation text, in array order."
        if let header = text.range(of: commentHeader), Self.containsSerializedAnnotations(text) {
            return String(text[..<header.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    package static func containsSerializedAnnotations(_ text: String) -> Bool {
        let start = text.range(of: "<response-comments>") ?? text.range(of: "<response-annotations>")
        guard let start,
              let end = text.range(of: "</response-comments>", range: start.upperBound..<text.endIndex)
                ?? text.range(of: "</response-annotations>", range: start.upperBound..<text.endIndex),
              let data = String(text[start.upperBound..<end.lowerBound]).data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !items.isEmpty else { return false }
        return items.allSatisfy { item in
            guard item["text"] is String, (item["comment"] is String || item["annotation"] is String),
                  let source = item["source"] as? [String: Any] else { return false }
            return source["messageId"] is String && source["blockID"] is Int
                && source["startOffset"] is Int && source["endOffset"] is Int
        }
    }

    /// `raise` lifts the bubble's anchor and the hint above the selection into a message's top padding.
    package func selectionHint(messageID: String, anchorID: Int, raisedBy raise: CGFloat = 0) -> some PHView {
        PHGroup {
            if let selection = currentTextSelection,
               selection.messageID == messageID, selection.anchorID == anchorID {
                PHGeometryReader { geometry in
                    let isOpen = annotationSelection?.id == selection.id
                    // The popover's anchor: the selected lines themselves, kept inside the text. One
                    // popover shows either action: sibling popovers presented as the selection appears
                    // (reopening highlighted text) showed the wrong one.
                    selectionAnchor(selection, in: geometry.size)
                        // Above the selected lines, where it covers what was read rather than what
                        // follows; AppKit moves it below them when the screen has no room above.
                        .popover(isPresented: selectionPopoverBinding(selection), arrowEdge: .top) {
                            switch selectionAction {
                            case .sideChat:
                                SideChatBubble(
                                    taskID: task.id,
                                    selectedText: selection.text,
                                    source: selection.source,
                                    savedChat: selection.sideChatID.flatMap { id in sideChats.first { $0.id == id } },
                                    models: modelOptions,
                                    defaultModelName: provider.defaultModelName,
                                    modelID: selectedModelID,
                                    effort: selectedEffort,
                                    conversationManager: conversationManager,
                                    dismiss: { dismissSelectionPopover(selection) }
                                )
                            case .comment:
                                commentPopover(selection)
                            }
                        }
                        .position(
                            x: min(max(selection.bounds.midX, 1), max(1, geometry.size.width - 1)),
                            y: selection.bounds.midY - raise
                        )
                    // The actions that open them, centered above the selection, gone while one is open.
                    // The scroll view clips what is above its top, so there they are pinned just inside
                    // it, over the selection's visible lines, and never further down than the selection's end.
                    let visibleTop = -geometry.frame(in: .scrollView).minY
                    let pillY = min(
                        max(selection.bounds.minY - raise - 22, visibleTop + 4 + SelectionActionsPill.height / 2),
                        selection.bounds.maxY + 22
                    )
                    if !isOpen {
                        AtomStack(common: AtomCommon(width: Double(SelectionActionsPill.width), height: Double(SelectionActionsPill.height))) {
                            SelectionActionsPill(
                                comment: { openSelectionPopover(selection, action: .comment) },
                                sideChat: { openSelectionPopover(selection, action: .sideChat) }
                            )
                        }
                        .position(
                            x: min(max(selection.bounds.midX, SelectionActionsPill.width / 2), max(SelectionActionsPill.width / 2, geometry.size.width - SelectionActionsPill.width / 2)),
                            y: pillY
                        )
                        .zIndex(20)
                    }
                }
            }
        }
    }

    private func selectionAnchor(_ selection: AnnotationSelection, in size: CGSize) -> some PHView {
        AtomStack(common: AtomCommon(
            width: Double(max(1, min(selection.bounds.width, size.width))), height: Double(max(1, selection.bounds.height)),
            passThrough: true, decorative: true
        )) {
            PHEmptyView()
        }
    }

    private func selectionPopoverBinding(_ selection: AnnotationSelection) -> PHBinding<Bool> {
        PHBinding(
            get: { annotationSelection?.id == selection.id },
            set: { isPresented in
                if !isPresented, annotationSelection?.id == selection.id {
                    dismissSelectionPopover(selection)
                }
            }
        )
    }

    /// Opens the comment popover or side chat bubble on `selection`; text already commented or
    /// side-chatted opens with them.
    package func openSelectionPopover(_ selection: AnnotationSelection, action: SelectionAction) {
        let opened = selection.isReopened ? selection : withSavedNotes(selection)
        selectionAction = action
        currentTextSelection = opened
        annotationSelection = opened
    }

    package func dismissSelectionPopover(_ selection: AnnotationSelection) {
        if annotationSelection?.id == selection.id { annotationSelection = nil }
        // Closing it ends the selection too: actions left over the text would cover a click that
        // reopens the highlight.
        if currentTextSelection?.id == selection.id { currentTextSelection = nil }
    }

    /// The comment popover on `selection`: its unsent comment opens to be changed or discarded,
    /// and text with only a sent comment shows it and adds another.
    package func commentPopover(_ selection: AnnotationSelection) -> some PHView {
        let matching = annotations.filter { $0.source == selection.source }
        let editable = isReadOnly ? nil : matching.last { $0.pending && !inFlightAnnotationIDs.contains($0.id) }
        let sent = matching.last { $0.id != editable?.id }
        return CommentPopover(
            editingComment: editable?.comment,
            sentComment: sent?.comment,
            submit: { text in
                if let editable {
                    editAnnotation(editable.id, comment: text)
                } else {
                    addAnnotation(selection, comment: text.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            },
            discard: { if let editable { editAnnotation(editable.id, comment: "") } },
            dismiss: { dismissSelectionPopover(selection) }
        )
    }

    /// A reply's Markdown through the Markdown atom at the transcript's reading size. Its host
    /// adds the transcript's comments, side chats and selection actions to each prose run.
    package func assistantMarkdown(
        _ markdown: String,
        messageID: String,
        responseAnnotations: [ResponseAnnotationReference]
    ) -> some PHView {
        AtomMarkdown(
            props: MarkdownProps(text: markdown, size: Double(Self.transcriptTextSize), selectable: true),
            host: MarkdownTextHost(
                slot: messageID,
                identifierPrefix: "assistant-markdown",
                // A reply's links open as they did before replies were an atom.
                opensAnyLink: true,
                blocksAreGroups: true,
                responseAnnotations: responseAnnotations,
                highlightedRanges: { layout in
                    annotations.filter { $0.messageID == messageID }.compactMap(layout.range(of:))
                },
                chatRanges: { layout in sideChatRanges(messageID: messageID, rangeOf: layout.range(of:)) },
                onHighlightClick: { layout, range, bounds in
                    reopenHighlight(range, bounds: bounds, messageID: messageID, anchorID: layout.id, rangeOf: layout.range(of:))
                },
                onSelection: { layout, range, text, bounds in
                    guard !text.isEmpty, let positions = layout.blockPositions(of: range) else {
                        currentTextSelection = nil
                        return
                    }
                    currentTextSelection = AnnotationSelection(
                        messageID: messageID, anchorID: layout.id,
                        blockID: positions.blockID, startOffset: positions.startOffset,
                        endBlockID: positions.endBlockID, endOffset: positions.endOffset,
                        text: text, bounds: bounds
                    )
                },
                overlay: { layout in PHAnyView(selectionHint(messageID: messageID, anchorID: layout.id)) }
            )
        )
    }

    /// Replies, and the questions and progress notes written like them, read at this size.
    package static let transcriptTextSize: CGFloat = 16

    /// The ranges of a message's text that saved side chats discuss.
    package func sideChatRanges(messageID: String, rangeOf: (ConversationTextSource) -> NSRange?) -> [NSRange] {
        sideChats.compactMap { sideChat in
            guard !sideChat.messages.isEmpty, let source = sideChat.source, source.messageID == messageID else { return nil }
            return rangeOf(source)
        }
    }

    /// `selection` with the comment and side chat already made on exactly that text, which
    /// its bubble opens with.
    package func withSavedNotes(_ selection: AnnotationSelection) -> AnnotationSelection {
        var selection = selection
        let source = selection.source
        let matching = annotations.filter { $0.source == source }
        selection.annotationID = (matching.last(where: \.pending) ?? matching.last)?.id
        selection.sideChatID = sideChats.last { $0.source == source && !$0.messages.isEmpty }?.id
        return selection
    }

    /// Opens what the commented or side-chatted text `range` that was clicked holds: its comment
    /// popover or its side chat bubble, or, holding both, the actions that choose between them.
    package func reopenHighlight(
        _ range: NSRange, bounds: CGRect, messageID: String, anchorID: Int,
        rangeOf: (ConversationTextSource) -> NSRange?
    ) {
        let source = annotations.last { $0.messageID == messageID && rangeOf($0.source) == range }?.source
            ?? sideChats.last { $0.source?.messageID == messageID && !$0.messages.isEmpty && $0.source.flatMap(rangeOf) == range }?.source
        guard let source else { return }
        let text = annotations.last { $0.source == source }?.text ?? sideChats.last { $0.source == source }?.selectedText ?? ""
        let selection = withSavedNotes(AnnotationSelection(
            messageID: messageID, anchorID: anchorID, blockID: source.blockID, startOffset: source.startOffset,
            endBlockID: source.endBlockID, endOffset: source.endOffset, text: text, bounds: bounds
        ))
        switch (selection.annotationID, selection.sideChatID) {
        case (nil, nil):
            return
        case (.some, .some):
            // Commented and side-chatted text shows both actions to choose between.
            annotationSelection = nil
            currentTextSelection = selection
        case (.some, nil):
            openSelectionPopover(selection, action: .comment)
        case (nil, .some):
            openSelectionPopover(selection, action: .sideChat)
        }
    }

    /// Discards every unsent comment the composer holds; ones a running send carries stay with it.
    package func discardPendingAnnotations() {
        annotations.removeAll { $0.pending && !inFlightAnnotationIDs.contains($0.id) }
        annotationSelection = nil
        currentTextSelection = nil
        if !isReadOnly { persistPendingAnnotations() }
    }

    /// Changes an unsent comment's text; saving it empty deletes the comment.
    package func editAnnotation(_ id: UUID, comment: String) {
        guard let index = annotations.firstIndex(where: { $0.id == id && $0.pending }),
              !inFlightAnnotationIDs.contains(id) else { return }
        let comment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        if comment.isEmpty {
            annotations.remove(at: index)
        } else {
            annotations[index].comment = comment
        }
        annotationSelection = nil
        currentTextSelection = nil
        guard !isReadOnly else { return }
        let taskID = task.id
        let taskManager = BoardTaskManager(modelContext: modelContext)
        let previousSave = composerDraft.annotationSaveTask
        composerDraft.annotationSaveTask = Task { @MainActor in
            await previousSave?.value
            do {
                try await taskManager.editPendingAnnotation(taskID, annotationID: id, comment: comment)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    package func addAnnotation(_ selection: AnnotationSelection, comment: String) {
        guard annotationSelection?.id == selection.id else { return }
        annotations.append(ConversationAnnotation(
            id: UUID(), messageID: selection.messageID, blockID: selection.blockID,
            startOffset: selection.startOffset, endBlockID: selection.endBlockID, endOffset: selection.endOffset,
            text: selection.text, comment: comment
        ))
        // Saved here, where the user adds it, not by an `onChange(of: annotations)` on the
        // composer: that observer stopped the transcript following the newest streamed text.
        if !isReadOnly { persistPendingAnnotations() }
        annotationSelection = nil
        currentTextSelection = nil
    }

    package func responseAnnotationReferences(for message: ConversationMessage) -> [ResponseAnnotationReference] {
        guard let messageIndex = messages.firstIndex(where: { $0.id == message.id }),
              let userMessage = messages[..<messageIndex].last(where: { $0.role == .user }),
              let start = userMessage.text.range(of: "<response-comments>")
                ?? userMessage.text.range(of: "<response-annotations>"),
              let end = userMessage.text.range(of: "</response-comments>", range: start.upperBound..<userMessage.text.endIndex)
                ?? userMessage.text.range(of: "</response-annotations>", range: start.upperBound..<userMessage.text.endIndex),
              let data = String(userMessage.text[start.upperBound..<end.lowerBound]).data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let text = item["text"] as? String,
                  let comment = item["comment"] as? String ?? item["annotation"] as? String else { return nil }
            return ResponseAnnotationReference(text: text, comment: comment)
        }
    }

}

/// An automatic message's text (a Playhouse nudge, a provider's own notice), which can carry
/// long context or handoff text. It shows the first lines, ending in an ellipsis, until the
/// reader expands it; a message that fits the preview shows in full with no control. Only the
/// presentation is shortened: the message keeps its whole text in history and in the bubble's
/// accessibility label.
package struct CollapsibleAutomaticMessageText<FullText: PHView>: PHView {
    package static var previewLineLimit: Int { 8 }

    package let text: String
    package let messageID: String
    @PHBinding package var isExpanded: Bool
    package let fullText: FullText
    @PHState private var previewHeight: CGFloat?
    @PHState private var wholeHeight: CGFloat?

    /// Unknown until both layouts are measured; the preview shows meanwhile, so a long
    /// message never flashes at full height.
    private var isTruncated: Bool? {
        guard let previewHeight, let wholeHeight else { return nil }
        return wholeHeight > previewHeight + 1
    }

    package var body: some PHView {
        AtomStack(props: StackProps(spacing: 4, align: "leading")) {
            // The measuring layouts lie under the shown text, which they never resize.
            AtomOverlay(props: OverlayProps(align: "topLeading")) {
                PHGroup {
                    if isExpanded || isTruncated == false {
                        fullText
                    } else {
                        // The selectable text's container inset (paddingY), so a short message keeps its height.
                        styledText(
                            lineLimit: Self.previewLineLimit, wrap: false,
                            common: AtomCommon(testID: "automatic-message-preview-\(messageID)", fillWidth: true, paddingY: 5)
                        )
                    }
                }
            } overlay: {
                // Both layouts at the shown width; only their heights matter.
                AtomStack(props: StackProps(axis: "z", align: "topLeading"), common: AtomCommon(decorative: true)) {
                    styledText(lineLimit: Self.previewLineLimit, wrap: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
                    styledText(lineLimit: nil, wrap: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { wholeHeight = $0 }
                }
                .hidden()
            }
            if isTruncated == true {
                AtomButton(
                    common: AtomCommon(
                        testID: "automatic-message-toggle-\(messageID)",
                        label: isExpanded ? "Collapse automatic message" : "Expand automatic message to show all text",
                        value: isExpanded ? "expanded" : "collapsed",
                        help: isExpanded ? "Show only the start of this automatic message" : "Show the whole automatic message"
                    ),
                    action: { isExpanded.toggle() }
                ) {
                    AtomLabel(props: LabelProps(
                        text: isExpanded ? "Show less" : "Show more",
                        icon: (isExpanded ? PHIcon.chevronUp : PHIcon.chevronDown).name,
                        size: 11, weight: "medium", color: "secondary"
                    ))
                }
            }
        }
    }

    /// The message at the transcript's size in the secondary label color; `wrap` grows it to its
    /// whole height instead of truncating it.
    private func styledText(lineLimit: Int?, wrap: Bool, common: AtomCommon = AtomCommon()) -> some PHView {
        AtomText(
            props: TextProps(text: text, size: 16, color: "secondary", lineLimit: lineLimit, lineSpacing: 4, wrap: wrap, truncation: "tail"),
            common: common
        )
    }

    package init(text: String, messageID: String, isExpanded: PHBinding<Bool>, fullText: FullText) {
        self.text = text
        self.messageID = messageID
        _isExpanded = isExpanded
        self.fullText = fullText
    }
}
