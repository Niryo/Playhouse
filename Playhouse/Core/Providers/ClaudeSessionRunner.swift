import Foundation

@MainActor
package final class ClaudeSessionRunner {
    package typealias ClientError = ClaudeCodeClient.ClientError

    package struct PendingQuestion {
        package let controlRequestID: String
        package let sessionID: String
        package let input: [String: Any]
        package let questions: [ConversationUserQuestion]

        package init(controlRequestID: String, sessionID: String, input: [String: Any], questions: [ConversationUserQuestion]) {
            self.controlRequestID = controlRequestID
            self.sessionID = sessionID
            self.input = input
            self.questions = questions
        }
    }

    package struct TurnCompletion {
        package var resultReceived = false
        package var resultError: Error?
        /// Results Claude sent during this logical turn, including woken turns.
        package var resultCount = 0
        /// Provider turns Claude Code started to deliver a background task's
        /// notification. Each owes its own result, which can arrive after the
        /// earlier turn's result or before it.
        package var wokenTurnCount = 0
        /// A top-level background task finished and Claude Code has not yet
        /// delivered its notification to the parent, either in a new provider
        /// turn (`system init`) or in the running one's next request.
        package var awaitingParentWake = false
        /// Whether the `system init` of the provider turn Claude Code started
        /// for the pending wake has already been counted, so repeated `init`
        /// events for one wake can't owe several results. It also authorizes
        /// the wake backstop to give that count back: only a wake whose woken
        /// turn was counted here has a result to stop owing when it times out.
        package var countedWakeInit = false

        package init(resultReceived: Bool = false, resultError: Error? = nil, resultCount: Int = 0, wokenTurnCount: Int = 0, awaitingParentWake: Bool = false, countedWakeInit: Bool = false) {
            self.resultReceived = resultReceived
            self.resultError = resultError
            self.resultCount = resultCount
            self.wokenTurnCount = wokenTurnCount
            self.awaitingParentWake = awaitingParentWake
            self.countedWakeInit = countedWakeInit
        }
    }

    /// How long a settled turn waits for Claude Code to deliver a finished
    /// background task before treating the notification as already consumed.
    package nonisolated static let parentWakeGracePeriod: Duration = .seconds(15)

    /// Tests shorten both backstop grace periods so a case does not spend the
    /// product's wall clock waiting one out; what they check — which silence
    /// settles the turn and which one waits for Claude — does not depend on the
    /// lengths. Resolved per turn, inside the request that carries the
    /// environment, rather than read from the backstop's detached task.
    package nonisolated static func graceOverride(_ name: String, default fallback: Duration) -> Duration {
        guard let seconds = PlayhouseProcessEnvironment.current[name].flatMap(Double.init),
              seconds.isFinite, seconds > 0, seconds < 86_400 else { return fallback }
        return .milliseconds(Int(seconds * 1000))
    }

    /// How long a woken turn Claude Code announced with `system init` may stay
    /// silent before Playhouse stops waiting for the result it owes. It is far
    /// longer than `parentWakeGracePeriod` because this turn exists and may
    /// simply be slow to speak — time to first token, or a retry backoff the
    /// CLI never reports — and cutting a live turn off loses its notification,
    /// while a turn that is really stranded only has to end eventually.
    package nonisolated static let wokenTurnSilenceGracePeriod: Duration = .seconds(120)

    /// This turn's resolved grace periods, read once where the request's
    /// environment is in scope.
    package var wakeGrace: Duration = ClaudeSessionRunner.parentWakeGracePeriod
    package var wokenSilenceGrace: Duration = ClaudeSessionRunner.wokenTurnSilenceGracePeriod

    package let sessionID: String
    package let executable: String
    package let configDirectoryOverride: String?
    package let persistsSessions: Bool
    package weak var owner: ClaudeCodeClient?

    package var outputPump: ProviderOutputPump?
    package var stdoutBuffer = Data()
    package var stderrTail = ""
    package var process: Process?
    package var inputPipe: Pipe?
    /// The run with file-backed stdio a runner of a daemon's shared client uses instead of a
    /// piped child, so its turn outlives the daemon.
    package var agentRun: ClaudeAgentRun?
    package let runsDirectory: URL?
    /// Set while rebuilding the turn from log lines a previous daemon already handled: nothing
    /// is written, recorded or reported again.
    package var isReplaying = false
    package var nextControlRequestID = 1
    package var pendingControlRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    package var activeMode: ConversationMode = .code
    /// A side chat's turn: file-editing tools and shell commands other than the CLI are denied.
    package var activeReadOnly = false
    package var pendingCommandUUIDs = Set<String>()
    /// What each model call (by message ID) has reported so far, so the live
    /// counter adds a call once and only its later growth after that.
    package var liveCallUsage: [String: (sent: Int, output: Int, usage: ConversationTokenUsage)] = [:]
    package var sawCommandLifecycle = false
    package var sessionWasMissing = false
    package var turnCompletion = TurnCompletion()
    package var turnWaiter: CheckedContinuation<Void, Error>?
    package var planWasPresented = false
    /// The latest answer text, held so the turn's last one becomes its final answer.
    /// `recorded` means it is already in the transcript as progress: a result came
    /// while background work or steered input kept the turn open.
    package var pendingAssistantText: (id: String, text: String, recorded: Bool)?
    /// Set when the pending answer text was followed only by Playhouse's
    /// end-of-turn call — a task outcome, or a standalone chat's page
    /// close-turn — so text Claude writes after it extends the same answer.
    package var pendingTextSpansOutcomeReport = false
    package var toolActivities: [String: ConversationActivity] = [:]
    package var activityStartedAtUptime: [String: UInt64] = [:]
    /// Background Agent/Task calls currently reported as outstanding by the most
    /// recent `background_tasks_changed` event. The turn must not settle while
    /// any of these are still running, or their results and the activity rows
    /// tracking them would be lost when the process is torn down.
    package var outstandingBackgroundTaskIDs: Set<String> = []
    /// A task_updated terminal status is not the final report. Wait for the
    /// distinct task_notification event even if background_tasks_changed has
    /// already removed the task from its outstanding list.
    package var pendingBackgroundTaskNotificationIDs: Set<String> = []
    /// Maps the provider's own background task id to the tool-use id (the
    /// activity's `childThreadID`) that launched it, learned from `task_started`.
    package var backgroundTaskToolUseIDs: [String: String] = [:]
    /// Task ids owned by a subagent itself (for example a nested Bash call the
    /// background agent ran), not a top-level Agent/Task call Playhouse tracks
    /// as its own activity row. Their notifications are internal to the agent's
    /// own work and must not spawn a stray top-level activity.
    package var nestedBackgroundTaskIDs: Set<String> = []
    /// Tool-use ids for Agent/Task and Bash calls launched with
    /// `run_in_background: true`, so their instant launch-confirmation
    /// tool_result isn't mistaken for the actual completion.
    package var backgroundedToolUseIDs: Set<String> = []
    /// Top-level background shells (`local_bash` not owned by a subagent). They
    /// keep the turn open like agents, but their summary is command status, not
    /// an agent report for the transcript.
    package var backgroundShellTaskIDs: Set<String> = []
    package var parentWakeBackstopGeneration = 0
    /// Why Playhouse sent this turn's `/compact`, which Claude Code itself
    /// reports as a manual compaction; nil for every other turn.
    package var compactionTrigger: ContextCompactionTrigger?
    /// The timeline row of a compaction Claude Code has started and not yet
    /// finished, so its boundary completes that row instead of adding one.
    package var pendingCompactionActivityID: String?

    package var activeTurnID: String?
    package var isTurnActive = false
    package var pendingQuestion: PendingQuestion?
    package var pendingUserInputRequest: ConversationUserInputRequest?
    package var wasInterrupted = false
    package var activityDurations: [String: Int] = [:]
    /// Set once Claude Code has accepted this session ID and owns its transcript.
    /// From then on the session exists whether or not the turn succeeds, so the
    /// next turn must resume it instead of claiming the ID again.
    package var sessionExists = false

    package var deltaHandler: ((String) -> Void)?
    package var finalMessageHandler: ((String) -> Void)?
    /// Receives a final answer already recorded as progress, with that item's ID, so it settles
    /// in place. Without it the answer goes to `finalMessageHandler` like any other.
    package var recordedFinalHandler: ((String, String) -> Void)?
    package var progressMessageHandler: ((ConversationMessage) -> Void)?
    package var steerMessageHandler: ((String, [String]) -> Void)?
    /// Called once the turn's message is with Claude Code, when the turn takes an interrupt or a steer.
    package var turnStartedHandler: ((String) -> Void)?
    package var activityHandler: ((ConversationActivity) -> Void)?
    package var actionRequestHandler: (() -> Void)?
    package var userInputHandler: ((ConversationUserInputRequest) async -> Void)?
    package var tokenUsageHandler: ((ConversationTurnUsageReport) -> Void)?

    package init(
        sessionID: String,
        executable: String,
        configDirectoryOverride: String?,
        persistsSessions: Bool,
        owner: ClaudeCodeClient?,
        runsDirectory: URL? = nil
    ) {
        self.sessionID = sessionID
        self.executable = executable
        self.configDirectoryOverride = configDirectoryOverride
        self.persistsSessions = persistsSessions
        self.owner = owner
        self.runsDirectory = runsDirectory
    }

    package var processIdentifier: Int32 { agentRun?.identity?.pid ?? process?.processIdentifier ?? -1 }

    package var isAgentRunning: Bool { agentRun?.isRunning ?? (process?.isRunning == true) }

    package var canInterrupt: Bool { activeTurnID != nil }

    package func diagnosticFields(_ additionalFields: [String: String]) -> [String: String] {
        var fields = additionalFields
        fields["provider"] = ConversationProvider.claude.rawValue
        fields["clientPID"] = String(ProcessInfo.processInfo.processIdentifier)
        fields["claudePID"] = String(processIdentifier)
        fields["activeThreadID"] = sessionID
        fields["activeTurnID"] = activeTurnID ?? ""
        fields["isTurnActive"] = String(isTurnActive)
        return fields
    }

    // MARK: - Turn

    /// Runs one turn to completion in this session's own process.

    // MARK: - Process and protocol

    /// Starts this session's process. Claude Code only ever sees one session per
    /// process, so the working directory is the conversation's own worktree.

    /// Whether Claude has finished everything this logical turn owns: its
    /// result, steered input, background tasks, and any turn Claude Code starts
    /// to deliver a finished background task. A failure settles regardless.
    package var isTurnSettled: Bool {
        guard turnCompletion.resultReceived, pendingCommandUUIDs.isEmpty || !sawCommandLifecycle,
              !isHeldByBackgroundTasks else { return false }
        if turnCompletion.resultError != nil { return true }
        return !turnCompletion.awaitingParentWake && turnCompletion.resultCount > turnCompletion.wokenTurnCount
    }


    /// Background work the turn still owes a result for. A background shell stops holding the
    /// turn once the agent has reported a stopping outcome: the agent has said the task's work
    /// is over, so the shell is a server it left running, not a result it is waiting for.
    /// A background agent always holds it, since its result wakes the parent.
    package var isHeldByBackgroundTasks: Bool {
        let holding = outstandingBackgroundTaskIDs.union(pendingBackgroundTaskNotificationIDs)
        guard !holding.isEmpty else { return false }
        guard holding.isSubset(of: backgroundShellTaskIDs),
              owner?.stoppingOutcomeProbes[sessionID]?.isStaged() == true else { return true }
        return false
    }

    package func debugImportReplay(_ message: [String: Any]) async { await handle(message) } // DEBUG-IMPORT: replays a recorded session line through the live handler.


    /// Reports one model call as soon as the stream shows it. Claude Code
    /// writes an `assistant` message per content block of a call, all sharing
    /// the call's message ID, so the first sight counts the call and later
    /// ones only add what its usage has since grown by.
}
