import Foundation
import Observation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// A question sent in parallel whose bubble the chat doesn't list yet.
package struct PendingParallelChatPrompt: Identifiable, Equatable {
    package let id = UUID()
    package let text: String

    package init(text: String) {
        self.text = text
    }
}

/// The app's parallel sends and closes. A send outlives the chat sidebar that started it, so
/// its bubble keeps running when the chat closes; the bubbles themselves are read from the store.
@MainActor @Observable
package final class ParallelChatBubbleStore {
    package static let shared = ParallelChatBubbleStore()

    package private(set) var pendingPrompts: [PendingParallelChatPrompt] = []
    /// Bubbles whose close is on its way to the daemon.
    package private(set) var closingIDs: Set<UUID> = []
    package var errorMessage: String?
    /// Bumped whenever a send or close changes which bubbles exist.
    package private(set) var revision = 0

    /// `restoreDraft` hands the question back to the composer when no bubble could take it.
    package func send(text: String, imageDataURLs: [String], using manager: RemoteConversationManager, restoreDraft: @escaping () -> Void = {}) {
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

    package func close(_ bubbleID: UUID, using manager: RemoteConversationManager) {
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
package struct ParallelChatBubbleStack: PHView {
    package static let width: CGFloat = 260

    package let bubbles: [StandaloneChat]
    package let pendingPrompts: [PendingParallelChatPrompt]
    package let runningIDs: Set<UUID>
    package let closingIDs: Set<UUID>
    package let openBubbleID: UUID?
    package let onOpen: (UUID) -> Void
    package let onClose: (UUID) -> Void

    package var body: some PHView {
        AtomStack(props: StackProps(axis: "v", spacing: 8, align: "leading"), common: AtomCommon(testID: "parallel-chat-bubbles")) {
            PHForEach(bubbles, id: \.id) { bubble in
                bubbleCard(
                    id: bubble.id, prompt: bubble.parallelPrompt ?? bubble.title,
                    isRunning: runningIDs.contains(bubble.id), isClosing: closingIDs.contains(bubble.id)
                )
            }
            PHForEach(pendingPrompts) { pending in
                bubbleCard(id: nil, prompt: pending.text, isRunning: true, isClosing: false)
            }
        }
    }

    private func bubbleCard(id: UUID?, prompt: String, isRunning: Bool, isClosing: Bool) -> some PHView {
        let isOpen = id != nil && id == openBubbleID
        return AtomStack(
            props: StackProps(axis: "h", spacing: 8, align: "center", group: true, fill: "panel", fillOpacity: 1, cornerRadius: 14, stroke: isOpen ? "accent" : "primary", strokeOpacity: isOpen ? 0.6 : 0.12),
            common: AtomCommon(testID: "parallel-chat-bubble", width: Double(Self.width), paddingX: 12, paddingY: 9)
        ) {
            // Beside the open button rather than in it, so each keeps its own identity.
            if isRunning || isClosing {
                AtomSpinner(props: SpinnerProps(size: "mini"), common: AtomCommon(testID: "parallel-chat-bubble-progress", label: "Answering"))
            } else {
                AtomIcon(props: IconProps(name: PHIcon.checkmarkCircleFill.name, size: 12, weight: "semibold", color: "accent"), common: AtomCommon(testID: "parallel-chat-bubble-done", label: "Answered"))
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
                    AtomIcon(props: IconProps(name: PHIcon.xmark.name, size: 9, weight: "bold", color: "secondary"), common: AtomCommon(width: 16, height: 16))
                }
            }
        }
        .phShadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }

    package init(bubbles: [StandaloneChat], pendingPrompts: [PendingParallelChatPrompt], runningIDs: Set<UUID>, closingIDs: Set<UUID>, openBubbleID: UUID?, onOpen: @escaping (UUID) -> Void, onClose: @escaping (UUID) -> Void) {
        self.bubbles = bubbles
        self.pendingPrompts = pendingPrompts
        self.runningIDs = runningIDs
        self.closingIDs = closingIDs
        self.openBubbleID = openBubbleID
        self.onOpen = onOpen
        self.onClose = onClose
    }
}

/// The bubble's conversation, with its existing page header and back action.
package struct ParallelChatBubblePanel: PHView {
    package let bubble: StandaloneChat
    package let onBack: () -> Void

    package var body: some PHView {
        StandaloneChatPanel(chat: bubble, onOpenTask: { _, _ in }, onClose: onBack)
            .equatable()
            .id(bubble.id)
            .background(WorkspaceTheme.windowBackground)
            .clipShape(PHRoundedRectangle(cornerRadius: 14))
            .overlay(PHRoundedRectangle(cornerRadius: 14).stroke(PHColor.primary.opacity(0.12)))
            .phShadow(color: .black.opacity(0.25), radius: 16, y: 4)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("parallel-chat-panel")
    }

    package init(bubble: StandaloneChat, onBack: @escaping () -> Void) {
        self.bubble = bubble
        self.onBack = onBack
    }
}

package struct ParallelChatPlaceholder: Identifiable, Equatable {
    package let id: UUID
    package let prompt: String
    package let anchorTurnID: String?

    package init(id: UUID, prompt: String, anchorTurnID: String?) {
        self.id = id
        self.prompt = prompt
        self.anchorTurnID = anchorTurnID
    }
}

/// The small row the chat keeps where a parallel bubble's page will return.
package struct ParallelChatPlaceholderRow: PHView {
    package let bubbleID: UUID
    package let prompt: String

    package var body: some PHView {
        AtomStack(props: StackProps(axis: "h", spacing: 8, align: "center", group: true), common: AtomCommon(testID: "parallel-chat-placeholder", paddingY: 4)) {
            PHRectangle().fill(PHColor.primary.opacity(0.1)).frame(height: 1)
            AtomStack(
                props: StackProps(axis: "h", spacing: 6, align: "center", fillOpacity: 0, capsule: true, stroke: "secondary", strokeOpacity: 0.35, dash: [3, 3]),
                common: AtomCommon(paddingX: 10, paddingY: 3)
            ) {
                AtomIcon(props: IconProps(name: PHIcon.squareOnSquare.name, size: 10, weight: "semibold", color: "secondary"))
                AtomText(props: TextProps(text: prompt, size: 11, weight: "medium", color: "secondary", lineLimit: 1), common: AtomCommon(testID: "parallel-chat-placeholder-prompt"))
            }
            .layoutPriority(1)
            PHRectangle().fill(PHColor.primary.opacity(0.1)).frame(height: 1)
        }
        .accessibilityValue(bubbleID.uuidString)
    }

    package init(bubbleID: UUID, prompt: String) {
        self.bubbleID = bubbleID
        self.prompt = prompt
    }
}

extension KanbanBoardView {
    /// On narrow displays the expanded view uses the stack's space so the composer stays reachable.
    package var parallelChatBubblesOverlay: some PHView {
        let store = ParallelChatBubbleStore.shared
        let runningIDs = Set(parallelBubbles.map(\.id).filter { conversationRuntime.isTurnActive(taskID: $0) })
        let expandedBubble = parallelBubbles.first { $0.id == openParallelBubbleID }
        let sidebarEdge = ChatSidebarLayout.chatLeadingEdge + chatSidebarShownWidth + 12
        let windowFrame = Platform.services.keyWindowFrame
        let windowWidth = boardContentWidth > 0 ? boardContentWidth : windowFrame?.width ?? sidebarEdge + 520
        let visibleRightEdge = Platform.services.activeScreenVisibleFrame?.maxX
        let visibleWidth = min(windowWidth, visibleRightEdge.map { $0 - (windowFrame?.minX ?? 0) } ?? windowWidth)
        let idealPanelWidth: CGFloat = 520
        let expandedWidth = min(idealPanelWidth, max(320, visibleWidth - sidebarEdge - 12))
        let sideBySideWidth = sidebarEdge + ParallelChatBubbleStack.width + 12 + idealPanelWidth + 12
        let showsStack = expandedBubble == nil || visibleWidth >= sideBySideWidth
        let leading = expandedBubble != nil && !showsStack
            ? max(0, min(sidebarEdge, visibleWidth - expandedWidth - 12))
            : sidebarEdge
        return PHZStack(alignment: .topLeading) {
            // Always present, so the bubbles are read even before the first one shows, such as
            // after a relaunch.
            PHColor.clear
                .frame(width: 0, height: 0)
                .task(id: parallelBubblesRefreshKey) { refreshParallelBubbles() }
            if isChatOverlayVisible, !parallelBubbles.isEmpty || !store.pendingPrompts.isEmpty {
                PHHStack(alignment: .top, spacing: 12) {
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
        .alert("Parallel page", isPresented: PHBinding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            PHButton("OK", role: .cancel) { store.errorMessage = nil }
                .buttonHoverPointer()
                .nativeHelp("Dismiss the parallel page error")
        } message: {
            PHText(store.errorMessage ?? "")
        }
    }

    /// Changes whenever a bubble may have appeared, started, finished or closed.
    private var parallelBubblesRefreshKey: String {
        let snapshot = conversationRuntime.snapshot
        let chatRevision = chatTask.flatMap { snapshot.conversationRevisions[$0.id.uuidString] } ?? 0
        return "\(ParallelChatBubbleStore.shared.revision)-\(chatRevision)-\(snapshot.activeTaskIDs.joined(separator: ","))-\(isShowingChatSidebar)"
    }

    package func refreshParallelBubbles() {
        guard let chatTask else { return }
        let bubbles = (try? BoardTaskManager(modelContext: modelContext).parallelChatBubbles(of: chatTask.id)) ?? []
        if bubbles.map(\.id) != parallelBubbles.map(\.id) { parallelBubbles = bubbles }
        if let id = openParallelBubbleID, !bubbles.contains(where: { $0.id == id }) { openParallelBubbleID = nil }
    }

    package func closeParallelBubble(_ id: UUID) {
        if openParallelBubbleID == id { openParallelBubbleID = nil }
        ParallelChatBubbleStore.shared.close(id, using: remoteConversations)
    }
}
