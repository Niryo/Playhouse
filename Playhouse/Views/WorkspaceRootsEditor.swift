import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

package struct WorkspaceRootsEditor: PHView {
    @PHEnvironment(\.dismiss) private var dismiss
    package let parentFolderURL: URL?
    package let initialRoots: [URL]
    package let repositoryWorktrees: [RepositoryWorktreeRecord]
    package let onSave: ([URL]) -> Void
    @PHState private var roots: [URL]

    package init(parentFolderURL: URL?, initialRoots: [URL], repositoryWorktrees: [RepositoryWorktreeRecord] = [], onSave: @escaping ([URL]) -> Void) {
        self.parentFolderURL = parentFolderURL
        self.initialRoots = initialRoots
        self.repositoryWorktrees = repositoryWorktrees
        self.onSave = onSave
        _roots = PHState(initialValue: initialRoots)
    }

    package var body: some PHView {
        AtomStack(props: StackProps(spacing: 16, align: "leading"), common: AtomCommon(width: 560, height: 620, paddingX: 24, paddingY: 24)) {
            AtomText(props: TextProps(text: "Edit working folders", size: 19, weight: "semibold", design: "rounded"))
            AtomText(props: TextProps(text: "Changes apply to the next Codex turn. The first folder is used as the working directory.", size: 12, color: "secondary"))
            WorkspaceRootSelector(
                parentFolderURL: parentFolderURL,
                roots: $roots,
                displayNames: Dictionary(uniqueKeysWithValues: repositoryWorktrees.map {
                    ($0.worktreePath, "\(URL(fileURLWithPath: $0.repositoryPath).lastPathComponent) · \($0.branch)")
                })
            )
            AtomLabel(props: LabelProps(
                text: "Codex has full machine and network access; this list sets task context only.",
                icon: PHIcon.exclamationmarkTriangleFill.name, size: 11, weight: "medium", color: "orange"
            ))
            AtomStack(props: StackProps(axis: "h")) {
                AtomSpacer()
                AtomButton(
                    props: ButtonProps(style: "automatic", shortcut: "cancel"),
                    common: AtomCommon(help: "Cancel folder changes"),
                    action: { dismiss() }
                ) {
                    AtomText(props: TextProps(text: "Cancel"))
                }
                AtomButton(
                    props: ButtonProps(style: "prominent", disabled: roots.isEmpty),
                    common: AtomCommon(testID: "save-workspace-roots-button", help: "Save working folders"),
                    action: {
                        onSave(roots)
                        dismiss()
                    }
                ) {
                    AtomText(props: TextProps(text: "Save folders"))
                }
            }
        }
    }
}
