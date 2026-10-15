import SwiftUI

struct TaskConversationView: View {
    let task: BoardTask
    let onBack: () -> Void

    @State private var draft = ""
    @State private var messages: [TaskChatMessage] = []
    @FocusState private var isComposerFocused: Bool

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

                conversation

                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)

                composer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var conversation: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                if messages.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 25, weight: .regular))
                            .foregroundStyle(Color.accentColor.opacity(0.8))
                        Text("Start a conversation")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Send a message to begin working on this task.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(30)
                    .accessibilityIdentifier("empty-conversation")
                } else {
                    LazyVStack(alignment: .trailing, spacing: 14) {
                        ForEach(messages.indices, id: \.self) { index in
                            let message = messages[index]
                            HStack {
                                Spacer(minLength: 80)
                                Text(message.text)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 11)
                                    .background(
                                        Color(red: 0.34, green: 0.40, blue: 0.86),
                                        in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                                    )
                                    .accessibilityIdentifier("sent-message-\(index)")
                            }
                            .id(message.id)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 820, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .scrollIndicators(.visible)
            .onChange(of: messages.count) { _, _ in
                guard let latestMessage = messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    scrollProxy.scrollTo(latestMessage.id, anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message…", text: $draft, axis: .vertical)
                .font(.system(size: 14))
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused($isComposerFocused)
                .onSubmit(sendMessage)
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
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
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
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 22)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
    }

    private func sendMessage() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        messages.append(TaskChatMessage(text: text))
        draft = ""
        isComposerFocused = true
    }
}

private struct TaskChatMessage: Identifiable {
    let id = UUID()
    let text: String
}
