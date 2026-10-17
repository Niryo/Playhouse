import SwiftData
import SwiftUI

struct TaskConversationView: View {
    private struct ChangeRepositoryGroup: Identifiable {
        let repository: String
        let entries: [WorkspaceChangeEntry]
        var id: String { repository }
    }

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var codexClient: CodexAppServerClient
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) private var defaultParentFolderPath = ""

    let task: BoardTask
    let onBack: () -> Void

    @State private var draft = ""
    @State private var conversationMode: CodexConversationMode = .code
    @State private var messages: [CodexChatMessage] = []
    @State private var activities: [CodexActivity] = []
    @State private var changeInventory = WorkspaceChangeInventory(staged: [], working: [])
    @State private var isLoadingChanges = false
    @State private var changesNeedRefresh = false
    @State private var changeWatcher: WorkspaceChangeWatcher?
    @State private var changesError: String?
    @State private var selectedChange: WorkspaceChangeEntry?
    @State private var selectedDiff: WorkspaceFileDiff?
    @State private var isDiffPresented = false
    @State private var isLoadingDiff = false
    @State private var diffError: String?
    @State private var isMonacoReady = false
    @State private var monacoError: String?
    @State private var diffChangeCount: Int?
    @State private var isLoadingHistory = false
    @State private var isResponding = false
    @State private var errorMessage: String?
    @State private var actionNotice: String?
    @State private var isShowingWorkspaceEditor = false
    @FocusState private var isComposerFocused: Bool

    private var isSendDisabled: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspaceRootURLs.isEmpty || isResponding || isLoadingHistory
    }

    private var diffHighlightStatus: String {
        guard let diffChangeCount else { return "Calculating changes…" }
        guard diffChangeCount > 0 else { return "No text changes" }
        return "\(diffChangeCount) change\(diffChangeCount == 1 ? "" : "s") highlighted"
    }

    var body: some View {
        HStack(spacing: 0) {
            taskSidebar

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)

            conversationPanel
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isShowingWorkspaceEditor) {
            WorkspaceRootsEditor(
                parentFolderURL: WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath),
                initialRoots: workspaceRootURLs,
                repositoryWorktrees: task.repositoryWorktrees,
                onSave: updateWorkspaceRoots
            )
        }
        .task {
            await loadConversation()
        }
        .task(id: task.workspaceRootPaths) {
            let watchPaths = await WorkspaceChangeWatcher.watchPaths(workspaceRoots: task.workspaceRootPaths)
            guard !Task.isCancelled else { return }
            changeWatcher?.stop()
            changeWatcher = WorkspaceChangeWatcher(paths: watchPaths) {
                Task { await refreshWorkspaceChanges() }
            }
            changeWatcher?.start()
            await refreshWorkspaceChanges()
        }
        .onDisappear {
            changeWatcher?.stop()
            changeWatcher = nil
        }
    }

    private var taskSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Changes")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityIdentifier("workspace-changes-title")
                Spacer(minLength: 0)
                Button {
                    Task { await refreshWorkspaceChanges() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Refresh workspace changes")
                .accessibilityLabel("Refresh workspace changes")
                .accessibilityIdentifier("refresh-workspace-changes-button")
                .disabled(isLoadingChanges)
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            if let changesError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Couldn't read Git changes", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.red)
                    Text(changesError)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry") {
                        Task { await refreshWorkspaceChanges() }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityIdentifier("retry-workspace-changes-button")
                }
                .padding(12)
                .accessibilityIdentifier("workspace-changes-error")
            } else if isLoadingChanges && changeInventory.isEmpty {
                ProgressView("Checking folders…")
                    .controlSize(.small)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("workspace-changes-loading")
            } else if changeInventory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text("No changes")
                        .font(.system(size: 12, weight: .medium))
                    Text("Changes in Git repositories under this task's folders will appear here.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(15)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("workspace-changes-empty")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        changeSection(title: "Staged Changes", entries: changeInventory.staged)
                        changeSection(title: "Changes", entries: changeInventory.working)
                    }
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.visible)
                .accessibilityIdentifier("workspace-changes-list")
            }
        }
        .frame(width: 232)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.62))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-sidebar")
    }

    private func changeSection(title: String, entries: [WorkspaceChangeEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: title == "Staged Changes" ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(title == "Staged Changes" ? .green : .secondary)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("\(entries.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .accessibilityIdentifier(title == "Staged Changes" ? "staged-changes-section" : "working-changes-section")

            if entries.isEmpty {
                Text("No files")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 31)
                    .padding(.vertical, 3)
            } else {
                let groups = repositoryGroups(entries)
                ForEach(groups, id: \.repository) { repositoryGroup in
                    if Set(changeInventory.staged.map(\.repository) + changeInventory.working.map(\.repository)).count > 1 {
                        Text(repositoryLabel(repositoryGroup.repository))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.leading, 17)
                            .padding(.top, 4)
                            .accessibilityIdentifier("workspace-repository-\(repositoryGroup.repository.hashValue)")
                    }
                    ForEach(repositoryGroup.entries) { entry in
                        Button {
                            openDiff(entry)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: changeSymbol(for: entry.status))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(changeColor(for: entry.status))
                                    .frame(width: 12)
                                Text(entry.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text(statusBadge(for: entry))
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(changeColor(for: entry.status))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .background(
                                selectedChange?.id == entry.id
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                        }
                        .buttonStyle(.plain)
                        .help("View \(entry.group.rawValue) diff for \(entry.path)")
                        .accessibilityLabel("\(entry.path), \(entry.status), \(entry.group.rawValue)")
                        .accessibilityIdentifier("workspace-change-\(entry.group.rawValue)-\(entry.path)")
                        .padding(.horizontal, 7)
                    }
                }
            }
        }
    }

    private func repositoryGroups(_ entries: [WorkspaceChangeEntry]) -> [ChangeRepositoryGroup] {
        Dictionary(grouping: entries, by: \.repository)
            .keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { repository in
                ChangeRepositoryGroup(repository: repository, entries: entries.filter { $0.repository == repository })
            }
    }

    private func repositoryLabel(_ path: String) -> String {
        let components = URL(fileURLWithPath: path).pathComponents
        return components.suffix(2).joined(separator: "/")
    }

    private func statusBadge(for entry: WorkspaceChangeEntry) -> String {
        if entry.statusCode == "??" { return "U" }
        if entry.statusCode.contains("R") { return "R" }
        if entry.statusCode.contains("A") { return "A" }
        if entry.statusCode.contains("D") { return "D" }
        if entry.status == "conflict" { return "!" }
        return "M"
    }

    private func changeSymbol(for status: String) -> String {
        switch status {
        case "added", "untracked": "plus.square.fill"
        case "deleted": "minus.square.fill"
        case "renamed", "copied": "arrow.turn.up.right"
        case "conflict": "exclamationmark.triangle.fill"
        default: "doc.text"
        }
    }

    private func changeColor(for status: String) -> Color {
        switch status {
        case "added", "untracked": .green
        case "deleted", "conflict": .red
        case "renamed", "copied": .orange
        default: .secondary
        }
    }

    private var conversationPanel: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                conversationHeader

                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)

                safetyNotice

                conversation

                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)

                composer
            }

            if isDiffPresented {
                fileDiffOverlay
                    .transition(.move(edge: .leading))
                    .zIndex(1)
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.24), value: isDiffPresented)
        .onExitCommand {
            if isDiffPresented { closeDiff() }
        }
    }

    private var fileDiffOverlay: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Button(action: closeDiff) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close diff")
                .accessibilityLabel("Close diff")
                .accessibilityIdentifier("close-workspace-diff-button")

                if let selectedChange {
                    Image(systemName: changeSymbol(for: selectedChange.status))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(changeColor(for: selectedChange.status))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedChange.path)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("workspace-diff-title")
                        Text("\(repositoryLabel(selectedChange.repository)) · \(selectedChange.group == .staged ? "Staged" : "Working tree")")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("workspace-diff-source")
                    }
                } else {
                    Text("File diff")
                        .font(.system(size: 12, weight: .semibold))
                }

                Spacer(minLength: 0)
                if selectedDiff?.isText == true {
                    Text(isMonacoReady ? "Side-by-side" : "Starting editor")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("workspace-diff-editor-status")
                    if isMonacoReady {
                        Text(diffHighlightStatus)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(diffChangeCount.map { $0 > 0 ? Color.green : Color.secondary } ?? Color.secondary)
                            .accessibilityIdentifier("workspace-diff-highlight-status")
                    }
                }
                Text("READ ONLY")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))

            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(height: 1)

            Group {
                if isLoadingDiff {
                    ProgressView("Loading file diff…")
                        .controlSize(.small)
                        .accessibilityIdentifier("workspace-diff-loading")
                } else if let diffError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(diffError)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .accessibilityIdentifier("workspace-diff-error")
                } else if let selectedDiff, selectedDiff.isText {
                    if let monacoError {
                        VStack(spacing: 9) {
                            Text(monacoError)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Reload editor") {
                                isMonacoReady = false
                                diffChangeCount = nil
                                self.monacoError = nil
                                self.selectedDiff = nil
                                if let selectedChange { openDiff(selectedChange) }
                            }
                            .font(.system(size: 11, weight: .medium))
                        }
                        .padding(24)
                    } else {
                        ZStack {
                            MonacoDiffEditor(
                                diff: selectedDiff,
                                theme: colorScheme == .dark ? "vs-dark" : "vs",
                                isReady: $isMonacoReady,
                                loadError: $monacoError,
                                diffChangeCount: $diffChangeCount
                            )
                            .accessibilityIdentifier("workspace-diff-editor")

                            if !isMonacoReady {
                                ProgressView("Starting Monaco…")
                                    .controlSize(.small)
                                    .padding(12)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                    .accessibilityIdentifier("workspace-diff-editor-loading")
                            }
                        }
                    }
                } else if let selectedDiff {
                    VStack(spacing: 9) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text(selectedDiff.message ?? "This file can't be shown as a text diff.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("workspace-diff-unsupported")
                    }
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspace-diff-overlay")
        .background(EscapeKeyMonitor(onEscape: closeDiff).frame(width: 0, height: 0))
    }

    private func openDiff(_ entry: WorkspaceChangeEntry) {
        selectedChange = entry
        selectedDiff = nil
        isLoadingDiff = true
        diffError = nil
        monacoError = nil
        isMonacoReady = false
        diffChangeCount = nil
        withAnimation(.easeInOut(duration: 0.24)) {
            isDiffPresented = true
        }

        Task {
            do {
                let diff = try await workspaceManager.diff(
                    for: task.id,
                    repository: entry.repository,
                    path: entry.path,
                    group: entry.group.rawValue
                )
                guard selectedChange?.id == entry.id else { return }
                selectedDiff = diff
            } catch {
                guard selectedChange?.id == entry.id else { return }
                diffError = error.localizedDescription
            }
            if selectedChange?.id == entry.id { isLoadingDiff = false }
        }
    }

    private func closeDiff() {
        withAnimation(.easeInOut(duration: 0.24)) {
            isDiffPresented = false
        }
    }

    private func refreshWorkspaceChanges() async {
        guard !isLoadingChanges else {
            changesNeedRefresh = true
            return
        }
        isLoadingChanges = true
        defer { isLoadingChanges = false }

        repeat {
            changesNeedRefresh = false
            do {
                let inventory = try await workspaceManager.changes(for: task.id)
                changeInventory = inventory
                changesError = nil
                if let selectedChange {
                    if let current = (inventory.staged + inventory.working).first(where: { $0.id == selectedChange.id }) {
                        self.selectedChange = current
                        if isDiffPresented {
                            do {
                                let diff = try await workspaceManager.diff(
                                    for: task.id,
                                    repository: current.repository,
                                    path: current.path,
                                    group: current.group.rawValue
                                )
                                if self.selectedChange?.id == current.id {
                                    selectedDiff = diff
                                    diffError = nil
                                }
                            } catch {
                                if self.selectedChange?.id == current.id {
                                    selectedDiff = nil
                                    diffError = error.localizedDescription
                                }
                            }
                        }
                    } else {
                        self.selectedChange = nil
                        selectedDiff = nil
                        diffError = "This file no longer has a Git change."
                    }
                }
            } catch {
                changesError = error.localizedDescription
            }
        } while changesNeedRefresh
    }

    private var conversationHeader: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to Kanban")
            .accessibilityLabel("Back to Kanban board")
            .accessibilityIdentifier("back-to-board-button")

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("task-view-title")

                HStack(spacing: 6) {
                    Circle()
                        .fill(task.status.accent)
                        .frame(width: 6, height: 6)
                    Text(task.status.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Button {
                isShowingWorkspaceEditor = true
            } label: {
                Label("Folders", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .help("Edit working folders for this task")
            .accessibilityIdentifier("edit-workspace-roots-button")
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Full machine and network access · working folders provide context only", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
            if workspaceRootURLs.isEmpty {
                Text("No working folders are set. Add one or more folders before sending a message.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                let folderLabels = workspaceRootURLs.map { url in
                    task.repositoryWorktrees.first(where: { URL(fileURLWithPath: $0.worktreePath).standardizedFileURL.path == url.path })
                        .map { "\(URL(fileURLWithPath: $0.repositoryPath).lastPathComponent) · \($0.branch)" } ?? url.lastPathComponent
                }
                let folderSummary = "Working in: " + folderLabels.joined(separator: " · ")
                let fullFolderSummary = "Working in: " + workspaceRootURLs.map(\.path).joined(separator: " · ")
                Text(folderSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityLabel(folderSummary)
                    .accessibilityValue(fullFolderSummary)
                    .accessibilityIdentifier("working-folders-summary")
            }
        }
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
        .padding(.top, 12)
    }

    private var conversation: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if messages.isEmpty {
                        VStack(spacing: 12) {
                            if isLoadingHistory {
                                ProgressView("Loading conversation…")
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.system(size: 25, weight: .regular))
                                    .foregroundStyle(Color.accentColor.opacity(0.8))
                                Text("Start a conversation")
                                    .font(.system(size: 17, weight: .semibold))
                                Text("Send a message to Codex · Luna.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 210)
                        .padding(30)
                        .accessibilityIdentifier("empty-conversation")
                    } else {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(messages) { message in
                                messageBubble(message)
                                    .id(message.id)
                            }
                        }
                    }

                    if !activities.isEmpty {
                        activityList
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.visible)
            .accessibilityIdentifier("conversation-scroll-view")
            .onChange(of: messages.count) { _, _ in
                scrollToLatest(using: scrollProxy)
            }
            .onChange(of: messages.map(\.text)) { _, _ in
                scrollToLatest(using: scrollProxy)
            }
            .onChange(of: activities) { _, _ in
                if isResponding { scrollToLatest(using: scrollProxy) }
            }
        }
    }

    private var activityList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codex activity")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(activities) { activity in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Image(systemName: activity.status == "completed" ? "checkmark.circle.fill" : "gearshape.2.fill")
                            .foregroundStyle(activity.status == "completed" ? .green : .accentColor)
                        Text(activity.title)
                            .font(.system(size: 11, weight: .medium))
                            .textSelection(.enabled)
                    }
                    if !activity.detail.isEmpty {
                        Text(activity.detail)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(9)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .accessibilityIdentifier("codex-activity-list")
    }

    @ViewBuilder
    private func messageBubble(_ message: CodexChatMessage) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .assistant {
                assistantBubble(message)
                Spacer(minLength: 70)
            } else {
                Spacer(minLength: 70)
                userBubble(message)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func assistantBubble(_ message: CodexChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Codex · Luna")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Group {
                if message.text.isEmpty && isResponding {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(message.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(.primary)
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .accessibilityLabel(message.text.isEmpty ? "Waiting for Codex response" : message.text)
            .accessibilityIdentifier("assistant-message-\(message.id)")
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    private func userBubble(_ message: CodexChatMessage) -> some View {
        Text(message.text)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(
                Color(red: 0.34, green: 0.40, blue: 0.86),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .frame(maxWidth: 620, alignment: .trailing)
            .accessibilityIdentifier("user-message-\(message.id)")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let actionNotice {
                Label(actionNotice, systemImage: "hand.raised.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("codex-action-notice")
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(errorMessage)
                    .accessibilityIdentifier("codex-chat-error")
            }

            HStack(alignment: .bottom, spacing: 12) {
                Menu {
                    ForEach(CodexConversationMode.allCases, id: \.self) { mode in
                        Button {
                            conversationMode = mode
                        } label: {
                            if conversationMode == mode {
                                Label(mode.title, systemImage: "checkmark")
                            } else {
                                Text(mode.title)
                            }
                        }
                        .accessibilityIdentifier("conversation-mode-\(mode.rawValue)")
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .semibold))
                        if conversationMode == .plan {
                            Text("Plan")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .foregroundStyle(conversationMode == .plan ? Color.accentColor : Color.secondary)
                    .frame(minWidth: 30, minHeight: 31)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Conversation mode: \(conversationMode.title)")
                .accessibilityIdentifier("conversation-mode-menu")

                TextField("Message…", text: $draft, axis: .vertical)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .focused($isComposerFocused)
                    .onSubmit(sendMessage)
                    .onChange(of: draft) { _, newValue in
                        if newValue.trimmingCharacters(in: .whitespacesAndNewlines) == "/plan" {
                            activatePlanMode()
                        }
                    }
                    .disabled(isResponding || isLoadingHistory)
                    .accessibilityIdentifier("message-composer")

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 31, height: 31)
                        .background(
                            Color(red: 0.34, green: 0.40, blue: 0.86),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(isSendDisabled)
                .opacity(isSendDisabled ? 0.45 : 1)
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("send-message-button")
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 22)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
    }

    private func loadConversation() async {
        isLoadingHistory = true
        errorMessage = nil
        defer { isLoadingHistory = false }

        do {
            let history = try await conversationManager.history(taskID: task.id) {
                actionNotice = "Codex requested an approval. StationAI denied it because approval prompts are disabled."
            }
            messages = history.messages
            activities = history.activities
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding, !isLoadingHistory else { return }
        if text == "/plan" {
            activatePlanMode()
            return
        }

        let userMessageID = UUID().uuidString
        let assistantMessageID = UUID().uuidString
        messages.append(CodexChatMessage(id: userMessageID, role: .user, text: text))
        messages.append(CodexChatMessage(id: assistantMessageID, role: .assistant, text: ""))
        isResponding = true
        errorMessage = nil
        actionNotice = nil
        activities = []

        Task { @MainActor in
            do {
                _ = try await conversationManager.send(taskID: task.id, text: text, mode: conversationMode) { update in
                    switch update.type {
                    case "text_delta":
                        guard let delta = update.text else { return }
                        guard let messageIndex = messages.firstIndex(where: { $0.id == assistantMessageID }) else { return }
                        messages[messageIndex].text += delta
                    case "assistant_final":
                        guard let text = update.text else { return }
                        guard let messageIndex = messages.lastIndex(where: { $0.role == .assistant }) else { return }
                        messages[messageIndex].text = text
                    case "activity":
                        guard let activity = update.activity else { return }
                        if let index = activities.firstIndex(where: { $0.id == activity.id }) {
                            activities[index] = activity
                        } else {
                            activities.append(activity)
                        }
                    case "diff":
                        break
                    case "history", "completed":
                        guard let history = update.history else { return }
                        messages = history.messages
                        activities = history.activities
                        if update.type == "completed" {
                            Task { await refreshWorkspaceChanges() }
                        }
                    case "action_notice":
                        actionNotice = update.message
                    default:
                        break
                    }
                }

                if messages.first(where: { $0.id == assistantMessageID })?.text.isEmpty == true {
                    messages.removeAll { $0.id == assistantMessageID }
                }
                draft = ""
                isComposerFocused = true
            } catch {
                messages.removeAll { $0.id == userMessageID || $0.id == assistantMessageID }
                errorMessage = error.localizedDescription
                isComposerFocused = true
            }

            isResponding = false
        }
    }

    private func activatePlanMode() {
        conversationMode = .plan
        draft = ""
    }

    private var workspaceRootURLs: [URL] {
        task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    private var conversationManager: CodexConversationManager {
        CodexConversationManager(
            tasks: BoardTaskManager(modelContext: modelContext),
            client: codexClient
        )
    }

    private var workspaceManager: WorkspaceManager {
        WorkspaceManager(taskManager: BoardTaskManager(modelContext: modelContext))
    }

    private func updateWorkspaceRoots(_ roots: [URL]) {
        do {
            _ = try WorkspaceManager(taskManager: BoardTaskManager(modelContext: modelContext))
                .setRoots(roots.map { $0.standardizedFileURL.path }, for: task.id)
            Task { await refreshWorkspaceChanges() }
        } catch {
            errorMessage = "Couldn't save working folders: \(error.localizedDescription)"
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        let target: String
        if let latestMessage = messages.last {
            target = latestMessage.id
        } else if let latestActivity = activities.last {
            target = latestActivity.id
        } else {
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}
