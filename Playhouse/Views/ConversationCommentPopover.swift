import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// What selected conversation text opens: a comment on it or a side chat about it.
package enum SelectionAction {
    case comment
    case sideChat
}

/// The Comment and Side chat actions on selected conversation text, as one divided pill.
package struct SelectionActionsPill: PHView {
    package let comment: () -> Void
    package let sideChat: () -> Void

    package static let width: CGFloat = 214
    package static let height: CGFloat = 30

    package var body: some PHView {
        PHHStack(spacing: 0) {
            action("Comment", icon: .textBubble, help: "Comment on the selected text", identifier: "selection-comment-button", perform: comment)
            PHRectangle()
                .fill(PHColor.primary.opacity(0.18))
                .frame(width: 1, height: 16)
                .accessibilityHidden(true)
            action("Side chat", icon: .bubbleLeftAndTextBubbleRight, help: "Discuss the selected text in a side chat", identifier: "side-chat-hint-button", perform: sideChat)
        }
        .phMaterialBackground(.regular, in: PHCapsule())
        .overlay(PHCapsule().strokeBorder(PHColor.white.opacity(0.12)).allowsHitTesting(false))
        .phShadow(color: .black.opacity(0.25), radius: 5, y: 2)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selection-actions-pill")
    }

    private func action(
        _ title: String, icon: PHIcon, help: String, identifier: String, perform: @escaping () -> Void
    ) -> some PHView {
        PHButton(action: perform) {
            PHLabel(title, icon: icon)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .contentShape(PHRectangle())
        }
        .buttonStyle(.plain)
        .plainButtonHoverPointer()
        .nativeHelp(help)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    package init(comment: @escaping () -> Void, sideChat: @escaping () -> Void) {
        self.comment = comment
        self.sideChat = sideChat
    }
}

/// The popover that adds a comment on selected text, or changes or discards the unsent comment
/// already made on it. A comment already sent on the text shows above the field, which then adds
/// another one.
package struct CommentPopover: PHView {
    /// The unsent comment being changed, if the text has one.
    package let editingComment: String?
    /// The sent comment on the text, which can no longer change.
    package let sentComment: String?
    /// Adds the comment, or saves the edited one; saving an edited comment empty deletes it.
    package let submit: (String) -> Void
    package let discard: () -> Void
    package let dismiss: () -> Void

    @PHState private var text: String

    package init(
        editingComment: String?, sentComment: String?,
        submit: @escaping (String) -> Void, discard: @escaping () -> Void, dismiss: @escaping () -> Void
    ) {
        self.editingComment = editingComment
        self.sentComment = sentComment
        self.submit = submit
        self.discard = discard
        self.dismiss = dismiss
        _text = PHState(initialValue: editingComment ?? "")
    }

    private var isEditing: Bool { editingComment != nil }

    package var body: some PHView {
        PHVStack(alignment: .leading, spacing: 6) {
            if let sentComment, !isEditing {
                PHLabel {
                    PHText(verbatim: sentComment)
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("sent-comment-text")
                } icon: {
                    PHImage(icon: .textBubble)
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .fixedSize(horizontal: false, vertical: true)
            }
            PHHStack(spacing: 8) {
                PHTextField(isEditing ? "Empty, saving deletes the comment" : "Add an optional comment…", text: $text)
                    .textFieldStyle(.plain)
                    .onSubmit { submit(text) }
                    .onExitCommand(perform: dismiss)
                    .accessibilityLabel("Comment")
                    .accessibilityIdentifier("comment-input-field")
                if isEditing {
                    PHButton(action: discard) {
                        PHImage(icon: .trash)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(PHCircle())
                    }
                    .buttonStyle(.plain)
                    .plainButtonHoverPointer()
                    .nativeHelp("Discard comment")
                    .accessibilityLabel("Discard comment")
                    .accessibilityIdentifier("discard-comment-button")
                }
                PHButton { submit(text) } label: {
                    PHImage(icon: .arrowUp)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PHColor.black)
                        .frame(width: 32, height: 32)
                        .background(PHColor.white.opacity(0.78), in: PHCircle())
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
            .background(PHColor(platformColor: .controlBackgroundColor), in: PHCapsule())
            // Hit-testable, the outline took every click on the buttons it is drawn over.
            .overlay(PHCapsule().strokeBorder(PHColor.primary.opacity(0.08)).allowsHitTesting(false))
        }
        .frame(width: isEditing ? 395 : 355)
        .padding(5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("comment-popover")
    }
}
