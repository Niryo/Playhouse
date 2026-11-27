import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

extension KanbanBoardView {
    package func chatSidebarResizeHandle(width: CGFloat) -> some PHView {
        PHRectangle()
            .fill(PHColor.primary.opacity(0.07))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                // A wide invisible strip makes the 1pt border easy to grab. It starts at the border
                // and extends only over the board, so the chat transcript's scroller, which runs
                // along the border's inner side, keeps its own pointer and drags.
                PHColor.clear
                    .frame(width: 9)
                    .contentShape(PHRectangle())
                    .hoverCursor(.resizeLeftRight)
                    .gesture(
                        PHDragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if chatSidebarResizeStartWidth == nil {
                                    // Held for the whole drag, so the pointer can leave the thin border.
                                    Platform.services.pushCursor(.resizeLeftRight)
                                }
                                let start = chatSidebarResizeStartWidth ?? width
                                chatSidebarResizeStartWidth = start
                                if chatSidebarReflowWidth == nil { chatSidebarReflowWidth = start }
                                chatSidebarDragWidth = ChatSidebarLayout.clampedWidth(start + value.translation.width)
                            }
                            .onEnded { _ in
                                endChatSidebarResize()
                            }
                    )
                    .onDisappear {
                        // A sidebar closed mid-drag may never end the gesture.
                        endChatSidebarResize()
                    }
                    .accessibilityElement()
                    .accessibilityLabel("Resize chat")
                    .accessibilityValue("\(Int(width.rounded())) points")
                    .accessibilityIdentifier("chat-sidebar-resize-handle")
            }
    }

    package func endChatSidebarResize() {
        guard chatSidebarResizeStartWidth != nil else { return }
        Platform.services.popCursor()
        if let chatSidebarDragWidth {
            storedChatSidebarWidth = Double(chatSidebarDragWidth)
        }
        chatSidebarResizeStartWidth = nil
        chatSidebarDragWidth = nil
        chatSidebarReflowWidth = nil
    }
    @MainActor
    package func loadNextArchivePage() {
        guard isShowingDoneArchive, archiveHasMore, !isLoadingArchivePage else { return }
        isLoadingArchivePage = true
        let descriptor = ModelFetch<BoardTask>(
            .equals("statusRawValue", TaskStatus.done.rawValue),
            sortBy: [("createdAt", false)],
            limit: 40,
            offset: archiveOffset
        )
        do {
            let page = try modelContext.fetch(descriptor)
            archiveTasks.append(contentsOf: page)
            archiveOffset += page.count
            archiveHasMore = page.count == 40
        } catch {
            presentSaveError(error.localizedDescription)
            archiveHasMore = false
        }
        isLoadingArchivePage = false
    }

    @MainActor
    package func closeDoneArchive() {
        isShowingDoneArchive = false
        archiveTasks = []
        archiveSearchResults = nil
        archiveOffset = 0
        archiveHasMore = true
    }

    package func presentSaveError(_ message: String) {
        saveError = message
    }

    package var isShowingSaveError: PHBinding<Bool> {
        PHBinding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    package func openChatSidebar() {
        if isShowingChatSidebar {
            setChatSidebarVisible(false)
            return
        }
        guard !isOpeningChatSidebar else { return }
        if let chatTask {
            phWithAnimation(.easeInOut(duration: 0.22)) {
                self.chatTask = chatTask
                isShowingChatSidebar = true
            }
            return
        }
        isOpeningChatSidebar = true
        Task { @MainActor in
            defer { isOpeningChatSidebar = false }
            do {
                let manager = BoardTaskManager(modelContext: modelContext)
                let record = try await manager.getOrCreateStandaloneChat(
                    provider: WorkspaceSettingsManager().defaultConversationProvider
                )
                guard let chat = try manager.standaloneChatModel(record.id) else {
                    throw BridgeCommandError(code: "operation_failed", message: "The standalone chat could not be opened.")
                }
                chatTask = chat
                setChatSidebarVisible(true)
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    package func setChatSidebarVisible(_ visible: Bool) {
        phWithAnimation(.easeInOut(duration: 0.22)) { isShowingChatSidebar = visible }
    }
    package func startPluginTask(_ placement: PluginPlacement) {
        PluginRegistry.setAddMode(false)
        phWithAnimation(.easeInOut(duration: 0.25)) { pluginSetupPlacement = placement }
    }

    package func finishPluginSetup(_ placement: PluginPlacement, name: String, presentation: PluginPresentation) {
        guard !isStartingPluginTask else { return }
        isStartingPluginTask = true
        Task { @MainActor in
            defer { isStartingPluginTask = false }
            do {
                let started = try await pluginRegistry.author(placement, name: name, presentation: presentation)
                openPluginConversation(started.taskID, draft: started.prompt)
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    package func openPluginConversation(_ id: UUID, draft: String?) {
        Task { @MainActor in
            let manager = BoardTaskManager(modelContext: modelContext)
            for _ in 0..<100 {
                if let chat = try? manager.standaloneChatModel(id) {
                    setChatSidebarVisible(false)
                    pluginInitialDraft = draft
                    phWithAnimation(.easeInOut(duration: 0.3)) {
                        pluginChat = chat
                        pluginSetupPlacement = nil
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            saveError = "Couldn't open the plugin conversation."
        }
    }

    /// Shows a task the daemon just created, such as one fixing skills, and
    /// has its conversation send `prompt` once it opens.
    package func openTask(_ id: UUID, sending prompt: String) {
        let origin = selectedTask?.id
        Task { @MainActor in
            let manager = BoardTaskManager(modelContext: modelContext)
            // The daemon wrote the task; give this window's store a moment to see it.
            for _ in 0..<100 {
                // The user moved on while the store caught up; leave their choice alone.
                guard selectedTask?.id == origin else { return }
                if let task = try? manager.taskModel(id) {
                    // A plugin's openTask shows the task without sending anything.
                    skillFixPrompts[id] = prompt.isEmpty ? nil : prompt
                    isSelectedTaskNew = false
                    phWithAnimation(.easeInOut(duration: 0.3)) {
                        selectedTask = task
                        pluginSetupPlacement = nil
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            saveError = "Playhouse created the task but couldn't open it. Find it in Backlog."
        }
    }

    package func openNewTask() {
        openNewTask(presentingSchedule: nil)
    }

    package func openNewTask(presentingSchedule: TaskScheduleKind?) {
        guard !isCreatingNewTask else { return }
        isCreatingNewTask = true
        let attemptID = UUID().uuidString
        let startedAt = DispatchTime.now().uptimeNanoseconds
        PlayhouseDiagnostics.record("ui.new_task.started", fields: [
            "attemptID": attemptID
        ])
        Task { @MainActor in
            defer { isCreatingNewTask = false }
            do {
                let manager = BoardTaskManager(modelContext: modelContext)
                let settings = WorkspaceSettingsManager()
                let created = try await manager.create(
                    title: "Untitled task",
                    repositories: [],
                    contextFolders: [],
                    provider: settings.defaultConversationProvider
                )
                let newTask = try manager.taskModel(created.id)
                presentScheduleOnOpen = presentingSchedule
                selectedTask = newTask
                isSelectedTaskNew = true
                PlayhouseDiagnostics.record("ui.new_task.succeeded", fields: [
                    "attemptID": attemptID,
                    "taskID": created.id.uuidString,
                    "durationMilliseconds": String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000)
                ])
            } catch {
                let nsError = error as NSError
                PlayhouseDiagnostics.record("ui.new_task.failed", fields: [
                    "attemptID": attemptID,
                    "durationMilliseconds": String((DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000),
                    "errorDomain": nsError.domain,
                    "errorCode": String(nsError.code),
                    "errorDescription": error.localizedDescription
                ])
                presentSaveError(error.localizedDescription)
            }
        }
    }
}
