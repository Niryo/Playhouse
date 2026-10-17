import AppKit
import SwiftData
import SwiftUI

struct KanbanBoardView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var codexClient: CodexAppServerClient
    @Query(sort: \BoardTask.createdAt, order: .reverse) private var tasks: [BoardTask]
    @State private var isShowingNewTask = false
    @State private var isChoosingDefaultParent = false
    @State private var saveError: String?
    @State private var lifecycleResetNotice: String?
    @State private var draggedTaskID: UUID?
    @State private var selectedTask: BoardTask?
    @State private var taskBeingRenamed: BoardTask?
    @State private var taskBeingDeleted: BoardTask?
    @State private var isShowingDeleteConfirmation = false
    @State private var isTrashTargetActive = false

    var body: some View {
        Group {
            if let selectedTask {
                TaskConversationView(task: selectedTask) {
                    self.selectedTask = nil
                }
                .id(selectedTask.id)
            } else {
                boardContent
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 980, minHeight: 640)
        .onAppear {
            let retained = StationAIStore.takeLifecycleResetNotice(
                dataDirectory: ProcessInfo.processInfo.environment["STATIONAI_DATA_DIRECTORY"]
            )
            if !retained.isEmpty {
                lifecycleResetNotice = "Existing tasks were cleared. These dirty managed worktrees were kept:\n\n" + retained.joined(separator: "\n")
            }
        }
        .sheet(isPresented: $isShowingNewTask) {
            NewTaskSheet(onCreate: createTask)
        }
        .sheet(isPresented: Binding(
            get: { taskBeingRenamed != nil },
            set: { if !$0 { taskBeingRenamed = nil } }
        )) {
            if let taskBeingRenamed {
                RenameTaskSheet(title: taskBeingRenamed.title) { title in
                    do {
                        _ = try BoardTaskManager(modelContext: modelContext).rename(taskBeingRenamed.id, title: title)
                    } catch {
                        saveError = error.localizedDescription
                    }
                    self.taskBeingRenamed = nil
                }
            }
        }
        .confirmationDialog(
            "Delete this task?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Task", role: .destructive) {
                guard let taskBeingDeleted else { return }
                do {
                    try BoardTaskManager(modelContext: modelContext).delete(taskBeingDeleted.id)
                } catch {
                    saveError = error.localizedDescription
                }
                self.taskBeingDeleted = nil
            }
            .accessibilityIdentifier("confirm-delete-task-button")
            Button("Cancel", role: .cancel) {
                taskBeingDeleted = nil
            }
            .accessibilityIdentifier("cancel-delete-task-button")
        } message: {
            Text("The task conversation and saved working folders will also be deleted.")
        }
        .alert("Couldn't save changes", isPresented: isShowingSaveError) {
            Button("OK", role: .cancel) {
                saveError = nil
            }
        } message: {
            Text(saveError ?? "Please try again.")
        }
        .alert("Some task worktrees were kept", isPresented: Binding(
            get: { lifecycleResetNotice != nil },
            set: { if !$0 { lifecycleResetNotice = nil } }
        )) {
            Button("OK", role: .cancel) { lifecycleResetNotice = nil }
        } message: {
            Text(lifecycleResetNotice ?? "")
        }
    }

    private var boardContent: some View {
        VStack(spacing: 0) {
            boardHeader

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(TaskStatus.allCases) { status in
                        KanbanColumnView(
                            status: status,
                            tasks: tasks.filter { $0.status == status },
                            onMoveTask: moveTask,
                            onAddTask: openNewTask,
                            onOpenTask: { selectedTask = $0 },
                            onRenameTask: { taskBeingRenamed = $0 },
                            onDeleteTask: {
                                taskBeingDeleted = $0
                                isShowingDeleteConfirmation = true
                            },
                            draggedTaskID: $draggedTaskID
                        )
                        .frame(width: 264)
                    }
                    if draggedTaskID != nil {
                        TrashDropTarget(isActive: $isTrashTargetActive, onDrop: deleteTaskFromTrash)
                            .frame(width: 104, height: 480)
                            .accessibilityIdentifier("task-trash-drop-target")
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 22)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.visible)
        }
    }

    private var boardHeader: some View {
        HStack(alignment: .center, spacing: 24) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.37, green: 0.43, blue: 0.92), Color(red: 0.54, green: 0.39, blue: 0.86)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text("StationAI")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .accessibilityIdentifier("board-title")
                    Text("A clear view of every task in flight.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 20)

            HStack(spacing: 14) {
                Text("\(tasks.count) \(tasks.count == 1 ? "task" : "tasks")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Task count")
                    .accessibilityValue("\(tasks.count)")
                    .accessibilityIdentifier("task-count")

                Button {
                    openNewTask()
                } label: {
                    Label("New Task", systemImage: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.34, green: 0.40, blue: 0.86))
                .accessibilityIdentifier("new-task-button")
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 24)
        .padding(.bottom, 21)
    }

    private var isShowingSaveError: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    private func openNewTask() {
        guard !isChoosingDefaultParent else { return }
        let settings = WorkspaceSettingsManager()
        guard settings.defaultParentFolderURL == nil else {
            isShowingNewTask = true
            return
        }

        let panel = NSOpenPanel()
        panel.title = "Choose default parent folder"
        panel.message = "StationAI will suggest Git repositories found below this folder."
        panel.prompt = "Use This Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        isChoosingDefaultParent = true
        panel.begin { response in
            DispatchQueue.main.async {
                isChoosingDefaultParent = false
                guard response == .OK, let selected = panel.url else { return }
                do {
                    try settings.setDefaultParentFolder(selected.standardizedFileURL.path)
                } catch {
                    saveError = error.localizedDescription
                    return
                }
                isShowingNewTask = true
            }
        }
    }

    private func createTask(title: String, repositories: [RepositoryWorktreeSpec], contextFolders: [URL]) throws {
        _ = try BoardTaskManager(modelContext: modelContext).create(
            title: title,
            repositories: repositories,
            contextFolders: contextFolders.map { $0.standardizedFileURL.path }
        )
    }

    private func moveTask(id: UUID, to status: TaskStatus) {
        guard let task = tasks.first(where: { $0.id == id }), task.status != status else { return }
        guard status == .done else { return }
        Task { @MainActor in
            do {
                _ = try await BoardTaskManager(modelContext: modelContext).move(
                    id,
                    to: status.rawValue,
                    client: codexClient,
                    onConflictResolutionStart: { selectedTask = task }
                )
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func deleteTaskFromTrash(_ id: UUID) {
        draggedTaskID = nil
        isTrashTargetActive = false
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        taskBeingDeleted = task
        Task { @MainActor in
            do {
                let needsConfirmation = try await BoardTaskManager(modelContext: modelContext)
                    .deleteRequiresConfirmation(id, client: CodexAppServerClient())
                if needsConfirmation {
                    isShowingDeleteConfirmation = true
                } else {
                    deleteTask(task)
                }
            } catch {
                // If inspection fails, ask before removing anything.
                isShowingDeleteConfirmation = true
            }
        }
    }

    private func deleteTask(_ task: BoardTask) {
        do {
            try BoardTaskManager(modelContext: modelContext).delete(task.id)
        } catch {
            saveError = error.localizedDescription
        }
        taskBeingDeleted = nil
    }

}

private struct TrashDropTarget: View {
    @Binding var isActive: Bool
    let onDrop: (UUID) -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "trash")
                .font(.system(size: 24, weight: .medium))
            Text("Delete")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(isActive ? Color.white : Color.red)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isActive ? Color.red : Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.red.opacity(0.35), lineWidth: 1))
        .onDrop(of: [.plainText], isTargeted: $isActive) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let value = value as? String, let id = UUID(uuidString: value) else { return }
                DispatchQueue.main.async { onDrop(id) }
            }
            return true
        }
    }
}

private struct KanbanColumnView: View {
    let status: TaskStatus
    let tasks: [BoardTask]
    let onMoveTask: (UUID, TaskStatus) -> Void
    let onAddTask: () -> Void
    let onOpenTask: (BoardTask) -> Void
    let onRenameTask: (BoardTask) -> Void
    let onDeleteTask: (BoardTask) -> Void
    @Binding var draggedTaskID: UUID?

    var body: some View {
        dropTarget
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("column-\(status.accessibilityKey)")
    }

    private var columnContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Circle()
                    .fill(status.accent)
                    .frame(width: 8, height: 8)
                Text(status.rawValue.uppercased())
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .tracking(0.65)
                    .foregroundStyle(.primary.opacity(0.82))
                    .accessibilityIdentifier("column-heading-\(status.accessibilityKey)")
                Spacer(minLength: 4)
                Text("\(tasks.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.primary.opacity(0.055)))
                if status == .backlog {
                    Button(action: onAddTask) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Add task to Backlog")
                    .accessibilityIdentifier("add-backlog-task-button")
                    .help("Add task to Backlog")
                }
            }
            .padding(.horizontal, 3)

            if tasks.isEmpty {
                emptyState
            } else {
                ForEach(tasks) { task in
                    draggableTaskCard(task)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 480, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.075), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var dropTarget: some View {
        if status != .done {
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
            onMoveToDone: task.status == .review ? { onMoveTask(task.id, .done) } : nil
        )

        if task.status == .review {
            card.onDrag {
                draggedTaskID = task.id
                return NSItemProvider(object: task.id.uuidString as NSString)
            }
        } else {
            card
        }
    }

    private var emptyState: some View {
        VStack(spacing: 9) {
            Image(systemName: status == .done ? "checkmark.circle" : "tray")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(status.accent.opacity(0.75))
            Text("No tasks yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(status == .backlog ? "Create a task to get started" : "Drop a task here")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 124)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("empty-state-\(status.accessibilityKey)")
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

private struct TaskCardView: View {
    let task: BoardTask
    let onOpen: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onMoveToDone: (() -> Void)?

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 6) {
                    Image(systemName: "circle.inset.filled")
                        .font(.system(size: 9))
                        .foregroundStyle(task.status.accent)
                    Text(task.status.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                }

                if let statusMessage = task.statusMessage, !statusMessage.isEmpty {
                    Text(statusMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(task.status == .blocked ? Color.red : Color.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("task-status-message-\(task.id.uuidString)")
                }

                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("task-title-\(task.id.uuidString)")

                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                    Text(task.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 10))
                }
                .foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.035), radius: 5, x: 0, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(task.title)
        .accessibilityHint("Open task")
        .accessibilityIdentifier("task-card-\(task.id.uuidString)")
        .contextMenu {
            if let onMoveToDone {
                Button("Merge and move to Done", systemImage: "arrow.triangle.merge", action: onMoveToDone)
                    .accessibilityIdentifier("move-task-to-done-menu-item")
            }
            Button("Rename…", systemImage: "pencil", action: onRename)
                .accessibilityIdentifier("rename-task-menu-item")
            Button("Delete Task", systemImage: "trash", role: .destructive, action: onDelete)
                .accessibilityIdentifier("delete-task-menu-item")
        }
    }
}

private struct RenameTaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String

    let onSave: (String) -> Void

    init(title: String, onSave: @escaping (String) -> Void) {
        _title = State(initialValue: title)
        self.onSave = onSave
    }

    private var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename task")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
            TextField("Task title", text: $title)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("rename-task-title-field")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(normalizedTitle)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(normalizedTitle.isEmpty)
                .accessibilityIdentifier("save-task-rename-button")
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
