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
        let branchFrom = editedBranchFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let mergeTarget = editedMergeTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty, !branchFrom.isEmpty else {
            errorMessage = "Branch and merge-from values can't be empty."
            return
        }
        Task { @MainActor in
            do {
                let saved = try await BoardTaskManager(modelContext: modelContext).updateRepository(
                    task.id,
                    repositoryPath: original.repositoryPath,
                    branch: branch,
                    branchFrom: branchFrom,
                    mergeTarget: mergeTarget.isEmpty ? nil : mergeTarget
                )
                // The popover stays open on the saved value so another field can be edited next.
                if editingRepositoryField == field {
                    editingRepositoryField = nil
                    // Show what was saved, which can differ from what was typed: a branch-from
                    // found only on the remote is saved as its remote-tracking branch.
                    if let record = saved.repositoryWorktrees.first(where: { $0.repositoryPath == original.repositoryPath }) {
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

    /// The stored settings for a repository, read fresh so an edit starts from what is saved.
    func currentRepositoryRecord(_ repository: RepositoryWorktreeRecord) -> RepositoryWorktreeRecord {
        task.repositoryWorktrees.first { $0.repositoryPath == repository.repositoryPath } ?? repository
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

    func removeConversationRepository(_ repository: RepositoryWorktreeRecord) {
        Task { @MainActor in
            do {
                _ = try await WorkspaceManager(
                    taskManager: BoardTaskManager(modelContext: modelContext)
                ).removeRepository(repository.repositoryPath, from: task.id)
                if repositoryBeingEdited?.repositoryPath == repository.repositoryPath { repositoryBeingEdited = nil }
                errorMessage = nil
                loadRecentRepositories()
                await refreshWorkspaceChanges()
            } catch {
                errorMessage = "Couldn't remove repository: \(error.localizedDescription)"
            }
        }
    }
}
