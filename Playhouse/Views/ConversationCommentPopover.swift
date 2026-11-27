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
        AtomStack(
            props: StackProps(
                axis: "h", spacing: 0, group: true, capsule: true, stroke: "white", strokeOpacity: 0.12,
                material: "regular", shadow: 5, shadowOpacity: 0.25, shadowY: 2
            ),
            common: AtomCommon(testID: "selection-actions-pill", fixedSize: true)
        ) {
            action("Comment", icon: .textBubble, help: "Comment on the selected text", identifier: "selection-comment-button", perform: comment)
            AtomStack(props: StackProps(fill: "primary", fillOpacity: 0.18), common: AtomCommon(width: 1, height: 16, decorative: true)) {
                PHEmptyView()
            }
            action("Side chat", icon: .bubbleLeftAndTextBubbleRight, help: "Discuss the selected text in a side chat", identifier: "side-chat-hint-button", perform: sideChat)
        }
    }

    private func action(
        _ title: String, icon: PHIcon, help: String, identifier: String, perform: @escaping () -> Void
    ) -> some PHView {
        AtomButton(
            common: AtomCommon(testID: identifier, label: title, help: help, paddingX: 12, paddingY: 7),
            action: perform
        ) {
            AtomLabel(props: LabelProps(text: title, icon: icon.name, size: 13, weight: "medium"))
        }
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
        AtomStack(
            props: StackProps(spacing: 6, align: "leading", group: true),
            common: AtomCommon(testID: "comment-popover", width: isEditing ? 395 : 355, padding: 5)
        ) {
            if let sentComment, !isEditing {
                AtomStack(props: StackProps(axis: "h", align: "baseline"), common: AtomCommon(fillWidth: true, paddingX: 10)) {
                    AtomIcon(props: IconProps(name: PHIcon.textBubble.name, size: 12, color: "secondary"))
                    AtomText(
                        props: TextProps(text: sentComment, size: 12, color: "secondary", lineLimit: 4, wrap: true, selectable: true),
                        common: AtomCommon(testID: "sent-comment-text")
                    )
                }
            }
            // The outline never takes the clicks on the buttons it is drawn over.
            AtomStack(
                props: StackProps(axis: "h", spacing: 8, fill: "control", capsule: true, stroke: "primary", strokeOpacity: 0.08),
                common: AtomCommon(paddingY: 7, paddingLeading: 15, paddingTrailing: 7)
            ) {
                AtomTextField(
                    props: TextFieldProps(text: text, placeholder: isEditing ? "Empty, saving deletes the comment" : "Add an optional comment…", style: "plain"),
                    common: AtomCommon(testID: "comment-input-field", label: "Comment"),
                    onChange: { text = $0 },
                    onSubmit: { submit(text) }
                )
                .onExitCommand(perform: dismiss)
                if isEditing {
                    AtomButton(
                        common: AtomCommon(testID: "discard-comment-button", label: "Discard comment", help: "Discard comment"),
                        action: discard
                    ) {
                        AtomIcon(
                            props: IconProps(name: PHIcon.trash.name, size: 12, weight: "medium", color: "secondary"),
                            common: AtomCommon(width: 28, height: 28)
                        )
                    }
                }
                AtomButton(
                    props: ButtonProps(disabled: isEditing && text == editingComment),
                    common: AtomCommon(
                        testID: "add-comment-button",
                        label: isEditing ? "Save comment" : "Add comment",
                        help: isEditing ? "Save comment" : "Add comment"
                    ),
                    action: { submit(text) }
                ) {
                    AtomStack(props: StackProps(fill: "white", fillOpacity: 0.78, capsule: true), common: AtomCommon(width: 32, height: 32)) {
                        AtomIcon(props: IconProps(name: PHIcon.arrowUp.name, size: 12, weight: "semibold", color: "black"))
                    }
                }
            }
        }
    }
}
