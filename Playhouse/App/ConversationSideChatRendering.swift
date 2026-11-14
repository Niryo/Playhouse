import AppKit
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SideChatBubble: View {
    private struct Message: Identifiable {
        let id = UUID()
        let isUser: Bool
        let text: String
    }

    let selectedText: String
    /// The comment already made on the selection, if any.
    let comment: String?
    /// Whether that comment is unsent, and so can still be changed or deleted.
    let canEditComment: Bool
    /// The task provider's models; the side chat starts on the task's model and effort.
    let models: [ConversationModelOption]
    let defaultModelName: String
    let send: (_ sideChatID: String?, _ message: String, _ modelID: String, _ effort: ConversationEffort, _ onDelta: @escaping (String) -> Void) async throws -> SideChatReply
    /// Receives the side chat as saved after each answer.
    let onSaved: (SavedSideChat) -> Void
    let addComment: (String) -> Void
    /// Saves the edited comment; empty text deletes it.
    let saveComment: (String) -> Void
    let close: (_ sideChatID: String) -> Void
    let dismiss: () -> Void

    @State private var messages: [Message]
    @State private var draft = ""
    @State private var commentDraft: String
    @State private var sideChatID: String?
    @State private var isResponding = false
    @State private var streamingText = ""
    @State private var errorMessage: String?
    @State private var didCopySelection = false
    /// The chat's natural height; the transcript shows all of it up to `maxTranscriptHeight`.
    @State private var transcriptContentHeight: CGFloat = 0
    /// This side chat's own model and effort: choosing them never changes the task's.
    @State private var modelID: String
    @State private var effort: ConversationEffort
    @State private var isModelPickerPresented = false

    init(
        selectedText: String,
        comment: String?,
        canEditComment: Bool,
        savedChat: SavedSideChat?,
        models: [ConversationModelOption],
        defaultModelName: String,
        modelID: String,
        effort: ConversationEffort,
        send: @escaping (_ sideChatID: String?, _ message: String, _ modelID: String, _ effort: ConversationEffort, _ onDelta: @escaping (String) -> Void) async throws -> SideChatReply,
        onSaved: @escaping (SavedSideChat) -> Void,
        addComment: @escaping (String) -> Void,
        saveComment: @escaping (String) -> Void,
        close: @escaping (_ sideChatID: String) -> Void,
        dismiss: @escaping () -> Void
    ) {
        self.selectedText = selectedText
        self.comment = comment
        self.canEditComment = canEditComment
        self.models = models
        self.defaultModelName = defaultModelName
        self.send = send
        self.onSaved = onSaved
        self.addComment = addComment
        self.saveComment = saveComment
        self.close = close
        self.dismiss = dismiss
        _messages = State(initialValue: (savedChat?.messages ?? []).map { Message(isUser: $0.isUser, text: $0.text) })
        _commentDraft = State(initialValue: comment ?? "")
        _sideChatID = State(initialValue: savedChat?.id)
        // A saved side chat continues on the model its last message chose.
        _modelID = State(initialValue: savedChat?.modelID ?? modelID)
        _effort = State(initialValue: savedChat?.effort ?? effort)
    }

    /// The bubble opens compact and grows as the chat does: wider once it has messages, taller
    /// with each one, until `maxTranscriptHeight`, after which the chat scrolls.
    static let compactWidth: CGFloat = 442
    static let width: CGFloat = 572
    static let maxTranscriptHeight: CGFloat = 340

    private struct TranscriptHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            commentEditor
            transcript
            composer
        }
        .padding(14)
        .frame(width: messages.isEmpty && !isResponding ? Self.compactWidth : Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.18), value: transcriptContentHeight)
        .animation(.easeOut(duration: 0.18), value: messages.isEmpty)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("side-chat-bubble")
        .onDisappear { if let sideChatID { close(sideChatID) } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label("Side chat", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(selectedText, forType: .string)
                    didCopySelection = true
                } label: {
                    Image(systemName: didCopySelection ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .buttonHoverPointer()
                .nativeHelp("Copy selected text")
                .accessibilityLabel("Copy selected text")
                .accessibilityIdentifier("side-chat-copy-selection")
            }
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.orange.opacity(0.8))
                    .frame(width: 3)
                Text(verbatim: selectedText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Its value is the whole selection, however much of it the three lines show.
                    .accessibilityIdentifier("side-chat-selected-text")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The comment already made on the selection: a field that changes it while it is unsent,
    /// where saving it empty deletes it, or its text once sent.
    @ViewBuilder
    private var commentEditor: some View {
        if let comment {
            VStack(alignment: .leading, spacing: 5) {
                Text("Comment")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                if canEditComment {
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Empty, saving deletes the comment", text: $commentDraft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .lineLimit(1...5)
                            .onSubmit { saveComment(commentDraft) }
                            .onExitCommand(perform: dismiss)
                            .accessibilityLabel("Comment")
                            .accessibilityIdentifier("side-chat-comment-field")
                        Button("Save") { saveComment(commentDraft) }
                            .controlSize(.small)
                            .disabled(commentDraft == comment)
                            .buttonHoverPointer()
                            .nativeHelp("Save the comment. Saving it empty deletes it.")
                            .accessibilityIdentifier("side-chat-comment-save")
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.orange.opacity(0.45)))
                } else {
                    Text(verbatim: comment)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("side-chat-comment-text")
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        messageRow(message, index: index)
                    }
                    if isResponding {
                        if streamingText.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("side-chat-responding")
                        } else {
                            assistantText(streamingText)
                                .accessibilityIdentifier("side-chat-streaming-reply")
                        }
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("side-chat-error")
                    }
                    Color.clear.frame(height: 1).id("side-chat-bottom")
                }
                .padding(.horizontal, 2)
                .hoverRevealScrollers()
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: TranscriptHeightKey.self, value: geometry.size.height)
                })
            }
            .frame(height: min(max(transcriptContentHeight, 1), Self.maxTranscriptHeight))
            .onPreferenceChange(TranscriptHeightKey.self) { transcriptContentHeight = $0 }
            .accessibilityIdentifier("side-chat-transcript")
            .onChange(of: messages.count) { _, _ in proxy.scrollTo("side-chat-bottom", anchor: .bottom) }
            .onChange(of: streamingText) { _, _ in proxy.scrollTo("side-chat-bottom", anchor: .bottom) }
        }
    }

    @ViewBuilder
    private func messageRow(_ message: Message, index: Int) -> some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 40)
                Text(verbatim: message.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message.text)
            .accessibilityIdentifier("side-chat-user-message-\(index)")
        } else {
            assistantText(message.text)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(message.text)
                .accessibilityIdentifier("side-chat-assistant-message-\(index)")
        }
    }

    private func assistantText(_ text: String) -> some View {
        let markdown = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        return Text(markdown)
            .font(.system(size: 12.5))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        AtomStack(
            props: StackProps(axis: "v", spacing: 6, fill: "panel", fillOpacity: 1, cornerRadius: 16, stroke: "primary", strokeOpacity: 0.1),
            common: AtomCommon(padding: 9)
        ) {
            AtomEditor(
                props: EditorProps(
                    text: draft, placeholder: "Ask about the selection…", placeholderTestID: "side-chat-placeholder",
                    enabled: true, autofocus: true, inputTestID: "side-chat-input", inputLabel: "Side chat message"
                ),
                common: AtomCommon(testID: "side-chat-input-scroll-view", hint: "Return sends the message. Add comment adds it as a comment instead."),
                onChange: { draft = $0 }, onSubmit: sendDraft, onSteerSubmit: sendDraft,
                onCancel: dismiss
            )
            AtomStack(props: StackProps(axis: "h", spacing: 8)) {
                // An unsent comment is changed in its own field above instead; a sent one can't
                // be, so another comment can still be added on its text.
                if !canEditComment {
                    AtomButton(
                        common: AtomCommon(testID: "add-comment-button", label: "Comment", help: "Add what you typed as a comment on the selected text"),
                        action: { addComment(draft.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    ) {
                        AtomStack(
                            props: StackProps(axis: "h", fill: "primary", fillOpacity: 0.1, capsule: true),
                            common: AtomCommon(height: 26, paddingX: 10)
                        ) {
                            AtomLabel(props: LabelProps(text: "Comment", icon: "text.bubble", size: 12, weight: "semibold"))
                        }
                    }
                }
                AtomSpacer(props: SpacerProps(minLength: 0))
                ComposerModelPicker(
                    picker: modelPicker, prefix: "side-chat-",
                    toggle: { isModelPickerPresented.toggle() },
                    dismiss: { isModelPickerPresented = false },
                    selectModel: { id in
                        guard models.contains(where: { $0.id == id }) else { return }
                        modelID = id
                        effort = models.effort(effort, keptFor: id)
                    },
                    selectEffort: { value in if let chosen = ConversationEffort(rawValue: value) { effort = chosen } }
                )
                AtomButton(
                    props: ButtonProps(disabled: isSendDisabled),
                    // Its value names the side chat this bubble runs, once the first message opened one.
                    common: AtomCommon(testID: "side-chat-send-button", label: "Send to side chat", value: sideChatID, help: "Send to side chat"),
                    action: sendDraft
                ) {
                    AtomStack(
                        props: StackProps(axis: "h", fill: "accent", fillOpacity: 1, cornerRadius: 13),
                        common: AtomCommon(width: 26, height: 26, opacity: isSendDisabled ? 0.45 : 1)
                    ) {
                        AtomIcon(props: IconProps(name: "arrow.up", size: 11, weight: "bold", color: "white"))
                    }
                }
            }
        }
    }

    private var isSendDisabled: Bool {
        isResponding || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedModel: ConversationModelOption? {
        modelID.isEmpty ? models.first(where: \.isDefault) : models.first(where: { $0.id == modelID })
    }

    private var effortChoices: [ConversationEffort] {
        models.effortChoices(for: modelID)
    }

    /// The same model button and popover as the conversation's composer, for this side chat.
    private var modelPicker: ComposerModel.ModelPicker {
        let name = selectedModel?.name ?? (modelID.isEmpty ? defaultModelName : modelID)
        return ComposerModel.ModelPicker(
            name: name,
            effort: effort.title,
            label: "Side chat model: \(name), effort: \(effort.title)",
            open: isModelPickerPresented,
            models: models.map { option in
                .init(id: option.id, title: option.name, checked: option.id == selectedModel?.id, icon: nil, help: "Select \(option.name)", testID: "model-option-\(option.id)")
            },
            effortChoices: effortChoices.map { .init(value: $0.rawValue, label: $0.title) },
            selectedEffort: effort.rawValue
        )
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return }
        draft = ""
        messages.append(Message(isUser: true, text: text))
        isResponding = true
        streamingText = ""
        errorMessage = nil
        Task { @MainActor in
            do {
                let reply = try await send(sideChatID, text, modelID, effort) { delta in streamingText += delta }
                sideChatID = reply.sideChatID
                onSaved(reply.sideChat)
                let answer = reply.reply.isEmpty ? streamingText : reply.reply
                messages.append(Message(isUser: false, text: answer.trimmingCharacters(in: .whitespacesAndNewlines)))
            } catch {
                errorMessage = error.localizedDescription
            }
            streamingText = ""
            isResponding = false
        }
    }
}

final class CommentTrackingTextView: MeasuredTextView {
    var hoverTrackingOwner: AnyObject?
    /// A single click that leaves nothing selected, with the index of the character it hit.
    var onClickWithoutSelection: ((Int) -> Void)?
    /// The whole message this block belongs to; copying a fully selected block copies it all.
    var wholeMessageText: String?
    /// The prose blocks laid out in this view, exposed as their own accessibility elements so
    /// each heading, paragraph, and list item stays identifiable though they share one view.
    var accessibilityBlocks: [AccessibilityBlock] = [] {
        didSet { if accessibilityBlocks != oldValue { blockElements = nil } }
    }
    /// Accessibility clients hold on to children between queries, so the elements live as long
    /// as the blocks they describe.
    private var blockElements: [BlockAccessibilityElement]?
    private var hoverTrackingArea: NSTrackingArea?

    struct AccessibilityBlock: Equatable {
        let identifier: String
        let label: String
        let range: NSRange
    }

    private final class BlockAccessibilityElement: NSAccessibilityElement {
        weak var textView: NSTextView?
        let range: NSRange

        init(block: AccessibilityBlock, textView: NSTextView) {
            self.textView = textView
            range = block.range
            super.init()
            setAccessibilityRole(.group)
            setAccessibilityLabel(block.label)
            setAccessibilityIdentifier(block.identifier)
            setAccessibilityParent(textView)
        }

        /// Computed on each query, since the view moves as the transcript scrolls. Placed
        /// relative to the text view's own accessibility frame: converting through the window
        /// misses the transcript's scroll offset for a text view taller than the viewport.
        override func accessibilityFrame() -> NSRect {
            guard let textView,
                  let layoutManager = textView.layoutManager, let textContainer = textView.textContainer,
                  NSMaxRange(range) <= (textView.string as NSString).length else { return .zero }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
                .offsetBy(dx: textView.textContainerOrigin.x - textView.bounds.minX,
                          dy: textView.textContainerOrigin.y - textView.bounds.minY)
            // The text view is flipped, and screen coordinates grow upward from its bottom edge.
            let viewFrame = textView.accessibilityFrame()
            return NSRect(x: viewFrame.minX + bounds.minX, y: viewFrame.maxY - bounds.maxY,
                          width: bounds.width, height: bounds.height)
        }
    }

    override func accessibilityChildren() -> [Any]? {
        let children = super.accessibilityChildren() ?? []
        guard !accessibilityBlocks.isEmpty else { return children }
        let elements = blockElements ?? accessibilityBlocks.map { BlockAccessibilityElement(block: $0, textView: self) }
        blockElements = elements
        return children + elements
    }

    override func copy(_ sender: Any?) {
        guard let wholeMessageText, selectedRange() == NSRange(location: 0, length: string.utf16.count) else {
            super.copy(sender)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(wholeMessageText, forType: .string)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    private var pendingClick: DispatchWorkItem?

    /// The text view tracks the drag that selects text until the mouse goes up, so the
    /// selection is settled by the time `super` returns. The click is reported once the
    /// double-click interval passes without another, so double-clicking still selects a word.
    override func mouseDown(with event: NSEvent) {
        pendingClick?.cancel()
        pendingClick = nil
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        guard event.clickCount == 1, selectedRange().length == 0, onClickWithoutSelection != nil,
              let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else { return }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: nil)
        // A click on the character itself, not on the empty end of its line.
        guard layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            .contains(containerPoint) else { return }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        let click = DispatchWorkItem { [weak self] in
            guard let self, self.selectedRange().length == 0 else { return }
            self.pendingClick = nil
            self.onClickWithoutSelection?(index)
        }
        pendingClick = click
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: click)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard hoverTrackingArea == nil, let hoverTrackingOwner else { return }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: hoverTrackingOwner,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }
}
