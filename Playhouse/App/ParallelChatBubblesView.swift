import SwiftUI
import SwiftData

/// A question sent in parallel whose bubble the chat doesn't list yet.
struct PendingParallelChatPrompt: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// The app's parallel sends and closes. A send outlives the chat sidebar that started it, so
/// its bubble keeps running when the chat closes; the bubbles themselves are read from the store.
@MainActor @Observable
final class ParallelChatBubbleStore {
    static let shared = ParallelChatBubbleStore()

    private(set) var pendingPrompts: [PendingParallelChatPrompt] = []
    /// Bubbles whose close is on its way to the daemon.
    private(set) var closingIDs: Set<UUID> = []
    var errorMessage: String?
    /// Bumped whenever a send or close changes which bubbles exist.
    private(set) var revision = 0

    /// `restoreDraft` hands the question back to the composer when no bubble could take it.
    func send(text: String, imageDataURLs: [String], using manager: RemoteConversationManager, restoreDraft: @escaping () -> Void = {}) {
        let pending = PendingParallelChatPrompt(text: text)
        pendingPrompts.append(pending)
        Task { @MainActor in
            var created = false
            do {
                try await manager.sendInParallel(text: text, imageDataURLs: imageDataURLs) {
                    created = true
                    self.pendingPrompts.removeAll { $0.id == pending.id }
                    self.revision += 1
                }
            } catch {
                errorMessage = error.localizedDescription
                if !created { restoreDraft() }
            }
            pendingPrompts.removeAll { $0.id == pending.id }
            revision += 1
        }
    }

    func close(_ bubbleID: UUID, using manager: RemoteConversationManager) {
        guard closingIDs.insert(bubbleID).inserted else { return }
        Task { @MainActor in
            do {
                try await manager.closeParallelChatBubble(id: bubbleID)
            } catch {
                errorMessage = error.localizedDescription
            }
            closingIDs.remove(bubbleID)
            revision += 1
        }
    }
}

/// The standalone chat's open parallel bubbles, floating out of the chat sidebar's right edge:
/// each shows its question and a spinner while it answers. A finished bubble opens into a
/// larger conversation, and closing it returns its page to the chat.
struct ParallelChatBubbleStack: View {
    static let width: CGFloat = 260

    let bubbles: [StandaloneChat]
    let pendingPrompts: [PendingParallelChatPrompt]
    let runningIDs: Set<UUID>
    let closingIDs: Set<UUID>
    let openBubbleID: UUID?
    let onOpen: (UUID) -> Void
    let onClose: (UUID) -> Void

    var body: some View {
        AtomStack(props: StackProps(axis: "v", spacing: 8, align: "leading"), common: AtomCommon(testID: "parallel-chat-bubbles")) {
            ForEach(bubbles, id: \.id) { bubble in
                bubbleCard(
                    id: bubble.id, prompt: bubble.parallelPrompt ?? bubble.title,
                    isRunning: runningIDs.contains(bubble.id), isClosing: closingIDs.contains(bubble.id)
                )
            }
            ForEach(pendingPrompts) { pending in
                bubbleCard(id: nil, prompt: pending.text, isRunning: true, isClosing: false)
            }
        }
    }

    private func bubbleCard(id: UUID?, prompt: String, isRunning: Bool, isClosing: Bool) -> some View {
        let isOpen = id != nil && id == openBubbleID
        return AtomStack(
            props: StackProps(axis: "h", spacing: 8, align: "center", group: true, fill: "panel", fillOpacity: 1, cornerRadius: 14, stroke: isOpen ? "accent" : "primary", strokeOpacity: isOpen ? 0.6 : 0.12),
            common: AtomCommon(testID: "parallel-chat-bubble", width: Double(Self.width), paddingX: 12, paddingY: 9)
        ) {
            // Beside the open button rather than in it, so each keeps its own identity.
            if isRunning || isClosing {
                AtomSpinner(props: SpinnerProps(size: "mini"), common: AtomCommon(testID: "parallel-chat-bubble-progress", label: "Answering"))
            } else {
                AtomIcon(props: IconProps(name: "checkmark.circle.fill", size: 12, weight: "semibold", color: "accent"), common: AtomCommon(testID: "parallel-chat-bubble-done", label: "Answered"))
            }
            AtomButton(
                props: ButtonProps(disabled: id == nil || isRunning),
                common: AtomCommon(
                    testID: "parallel-chat-bubble-open", label: prompt, value: isRunning ? "Answering" : "Answered",
                    help: isRunning ? "Still answering" : "Open this parallel page", fillWidth: true
                ),
                action: { if let id { onOpen(id) } }
            ) {
                AtomText(props: TextProps(text: prompt, size: 12, weight: "medium", lineLimit: 2), common: AtomCommon(fillWidth: true))
            }
            if let id {
                AtomButton(
                    props: ButtonProps(disabled: isRunning || isClosing),
                    common: AtomCommon(
                        testID: "parallel-chat-bubble-close", label: "Close parallel page",
                        help: isRunning ? "A parallel page closes once it has answered" : "Close and return this page to the chat"
                    ),
                    action: { onClose(id) }
                ) {
                    AtomIcon(props: IconProps(name: "xmark", size: 9, weight: "bold", color: "secondary"), common: AtomCommon(width: 16, height: 16))
                }
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}

/// The bubble's conversation, with its existing page header and back action.
struct ParallelChatBubblePanel: View {
    let bubble: StandaloneChat
    let onBack: () -> Void

    var body: some View {
        StandaloneChatPanel(chat: bubble, onOpenTask: { _, _ in }, onClose: onBack)
            .equatable()
            .id(bubble.id)
            .background(WorkspaceTheme.windowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.25), radius: 16, y: 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("parallel-chat-panel")
    }
}

struct ParallelChatPlaceholder: Identifiable, Equatable {
    let id: UUID
    let prompt: String
    let anchorTurnID: String?
}

/// The small row the chat keeps where a parallel bubble's page will return.
struct ParallelChatPlaceholderRow: View {
    let bubbleID: UUID
    let prompt: String

    var body: some View {
        AtomStack(props: StackProps(axis: "h", spacing: 8, align: "center", group: true), common: AtomCommon(testID: "parallel-chat-placeholder", paddingY: 4)) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            AtomStack(
                props: StackProps(axis: "h", spacing: 6, align: "center", fillOpacity: 0, capsule: true, stroke: "secondary", strokeOpacity: 0.35, dash: [3, 3]),
                common: AtomCommon(paddingX: 10, paddingY: 3)
            ) {
                AtomIcon(props: IconProps(name: "square.on.square", size: 10, weight: "semibold", color: "secondary"))
                AtomText(props: TextProps(text: prompt, size: 11, weight: "medium", color: "secondary", lineLimit: 1), common: AtomCommon(testID: "parallel-chat-placeholder-prompt"))
            }
            .layoutPriority(1)
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
        }
        .accessibilityValue(bubbleID.uuidString)
    }
}

extension KanbanBoardView {
    /// On narrow displays the expanded view uses the stack's space so the composer stays reachable.
    var parallelChatBubblesOverlay: some View {
        let store = ParallelChatBubbleStore.shared
        let runningIDs = Set(parallelBubbles.map(\.id).filter { conversationRuntime.isTurnActive(taskID: $0) })
        let expandedBubble = parallelBubbles.first { $0.id == openParallelBubbleID }
        let sidebarEdge = ChatSidebarLayout.chatLeadingEdge + chatSidebarShownWidth + 12
        let window = NSApp.keyWindow
        let windowWidth = boardContentWidth > 0 ? boardContentWidth : window?.frame.width ?? sidebarEdge + 520
        let visibleRightEdge = (window?.screen ?? NSScreen.main)?.visibleFrame.maxX
        let visibleWidth = min(windowWidth, visibleRightEdge.map { $0 - (window?.frame.minX ?? 0) } ?? windowWidth)
        let idealPanelWidth: CGFloat = 520
        let expandedWidth = min(idealPanelWidth, max(320, visibleWidth - sidebarEdge - 12))
        let sideBySideWidth = sidebarEdge + ParallelChatBubbleStack.width + 12 + idealPanelWidth + 12
        let showsStack = expandedBubble == nil || visibleWidth >= sideBySideWidth
        let leading = expandedBubble != nil && !showsStack
            ? max(0, min(sidebarEdge, visibleWidth - expandedWidth - 12))
            : sidebarEdge
        return ZStack(alignment: .topLeading) {
            // Always present, so the bubbles are read even before the first one shows, such as
            // after a relaunch.
            Color.clear
                .frame(width: 0, height: 0)
                .task(id: parallelBubblesRefreshKey) { refreshParallelBubbles() }
            if isChatOverlayVisible, !parallelBubbles.isEmpty || !store.pendingPrompts.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    if showsStack {
                        ParallelChatBubbleStack(
                            bubbles: parallelBubbles, pendingPrompts: store.pendingPrompts,
                            runningIDs: runningIDs, closingIDs: store.closingIDs, openBubbleID: openParallelBubbleID,
                            onOpen: { id in openParallelBubbleID = openParallelBubbleID == id ? nil : id },
                            onClose: { id in closeParallelBubble(id) }
                        )
                    }
                    if let bubble = expandedBubble {
                        ParallelChatBubblePanel(
                            bubble: bubble,
                            onBack: {
                                if openParallelBubbleID == bubble.id { openParallelBubbleID = nil }
                            }
                        )
                        .frame(width: expandedWidth)
                        .frame(maxHeight: .infinity)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
                .padding(.leading, leading)
                .padding(.top, 16)
                .padding(.bottom, 16)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: openParallelBubbleID)
        .alert("Parallel page", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
                .buttonHoverPointer()
                .nativeHelp("Dismiss the parallel page error")
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    /// Changes whenever a bubble may have appeared, started, finished or closed.
    private var parallelBubblesRefreshKey: String {
        let snapshot = conversationRuntime.snapshot
        let chatRevision = chatTask.flatMap { snapshot.conversationRevisions[$0.id.uuidString] } ?? 0
        return "\(ParallelChatBubbleStore.shared.revision)-\(chatRevision)-\(snapshot.activeTaskIDs.joined(separator: ","))-\(isShowingChatSidebar)"
    }

    func refreshParallelBubbles() {
        guard let chatTask else { return }
        let bubbles = (try? BoardTaskManager(modelContext: modelContext).parallelChatBubbles(of: chatTask.id)) ?? []
        if bubbles.map(\.id) != parallelBubbles.map(\.id) { parallelBubbles = bubbles }
        if let id = openParallelBubbleID, !bubbles.contains(where: { $0.id == id }) { openParallelBubbleID = nil }
    }

    func closeParallelBubble(_ id: UUID) {
        if openParallelBubbleID == id { openParallelBubbleID = nil }
        ParallelChatBubbleStore.shared.close(id, using: remoteConversations)
    }
}
