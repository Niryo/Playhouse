import AppKit
import SwiftData
import SwiftUI

struct TopLeadingScrollAlignment: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.defaultScrollAnchor(.topLeading, for: .alignment)
        } else {
            content
        }
    }
}

struct DoneDropDrawer: View {
    let isOpen: Bool
    @Binding var isActive: Bool
    let onDrop: (UUID) -> Void

    private static let tabWidth: CGFloat = 44
    private static let tabHeight: CGFloat = 168
    private static let gap: CGFloat = 10
    private static let trailingMargin: CGFloat = 10
    /// How much of the tab's leading edge stays visible while no drag is in progress.
    private static let peekWidth: CGFloat = 5
    /// The full width the drawer occupies at the board's trailing edge.
    static let gutterWidth = gap + tabWidth + trailingMargin

    var body: some View {
        // The gutter keeps its width so the board never reflows; only the tab slides, from
        // a sliver peeking at the window edge to fully open while a card is dragged.
        tab
            .frame(width: Self.tabWidth, height: Self.tabHeight)
            .scaleEffect(isActive ? 1.06 : 1)
            .offset(x: isOpen ? 0 : Self.tabWidth + Self.trailingMargin - Self.peekWidth)
            .padding(.leading, Self.gap)
            .padding(.trailing, Self.trailingMargin)
            .frame(maxHeight: .infinity)
            .clipped()
            .animation(.spring(response: 0.34, dampingFraction: 0.84), value: isOpen)
            .animation(.easeOut(duration: 0.14), value: isActive)
    }

    private var tab: some View {
        VStack(spacing: 7) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
            Text("Done")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(isActive ? Color.white : TaskStatus.done.accent)
        .opacity(isOpen ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            isActive ? TaskStatus.done.accent : TaskStatus.done.accent.opacity(isOpen ? 0.12 : 0.45),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(TaskStatus.done.accent.opacity(isActive ? 0 : 0.45), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onDrop(of: [.plainText], delegate: DoneDrawerDropDelegate(isOpen: isOpen, isActive: $isActive, onDrop: onDrop))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("task-done-drop-target")
        .accessibilityLabel("Move task to Done")
        .accessibilityValue(isOpen ? "Open" : "Resting")
        .accessibilityHint("Drop a reviewed task here to move it to Done.")
    }
}

/// The resting sliver stays on screen during drags it doesn't open for (such as a
/// Waiting Response card heading to Review), so it must neither light up nor accept them.
private struct DoneDrawerDropDelegate: DropDelegate {
    let isOpen: Bool
    @Binding var isActive: Bool
    let onDrop: (UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        isOpen && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        isActive = isOpen
    }

    func dropExited(info: DropInfo) {
        isActive = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isActive = false
        guard isOpen, let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let value = value as? String, let id = UUID(uuidString: value) else { return }
            DispatchQueue.main.async { onDrop(id) }
        }
        return true
    }
}

struct KanbanColumnView: View {
    let status: TaskStatus
    let tasks: [BoardTask]
    let onMoveTask: (UUID, TaskStatus) -> Void
    let onCreatePullRequests: (BoardTask) -> Void
    let onSetPullRequestMode: (BoardTask, PullRequestMode) -> Void
    let onResolveConflicts: (BoardTask) -> Void
    let creatingPullRequestTaskIDs: Set<UUID>
    let mergedReviewTaskIDs: Set<UUID>
    let conflictedReviewTaskIDs: Set<UUID>
    let pullRequestHealth: [UUID: [Int: PullRequestHealth]]
    let onAddTask: () -> Void
    let onOpenTask: (BoardTask) -> Void
    let onRenameTask: (BoardTask) -> Void
    let onDeleteTask: (BoardTask) -> Void
    let onShowTaskTokenStats: (BoardTask) -> Void
    @Binding var draggedTaskID: UUID?
    /// True while a card this column can receive is being dragged.
    let acceptsDraggedTask: Bool
    let minHeight: CGFloat
    @State private var isDropTargeted = false

    var body: some View {
        dropTarget
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("column-\(status.accessibilityKey)")
    }

    private var columnContent: some View {
        KanbanColumnSection(
            model: KanbanColumnModel(status: status, taskCount: tasks.count),
            minHeight: Double(minHeight),
            onAdd: onAddTask
        ) {
            ForEach(tasks) { task in
                draggableTaskCard(task)
            }
        }
        .overlay {
            if acceptsDraggedTask {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(status.accent.opacity(isDropTargeted ? 0.16 : 0.06))
                    .strokeBorder(status.accent.opacity(isDropTargeted ? 0.9 : 0.45), style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.5, dash: isDropTargeted ? [] : [6, 4]))
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("task-\(status.accessibilityKey)-drop-target")
            }
        }
    }

    @ViewBuilder
    private var dropTarget: some View {
        if status == .review {
            // Waiting Response cards drop here; the board ignores any other source.
            columnContent
                .onDrop(of: [.plainText], isTargeted: $isDropTargeted) { providers in
                    guard acceptsDraggedTask, let provider = providers.first else { return false }
                    // End the drag now, so the card turning Review can't briefly open the Done drawer.
                    draggedTaskID = nil
                    _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                        guard let value = value as? String, let id = UUID(uuidString: value) else { return }
                        DispatchQueue.main.async { onMoveTask(id, status) }
                    }
                    return true
                }
        } else if status != .done {
            columnContent
        } else if #available(macOS 26.0, *) {
            NativeMoveDropDestination { taskID in
                onMoveTask(taskID, status)
            } content: {
                columnContent
            }
        } else {
            columnContent
                .onDrop(of: [.plainText], delegate: KanbanTaskDropDelegate(
                    status: status,
                    draggedTaskID: $draggedTaskID,
                    onMoveTask: onMoveTask
                ))
        }
    }

    @ViewBuilder
    private func draggableTaskCard(_ task: BoardTask) -> some View {
        let card = TaskCardView(
            task: task,
            onOpen: { onOpenTask(task) },
            onRename: { onRenameTask(task) },
            onDelete: { onDeleteTask(task) },
            onShowTokenStats: { onShowTaskTokenStats(task) },
            onCreatePullRequests: { onCreatePullRequests(task) },
            onSetPullRequestMode: { onSetPullRequestMode(task, $0) },
            onResolveConflicts: { onResolveConflicts(task) },
            isCreatingPullRequests: creatingPullRequestTaskIDs.contains(task.id),
            isPullRequestMerged: mergedReviewTaskIDs.contains(task.id),
            hasPullRequestConflicts: conflictedReviewTaskIDs.contains(task.id),
            pullRequestHealth: pullRequestHealth[task.id] ?? [:],
            onMoveToDone: task.status == .review ? { onMoveTask(task.id, .done) } : nil,
            onMoveToReview: task.status == .waitingResponse ? { onMoveTask(task.id, .review) } : nil
        )
        if task.status == .waitingResponse || task.status == .review {
            card.onDrag {
                draggedTaskID = task.id
                return NSItemProvider(object: task.id.uuidString as NSString)
            }
        } else {
            card
        }
    }
}

private struct NativeMoveDropDestination<Content: View>: NSViewRepresentable {
    let onMoveTask: (UUID) -> Void
    @ViewBuilder let content: Content

    func makeNSView(context: Context) -> NativeMoveDropContainer<Content> {
        NativeMoveDropContainer(rootView: content, onMoveTask: onMoveTask)
    }

    func updateNSView(_ nsView: NativeMoveDropContainer<Content>, context: Context) {
        nsView.rootView = content
        nsView.onMoveTask = onMoveTask
    }
}

@MainActor
private final class NativeMoveDropContainer<Content: View>: NSView {
    private let hostingView: NSHostingView<Content>
    var onMoveTask: (UUID) -> Void

    var rootView: Content {
        get { hostingView.rootView }
        set { hostingView.rootView = newValue }
    }

    private let textPasteboardTypes: [NSPasteboard.PasteboardType] = [
        .string,
        NSPasteboard.PasteboardType("public.plain-text"),
        NSPasteboard.PasteboardType("public.utf8-plain-text")
    ]

    init(rootView: Content, onMoveTask: @escaping (UUID) -> Void) {
        hostingView = NSHostingView(rootView: rootView)
        self.onMoveTask = onMoveTask
        super.init(frame: .zero)

        registerForDraggedTypes(textPasteboardTypes)
        addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        offeredMoveOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        offeredMoveOperation(for: sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard offeredMoveOperation(for: sender) != [],
              taskID(from: sender) != nil else {
            return false
        }

        // AppKit otherwise animates the drag image to its destination after the drop.
        sender.animatesToDestination = false
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard offeredMoveOperation(for: sender) != [],
              let taskID = taskID(from: sender) else {
            return false
        }

        onMoveTask(taskID)
        return true
    }

    private func offeredMoveOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard taskID(from: sender) != nil else {
            return []
        }

        return sender.draggingSourceOperationMask.contains(.move) ? .move : .copy
    }

    private func taskID(from sender: NSDraggingInfo) -> UUID? {
        guard let type = sender.draggingPasteboard.availableType(from: textPasteboardTypes),
              let identifier = sender.draggingPasteboard.string(forType: type) else {
            return nil
        }

        return UUID(uuidString: identifier)
    }
}

private struct KanbanTaskDropDelegate: DropDelegate {
    let status: TaskStatus
    @Binding var draggedTaskID: UUID?
    let onMoveTask: (UUID, TaskStatus) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let id = draggedTaskID else { return false }
        onMoveTask(id, status)
        draggedTaskID = nil
        return true
    }
}

/// A board card: the task's display model, rendered by the atom-built
/// `TaskItemView`, wired to the board's actions.
private struct TaskCardView: View {
    @AppStorage(WorkspaceSettings.tokenUsageColorMaxKey, store: WorkspaceSettings.preferencesStore)
    private var tokenUsageColorMax = WorkspaceSettings.defaultTokenUsageColorMax
    @AppStorage(WorkspaceSettings.cpuUsageColorMaxKey, store: WorkspaceSettings.preferencesStore)
    private var cpuUsageColorMax = WorkspaceSettings.defaultCPUUsageColorMax
    @EnvironmentObject private var cpuUsageModel: TaskCPUUsageModel
    let task: BoardTask
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onShowTokenStats: () -> Void
    let onCreatePullRequests: () -> Void
    let onSetPullRequestMode: (PullRequestMode) -> Void
    let onResolveConflicts: () -> Void
    let isCreatingPullRequests: Bool
    let isPullRequestMerged: Bool
    let hasPullRequestConflicts: Bool
    let pullRequestHealth: [Int: PullRequestHealth]
    let onMoveToDone: (() -> Void)?
    let onMoveToReview: (() -> Void)?

    var body: some View {
        TaskItemView(model: model, actions: TaskItemActions(
            open: onOpen,
            menu: { id in
                switch id {
                case "done": onMoveToDone?()
                case "review": onMoveToReview?()
                case "rename": onRename()
                case "stats": onShowTokenStats()
                case "delete": onDelete()
                default: break
                }
            },
            showTokenStats: onShowTokenStats,
            createPullRequests: onCreatePullRequests,
            setPullRequestMode: { raw in
                if let mode = PullRequestMode(rawValue: raw) { onSetPullRequestMode(mode) }
            },
            moveToDone: { onMoveToDone?() },
            resolveConflicts: onResolveConflicts
        ))
    }

    /// For Codex the CPU share is the task's working-directory share of the
    /// shared app-server (see `TaskCPUUsageSnapshot`); `nil` with no running turn or sample yet.
    private var model: TaskItemModel {
        TaskItemModel(
            task: task,
            cpuPercent: cpuUsageModel.percent(threadID: task.activeConversationID),
            cpuUsageColorMax: cpuUsageColorMax,
            tokenUsageColorMax: tokenUsageColorMax,
            isCreatingPullRequests: isCreatingPullRequests,
            isPullRequestMerged: isPullRequestMerged,
            hasPullRequestConflicts: hasPullRequestConflicts,
            pullRequestHealth: pullRequestHealth,
            canMoveToDone: onMoveToDone != nil,
            canMoveToReview: onMoveToReview != nil
        )
    }
}
