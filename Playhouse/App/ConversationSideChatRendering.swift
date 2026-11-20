import AppKit
import ImageIO
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct SideChatBubble: View {
    let taskID: UUID
    let selectedText: String
    /// Where the selection is in the transcript, which a new side chat is saved with.
    let source: ConversationTextSource?
    /// The task provider's models; the side chat starts on the task's model and effort.
    let models: [ConversationModelOption]
    let defaultModelName: String
    let conversationManager: RemoteConversationManager
    let dismiss: () -> Void

    /// The side chat or run this bubble follows, from `SideChatStore`, which owns its messages
    /// and turns: nil until the first message of a new selection is sent.
    @State private var runID: String?
    @State private var draft = ""
    @State private var didCopySelection = false
    /// The chat's natural height; the transcript shows all of it up to `maxTranscriptHeight`.
    @State private var transcriptContentHeight: CGFloat = 0
    /// This side chat's own model and effort: choosing them never changes the task's.
    @State private var modelID: String
    @State private var effort: ConversationEffort
    @State private var isModelPickerPresented = false

    init(
        taskID: UUID,
        selectedText: String,
        source: ConversationTextSource?,
        savedChat: SavedSideChat?,
        models: [ConversationModelOption],
        defaultModelName: String,
        modelID: String,
        effort: ConversationEffort,
        conversationManager: RemoteConversationManager,
        dismiss: @escaping () -> Void
    ) {
        self.taskID = taskID
        self.selectedText = selectedText
        self.source = source
        self.models = models
        self.defaultModelName = defaultModelName
        self.conversationManager = conversationManager
        self.dismiss = dismiss
        _runID = State(initialValue: savedChat?.id)
        // A saved side chat continues on the model its last message chose.
        _modelID = State(initialValue: savedChat?.modelID ?? modelID)
        _effort = State(initialValue: savedChat?.effort ?? effort)
    }

    /// The bubble opens compact and grows as the chat does: wider once it has messages, taller
    /// with each one, until `maxTranscriptHeight`, after which the chat scrolls.
    static let compactWidth: CGFloat = 480
    static let width: CGFloat = 660
    static let maxTranscriptHeight: CGFloat = 440
    /// The size of the chat's messages.
    static let bodyFontSize: CGFloat = 14

    private struct TranscriptHeightKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private var store: SideChatStore { .shared }
    private var run: SideChatRun? { store.run(taskID: taskID, id: runID) }
    private var messages: [SavedSideChat.Message] { store.messages(taskID: taskID, id: runID) }
    private var sideChatID: String? { store.sideChatID(taskID: taskID, id: runID) }
    private var isResponding: Bool { run?.isResponding ?? false }
    private var streamingText: String { run?.streamingText ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
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
        .onAppear { store.bubbleOpened(runID) }
        // A new selection's bubble shows its side chat once the first message opens one.
        .onChange(of: runID) { old, new in if old == nil { store.bubbleOpened(new) } }
        .onDisappear { store.bubbleClosed(taskID: taskID, id: runID, manager: conversationManager) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Label("Side chat", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 13, weight: .semibold))
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
                    .font(.system(size: 13))
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

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                        messageRow(message, index: index)
                    }
                    if isResponding {
                        if streamingText.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("side-chat-responding")
                        } else {
                            assistantText(streamingText)
                                .accessibilityIdentifier("side-chat-streaming-reply")
                        }
                    }
                    if let errorMessage = run?.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("side-chat-error")
                    }
                    Color.clear.frame(height: 1).id("side-chat-bottom")
                }
                .padding(.leading, 2)
                // The overlay scroller floats over the content's trailing edge; keep the text clear of it.
                .padding(.trailing, HoverRevealScrollers.scrollerWidth)
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
    private func messageRow(_ message: SavedSideChat.Message, index: Int) -> some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 40)
                Text(verbatim: message.text)
                    .font(.system(size: Self.bodyFontSize))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(message.text)
            .accessibilityIdentifier("side-chat-user-message-\(index)")
        } else {
            // Contains its blocks, so a formatted answer's headings and list items stay reachable.
            assistantText(message.text)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(message.text)
                .accessibilityIdentifier("side-chat-assistant-message-\(index)")
        }
    }

    private func assistantText(_ text: String) -> some View {
        AtomMarkdown(
            props: MarkdownProps(text: text, size: Double(Self.bodyFontSize), selectable: true),
            common: AtomCommon(fillWidth: true)
        )
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
                common: AtomCommon(testID: "side-chat-input-scroll-view", hint: "Return sends the message."),
                onChange: { draft = $0 }, onSubmit: sendDraft, onSteerSubmit: sendDraft,
                onCancel: dismiss
            )
            AtomStack(props: StackProps(axis: "h", spacing: 8)) {
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
        runID = store.send(
            taskID: taskID, id: runID, selectedText: selectedText, source: source,
            message: text, modelID: modelID, effort: effort, manager: conversationManager
        )
    }
}

/// One side chat's turns as the app runs them. It lives in `SideChatStore` rather than in a
/// bubble, so a question keeps being answered after its bubble closes or its conversation is
/// left, and the bubble reopened on its text shows the answer. Streaming text is its own
/// observed property, so a delta redraws the bubble showing it, not the transcript that
/// highlights the side chat's text.
@MainActor @Observable
final class SideChatRun {
    /// Stable for the run's lifetime: the side chat's id when it was already saved, otherwise a
    /// local placeholder that the transcript's highlight and a reopened bubble use until the
    /// first answer names the side chat.
    let id: String
    let taskID: UUID
    let selectedText: String
    let source: ConversationTextSource?
    let createdAt = Date.now
    /// The daemon's side chat, once one exists.
    var sideChatID: String?
    /// The question sent and not saved yet: still being answered, or failed.
    var pendingMessage: String?
    var modelID: String
    var effort: ConversationEffort
    var streamingText = ""
    var isResponding = false
    var errorMessage: String?

    init(id: String, taskID: UUID, selectedText: String, source: ConversationTextSource?, sideChatID: String?, modelID: String, effort: ConversationEffort) {
        self.id = id
        self.taskID = taskID
        self.selectedText = selectedText
        self.source = source
        self.sideChatID = sideChatID
        self.modelID = modelID
        self.effort = effort
    }
}

/// The side chats of every task the app has shown, kept for the app's lifetime: those saved on
/// the task and those whose turns are running. Sends run in tasks the store owns, so closing a
/// bubble or leaving the conversation never drops a question being answered. The same
/// `conversation.side_chat` bridge operation serves every provider, so nothing here depends on one.
@MainActor @Observable
final class SideChatStore {
    static let shared = SideChatStore()

    private var savedByTask: [UUID: [SavedSideChat]] = [:]
    private var runsByTask: [UUID: [SideChatRun]] = [:]
    /// How many bubbles show each side chat, by the id they opened on. A reply that arrives
    /// while none does ends the daemon's live session, as closing an idle bubble does.
    @ObservationIgnored private var shownCounts: [String: Int] = [:]
    @ObservationIgnored private var loadsInFlight: [UUID: Int] = [:]
    /// Replies kept while a load was in flight, which a list read before they were saved lacks.
    @ObservationIgnored private var repliesDuringLoad: [UUID: [String: SavedSideChat]] = [:]

    /// The task's side chats, oldest first, as the transcript highlights and reopens them. A
    /// question still being answered is the last message of its side chat, or, while it is the
    /// first, of a placeholder entry under its run's id, so its text highlights and reopens on
    /// the run before the daemon has saved anything.
    func sideChats(taskID: UUID) -> [SavedSideChat] {
        var chats = savedByTask[taskID] ?? []
        for run in runsByTask[taskID] ?? [] {
            guard let pending = run.pendingMessage else { continue }
            let question = SavedSideChat.Message(isUser: true, text: pending)
            if let sideChatID = run.sideChatID, let index = chats.firstIndex(where: { $0.id == sideChatID }) {
                chats[index].messages.append(question)
            } else {
                // Only the transcript and the bubble read this entry, never its provider or thread,
                // and the daemon never sees it.
                chats.append(SavedSideChat(
                    id: run.sideChatID ?? run.id, provider: .claude, threadID: "", modelID: run.modelID, effort: run.effort,
                    selectedText: run.selectedText, source: run.source, messages: [question], createdAt: run.createdAt
                ))
            }
        }
        return chats
    }

    /// The run a bubble opened on `id` follows: found by its placeholder or its side chat's id.
    func run(taskID: UUID, id: String?) -> SideChatRun? {
        guard let id else { return nil }
        return runsByTask[taskID]?.first { $0.id == id || $0.sideChatID == id }
    }

    /// The daemon's side chat a bubble opened on `id` continues, if one exists yet.
    func sideChatID(taskID: UUID, id: String?) -> String? {
        guard let id else { return nil }
        guard let run = run(taskID: taskID, id: id) else { return id }
        return run.sideChatID
    }

    /// The messages a bubble opened on `id` shows: the saved exchanges, then the unsaved question.
    func messages(taskID: UUID, id: String?) -> [SavedSideChat.Message] {
        guard let id else { return [] }
        let run = run(taskID: taskID, id: id)
        let chatID = run == nil ? id : run?.sideChatID
        var messages = chatID.flatMap { chatID in savedByTask[taskID]?.first { $0.id == chatID }?.messages } ?? []
        if let pending = run?.pendingMessage { messages.append(SavedSideChat.Message(isUser: true, text: pending)) }
        return messages
    }

    /// Reads the side chats saved on the task. Runs are kept apart, so none is dropped, and a
    /// reply kept while the read was in flight stays when the list predates it.
    func load(taskID: UUID, using manager: RemoteConversationManager) {
        loadsInFlight[taskID, default: 0] += 1
        Task { @MainActor in
            let loaded = try? await manager.savedSideChats(taskID: taskID)
            let replies = repliesDuringLoad[taskID] ?? [:]
            loadsInFlight[taskID, default: 1] -= 1
            if loadsInFlight[taskID] == 0 {
                loadsInFlight[taskID] = nil
                repliesDuringLoad[taskID] = nil
            }
            guard var chats = loaded else { return }
            for reply in replies.values {
                if let index = chats.firstIndex(where: { $0.id == reply.id }) {
                    if chats[index].messages.count < reply.messages.count { chats[index] = reply }
                } else {
                    chats.append(reply)
                }
            }
            if savedByTask[taskID] != chats { savedByTask[taskID] = chats }
        }
    }

    /// Keeps a side chat as saved after an answer.
    func keep(_ sideChat: SavedSideChat, taskID: UUID) {
        if loadsInFlight[taskID] != nil { repliesDuringLoad[taskID, default: [:]][sideChat.id] = sideChat }
        var chats = savedByTask[taskID] ?? []
        if let index = chats.firstIndex(where: { $0.id == sideChat.id }) {
            chats[index] = sideChat
        } else {
            chats.append(sideChat)
        }
        savedByTask[taskID] = chats
    }

    /// Sends `message` on the side chat a bubble opened on `id`, or opens one on `selectedText`
    /// when it opened on none, and returns the id the bubble follows from then on. A side chat
    /// still answering takes no second message.
    func send(
        taskID: UUID, id: String?, selectedText: String, source: ConversationTextSource?,
        message: String, modelID: String, effort: ConversationEffort, manager: RemoteConversationManager
    ) -> String {
        let run: SideChatRun
        if let existing = self.run(taskID: taskID, id: id) {
            guard !existing.isResponding else { return id ?? existing.id }
            run = existing
        } else {
            run = SideChatRun(
                id: id ?? "pending-side-chat-\(UUID().uuidString.lowercased())", taskID: taskID,
                selectedText: selectedText, source: source, sideChatID: id, modelID: modelID, effort: effort
            )
            runsByTask[taskID, default: []].append(run)
        }
        run.modelID = modelID
        run.effort = effort
        run.pendingMessage = message
        run.streamingText = ""
        run.errorMessage = nil
        run.isResponding = true
        let sideChatID = run.sideChatID
        Task { @MainActor in
            do {
                let reply = try await manager.sideChat(
                    taskID: taskID, sideChatID: sideChatID,
                    selection: sideChatID == nil ? run.selectedText : nil,
                    source: sideChatID == nil ? run.source : nil,
                    message: message, modelID: modelID, effort: effort
                ) { delta in run.streamingText += delta }
                // In one step, so the question never shows both pending and saved.
                run.sideChatID = reply.sideChatID
                keep(reply.sideChat, taskID: taskID)
                run.pendingMessage = nil
            } catch {
                run.errorMessage = error.localizedDescription
            }
            run.streamingText = ""
            run.isResponding = false
            if !isShown(run), let sideChatID = run.sideChatID {
                await manager.closeSideChat(taskID: taskID, sideChatID: sideChatID)
            }
        }
        return id ?? run.id
    }

    func bubbleOpened(_ id: String?) {
        guard let id else { return }
        shownCounts[id, default: 0] += 1
    }

    /// Ends the daemon's live session when the last bubble on an idle side chat closes; one
    /// still answering keeps it until its reply arrives.
    func bubbleClosed(taskID: UUID, id: String?, manager: RemoteConversationManager) {
        guard let id else { return }
        let count = (shownCounts[id] ?? 1) - 1
        shownCounts[id] = count > 0 ? count : nil
        let sideChatID: String
        if let run = run(taskID: taskID, id: id) {
            guard !run.isResponding, !isShown(run), let id = run.sideChatID else { return }
            sideChatID = id
        } else {
            // A saved side chat this app session sent nothing on, whose session a CLI may have opened.
            guard shownCounts[id] == nil else { return }
            sideChatID = id
        }
        Task { await manager.closeSideChat(taskID: taskID, sideChatID: sideChatID) }
    }

    private func isShown(_ run: SideChatRun) -> Bool {
        (shownCounts[run.id] ?? 0) > 0 || run.sideChatID.map { (shownCounts[$0] ?? 0) > 0 } == true
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
