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
        PHVStack(alignment: .leading, spacing: 16) {
            PHText("Edit working folders")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
            PHText("Changes apply to the next Codex turn. The first folder is used as the working directory.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            WorkspaceRootSelector(
                parentFolderURL: parentFolderURL,
                roots: $roots,
                displayNames: Dictionary(uniqueKeysWithValues: repositoryWorktrees.map {
                    ($0.worktreePath, "\(URL(fileURLWithPath: $0.repositoryPath).lastPathComponent) · \($0.branch)")
                })
            )
            PHLabel("Codex has full machine and network access; this list sets task context only.", icon: .exclamationmarkTriangleFill)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            PHHStack {
                PHSpacer()
                PHButton("Cancel") { dismiss() }
                    .buttonHoverPointer()
                    .shortcutHelp("Cancel folder changes", shortcut: "cancel")
                PHButton("Save folders") {
                    onSave(roots)
                    dismiss()
                }
                .buttonHoverPointer()
                .nativeHelp("Save working folders")
                .buttonStyle(.borderedProminent)
                .disabled(roots.isEmpty)
                .accessibilityIdentifier("save-workspace-roots-button")
            }
        }
        .padding(24)
        .frame(width: 560, height: 620)
    }
}
