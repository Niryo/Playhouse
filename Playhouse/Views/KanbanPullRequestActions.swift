import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

extension KanbanBoardView {
    package func moveTask(
        id: UUID,
        to status: TaskStatus,
        allowUnmergedPullRequests: Bool = false,
        allowDiscardingUncommittedChanges: Bool = false,
        skipMergeVerification: Bool = false
    ) {
        guard let task = tasks.first(where: { $0.id == id }), task.status != status else { return }
        if status == .review {
            guard TaskStatus.manualReviewSources.contains(task.status) else { return }
            Task { @MainActor in
                do {
                    _ = try await remoteConversations.moveTaskToReview(taskID: id)
                } catch {
                    reviewMoveError = error.localizedDescription
                }
            }
            return
        }
        guard status == .done else { return }
        Task { @MainActor in
            do {
                _ = try await BoardTaskManager(modelContext: modelContext).move(
                    id,
                    to: status.rawValue,
                    allowUnmergedPullRequests: allowUnmergedPullRequests,
                    allowDiscardingUncommittedChanges: allowDiscardingUncommittedChanges,
                    skipMergeVerification: skipMergeVerification
                )
            } catch PlayhouseManagerError.unmergedPullRequests {
                taskAwaitingUnmergedConfirmation = id
            } catch let error as PlayhouseManagerError {
                if case .uncommittedChanges = error {
                    discardConfirmationMessage = error.localizedDescription
                    taskAwaitingDiscardConfirmation = id
                } else {
                    doneMoveError = error.localizedDescription
                }
            } catch {
                doneMoveError = error.localizedDescription
            }
        }
    }

    package func createPullRequests(for task: BoardTask) {
        guard taskCreatingPullRequests.insert(task.id).inserted else { return }
        Task { @MainActor in
            defer { taskCreatingPullRequests.remove(task.id) }
            do {
                _ = try await remoteConversations.createPullRequests(taskID: task.id)
            } catch {
                pullRequestError = error.localizedDescription
            }
        }
    }
}
