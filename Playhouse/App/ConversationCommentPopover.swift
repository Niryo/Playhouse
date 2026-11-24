import SwiftUI

/// What selected conversation text opens: a comment on it or a side chat about it.
enum SelectionAction {
    case comment
    case sideChat
}

/// The Comment and Side chat actions on selected conversation text, as one divided pill.
struct SelectionActionsPill: View {
    let comment: () -> Void
    let sideChat: () -> Void

    static let width: CGFloat = 214
    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            action("Comment", systemImage: "text.bubble", help: "Comment on the selected text", identifier: "selection-comment-button", perform: comment)
            Rectangle()
                .fill(Color.primary.opacity(0.18))
                .frame(width: 1, height: 16)
                .accessibilityHidden(true)
            action("Side chat", systemImage: "bubble.left.and.text.bubble.right", help: "Discuss the selected text in a side chat", identifier: "side-chat-hint-button", perform: sideChat)
        }
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)).allowsHitTesting(false))
        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selection-actions-pill")
    }

    private func action(
        _ title: String, systemImage: String, help: String, identifier: String, perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .plainButtonHoverPointer()
        .nativeHelp(help)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

/// The popover that adds a comment on selected text, or changes or discards the unsent comment
/// already made on it. A comment already sent on the text shows above the field, which then adds
/// another one.
struct CommentPopover: View {
    /// The unsent comment being changed, if the text has one.
    let editingComment: String?
    /// The sent comment on the text, which can no longer change.
    let sentComment: String?
    /// Adds the comment, or saves the edited one; saving an edited comment empty deletes it.
    let submit: (String) -> Void
    let discard: () -> Void
    let dismiss: () -> Void

    @State private var text: String

    init(
        editingComment: String?, sentComment: String?,
        submit: @escaping (String) -> Void, discard: @escaping () -> Void, dismiss: @escaping () -> Void
    ) {
        self.editingComment = editingComment
        self.sentComment = sentComment
        self.submit = submit
        self.discard = discard
        self.dismiss = dismiss
        _text = State(initialValue: editingComment ?? "")
    }

    private var isEditing: Bool { editingComment != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sentComment, !isEditing {
                Label {
                    Text(verbatim: sentComment)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("sent-comment-text")
                } icon: {
                    Image(systemName: "text.bubble")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                TextField(isEditing ? "Empty, saving deletes the comment" : "Add an optional comment…", text: $text)
                    .textFieldStyle(.plain)
                    .onSubmit { submit(text) }
                    .onExitCommand(perform: dismiss)
                    .accessibilityLabel("Comment")
                    .accessibilityIdentifier("comment-input-field")
                if isEditing {
                    Button(action: discard) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .plainButtonHoverPointer()
                    .nativeHelp("Discard comment")
                    .accessibilityLabel("Discard comment")
                    .accessibilityIdentifier("discard-comment-button")
                }
                Button { submit(text) } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.black)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.78), in: Circle())
                }
                .buttonStyle(.plain)
                .plainButtonHoverPointer()
                .disabled(isEditing && text == editingComment)
                .nativeHelp(isEditing ? "Save comment" : "Add comment")
                .accessibilityLabel(isEditing ? "Save comment" : "Add comment")
                .accessibilityIdentifier("add-comment-button")
            }
            .padding(.leading, 15)
            .padding(.trailing, 7)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            // Hit-testable, the outline took every click on the buttons it is drawn over.
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)).allowsHitTesting(false))
        }
        .frame(width: isEditing ? 395 : 355)
        .padding(5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("comment-popover")
    }
}
