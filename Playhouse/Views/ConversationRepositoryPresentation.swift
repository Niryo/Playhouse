import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

extension TaskConversationView {
    package func updateWorkspaceRoots(_ roots: [URL]) {
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

    package func saveConversationRepository(_ original: RepositoryWorktreeRecord, field: String) {
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
    package func resolveRepositoryDefaults(_ repository: RepositoryWorktreeRecord) {
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
    package func currentRepositoryRecord(_ repository: RepositoryWorktreeRecord) -> RepositoryWorktreeRecord {
        task.repositoryWorktrees.first { $0.isSameWorktree(as: repository) } ?? repository
    }

    package func resetRepositoryEdits(to repository: RepositoryWorktreeRecord) {
        let current = currentRepositoryRecord(repository)
        editedBranch = current.branch
        editedBranchFrom = current.branchFrom
        editedMergeTarget = current.mergeTarget ?? ""
    }

    package func beginRepositoryFieldEdit(_ field: String, repository: RepositoryWorktreeRecord) {
        // Only one field is edited at a time; switching fields drops the unsaved one.
        resetRepositoryEdits(to: repository)
        editingRepositoryField = field
        DispatchQueue.main.async { focusedRepositoryField = field }
    }

    package func cancelRepositoryFieldEdit(_ repository: RepositoryWorktreeRecord) {
        guard editingRepositoryField != nil else { return }
        resetRepositoryEdits(to: repository)
        editingRepositoryField = nil
        focusedRepositoryField = nil
    }

    /// The worktree's pull request, as the task last recorded it, linking to GitHub.
    package func repositoryPullRequestRow(_ repository: RepositoryWorktreeRecord, number: Int) -> some PHView {
        let state = repository.isPullRequestMerged ? "merged" : repository.isPullRequestClosed ? "closed" : "open"
        let text = "#\(number) · \(state)"
        let testID = "conversation-repository-pull-request"
        return AtomStack(props: StackProps(axis: "h", spacing: 12), common: AtomCommon(minHeight: 34)) {
            repositoryRowTitle("Pull request")
            if let url = repository.pullRequestURL, URL(string: url) != nil {
                // A link draws its title in the accent color, as a native link does.
                AtomLink(
                    props: LinkProps(url: url),
                    common: AtomCommon(testID: testID, label: text, value: state, help: "Open pull request #\(number) on GitHub")
                ) {
                    AtomText(props: TextProps(text: text, size: 13, weight: "medium", color: "accent", lineLimit: 1))
                }
            } else {
                AtomText(
                    props: TextProps(text: text, size: 13, weight: "medium", lineLimit: 1),
                    common: AtomCommon(testID: testID, label: text, value: state)
                )
            }
            AtomSpacer(props: SpacerProps(minLength: 0))
        }
    }

    /// A settings row's title, in a fixed-width leading column.
    private func repositoryRowTitle(_ title: String) -> some PHView {
        AtomText(
            props: TextProps(text: title, size: 13, color: "secondary"),
            common: AtomCommon(width: 96, frameAlign: "leading", passThrough: true)
        )
    }

    @PHViewBuilder
    package func repositoryDetailRow(
        _ title: String,
        value: PHBinding<String>,
        field: String,
        placeholder: String,
        identifier: String,
        repository: RepositoryWorktreeRecord
    ) -> some PHView {
        let editable = repository.isPending
        AtomStack(props: StackProps(axis: "h", spacing: 12), common: AtomCommon(minHeight: 34)) {
            repositoryRowTitle(title)
            if editable, editingRepositoryField == field {
                AtomOverlay(props: OverlayProps(align: "trailing")) {
                    AtomStack(
                        props: StackProps(fill: "primary", fillOpacity: 0.06, cornerRadius: 7, stroke: "accent", strokeOpacity: 0.8, strokeWidth: 1.5),
                        common: AtomCommon(paddingY: 6, paddingLeading: 9, paddingTrailing: 34)
                    ) {
                        // It takes the keyboard as it appears: the pencil opens it to type in.
                        AtomTextField(
                            props: TextFieldProps(text: value.wrappedValue, placeholder: placeholder, autoFocus: true, style: "plain", size: 13, focusRequest: 1),
                            common: AtomCommon(testID: identifier),
                            onChange: { value.wrappedValue = $0 },
                            onSubmit: { saveConversationRepository(repository, field: field) },
                            onEscape: { cancelRepositoryFieldEdit(repository) }
                        )
                    }
                } overlay: {
                    AtomStack(common: AtomCommon(paddingTrailing: 5)) {
                        AtomButton(
                            common: AtomCommon(testID: "\(identifier)-save", label: "Save \(title)", help: "Save \(title)"),
                            action: { saveConversationRepository(repository, field: field) }
                        ) {
                            AtomStack(props: StackProps(fill: "accent", capsule: true), common: AtomCommon(width: 22, height: 22)) {
                                AtomIcon(props: IconProps(name: PHIcon.checkmark.name, size: 11, weight: "bold", color: "white"))
                            }
                        }
                    }
                }
            } else {
                let displayValue = value.wrappedValue.isEmpty ? placeholder : value.wrappedValue
                AtomStack(props: StackProps(axis: "h", spacing: 3), common: AtomCommon(paddingY: 6)) {
                    AtomText(
                        props: TextProps(text: displayValue, size: 13, weight: "medium", lineLimit: 1, truncation: "middle"),
                        common: AtomCommon(testID: "\(identifier)-value", label: displayValue, passThrough: true)
                    )
                    if editable {
                        AtomButton(
                            common: AtomCommon(testID: "\(identifier)-edit", label: "Edit \(title)", help: "Edit \(title)"),
                            action: { beginRepositoryFieldEdit(field, repository: repository) }
                        ) {
                            AtomStack(common: AtomCommon(width: 22, height: 24)) {
                                AtomIcon(
                                    props: IconProps(asset: "EditPencil", color: "secondary"),
                                    common: AtomCommon(width: 14, height: 14)
                                )
                            }
                        }
                    }
                }
                AtomSpacer(props: SpacerProps(minLength: 0))
            }
        }
    }

    /// The chip settings' Add worktree: another worktree of the same repository on its
    /// own branch (the typed one, or one named from the task title).
    package func addConversationWorktree(_ repository: RepositoryWorktreeRecord) {
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

    package func removeConversationRepository(_ repository: RepositoryWorktreeRecord) {
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
