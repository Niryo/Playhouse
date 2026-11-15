import Foundation
import AppKit
import SwiftData
import Darwin
import SQLite3

extension ConversationManager {
    func standaloneChatDisplayHistory(taskID: UUID, _ history: ConversationHistory) -> ConversationHistory {
        guard (try? tasks.conversationSubject(taskID))?.isStandaloneChat == true else { return history }
        let restored = standaloneChatMessagesRestoringEarlierPages(taskID: taskID, history.messages)
        guard restored.count != history.messages.count else { return history }
        return ConversationHistory(
            messages: restored,
            activities: history.activities,
            timelineActivities: history.timelineActivities,
            diff: history.diff,
            answeredAsyncQuestionIDs: history.answeredAsyncQuestionIDs,
            pendingUserInputRequest: history.pendingUserInputRequest,
            providerBoundaries: history.providerBoundaries
        )
    }

    /// Names a one-time scheduled task that still has a placeholder title from its scheduled
    /// prompt, as its first send would, so it doesn't wait on the board untitled. The title is
    /// reserved before this returns; the name is generated in the background and falls back to
    /// the prompt's first words. Returns the reserved task, or nil when nothing needs a name.
    func nameScheduledTask(_ taskID: UUID) async throws -> BoardTaskRecord? {
        let task = try tasks.taskModel(taskID)
        guard task.scheduleKind == .once, ["Untitled task", "Generating title…"].contains(task.title),
              let prompt = task.scheduledPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty,
              let reserved = try await tasks.renameIfTitleMatches(taskID, expectedTitle: task.title, title: "Generating title…")
        else { return nil }
        // A task with no repository yet still gets a name; the title turn needs no workspace.
        let roots = task.workspaceRootPaths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let workspace = try (try? ConversationWorkspaceContext(roots: roots)) ?? ConversationWorkspaceContext(roots: [])
        let titleClients = clients.helperClients(preferring: task.conversationProvider)
        // Registered work keeps the daemon alive after the request that scheduled it returns.
        BridgeBackgroundWork.start {
            // Best-effort like a send's title: the helper records failures and falls back.
            _ = try? await self.generateAndApplyTitle(taskID: taskID, prompt: prompt, workspace: workspace, clients: titleClients)
        }
        return reserved
    }

    func generateAndApplyTitle(
        taskID: UUID,
        prompt: String,
        workspace: ConversationWorkspaceContext,
        clients titleClients: [ConversationProviderClient]
    ) async throws -> String {
        let result = await ConversationTitleGenerator(clients: titleClients)
            .generateTitle(from: prompt, workspace: workspace, taskID: taskID)
        let generated = result?.title
        let fallback = prompt.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        let resolvedTitle = generated.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        let titleSource = result?.provider.rawValue ?? "prompt-fallback"
        let latest: any ConversationSubject
        do {
            latest = try tasks.conversationSubject(taskID)
        } catch {
            var fields = PlayhouseDiagnostics.errorFields(error)
            fields["taskID"] = taskID.uuidString
            fields["titleSource"] = titleSource
            PlayhouseDiagnostics.record("task.title_apply.skipped", fields: fields.merging(["reason": "task_unavailable"]) { _, new in new })
            return fallback
        }
        guard latest.title == "Generating title…" else {
            PlayhouseDiagnostics.record("task.title_apply.skipped", fields: [
                "taskID": taskID.uuidString,
                "reason": "title_changed",
                "currentTitleState": PlayhouseTaskTitleDiagnostics.state(of: latest.title),
                "titleSource": titleSource
            ])
            return ["Generating title…", "Untitled task"].contains(latest.title)
                ? resolvedTitle
                : latest.title
        }
        do {
            guard try await tasks.renameIfTitleMatches(
                taskID,
                expectedTitle: "Generating title…",
                title: resolvedTitle
            ) != nil else {
                let currentTitle = (try? tasks.conversationSubject(taskID).title) ?? ""
                PlayhouseDiagnostics.record("task.title_apply.skipped", fields: [
                    "taskID": taskID.uuidString,
                    "reason": "title_changed",
                    "currentTitleState": PlayhouseTaskTitleDiagnostics.state(of: currentTitle),
                    "titleSource": titleSource
                ])
                return currentTitle
            }
            PlayhouseDiagnostics.record("task.title_apply.succeeded", fields: [
                "taskID": taskID.uuidString,
                "titleSource": titleSource,
                "fallbackWordCount": generated == nil ? String(fallback.split(whereSeparator: \.isWhitespace).count) : "0"
            ])
            return resolvedTitle
        } catch {
            var fields = PlayhouseDiagnostics.errorFields(error, redacting: [resolvedTitle, prompt])
            fields["taskID"] = taskID.uuidString
            fields["titleSource"] = titleSource
            PlayhouseDiagnostics.record("task.title_apply.failed", fields: fields)
            guard generated != nil else { throw error }

            // A generated title is optional; recover with the deterministic prompt
            // fallback before any auto-named worktree can be allocated.
            do {
                guard try await tasks.renameIfTitleMatches(
                    taskID,
                    expectedTitle: "Generating title…",
                    title: fallback
                ) != nil else {
                    let currentTitle = (try? tasks.conversationSubject(taskID).title) ?? ""
                    PlayhouseDiagnostics.record("task.title_apply.skipped", fields: [
                        "taskID": taskID.uuidString,
                        "reason": "title_changed",
                        "currentTitleState": PlayhouseTaskTitleDiagnostics.state(of: currentTitle),
                        "titleSource": "prompt-fallback"
                    ])
                    return currentTitle
                }
                PlayhouseDiagnostics.record("task.title_apply.succeeded", fields: [
                    "taskID": taskID.uuidString,
                    "titleSource": "prompt-fallback",
                    "fallbackWordCount": String(fallback.split(whereSeparator: \.isWhitespace).count)
                ])
                return fallback
            } catch {
                var recoveryFields = PlayhouseDiagnostics.errorFields(error, redacting: [fallback, prompt])
                recoveryFields["taskID"] = taskID.uuidString
                recoveryFields["titleSource"] = "prompt-fallback"
                recoveryFields["recoveryAttempt"] = "true"
                PlayhouseDiagnostics.record("task.title_apply.failed", fields: recoveryFields)
                throw error
            }
        }
    }

    static let privateRecoveryPromptMarker = "Continue this conversation by applying the user's answer to the pending question"
    static let privateOutcomeReminderMarker = PrivateOutcomeNudgeMarker.current
    static let privateOutcomeReminderPlaceholder = PrivatePromptPlaceholder.outcomeReminder
    static let privateOutcomeReminderResponsePlaceholder = "[Playhouse private outcome response hidden]"

    /// Sent when a turn ended without reporting any outcome: ask where the work
    /// stands rather than assuming it is finished or blocked on the user.
    static func outcomeNudgePrompt(attempt: Int) -> String {
        """
        \(privateOutcomeReminderMarker)

        Your previous turn ended without reporting a task outcome, so Playhouse doesn't know where this task stands. Don't repeat or redo finished work — just report the current status with the task outcome command: `in-progress` if work remains and you need nothing from the user (keep working right away in this turn), `waiting-response` if you need the user to answer or decide, `completed` if everything is done. This is nudge \(attempt) of \(TurnOutcome.maxContinuations); after that Playhouse marks the task Blocked.
        """
    }

    /// Sent once when a standalone chat turn ended without its close-turn page signal. It is
    /// shown as an automatic message, and its turn is never filed into a chat page.
    static func chatPageCloseTurnNudgePrompt(chatID: UUID) -> String {
        """
        \(privateOutcomeReminderMarker)

        Your previous reply didn't run `chat page close-turn \(chatID.uuidString)`, so Playhouse couldn't file it under a chat page. Run it now for that reply, with `--continues true` unless that reply started a new, unrelated topic (then `--continues false --new-title "<short title>"`). Don't repeat or redo the previous reply; after the command, say at most one short line. This is the only reminder for that reply.
        """
    }

    /// Probes an autopilot task's pull requests in Review and, when they're red
    /// (failing checks, conflicts, or unresolved review threads), sends the task's
    /// provider a visible fix turn through the normal send path. The loop stops on
    /// green, on merge, when the model reports `waiting-response`, or when
    /// `claimPullRequestAutopilotFix` finds nothing changed since the last attempt.
    func runPullRequestAutopilot(
        taskID: UUID,
        onStatus: @escaping ([PullRequestReviewState]) -> Void = { _ in }
    ) async throws -> PullRequestAutopilotOutcome {
        let task = try tasks.taskModel(taskID)
        func outcome(_ action: String, _ states: [PullRequestReviewState] = [], reason: String? = nil) throws -> PullRequestAutopilotOutcome {
            PullRequestAutopilotOutcome(action: action, states: states, taskStatus: try tasks.taskModel(taskID).status.rawValue, reason: reason)
        }
        guard task.pullRequestAutopilot else { return try outcome("inactive", reason: "Autopilot is off for this task.") }
        guard task.status == .review else { return try outcome("inactive", reason: "Autopilot acts only on tasks in Review.") }
        guard task.repositoryWorktrees.contains(where: { !$0.isPending && $0.pullRequestNumber != nil }) else {
            return try outcome("inactive", reason: "This task has no linked pull request yet.")
        }
        guard Self.autopilotRunningTaskIDs.insert(taskID).inserted else {
            return try outcome("inactive", reason: "Autopilot is already handling this task.")
        }
        defer { Self.autopilotRunningTaskIDs.remove(taskID) }
        guard try !tasks.hasConversationTurnReservation(taskID) else {
            return try outcome("inactive", reason: "A conversation turn is running for this task.")
        }
        let states = try await tasks.reviewPullRequests(task)
        onStatus(states)
        switch BoardTaskManager.assessPullRequestAutopilot(states) {
        case .merged:
            return try outcome("merged", states)
        case .green:
            try await tasks.resetPullRequestAutopilotAttempts(taskID)
            guard task.pullRequestAutoMerge else { return try outcome("green", states) }
            // A head with no checks yet is still pending inside the registration grace,
            // so `.none` here is a repository without CI: it merges on mergeability alone.
            // GitHub may still be computing mergeability; merge once it says MERGEABLE.
            guard states.filter({ !$0.merged }).allSatisfy({ $0.mergeable == "MERGEABLE" }) else {
                return try outcome("pending", states)
            }
            switch try await tasks.mergeGreenPullRequests(taskID, states: states) {
            case .skipped:
                return try outcome("inactive", states, reason: "The task left Review, a turn started, or merge mode was turned off.")
            case .refused(let reason):
                return try outcome("stalled", states, reason: reason)
            case .merged(let numbers):
                var result = try outcome("merged", try await tasks.reviewPullRequests(try tasks.taskModel(taskID)))
                result.mergedPullRequests = numbers
                return result
            }
        case .pending:
            return try outcome("pending", states)
        case .needsFix:
            let current = try tasks.taskModel(taskID)
            guard current.status == .review, current.pullRequestAutopilot else {
                return try outcome("inactive", states, reason: "The task left Review or autopilot was turned off.")
            }
            let signature = BoardTaskManager.pullRequestAutopilotSignature(states)
            switch try await tasks.claimPullRequestAutopilotFix(taskID, signature: signature) {
            case .stalled(let reason):
                return try outcome("stalled", states, reason: reason)
            case .fix:
                PlayhouseDiagnostics.record("task.pr.autopilot.fix.started", fields: [
                    "taskID": taskID.uuidString, "provider": current.conversationProvider.rawValue
                ])
                var turnStarted = false
                do {
                    _ = try await send(
                        taskID: taskID,
                        text: Self.pullRequestAutopilotPrompt(states),
                        onTurnStarting: { turnStarted = true },
                        historyMessageLimit: 1
                    )
                } catch {
                    if !turnStarted { try? await tasks.releasePullRequestAutopilotFix(taskID, signature: signature) }
                    throw error
                }
                return try outcome("fixed", states)
            }
        }
    }

    static var autopilotRunningTaskIDs = Set<UUID>()

    static let pullRequestAutopilotPromptMarker = PlayhouseSentMessage.pullRequestAutopilotMarker

    static func pullRequestAutopilotPrompt(_ states: [PullRequestReviewState]) -> String {
        let problems = states.filter { !$0.merged }.compactMap { state -> String? in
            var issues: [String] = []
            if state.checks == .failure {
                issues.append(state.failingChecks.isEmpty ? "failing checks" : "failing checks: \(state.failingChecks.joined(separator: ", "))")
            }
            if state.hasConflicts { issues.append("merge conflicts with its base branch") }
            if let threads = state.unresolvedReviewThreads, threads > 0 {
                issues.append("\(threads) unresolved review \(threads == 1 ? "thread" : "threads")")
            }
            guard !issues.isEmpty else { return nil }
            return "- Pull request #\(state.number) (\(state.repositoryPath)): \(issues.joined(separator: "; "))."
        }
        return """
        \(pullRequestAutopilotPromptMarker) this task's pull request isn't green yet. Please get it there.

        \(problems.joined(separator: "\n"))

        1. Read the details with the GitHub CLI from the task worktree: `gh pr checks <number>`, `gh run view <run-id> --log-failed` for failing runs, and the review threads through `gh api graphql` (`reviewThreads` with their comments).
        2. Fix genuine failures in the task worktree. For merge conflicts, merge the base branch and resolve them. Commit your work; Playhouse pushes the task branch when you report `completed`.
        3. Treat every unresolved review comment critically: reviewers and bots can be wrong, noisy, or out of scope. Change the code only for comments that really deserve it. For every thread, fixed or not, reply with what you changed or why you left the code as it is, then resolve the thread (GraphQL `addPullRequestReviewThreadReply` and `resolveReviewThread`).
        4. If something can't be fixed from here — for example GitHub or CI is down, a check needs credentials or permissions you don't have, or the user must act (such as adding a Jira ticket to the pull request title) — don't retry in a loop. Report `waiting-response` and tell the user exactly what is blocking the pull request and what they need to do. Otherwise report `completed` when you're done; Playhouse keeps watching the pull request and sends another turn if it is still red.
        """
    }

    /// Sent after an explicit `in-progress`: the model asked to keep going.
    static func outcomeContinuationPrompt(attempt: Int) -> String {
        """
        \(privateOutcomeReminderMarker)

        You reported `in-progress`, so continue the work from where your last turn left off. Don't repeat or redo finished work, and don't ask the user anything here. End this turn with a task outcome call: `in-progress` again if more work remains, `waiting-response` if you now need the user, `completed` when everything is done. This is continuation \(attempt) of \(TurnOutcome.maxContinuations); after that Playhouse marks the task Blocked.
        """
    }

    /// A status nudge, and the agent's reply to it, only mean something in the session they were sent to,
    /// so neither is replayed to another provider or into a fresh session. A message the user steered
    /// into a nudge turn is theirs and stays. A notice the provider's runtime added inside a turn is
    /// dropped the same way, while the rest of its turn stays.
    static func withoutNudgeTurns(_ messages: [ConversationMessage]) -> [ConversationMessage] {
        let nudgeTurnIDs = Set(messages.filter { $0.role == .user && PrivateOutcomeNudgeMarker.matches($0.text) }.compactMap(\.turnID))
        return messages.filter { message in
            if message.role == .user, ProviderAutomaticNotice.matches(message.text) { return false }
            guard let turnID = message.turnID, nudgeTurnIDs.contains(turnID) else { return true }
            return message.role == .user && !PrivateOutcomeNudgeMarker.matches(message.text)
        }
    }

    static func isPrivateTaskPrompt(_ text: String) -> Bool {
        text.contains(privateRecoveryPromptMarker) || isPrivateOutcomeReminderPrompt(text)
    }

    static func privatePromptPlaceholder(for text: String) -> String {
        isPrivateOutcomeReminderPrompt(text)
            ? privateOutcomeReminderPlaceholder
            : PrivatePromptPlaceholder.recoveryAnswer
    }

    /// Only transcripts written before nudges were shown still hold a nudge as the hidden-prompt
    /// placeholder; those turns stay hidden. A nudge sent today is stored and shown as sent.
    static func isPrivateOutcomeReminderPrompt(_ text: String) -> Bool {
        text.contains(privateOutcomeReminderPlaceholder)
    }

    static func redactingSensitiveText(_ text: String, values: [String]) -> String {
        values.filter { !$0.isEmpty }.sorted { $0.count > $1.count }.reduce(text) { result, value in
            result.replacingOccurrences(of: value, with: "[redacted secret answer]")
        }
    }

    static func sensitiveCodexTurnIDs(_ transcript: ConversationTranscript) -> Set<String> {
        let codexTurnIDs = Set(transcript.segments.filter { $0.provider == .codex }.flatMap(\.codexTurnIDs))
        return Set(transcript.sensitiveCodexTurnIDs ?? [])
            .union(Set(transcript.sensitiveTurnIDs ?? []).intersection(codexTurnIDs))
    }

    static func codexMessagesForDisplay(
        _ messages: [ConversationMessage],
        transcript: ConversationTranscript
    ) -> [ConversationMessage] {
        let privateTurnIDs = sensitiveCodexTurnIDs(transcript)
        let privateReminderTurnIDs = Set(messages.filter {
            $0.role == .user && isPrivateOutcomeReminderPrompt($0.text)
        }.compactMap(\.turnID))
        let safeMessagesByTurn = transcript.sensitiveCodexTurnMessages ?? [:]
        var emittedSafeTurnIDs = Set<String>()
        var visible: [ConversationMessage] = []
        for message in messages {
            var message = message
            message.createdAt = message.createdAt ?? transcript.messageTimestamps?[message.id]
            if message.turnID.map(privateReminderTurnIDs.contains) == true { continue }
            guard let turnID = message.turnID, privateTurnIDs.contains(turnID) else {
                visible.append(message)
                continue
            }
            if let safeMessages = safeMessagesByTurn[turnID] {
                if emittedSafeTurnIDs.insert(turnID).inserted {
                    visible.append(contentsOf: safeMessages)
                }
            } else {
                var placeholder = message
                placeholder.text = message.role == .user
                    ? privatePromptPlaceholder(for: message.text)
                    : (privateReminderTurnIDs.contains(turnID)
                        ? privateOutcomeReminderResponsePlaceholder
                        : "[Response to private answer hidden]")
                placeholder.asyncQuestions = nil
                visible.append(placeholder)
            }
        }
        return visible
    }

    static func shouldHideCodexDiff(_ transcript: ConversationTranscript, codex: ConversationHistory?) -> Bool {
        if transcript.pendingSensitiveUserInputRedaction == true { return true }
        let latestCodexTurnID = transcript.segments.last(where: { $0.provider == .codex })?.codexTurnIDs.last
            ?? codex?.messages.reversed().compactMap(\.turnID).first
        guard let latestCodexTurnID else {
            return !(transcript.sensitiveCodexTurnIDs ?? []).isEmpty
        }
        return sensitiveCodexTurnIDs(transcript).contains(latestCodexTurnID)
    }

    static func redactingSensitiveMessages(
        _ messages: [ConversationMessage],
        turnIDs: Set<String>,
        values: [String] = [],
        redactAllMessages: Bool = false
    ) -> [ConversationMessage] {
        let privateReminderTurnIDs = Set(messages.filter {
            $0.role == .user && isPrivateOutcomeReminderPrompt($0.text)
        }.compactMap(\.turnID))
        return messages.map { message in
            let matchesTurn = message.turnID.map(turnIDs.contains) ?? false
            let matchesValue = values.contains { !$0.isEmpty && message.text.contains($0) }
            var redacted = message
            if redactAllMessages || matchesTurn {
                redacted.text = message.role == .user
                    ? privatePromptPlaceholder(for: message.text)
                    : (message.turnID.map { privateReminderTurnIDs.contains($0) } == true
                        ? privateOutcomeReminderResponsePlaceholder
                        : "[Response to private answer hidden]")
                redacted.asyncQuestions = nil
            } else if matchesValue {
                redacted.text = Self.redactingSensitiveText(message.text, values: values)
            }
            if !redactAllMessages, !matchesTurn, let questions = message.asyncQuestions {
                redacted.asyncQuestions = questions.map { question in
                    ConversationAsyncQuestion(
                        title: Self.redactingSensitiveText(question.title, values: values),
                        options: question.options?.map { Self.redactingSensitiveText($0, values: values) }
                    )
                }
            }
            return redacted
        }
    }

    static func isValidModelID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-").contains($0)
        }
    }

    static func isValidImageDataURL(_ value: String) -> Bool {
        guard let separator = value.firstIndex(of: ",") else { return false }
        let mime = String(value[..<separator])
        guard let data = Data(base64Encoded: String(value[value.index(after: separator)...])), data.count <= 10_000_000 else { return false }
        let bytes = [UInt8](data.prefix(12))
        if mime == "data:image/png;base64" {
            return bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])
        }
        if mime == "data:image/jpeg;base64" {
            return bytes.starts(with: [255, 216, 255])
        }
        return false
    }
}
