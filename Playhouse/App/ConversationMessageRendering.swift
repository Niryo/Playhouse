import AppKit
import SwiftData
import SwiftUI

extension TaskConversationView {

    @ViewBuilder
    var activityDisclosureButtonLabel: some View {
        if isDisplayingActiveResponse, let responseStartedAt {
            TimelineView(.periodic(from: responseStartedAt, by: 1)) { timeline in
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

    func activityDisclosureContents(workingFor: String? = nil, workedFor: String? = nil) -> some View {
        return HStack(spacing: 7) {
            if let workingFor {
                Text("Working for \(workingFor)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("codex-working-duration")
            } else if let workedFor {
                Text(workedFor.isEmpty ? "Worked for" : "Worked for \(workedFor)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("codex-worked-duration")
            } else {
                Text("Codex activity")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Image(systemName: isActivityExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .accessibilityIdentifier("codex-activity-chevron")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // After the frame, so the whole row the button spans takes the click.
        .contentShape(Rectangle())
    }

    @ViewBuilder
    func messageBubble(_ message: ConversationMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .assistant {
                if message.asyncQuestions == nil &&
                    Self.displayableAssistantText(message.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isResponding {
                    EmptyView()
                } else if message.asyncQuestions != nil {
                    asyncQuestionBubble(message)
                } else {
                    assistantBubble(message)
                }
                Spacer(minLength: 70)
            } else {
                Spacer(minLength: 70)
                userBubble(message)
            }
        }
        .frame(maxWidth: .infinity)
    }

    func asyncQuestionKey(messageID: String, index: Int) -> String {
        "\(messageID):\(index)"
    }

    func asyncQuestionWasAnswered(_ message: ConversationMessage) -> Bool {
        answeredAsyncQuestionIDs.contains(message.id)
            || queuedMessages.contains { $0.asyncQuestionItemID == message.id }
    }

    func asyncQuestionBubble(_ message: ConversationMessage) -> some View {
        let questions = message.asyncQuestions ?? []
        let answered = asyncQuestionWasAnswered(message)
        return VStack(alignment: .leading, spacing: 12) {
            Text(assistantLabel(for: message))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                let answerKey = asyncQuestionKey(messageID: message.id, index: index)
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.title)
                        .font(.system(size: 15, weight: .semibold))
                    if let options = question.options, !options.isEmpty {
                        if !answered && !isReadOnly {
                            ForEach(Array(options.enumerated()), id: \.offset) { optionIndex, option in
                                Button {
                                    asyncQuestionAnswers[answerKey] = option
                                } label: {
                                    Label(option, systemImage: asyncQuestionAnswers[answerKey] == option ? "largecircle.fill.circle" : "circle")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .buttonHoverPointer()
                                .nativeHelp("Choose this answer for \(question.title)")
                                .accessibilityIdentifier("async-question-option-\(message.id)-\(index)-\(optionIndex)")
                                .accessibilityValue(asyncQuestionAnswers[answerKey] == option ? "selected" : "not selected")
                            }
                            TextField("Other answer", text: Binding(
                                get: {
                                    let answer = asyncQuestionAnswers[answerKey] ?? ""
                                    return options.contains(answer) ? "" : answer
                                },
                                set: { asyncQuestionAnswers[answerKey] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("async-question-other-\(message.id)-\(index)")
                        } else {
                            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                                Text(option).font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                    } else if !answered && !isReadOnly {
                        TextField("Your answer", text: Binding(
                                get: { asyncQuestionAnswers[answerKey] ?? "" },
                                set: { asyncQuestionAnswers[answerKey] = $0 }
                            ))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("async-question-answer-\(message.id)-\(index)")
                    }
                }
            }
            if answered {
                Text(answeredAsyncQuestionIDs.contains(message.id) ? "Answered" : "Pending")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else if !isReadOnly {
                Button("Send answers") { submitAsyncQuestions(message) }
                    .buttonStyle(.borderedProminent)
                    .buttonHoverPointer()
                    .nativeHelp("Send your answers to \(provider.displayName)")
                    .disabled(isSubmittingLiveMessage || isLoadingHistory || questions.enumerated().contains { index, _ in
                        let key = asyncQuestionKey(messageID: message.id, index: index)
                        return (asyncQuestionAnswers[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    })
                    .accessibilityIdentifier("submit-async-questions-\(message.id)")
            }
        }
        .padding(15)
        .frame(maxWidth: 620, alignment: .leading)
        .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 17))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("async-question-\(message.id)")
    }

    func submitAsyncQuestions(_ message: ConversationMessage) {
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

    func assistantBubble(_ message: ConversationMessage) -> some View {
        let displayText = Self.displayableAssistantText(message.text)
        let accessibilityText = displayText.count <= 1_000 && !displayText.isEmpty
            ? displayText
            : "Response from \((message.provider ?? provider).displayName)"
        let responseAnnotations = responseAnnotationReferences(for: message)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let createdAt = message.createdAt {
                    Text(createdAt, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("message-time-\(message.id)")
                }
                Text(assistantLabel(for: message))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("assistant-provider-\(message.id)")
            }

            ForEach(Array(message.imageDataURLs.enumerated()), id: \.offset) { index, dataURL in
                if let image = Self.chatImage(fromDataURL: dataURL, messageID: message.id, index: index) {
                    Button { selectedChatImage = image } label: {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 520, maxHeight: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open attached image")
                    .accessibilityIdentifier("chat-image-\(message.id)-\(index)")
                    .buttonHoverPointer()
                    .nativeHelp("Open image at full size")
                }
            }
            if !displayText.isEmpty {
                assistantMarkdownContent(displayText, messageID: message.id, responseAnnotations: responseAnnotations)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(WorkspaceTheme.conversationText)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(accessibilityText)
                    .accessibilityIdentifier("assistant-message-\(message.id)")
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    func userBubble(_ message: ConversationMessage) -> some View {
        let isPlayhouseSent = message.isPlayhouseSent
        let accessibleText = isPlayhouseSent ? PlayhouseSentMessage.displayText(message.text) : Self.displayableUserText(message.text)
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .trailing, spacing: 8) {
                ForEach(Array(message.imageDataURLs.enumerated()), id: \.offset) { index, dataURL in
                    if let image = Self.chatImage(fromDataURL: dataURL, messageID: message.id, index: index) {
                        Button { selectedChatImage = image } label: {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open attached image")
                        .accessibilityIdentifier("chat-image-\(message.id)-\(index)")
                        .buttonHoverPointer()
                        .nativeHelp("Open image at full size")
                    }
                }
                let visibleText = accessibleText
                if isPlayhouseSent {
                    Label(PlayhouseSentMessage.senderLabel(message.text), systemImage: "gearshape.2")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("playhouse-message-label-\(message.id)")
                }
                let mentions = isPlayhouseSent ? [] : messageMentions(message, visibleText: visibleText)
                if !visibleText.isEmpty {
                    let userMessageRange: (ConversationTextSource) -> NSRange? = { source in
                        source.blockID == 0 && source.endBlockID == 0
                            ? NSRange(location: source.startOffset, length: source.endOffset - source.startOffset) : nil
                    }
                    let highlightedRanges = annotations.filter { $0.messageID == message.id }.compactMap { userMessageRange($0.source) }
                    let chatRanges = sideChatRanges(messageID: message.id, rangeOf: userMessageRange)
                    let fullText = SelectableAnnotationText(
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
                        .fixedSize(horizontal: false, vertical: true)
                    Group {
                        // The preview cannot draw comments or side chats, so a message carrying
                        // either always shows the selectable text that does.
                        if isPlayhouseSent && highlightedRanges.isEmpty && chatRanges.isEmpty {
                            CollapsibleAutomaticMessageText(
                                text: visibleText,
                                messageID: message.id,
                                isExpanded: Binding(
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
                        // Anchored on the text like assistant blocks; as a ZStack sibling of the
                        // bubble the hint's popover ignored clicks on its controls.
                        .overlay(alignment: .topLeading) {
                            selectionHint(messageID: message.id, anchorID: 0)
                                .offset(y: -16)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        // The border is part of the background so the selection hint above stays clickable.
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(isPlayhouseSent ? Color.primary.opacity(0.04) : WorkspaceTheme.inputBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(
                                            Color.primary.opacity(isPlayhouseSent ? 0.18 : 0.2),
                                            style: StrokeStyle(lineWidth: 1, dash: isPlayhouseSent ? [4, 3] : [])
                                        )
                                )
                        }
                }
                if let createdAt = message.createdAt {
                    Text(createdAt, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("message-time-\(message.id)")
                }
            }
            .frame(maxWidth: 620, alignment: .trailing)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibleText.isEmpty ? "Attached image" : accessibleText)
            .accessibilityIdentifier(isPlayhouseSent ? "playhouse-message-\(message.id)" : "user-message-\(message.id)")
        }
    }

    static func markdownAttributedText(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)))
            ?? AttributedString(markdown)
    }

    /// Every transcript body re-evaluation re-renders each assistant block, so parsed Markdown is
    /// memoized by its exact inputs instead of being re-parsed for an unchanged block.
    /// Bounded because a streaming block adds a key for every partial text it passes through.
    static let markdownPlainTextCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 500
        return cache
    }()
    static let markdownNSAttributedStringCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 500
        return cache
    }()

    static func markdownPlainText(_ markdown: String) -> String {
        if let cached = markdownPlainTextCache.object(forKey: markdown as NSString) {
            return cached as String
        }
        let text = String(Self.markdownAttributedText(markdown).characters)
        markdownPlainTextCache.setObject(text as NSString, forKey: markdown as NSString)
        return text
    }

    /// Bridges Markdown-parsed text to `NSAttributedString`, resizing inline code/bold/italic
    /// runs to `baseFont`'s point size (preserving their monospace/bold/italic traits) instead of
    /// the parser's own default-size font, so inline formatting matches the surrounding body text.
    static func markdownNSAttributedString(_ markdown: String, baseFont: NSFont) -> NSAttributedString {
        let cacheKey = "\(baseFont.fontName)|\(baseFont.pointSize)|\(markdown)" as NSString
        if let cached = markdownNSAttributedStringCache.object(forKey: cacheKey) {
            return cached
        }
        let attributed = Self.markdownAttributedText(markdown)
        // Fonts are applied on the NSAttributedString because NSFont is not Sendable,
        // which AttributedString's AppKit font attribute requires.
        let result = NSMutableAttributedString(attributed)
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let font: NSFont
            if intent.contains(.code) {
                // Slightly smaller than the prose, which a monospaced face reads larger than.
                font = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular)
                InlineCodeStyle.apply(to: result, range: NSRange(run.range, in: attributed))
            } else {
                var traits: NSFontTraitMask = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
                guard !traits.isEmpty else { continue }
                font = NSFontManager.shared.convert(baseFont, toHaveTrait: traits)
            }
            result.addAttribute(.font, value: font, range: NSRange(run.range, in: attributed))
        }
        markdownNSAttributedStringCache.setObject(result, forKey: cacheKey)
        return result
    }

    static func displayableAssistantText(_ text: String) -> String {
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

    static func displayableUserText(_ text: String) -> String {
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

    static func containsSerializedAnnotations(_ text: String) -> Bool {
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

    func selectionHint(messageID: String, anchorID: Int) -> some View {
        Group {
            if let selection = currentTextSelection,
               selection.messageID == messageID, selection.anchorID == anchorID {
                GeometryReader { geometry in
                    let isBubbleOpen = annotationSelection?.id == selection.id
                    // The bubble's anchor: the selected lines themselves, kept inside the text.
                    Color.clear
                        .frame(width: max(1, min(selection.bounds.width, geometry.size.width)), height: max(1, selection.bounds.height))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .popover(isPresented: Binding(
                            get: { isBubbleOpen },
                            set: { isPresented in
                                if !isPresented, annotationSelection?.id == selection.id {
                                    annotationSelection = nil
                                    // A reopened bubble selected nothing, so no hint is left behind.
                                    if selection.isReopened, currentTextSelection?.id == selection.id { currentTextSelection = nil }
                                }
                            }
                        // Above the selected lines, where it covers what was read rather than what
                        // follows; AppKit moves it below them when the screen has no room above.
                        ), arrowEdge: .top) {
                            let comment = selection.annotationID.flatMap { id in annotations.first { $0.id == id } }
                            SideChatBubble(
                                selectedText: selection.text,
                                comment: comment?.comment,
                                canEditComment: comment.map { !isReadOnly && $0.pending && !inFlightAnnotationIDs.contains($0.id) } ?? false,
                                savedChat: selection.sideChatID.flatMap { id in sideChats.first { $0.id == id } },
                                models: modelOptions,
                                defaultModelName: provider.defaultModelName,
                                modelID: selectedModelID,
                                effort: selectedEffort,
                                send: { sideChatID, message, modelID, effort, onDelta in
                                    try await conversationManager.sideChat(
                                        taskID: task.id, sideChatID: sideChatID,
                                        selection: sideChatID == nil ? selection.text : nil,
                                        source: sideChatID == nil ? selection.source : nil,
                                        message: message, modelID: modelID, effort: effort, onDelta: onDelta
                                    )
                                },
                                onSaved: keepSideChat,
                                addComment: { comment in addAnnotation(selection, comment: comment) },
                                saveComment: { text in if let comment { editAnnotation(comment.id, comment: text) } },
                                close: { sideChatID in
                                    Task { await conversationManager.closeSideChat(taskID: task.id, sideChatID: sideChatID) }
                                },
                                dismiss: {
                                    if annotationSelection?.id == selection.id { annotationSelection = nil }
                                    if selection.isReopened, currentTextSelection?.id == selection.id { currentTextSelection = nil }
                                }
                            )
                        }
                        .position(
                            x: min(max(selection.bounds.midX, 1), max(1, geometry.size.width - 1)),
                            y: selection.bounds.midY
                        )
                    // The hint that opens the bubble, centered above the selection, gone while it is open.
                    if !isBubbleOpen {
                        Button {
                            // Text already commented or side-chatted reopens with them.
                            let opened = withSavedNotes(selection)
                            currentTextSelection = opened
                            annotationSelection = opened
                        } label: {
                            Label("Side chat", systemImage: "bubble.left.and.text.bubble.right")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
                                .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                        }
                        .buttonStyle(.plain)
                        .buttonHoverPointer()
                        .nativeHelp("Discuss or comment on the selected text")
                        .accessibilityLabel("Side chat")
                        .accessibilityIdentifier("side-chat-hint-button")
                        .frame(width: 120, height: 30)
                        .position(
                            x: min(max(selection.bounds.midX, 60), max(60, geometry.size.width - 60)),
                            y: selection.bounds.minY - 22
                        )
                        .zIndex(20)
                    }
                }
            }
        }
    }

    func assistantMarkdownContent(
        _ markdown: String,
        messageID: String? = nil,
        responseAnnotations: [ResponseAnnotationReference] = []
    ) -> some View {
        // Progress text without a message ID is short-lived, so only replies are kept.
        let blocks = messageID.map { messageID in
            Self.markdownBlocksCache.value(slot: messageID, key: markdown) { Self.markdownBlocks(markdown) }
        } ?? Self.markdownBlocks(markdown)
        return VStack(alignment: .leading, spacing: 7) {
            if let messageID {
                ForEach(AssistantMarkdownSegment.segments(of: blocks)) { segment in
                    switch segment {
                    case .prose(let prose):
                        assistantProseText(prose, messageID: messageID, responseAnnotations: responseAnnotations, wholeMessageText: markdown)
                    case .card(let block):
                        markdownCard(block)
                    }
                }
            } else {
                ForEach(blocks) { block in
                    switch block.kind {
                    case .heading(let level):
                        markdownBlockText(block)
                            .font(.system(size: level == 1 ? 19 : level == 2 ? 17 : 15, weight: .semibold))
                            .accessibilityIdentifier("assistant-markdown-heading-\(block.id)")
                    case .listItem:
                        // The marker is rendered through SelectableAnnotationText/NSTextView, so
                        // its baseline is AppKit's, as in a transcript reply's prose text.
                        HStack(alignment: .top, spacing: 7) {
                            markerText("•")
                            markdownBlockText(block)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(Self.markdownPlainText(block.text))
                        .accessibilityIdentifier("assistant-markdown-list-item-\(block.id)")
                    case .orderedListItem(let number):
                        HStack(alignment: .top, spacing: 7) {
                            markerText("\(number).")
                            markdownBlockText(block)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(number). " + Self.markdownPlainText(block.text))
                        .accessibilityIdentifier("assistant-markdown-ordered-list-item-\(block.id)")
                    case .codeBlock, .table:
                        markdownCard(block)
                    case .paragraph:
                        markdownBlockText(block)
                            .accessibilityIdentifier("assistant-markdown-paragraph-\(block.id)")
                            .padding(.bottom, 5)
                    }
                }
            }
        }
    }

    @ViewBuilder
    func markdownCard(_ block: AssistantMarkdownBlock) -> some View {
        switch block.kind {
        case .codeBlock(let language):
            CodeBlockCardView(blockID: block.id, code: block.text, language: language, font: block.font)
                .accessibilityIdentifier("assistant-markdown-code-block-\(block.id)")
        case .table(let headers, let alignments, let rows):
            TableBlockView(blockID: block.id, headers: headers, alignments: alignments, rows: rows, font: block.font)
        case .heading, .listItem, .orderedListItem, .paragraph:
            EmptyView()
        }
    }

    /// One reply's consecutive prose blocks in a single text view, so a selection, and the
    /// comment made on it, can run across headings, paragraphs, and list items.
    func assistantProseText(
        _ blocks: [AssistantMarkdownBlock],
        messageID: String,
        responseAnnotations: [ResponseAnnotationReference],
        wholeMessageText: String
    ) -> some View {
        let layout = AssistantProseLayout.cached(slot: "\(messageID):\(blocks[0].id)", blocks: blocks, responseAnnotations: responseAnnotations)
        return SelectableAnnotationText(
            text: layout.text.string,
            highlightedRanges: annotations.filter { $0.messageID == messageID }.compactMap(layout.range(of:)),
            chatRanges: sideChatRanges(messageID: messageID, rangeOf: layout.range(of:)),
            onHighlightClick: { range, bounds in
                reopenHighlight(range, bounds: bounds, messageID: messageID, anchorID: layout.id, rangeOf: layout.range(of:))
            },
            responseAnnotations: responseAnnotations,
            responseCommentSourcePrefix: "\(messageID):\(layout.id)",
            isAssistantText: true,
            onSelection: { range, text, bounds in
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
            formattedText: layout.text,
            wholeMessageText: wholeMessageText,
            accessibilityBlocks: layout.accessibilityBlocks
        )
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topLeading) { selectionHint(messageID: messageID, anchorID: layout.id) }
            .accessibilityIdentifier("assistant-markdown-prose-\(layout.id)")
            .padding(.bottom, layout.endsWithParagraph ? 5 : 0)
    }

    func markdownBlockText(_ block: AssistantMarkdownBlock) -> some View {
        let formatted = NSMutableAttributedString(attributedString: Self.markdownNSAttributedString(block.text, baseFont: block.font))
        // SwiftUI text has no pill drawing of its own; the inline code tint is drawn as a plain background.
        formatted.enumerateAttribute(InlineCodeStyle.attribute, in: NSRange(location: 0, length: formatted.length)) { value, range, _ in
            if let color = value as? NSColor { formatted.addAttribute(.backgroundColor, value: color, range: range) }
        }
        // A row is placed at the height it measured, and a stack around this text, like the question form's,
        // may hand that height out unevenly; keeping the text's natural height stops it truncating to one line.
        return Text((try? AttributedString(formatted, including: \.appKit)) ?? Self.markdownAttributedText(block.text))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Renders a list marker ("•" or "1.") through the same `SelectableAnnotationText`/NSTextView
    /// plumbing as list-item content, so the marker shares identical font metrics and
    /// `textContainerInset` with its sibling content view — guaranteeing `.top`-aligned HStack
    /// rows line up exactly, rather than approximating the gap between two different text-layout
    /// engines (SwiftUI `Text` vs. AppKit `NSTextView`) with a guessed padding constant.
    func markerText(_ marker: String) -> some View {
        let markerFont = marker == "•" ? AssistantProseLayout.bulletFont : AssistantProseLayout.markerFont
        // Measure the marker itself instead of a fixed column width, so two-digit (or longer)
        // ordered-list numbers ("10.", "100.") get enough width and never wrap/clip.
        let markerWidth = NSAttributedString(string: marker, attributes: [.font: markerFont]).size().width
        return SelectableAnnotationText(
            text: marker,
            highlightedRanges: [],
            onSelection: { _, _, _ in },
            formattedText: NSAttributedString(string: marker, attributes: [
                .font: markerFont,
                .foregroundColor: NSColor.labelColor,
            ]),
            font: markerFont
        )
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: ceil(markerWidth) + 4, alignment: .leading)
    }

    /// The ranges of a message's text that saved side chats discuss.
    func sideChatRanges(messageID: String, rangeOf: (ConversationTextSource) -> NSRange?) -> [NSRange] {
        sideChats.compactMap { sideChat in
            guard !sideChat.messages.isEmpty, let source = sideChat.source, source.messageID == messageID else { return nil }
            return rangeOf(source)
        }
    }

    /// `selection` with the comment and side chat already made on exactly that text, which
    /// its bubble opens with.
    func withSavedNotes(_ selection: AnnotationSelection) -> AnnotationSelection {
        var selection = selection
        let source = selection.source
        let matching = annotations.filter { $0.source == source }
        selection.annotationID = (matching.last(where: \.pending) ?? matching.last)?.id
        selection.sideChatID = sideChats.last { $0.source == source && !$0.messages.isEmpty }?.id
        return selection
    }

    /// Opens the bubble on the commented or side-chatted text `range` that was clicked, with
    /// its comment and side chat.
    func reopenHighlight(
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
        guard selection.isReopened else { return }
        currentTextSelection = selection
        annotationSelection = selection
    }

    /// Changes an unsent comment's text; saving it empty deletes the comment.
    func editAnnotation(_ id: UUID, comment: String) {
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

    func addAnnotation(_ selection: AnnotationSelection, comment: String) {
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

    func responseAnnotationReferences(for message: ConversationMessage) -> [ResponseAnnotationReference] {
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

    /// Splits a Markdown table row on `|`, dropping an optional leading/trailing pipe the way
    /// GFM tables are usually written (`| a | b |` as well as the bare `a | b`).
    static func markdownTableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Returns the per-column alignment if `line` is a valid GFM table separator row (each cell is
    /// dashes with optional leading/trailing colon, e.g. `---`, `:---`, `:---:`, `---:`), or `nil`
    /// if it isn't a separator row at all.
    static func markdownTableSeparatorAlignments(_ line: String) -> [MarkdownTableColumnAlignment]? {
        let cells = markdownTableCells(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [MarkdownTableColumnAlignment] = []
        for cell in cells {
            var body = cell
            let leadingColon = body.hasPrefix(":")
            if leadingColon { body.removeFirst() }
            let trailingColon = body.hasSuffix(":")
            if trailingColon { body.removeLast() }
            guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
            switch (leadingColon, trailingColon) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    static func orderedListPrefix(_ line: Substring) -> (number: Int, rest: Substring)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard afterDigits.first == ".", afterDigits.dropFirst().first == " " else { return nil }
        return (number, afterDigits.dropFirst(2))
    }

    static let markdownBlocksCache = ReplyRenderCache<[AssistantMarkdownBlock]>(countLimit: 2000)

    static func markdownBlocks(_ markdown: String) -> [AssistantMarkdownBlock] {
        var blocks: [AssistantMarkdownBlock] = []
        var paragraphLines: [String] = []
        var paragraphStart: Int?
        // Treat digit-dot-space prefixes as an ordered list when they start a block (any number,
        // as in CommonMark) or start at 1 while a paragraph is open, then increment by one;
        // otherwise a wrapped sentence like "3. 5 billion parameters…" would be mis-parsed.
        var lastOrderedNumber: Int?

        func flushParagraph() {
            guard let start = paragraphStart, !paragraphLines.isEmpty else { return }
            blocks.append(AssistantMarkdownBlock(
                id: start,
                kind: .paragraph,
                text: paragraphLines.joined(separator: " ")
            ))
            paragraphLines.removeAll()
            paragraphStart = nil
        }

        let rawLines = markdown.components(separatedBy: .newlines)
        var index = 0
        while index < rawLines.count {
            let rawLine = rawLines[index]
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else {
                // A blank line alone does not end an ordered list: Markdown allows a "loose"
                // list with blank lines between items, so `lastOrderedNumber` carries across
                // this gap and only resets once a non-list block actually interrupts it.
                flushParagraph()
                index += 1
                continue
            }
            if line.hasPrefix("```") {
                flushParagraph()
                lastOrderedNumber = nil
                let fenceStart = index
                let language = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                // Only a line consisting solely of backticks closes the fence, matching
                // CommonMark; a mere `hasPrefix("```")` would also match content lines inside the
                // code block itself (e.g. a code sample that demonstrates Markdown fences).
                while index < rawLines.count {
                    let candidate = rawLines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.count >= 3, candidate.allSatisfy({ $0 == "`" }) { break }
                    codeLines.append(rawLines[index])
                    index += 1
                }
                if index < rawLines.count { index += 1 } // consume closing fence
                blocks.append(AssistantMarkdownBlock(
                    id: fenceStart,
                    kind: .codeBlock(language: language.isEmpty ? nil : language),
                    text: codeLines.joined(separator: "\n")
                ))
                continue
            }
            if line.contains("|"), index + 1 < rawLines.count,
               let alignments = Self.markdownTableSeparatorAlignments(rawLines[index + 1].trimmingCharacters(in: .whitespaces)) {
                let headers = Self.markdownTableCells(line)
                // A separator row with a different cell count than the header isn't a valid GFM
                // table (e.g. a stray "---" thematic break after a line that merely contains "|");
                // fall through to the normal paragraph/heading/list handling below instead.
                if headers.count == alignments.count {
                    flushParagraph()
                    lastOrderedNumber = nil
                    let tableStart = index
                    index += 2 // consume the header row and the separator row
                    var rows: [[String]] = []
                    while index < rawLines.count {
                        let rowLine = rawLines[index].trimmingCharacters(in: .whitespaces)
                        guard !rowLine.isEmpty, rowLine.contains("|") else { break }
                        // GFM pads short rows and drops extra cells, so every row renders with the
                        // header's column count; without this a ragged row would shift the Grid's
                        // remaining columns out of alignment with their headers.
                        var cells = Self.markdownTableCells(rowLine)
                        if cells.count > headers.count { cells.removeSubrange(headers.count...) }
                        cells.append(contentsOf: Array(repeating: "", count: max(0, headers.count - cells.count)))
                        rows.append(cells)
                        index += 1
                    }
                    blocks.append(AssistantMarkdownBlock(
                        id: tableStart,
                        kind: .table(headers: headers, alignments: alignments, rows: rows),
                        text: ""
                    ))
                    continue
                }
            }
            if line.range(of: #":(?:playhouse-annotation|codex-annotation)\{index=\"\d+\"\}"#, options: .regularExpression) != nil {
                flushParagraph()
                lastOrderedNumber = nil
                blocks.append(AssistantMarkdownBlock(id: index, kind: .paragraph, text: line))
                index += 1
                continue
            }
            let headingPrefix = line.prefix(while: { $0 == "#" })
            if !headingPrefix.isEmpty, headingPrefix.count <= 6,
               line.dropFirst(headingPrefix.count).first == " " {
                flushParagraph()
                lastOrderedNumber = nil
                blocks.append(AssistantMarkdownBlock(
                    id: index,
                    kind: .heading(headingPrefix.count),
                    text: String(line.dropFirst(headingPrefix.count + 1))
                ))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushParagraph()
                lastOrderedNumber = nil
                blocks.append(AssistantMarkdownBlock(id: index, kind: .listItem, text: String(line.dropFirst(2))))
            } else if let ordered = orderedListPrefix(line[...]),
                      // As in CommonMark, only a list starting at 1 may interrupt a paragraph,
                      // so a wrapped line that happens to begin "3. " stays part of its paragraph.
                      // With no paragraph open, a new list may start at any number.
                      paragraphLines.isEmpty || ordered.number == 1,
                      ordered.number == (lastOrderedNumber.map { $0 + 1 } ?? (paragraphLines.isEmpty ? ordered.number : 1)) {
                flushParagraph()
                lastOrderedNumber = ordered.number
                blocks.append(AssistantMarkdownBlock(id: index, kind: .orderedListItem(number: ordered.number), text: String(ordered.rest)))
            } else {
                lastOrderedNumber = nil
                paragraphStart = paragraphStart ?? index
                paragraphLines.append(line)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }
}

/// An automatic message's text (a Playhouse nudge, a provider's own notice), which can carry
/// long context or handoff text. It shows the first lines, ending in an ellipsis, until the
/// reader expands it; a message that fits the preview shows in full with no control. Only the
/// presentation is shortened: the message keeps its whole text in history and in the bubble's
/// accessibility label.
struct CollapsibleAutomaticMessageText<FullText: View>: View {
    static var previewLineLimit: Int { 8 }

    let text: String
    let messageID: String
    @Binding var isExpanded: Bool
    let fullText: FullText
    @State private var previewHeight: CGFloat?
    @State private var wholeHeight: CGFloat?

    /// Unknown until both layouts are measured; the preview shows meanwhile, so a long
    /// message never flashes at full height.
    private var isTruncated: Bool? {
        guard let previewHeight, let wholeHeight else { return nil }
        return wholeHeight > previewHeight + 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if isExpanded || isTruncated == false {
                    fullText
                } else {
                    styledText
                        .lineLimit(Self.previewLineLimit)
                        .truncationMode(.tail)
                        // The selectable text's container inset, so a short message keeps its height.
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("automatic-message-preview-\(messageID)")
                }
            }
            .background(alignment: .topLeading) {
                // Both layouts at the shown width; only their heights matter.
                ZStack(alignment: .topLeading) {
                    styledText
                        .lineLimit(Self.previewLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewHeight = $0 }
                    styledText
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { wholeHeight = $0 }
                }
                .hidden()
                .accessibilityHidden(true)
            }
            if isTruncated == true {
                Button {
                    isExpanded.toggle()
                } label: {
                    Label(isExpanded ? "Show less" : "Show more", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .buttonHoverPointer()
                .nativeHelp(isExpanded ? "Show only the start of this automatic message" : "Show the whole automatic message")
                .accessibilityLabel(isExpanded ? "Collapse automatic message" : "Expand automatic message to show all text")
                .accessibilityValue(isExpanded ? "expanded" : "collapsed")
                .accessibilityIdentifier("automatic-message-toggle-\(messageID)")
            }
        }
    }

    private var styledText: some View {
        Text(text)
            .font(.system(size: 16))
            .lineSpacing(4)
            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }
}
