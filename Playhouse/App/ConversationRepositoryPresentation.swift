import AppKit
import SwiftData
import SwiftUI

extension TaskConversationView {
    func updateWorkspaceRoots(_ roots: [URL]) {
        Task { @MainActor in
            do {
                _ = try await WorkspaceManager(taskManager: BoardTaskManager(modelContext: modelContext))
                    .setRoots(roots.map { $0.standardizedFileURL.path }, for: task.id)
                await refreshWorkspaceChanges()
            } catch {
                errorMessage = "Couldn't save working folders: \(error.localizedDescription)"
            }
        }
    }

    func saveConversationRepository(_ original: RepositoryWorktreeRecord, field: String) {
        let branch = editedBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        var branchFrom = editedBranchFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        var mergeTarget = editedMergeTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        // A field saved before the chip worked its defaults out waits for them below.
        let awaitsDefaults = currentRepositoryRecord(original).hasUndecidedDefaults
        guard !branch.isEmpty, !branchFrom.isEmpty || awaitsDefaults else {
            errorMessage = "Branch and merge-from values can't be empty."
            return
        }
        Task { @MainActor in
            do {
                if awaitsDefaults {
                    let saved = try await BoardTaskManager(modelContext: modelContext)
                        .resolveRepositoryDefaults(task.id, worktree: .record(currentRepositoryRecord(original)))
                    let resolved = saved.repositoryWorktrees.first { $0.isSameWorktree(as: original) }
                    if branchFrom.isEmpty { branchFrom = resolved?.branchFrom ?? "" }
                    if mergeTarget.isEmpty { mergeTarget = resolved?.mergeTarget ?? "" }
                }
                let current = currentRepositoryRecord(original)
                let index = task.repositoryWorktrees.firstIndex { $0.isSameWorktree(as: current) }
                let saved = try await BoardTaskManager(modelContext: modelContext).updateRepository(
                    task.id,
                    worktree: .record(current),
                    branch: branch,
                    branchFrom: branchFrom,
                    mergeTarget: mergeTarget.isEmpty ? nil : mergeTarget
                )
                // The popover stays open on the saved value so another field can be edited next.
                if editingRepositoryField == field {
                    editingRepositoryField = nil
                    // Show what was saved, which can differ from what was typed: a branch-from
                    // found only on the remote is saved as its remote-tracking branch.
                    if let index, saved.repositoryWorktrees.indices.contains(index) {
                        let record = saved.repositoryWorktrees[index]
                        editedBranch = record.branch
                        editedBranchFrom = record.branchFrom
                        editedMergeTarget = record.mergeTarget ?? ""
                    }
                }
                errorMessage = nil
            } catch {
                errorMessage = "Couldn't save repository settings: \(error.localizedDescription)"
            }
        }
    }

    /// A pending repository added without branch settings works them out when its settings
    /// open, rather than when it was added; the popover then shows them.
    func resolveRepositoryDefaults(_ repository: RepositoryWorktreeRecord) {
        guard repository.hasUndecidedDefaults, !isReadOnly else { return }
        Task { @MainActor in
            do {
                _ = try await BoardTaskManager(modelContext: modelContext)
                    .resolveRepositoryDefaults(task.id, worktree: .record(repository))
                // A field the user began editing meanwhile keeps what they typed.
                guard repositoryBeingEdited?.isSameWorktree(as: repository) == true else { return }
                let current = currentRepositoryRecord(repository)
                if editingRepositoryField != "from" { editedBranchFrom = current.branchFrom }
                if editingRepositoryField != "to" { editedMergeTarget = current.mergeTarget ?? "" }
            } catch {
                errorMessage = "Couldn't read the repository's default branches: \(error.localizedDescription)"
            }
        }
    }

    /// The stored settings for a repository, read fresh so an edit starts from what is saved.
    func currentRepositoryRecord(_ repository: RepositoryWorktreeRecord) -> RepositoryWorktreeRecord {
        task.repositoryWorktrees.first { $0.isSameWorktree(as: repository) } ?? repository
    }

    func resetRepositoryEdits(to repository: RepositoryWorktreeRecord) {
        let current = currentRepositoryRecord(repository)
        editedBranch = current.branch
        editedBranchFrom = current.branchFrom
        editedMergeTarget = current.mergeTarget ?? ""
    }

    func beginRepositoryFieldEdit(_ field: String, repository: RepositoryWorktreeRecord) {
        // Only one field is edited at a time; switching fields drops the unsaved one.
        resetRepositoryEdits(to: repository)
        editingRepositoryField = field
        DispatchQueue.main.async { focusedRepositoryField = field }
    }

    func cancelRepositoryFieldEdit(_ repository: RepositoryWorktreeRecord) {
        guard editingRepositoryField != nil else { return }
        resetRepositoryEdits(to: repository)
        editingRepositoryField = nil
        focusedRepositoryField = nil
    }

    /// The worktree's pull request, as the task last recorded it, linking to GitHub.
    func repositoryPullRequestRow(_ repository: RepositoryWorktreeRecord, number: Int) -> some View {
        let state = repository.isPullRequestMerged ? "merged" : repository.isPullRequestClosed ? "closed" : "open"
        let text = "#\(number) · \(state)"
        return HStack(spacing: 12) {
            Text("Pull request").foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                .allowsHitTesting(false)
            Group {
                if let url = repository.pullRequestURL.flatMap(URL.init(string:)) {
                    Link(text, destination: url)
                        .buttonHoverPointer()
                        .nativeHelp("Open pull request #\(number) on GitHub")
                } else {
                    Text(text)
                }
            }
            .fontWeight(.medium)
            .lineLimit(1)
            .accessibilityLabel(text)
            .accessibilityValue(state)
            .accessibilityIdentifier("conversation-repository-pull-request")
            Spacer(minLength: 0)
        }
        .frame(minHeight: 34)
    }

    @ViewBuilder
    func repositoryDetailRow(
        _ title: String,
        value: Binding<String>,
        field: String,
        placeholder: String,
        identifier: String,
        repository: RepositoryWorktreeRecord
    ) -> some View {
        let editable = repository.isPending
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                .allowsHitTesting(false)
            if editable, editingRepositoryField == field {
                TextField(placeholder, text: value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focusedRepositoryField, equals: field)
                    .onSubmit { saveConversationRepository(repository, field: field) }
                    .onKeyPress(.escape) {
                        cancelRepositoryFieldEdit(repository)
                        return .handled
                    }
                    .accessibilityIdentifier(identifier)
                    .padding(.leading, 9).padding(.trailing, 34).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5))
                    .overlay(alignment: .trailing) {
                        Button { saveConversationRepository(repository, field: field) } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Color.accentColor, in: Circle())
                                .contentShape(Circle())
                        }
                        .buttonHoverPointer()
                        .buttonStyle(.plain)
                        .nativeHelp("Save \(title)")
                        .accessibilityLabel("Save \(title)")
                        .accessibilityIdentifier("\(identifier)-save")
                        .padding(.trailing, 5)
                    }
            } else {
                let displayValue = value.wrappedValue.isEmpty ? placeholder : value.wrappedValue
                HStack(spacing: 3) {
                    Text(displayValue)
                        .fontWeight(.medium)
                        .lineLimit(1).truncationMode(.middle)
                        .allowsHitTesting(false)
                        .accessibilityLabel(displayValue)
                        .accessibilityIdentifier("\(identifier)-value")
                    if editable {
                        Button {
                            beginRepositoryFieldEdit(field, repository: repository)
                        } label: {
                            EditPencilShape()
                                .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                                .foregroundStyle(.secondary)
                                .frame(width: 14, height: 14)
                                .frame(width: 22, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonHoverPointer()
                        .buttonStyle(.plain).nativeHelp("Edit \(title)").accessibilityLabel("Edit \(title)")
                        .accessibilityIdentifier("\(identifier)-edit")
                    }
                }
                .padding(.vertical, 6)
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: 34)
    }

    /// The chip settings' Add worktree: another worktree of the same repository on its
    /// own branch (the typed one, or one named from the task title).
    func addConversationWorktree(_ repository: RepositoryWorktreeRecord) {
        guard !isAddingWorktree else { return }
        isAddingWorktree = true
        let branch = newWorktreeBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            defer { isAddingWorktree = false }
            do {
                _ = try await WorkspaceManager(
                    taskManager: BoardTaskManager(modelContext: modelContext)
                ).addWorktree(repository.repositoryPath, to: task.id, branch: branch.isEmpty ? nil : branch)
                newWorktreeBranch = ""
                repositoryBeingEdited = nil
                errorMessage = nil
                await refreshWorkspaceChanges()
            } catch {
                errorMessage = "Couldn't add a worktree: \(error.localizedDescription)"
            }
        }
    }

    func removeConversationRepository(_ repository: RepositoryWorktreeRecord) {
        Task { @MainActor in
            let edited = repositoryBeingEdited
            do {
                _ = try await WorkspaceManager(
                    taskManager: BoardTaskManager(modelContext: modelContext)
                ).removeRepository(.record(repository), from: task.id)
                // A pending chip's key is its position, so removing an earlier sibling moves
                // the key onto another record: the open editor closes rather than follow it.
                if let edited, edited.isSameWorktree(as: repository) || repositoryBeingEdited?.isSameWorktree(as: edited) != true {
                    repositoryBeingEditedKey = nil
                }
                errorMessage = nil
                loadRecentRepositories()
                await refreshWorkspaceChanges()
            } catch {
                errorMessage = "Couldn't remove repository: \(error.localizedDescription)"
            }
        }
    }
}
