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

    func scrollToLatest(using proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        guard !messages.isEmpty || !activities.isEmpty || activeGoal?.status == "complete" else { return }
        // A load in progress owns the scroll position: following the bottom now
        // would scroll past the question the transcript is about to pin.
        if isLatestConversationTurnPinPending {
            presentLatestConversationTurn(using: proxy)
            return
        }
        // While the newest turn still fits the viewport, keep its question
        // pinned to the top instead of following the bottom into the filler
        // that makes that pin reachable.
        if let turnStartID = latestConversationTurnStartID,
           oldestRenderedMessageID == turnStartID,
           latestTurnContentHeight > 0,
           latestTurnContentHeight + 2 * Self.conversationVerticalPadding <= viewportHeight {
            presentLatestConversationTurn(using: proxy)
            return
        }
        // A reader who is not following lands on the latest message itself, so the
        // filler below a short turn never opens as blank space under the chat.
        // Defer until the state-driven content update has had a layout pass.
        let shouldAnimate = hasPresentedLatestConversation
        Task { @MainActor in
            await Task.yield()
            // Record the question this presentation lands on, so a newly sent
            // one is told apart from the one already in view.
            lastScrolledUserMessageID = renderedConversationMessages.last(where: { $0.role == .user && !$0.isPlayhouseSent })?.id
            // Each scroll reads its target when it runs: a reply can stream several messages
            // in before the settle scroll, and a target taken earlier would pull the viewport
            // back up to an older message, which ends following as a reader scrolling up does.
            let scroll = {
                if lastConversationScrollSample.isFollowingLatest {
                    // Following already holds the bottom; its target is the very end, which
                    // never lies above where following left the viewport.
                    proxy.scrollTo(Self.conversationScrollEndID, anchor: .bottom)
                } else if let latestMessageID = renderedConversationMessages.last?.id, userInputRequest == nil {
                    proxy.scrollTo(latestMessageID, anchor: .bottom)
                } else {
                    // A pending question renders below the latest message.
                    proxy.scrollTo("conversation-latest-anchor", anchor: .bottom)
                }
            }
            if shouldAnimate {
                withAnimation(.easeOut(duration: 0.2), scroll)
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction, scroll)
            }
            // Rows that render in this pass, such as settled rows measured for the
            // first time, can still change the content's height after the first
            // scroll; scrolling again once they have laid out lands on the real end.
            var settleTransaction = Transaction()
            settleTransaction.disablesAnimations = true
            for delay in Self.scrollSettleDelays {
                try? await Task.sleep(nanoseconds: delay)
                withTransaction(settleTransaction, scroll)
            }
            hasPresentedLatestConversation = true
        }
    }

    /// After the conversation is already settled, a newly sent question should land at the
    /// top of the viewport while its answer streams in below. The filler makes that pin the
    /// bottom of the transcript, so once the answer outgrows the viewport, following the
    /// bottom carries the reader along with it unless they have scrolled up.
    func scrollToLatestUserMessage(using proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        guard hasPresentedLatestConversation else {
            scrollToLatest(using: proxy, viewportHeight: viewportHeight)
            return
        }
        guard let latestUserMessage = renderedConversationMessages.last(where: { $0.role == .user && !$0.isPlayhouseSent }),
              latestUserMessage.id != lastScrolledUserMessageID else { return }
        lastScrolledUserMessageID = latestUserMessage.id
        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeOut(duration: 0.2)) {
                // A question form that arrived with this turn renders below it and must stay
                // reachable, Submit included, so it wins over pinning the question to the top.
                if let request = userInputRequest, request.threadID == task.activeConversationID {
                    proxy.scrollTo("conversation-latest-anchor", anchor: .bottom)
                } else {
                    proxy.scrollTo(latestUserMessage.id, anchor: .top)
                }
            }
        }
    }
}
