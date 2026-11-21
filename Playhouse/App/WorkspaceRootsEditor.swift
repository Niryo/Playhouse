import SwiftUI

struct WorkspaceRootsEditor: View {
    @Environment(\.dismiss) private var dismiss
    let parentFolderURL: URL?
    let initialRoots: [URL]
    let repositoryWorktrees: [RepositoryWorktreeRecord]
    let onSave: ([URL]) -> Void
    @State private var roots: [URL]

    init(parentFolderURL: URL?, initialRoots: [URL], repositoryWorktrees: [RepositoryWorktreeRecord] = [], onSave: @escaping ([URL]) -> Void) {
        self.parentFolderURL = parentFolderURL
        self.initialRoots = initialRoots
        self.repositoryWorktrees = repositoryWorktrees
        self.onSave = onSave
        _roots = State(initialValue: initialRoots)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit working folders")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
            Text("Changes apply to the next Codex turn. The first folder is used as the working directory.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            WorkspaceRootSelector(
                parentFolderURL: parentFolderURL,
                roots: $roots,
                displayNames: Dictionary(uniqueKeysWithValues: repositoryWorktrees.map {
                    ($0.worktreePath, "\(URL(fileURLWithPath: $0.repositoryPath).lastPathComponent) · \($0.branch)")
                })
            )
            Label("Codex has full machine and network access; this list sets task context only.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonHoverPointer()
                    .shortcutHelp("Cancel folder changes", shortcut: "cancel")
                Button("Save folders") {
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
