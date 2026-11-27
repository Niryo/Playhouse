import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

package struct TopLeadingScrollAlignment: PHViewModifier {
    package func body(content: Content) -> some PHView {
        if #available(macOS 15.0, *) {
            content.defaultScrollAnchor(.topLeading, for: .alignment)
        } else {
            content
        }
    }

    package init() {}
}

package struct DoneDropDrawer: PHView {
    package let isOpen: Bool
    @PHBinding package var isActive: Bool
    package let onDrop: (UUID) -> Void

    private static let tabWidth: CGFloat = 44
    private static let tabHeight: CGFloat = 168
    private static let gap: CGFloat = 10
    private static let trailingMargin: CGFloat = 10
    /// How much of the tab's leading edge stays visible while no drag is in progress.
    private static let peekWidth: CGFloat = 5
    /// The full width the drawer occupies at the board's trailing edge.
    package static let gutterWidth = gap + tabWidth + trailingMargin

    package var body: some PHView {
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

    private var tab: some PHView {
        PHVStack(spacing: 7) {
            PHImage(icon: .checkmark)
                .font(.system(size: 14, weight: .bold))
            PHText("Done")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(isActive ? PHColor.white : TaskStatus.done.accent)
        .opacity(isOpen ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            isActive ? TaskStatus.done.accent : TaskStatus.done.accent.opacity(isOpen ? 0.12 : 0.45),
            in: PHRoundedRectangle.phContinuous(cornerRadius: 14)
        )
        .overlay(
            PHRoundedRectangle.phContinuous(cornerRadius: 14)
                .strokeBorder(TaskStatus.done.accent.opacity(isActive ? 0 : 0.45), lineWidth: 1)
        )
        .contentShape(PHRoundedRectangle.phContinuous(cornerRadius: 14))
        .onDrop(of: [.plainText], delegate: DoneDrawerDropDelegate(isOpen: isOpen, isActive: $isActive, onDrop: onDrop))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("task-done-drop-target")
        .accessibilityLabel("Move task to Done")
        .accessibilityValue(isOpen ? "Open" : "Resting")
        .accessibilityHint("Drop a reviewed task here to move it to Done.")
    }

    package init(isOpen: Bool, isActive: PHBinding<Bool>, onDrop: @escaping (UUID) -> Void) {
        self.isOpen = isOpen
        _isActive = isActive
        self.onDrop = onDrop
    }
}

/// The resting sliver stays on screen during drags it doesn't open for (such as a
/// Waiting Response card heading to Review), so it must neither light up nor accept them.
private struct DoneDrawerDropDelegate: PHDropDelegate {
    let isOpen: Bool
    @PHBinding var isActive: Bool
    let onDrop: (UUID) -> Void

    func validateDrop(info: PHDropInfo) -> Bool {
        isOpen && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: PHDropInfo) {
        isActive = isOpen
    }

    func dropExited(info: PHDropInfo) {
        isActive = false
    }

    func performDrop(info: PHDropInfo) -> Bool {
        isActive = false
        guard isOpen, let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let value = value as? String, let id = UUID(uuidString: value) else { return }
            DispatchQueue.main.async { onDrop(id) }
        }
        return true
    }
}

package struct KanbanColumnView: PHView {
    package let status: TaskStatus
    package let tasks: [BoardTask]
    package let onMoveTask: (UUID, TaskStatus) -> Void
    /// What the cards' plugins (`PluginPlacement.taskItem`) can do on the board.
    package let pluginActions: PluginUIActions
    /// Presents a card plugin's modal, sidebar or page for its task.
    package let onOpenPlugin: (PluginRecord, BoardTask) -> Void
    /// Add Plugin mode's "Add here" placeholder on a card was pressed.
    package let onAddPlugin: (PluginPlacement) -> Void
    package let onAddTask: () -> Void
    package let onOpenTask: (BoardTask) -> Void
    package let onRenameTask: (BoardTask) -> Void
    package let onDeleteTask: (BoardTask) -> Void
    package let onShowTaskTokenStats: (BoardTask) -> Void
    @PHBinding package var draggedTaskID: UUID?
    /// True while a card this column can receive is being dragged.
    package let acceptsDraggedTask: Bool
    package let minHeight: CGFloat
    @PHState private var isDropTargeted = false

    package var body: some PHView {
        dropTarget
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("column-\(status.accessibilityKey)")
    }

    private var columnContent: some PHView {
        KanbanColumnSection(
            model: KanbanColumnModel(status: status, taskCount: tasks.count),
            minHeight: Double(minHeight),
            onAdd: onAddTask
        ) {
            PHForEach(tasks) { task in
                draggableTaskCard(task)
            }
        }
        .overlay {
            if acceptsDraggedTask {
                PHRoundedRectangle.phContinuous(cornerRadius: 16)
                    .fill(status.accent.opacity(isDropTargeted ? 0.16 : 0.06))
                    .strokeBorder(status.accent.opacity(isDropTargeted ? 0.9 : 0.45), style: PHStrokeStyle(lineWidth: isDropTargeted ? 2 : 1.5, dash: isDropTargeted ? [] : [6, 4]))
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("task-\(status.accessibilityKey)-drop-target")
            }
        }
    }

    @PHViewBuilder
    private var dropTarget: some PHView {
        if status == .review {
            // Waiting Response and Blocked cards drop here; the board ignores any other source.
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
            PHMoveDropDestination { taskID in
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

    @PHViewBuilder
    private func draggableTaskCard(_ task: BoardTask) -> some PHView {
        let card = TaskCardView(
            task: task,
            onOpen: { onOpenTask(task) },
            onRename: { onRenameTask(task) },
            onDelete: { onDeleteTask(task) },
            onShowTokenStats: { onShowTaskTokenStats(task) },
            pluginActions: pluginActions,
            onOpenPlugin: { onOpenPlugin($0, task) },
            onAddPlugin: onAddPlugin,
            onMoveToDone: TaskStatus.manualDoneSources.contains(task.status) ? { onMoveTask(task.id, .done) } : nil,
            onMoveToReview: TaskStatus.manualReviewSources.contains(task.status) ? { onMoveTask(task.id, .review) } : nil
        )
        if TaskStatus.manualDoneSources.contains(task.status) {
            card.onDrag {
                draggedTaskID = task.id
                return NSItemProvider(object: task.id.uuidString as NSString)
            }
        } else {
            card
        }
    }

    package init(status: TaskStatus, tasks: [BoardTask], onMoveTask: @escaping (UUID, TaskStatus) -> Void, pluginActions: PluginUIActions, onOpenPlugin: @escaping (PluginRecord, BoardTask) -> Void, onAddPlugin: @escaping (PluginPlacement) -> Void, onAddTask: @escaping () -> Void, onOpenTask: @escaping (BoardTask) -> Void, onRenameTask: @escaping (BoardTask) -> Void, onDeleteTask: @escaping (BoardTask) -> Void, onShowTaskTokenStats: @escaping (BoardTask) -> Void, draggedTaskID: PHBinding<UUID?>, acceptsDraggedTask: Bool, minHeight: CGFloat) {
        self.status = status
        self.tasks = tasks
        self.onMoveTask = onMoveTask
        self.pluginActions = pluginActions
        self.onOpenPlugin = onOpenPlugin
        self.onAddPlugin = onAddPlugin
        self.onAddTask = onAddTask
        self.onOpenTask = onOpenTask
        self.onRenameTask = onRenameTask
        self.onDeleteTask = onDeleteTask
        self.onShowTaskTokenStats = onShowTaskTokenStats
        _draggedTaskID = draggedTaskID
        self.acceptsDraggedTask = acceptsDraggedTask
        self.minHeight = minHeight
    }
}
private struct KanbanTaskDropDelegate: PHDropDelegate {
    let status: TaskStatus
    @PHBinding var draggedTaskID: UUID?
    let onMoveTask: (UUID, TaskStatus) -> Void

    func validateDrop(info: PHDropInfo) -> Bool {
        true
    }

    func dropUpdated(info: PHDropInfo) -> PHDropProposal? {
        PHDropProposal(operation: .move)
    }

    func performDrop(info: PHDropInfo) -> Bool {
        guard let id = draggedTaskID else { return false }
        onMoveTask(id, status)
        draggedTaskID = nil
        return true
    }
}

/// A board card: the task's display model, rendered by the atom-built
/// `TaskItemView`, wired to the board's actions.
private struct TaskCardView: PHView {
    @PHAppStorage(WorkspaceSettings.tokenUsageColorMaxKey, store: WorkspaceSettings.preferencesStore)
    private var tokenUsageColorMax = WorkspaceSettings.defaultTokenUsageColorMax
    @PHAppStorage(WorkspaceSettings.cpuUsageColorMaxKey, store: WorkspaceSettings.preferencesStore)
    private var cpuUsageColorMax = WorkspaceSettings.defaultCPUUsageColorMax
    @PHEnvironment(TaskCPUUsageModel.self) private var cpuUsageModel
    let task: BoardTask
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onShowTokenStats: () -> Void
    let pluginActions: PluginUIActions
    let onOpenPlugin: (PluginRecord) -> Void
    let onAddPlugin: (PluginPlacement) -> Void
    let onMoveToDone: (() -> Void)?
    let onMoveToReview: (() -> Void)?

    var body: some PHView {
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
            showTokenStats: onShowTokenStats
        ), pluginRow: PHAnyView(TaskItemPluginRow(
            task: task, hasBuiltInControls: model.hasPluginRow, actions: pluginActions, open: onOpenPlugin, add: onAddPlugin
        )))
    }

    /// For Codex the CPU share is the task's working-directory share of the
    /// shared app-server (see `TaskCPUUsageSnapshot`); `nil` with no running turn or sample yet.
    private var model: TaskItemModel {
        TaskItemModel(
            task: task,
            cpuPercent: cpuUsageModel.percent(threadID: task.activeConversationID),
            cpuUsageColorMax: cpuUsageColorMax,
            tokenUsageColorMax: tokenUsageColorMax,
            canMoveToDone: onMoveToDone != nil,
            canMoveToReview: onMoveToReview != nil
        )
    }
}

/// A card's bottom row: the task card plugins (`PluginPlacement.taskItem`),
/// right-aligned. The built-in ones (the mode pill and the pull request
/// controls) render inline once the task has started in a repository;
/// installed ones show on every card, inline or as entry buttons, beside
/// Add Plugin mode's "Add here" placeholder.
package struct TaskItemPluginRow: PHView {
    package let task: BoardTask
    package let hasBuiltInControls: Bool
    package let actions: PluginUIActions
    package let open: (PluginRecord) -> Void
    package let add: (PluginPlacement) -> Void
    @PHEnvironment(PluginRegistry.self) private var registry
    @PHAppStorage(WorkspaceSettings.pluginAddModeKey, store: WorkspaceSettings.preferencesStore) private var isAddModeOn = false
    @PHAppStorage(WorkspaceSettings.appearanceKey, store: WorkspaceSettings.preferencesStore) private var appearance = "dark"

    private var hasInstalledPlugins: Bool {
        (registry.plugins(for: .taskItem) + registry.inlinePlugins(for: .taskItem)).contains { !$0.builtIn }
    }

    package var body: some PHView {
        if hasBuiltInControls || hasInstalledPlugins || isAddModeOn {
            AtomStack(props: StackProps(axis: "h", spacing: 8), common: AtomCommon(minHeight: 30)) {
                AtomSpacer(props: SpacerProps(minLength: 8))
                AtomStack(props: StackProps(axis: "h", spacing: 5)) {
                    PluginSlot(placement: .taskItem, props: props, actions: actions, open: open, add: add)
                    // A card is rebuilt in its new column when its task
                    // moves; its plugins keep running and hear the move.
                    PluginInlineSlot(placement: .taskItem, props: props, actions: actions, keepAliveScope: task.id.uuidString)
                }
            }
            // The card's own element is its press target, a sibling of the
            // row, so the row is a container of its own.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("task-card-plugins-\(task.id.uuidString)")
        }
    }

    private func props(_ plugin: PluginRecord) -> [String: PluginValue] {
        PluginContext.props(plugin: plugin, appearance: appearance, task: PluginTaskContext(task: task), composer: nil)
    }

    package init(task: BoardTask, hasBuiltInControls: Bool, actions: PluginUIActions, open: @escaping (PluginRecord) -> Void, add: @escaping (PluginPlacement) -> Void) {
        self.task = task
        self.hasBuiltInControls = hasBuiltInControls
        self.actions = actions
        self.open = open
        self.add = add
    }
}
