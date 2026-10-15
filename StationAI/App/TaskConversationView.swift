import SwiftData
import SwiftUI

struct TaskConversationView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var codexClient: CodexAppServerClient

    let task: BoardTask
    let onBack: () -> Void

    @State private var draft = ""
    @State private var messages: [CodexChatMessage] = []
    @State private var isLoadingHistory = false
    @State private var isResponding = false
    @State private var errorMessage: String?
    @State private var actionNotice: String?
    @FocusState private var isComposerFocused: Bool

    private var isSendDisabled: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResponding || isLoadingHistory
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
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
    }

    private var safetyNotice: some View {
        Label("Text replies only · no project files shared", systemImage: "lock.shield")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 12)
    }

    private var conversation: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(30)
                    .accessibilityIdentifier("empty-conversation")
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
            }
            .scrollIndicators(.visible)
            .onChange(of: messages.count) { _, _ in
                scrollToLatest(using: scrollProxy)
            }
            .onChange(of: messages.map(\.text)) { _, _ in
                scrollToLatest(using: scrollProxy)
            }
        }
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
        guard let threadID = task.codexThreadID else { return }
        isLoadingHistory = true
        errorMessage = nil
        defer { isLoadingHistory = false }

        do {
            let directory = try workspaceURL()
            messages = try await codexClient.loadThread(id: threadID, workspaceURL: directory) {
                actionNotice = "Codex requested an action. StationAI denied it in text-only mode."
            }
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

        Task { @MainActor in
            do {
                let directory = try workspaceURL()
                let threadID: String

                if let existingThreadID = task.codexThreadID {
                    threadID = existingThreadID
                } else {
                    let createdThreadID = try await codexClient.startThread(workspaceURL: directory)
                    task.codexThreadID = createdThreadID
                    do {
                        try modelContext.save()
                    } catch {
                        task.codexThreadID = nil
                        throw error
                    }
                    threadID = createdThreadID
                }

                try await codexClient.sendMessage(
                    text,
                    threadID: threadID,
                    workspaceURL: directory,
                    onDelta: { delta in
                        guard let messageIndex = messages.firstIndex(where: { $0.id == assistantMessageID }) else { return }
                        messages[messageIndex].text += delta
                    },
                    onActionRequest: {
                        actionNotice = "Codex requested an action. StationAI denied it in text-only mode."
                    }
                )

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

    private func workspaceURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let taskDirectory = applicationSupport
            .appendingPathComponent("StationAI", isDirectory: true)
            .appendingPathComponent("CodexWorkspaces", isDirectory: true)
            .appendingPathComponent(task.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: taskDirectory, withIntermediateDirectories: true)
        return taskDirectory
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        guard let latestMessage = messages.last else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(latestMessage.id, anchor: .bottom)
        }
    }
}
