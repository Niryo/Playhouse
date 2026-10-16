import SwiftData
import SwiftUI

struct TaskConversationView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var codexClient: CodexAppServerClient
    @AppStorage(WorkspaceSettings.defaultParentFolderKey, store: WorkspaceSettings.preferencesStore) private var defaultParentFolderPath = ""

    let task: BoardTask
    let onBack: () -> Void

    @State private var draft = ""
    @State private var messages: [CodexChatMessage] = []
    @State private var activities: [CodexActivity] = []
    @State private var turnDiff: CodexTurnDiff?
    @State private var isDiffExpanded = false
    @State private var isLoadingHistory = false
    @State private var isResponding = false
    @State private var errorMessage: String?
    @State private var actionNotice: String?
    @State private var isShowingWorkspaceEditor = false
    @FocusState private var isComposerFocused: Bool

    private var isSendDisabled: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspaceRootURLs.isEmpty || isResponding || isLoadingHistory
    }

    var body: some View {
        HStack(spacing: 0) {
            taskSidebar

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)

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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $isShowingWorkspaceEditor) {
            WorkspaceRootsEditor(
                parentFolderURL: WorkspaceSettings.validDirectoryURL(for: defaultParentFolderPath),
                initialRoots: workspaceRootURLs,
                onSave: updateWorkspaceRoots
            )
        }
        .task {
            await loadConversation()
        }
    }

    private var taskSidebar: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
        }
        .frame(width: 232)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-sidebar")
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
                let folderSummary = "Working in: " + workspaceRootURLs.map(\.path).joined(separator: " · ")
                Text(folderSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .accessibilityLabel(folderSummary)
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
                    if let turnDiff, !turnDiff.unifiedDiff.isEmpty {
                        diffCard(turnDiff)
                            .id("latest-turn-diff")
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.visible)
            .accessibilityIdentifier("conversation-scroll-view")
            .onChange(of: isDiffExpanded) { _, isExpanded in
                guard isExpanded, turnDiff != nil else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollProxy.scrollTo("latest-turn-diff", anchor: .bottom)
                }
            }
            .onChange(of: messages.count) { _, _ in
                scrollToLatest(using: scrollProxy)
            }
            .onChange(of: messages.map(\.text)) { _, _ in
                scrollToLatest(using: scrollProxy)
            }
            .onChange(of: activities) { _, _ in
                if isResponding { scrollToLatest(using: scrollProxy) }
            }
            .onChange(of: turnDiff?.unifiedDiff) { _, _ in
                scrollToLatest(using: scrollProxy)
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

    private func diffCard(_ diff: CodexTurnDiff) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("Changes", systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
            if !diff.changedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(diff.changedFiles, id: \.self) { path in
                        Label(path, systemImage: "doc.text")
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(path)
                            .accessibilityIdentifier("codex-changed-file-\(URL(fileURLWithPath: path).lastPathComponent)")
                    }
                }
            }
            Button {
                isDiffExpanded.toggle()
            } label: {
                Label("View diff", systemImage: isDiffExpanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .accessibilityIdentifier("codex-view-diff-toggle")

            if isDiffExpanded {
                ScrollView([.horizontal, .vertical]) {
                    Text(diff.unifiedDiff)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .accessibilityLabel(diff.unifiedDiff)
                        .accessibilityIdentifier("codex-unified-diff")
                }
                .frame(maxHeight: 260)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityIdentifier("codex-unified-diff-scroll")
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("codex-turn-diff")
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
                TextField("Message…", text: $draft, axis: .vertical)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .focused($isComposerFocused)
                    .onSubmit(sendMessage)
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
            turnDiff = history.diff
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding, !isLoadingHistory else { return }

        let userMessageID = UUID().uuidString
        let assistantMessageID = UUID().uuidString
        messages.append(CodexChatMessage(id: userMessageID, role: .user, text: text))
        messages.append(CodexChatMessage(id: assistantMessageID, role: .assistant, text: ""))
        isResponding = true
        errorMessage = nil
        actionNotice = nil
        activities = []
        turnDiff = nil
        isDiffExpanded = false

        Task { @MainActor in
            do {
                _ = try await conversationManager.send(taskID: task.id, text: text) { update in
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
                        guard let unifiedDiff = update.diff else { return }
                        let diff = CodexTurnDiff(unifiedDiff: unifiedDiff)
                        turnDiff = turnDiff?.merging(diff) ?? diff
                    case "history", "completed":
                        guard let history = update.history else { return }
                        messages = history.messages
                        activities = history.activities
                        turnDiff = history.diff
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

    private var workspaceRootURLs: [URL] {
        task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }

    private var conversationManager: CodexConversationManager {
        CodexConversationManager(
            tasks: BoardTaskManager(modelContext: modelContext),
            client: codexClient
        )
    }

    private func updateWorkspaceRoots(_ roots: [URL]) {
        do {
            _ = try WorkspaceManager(taskManager: BoardTaskManager(modelContext: modelContext))
                .setRoots(roots.map { $0.standardizedFileURL.path }, for: task.id)
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
        } else if turnDiff != nil {
            target = "latest-turn-diff"
        } else {
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }
}
