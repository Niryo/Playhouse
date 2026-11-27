import Foundation

/// A command a Codex turn started, followed past the end of that turn. Codex leaves a
/// unified-exec command running when its turn ends and has no way to wake the model when it
/// exits, so Playhouse watches it through the app-server instead: `item/completed` still
/// arrives for the command after `turn/completed`, with its exit code and output, and
/// `thread/backgroundTerminals/list` says which commands are still alive (verified against
/// `codex-cli 0.162.1`; neither has a notification of its own for a terminal ending).
package struct CodexCommandJob {
    package let id: String
    package var command: String
    package var processID: String?
    package var output = ""
    /// Set once the command ended with no turn of its thread running to see it.
    package var result: ProviderBackgroundJobResult?
    /// Whether the app-server listed it as a background terminal. Only such a command counts
    /// as background work when it disappears without a result.
    package var isConfirmedBackground = false
    package var missedReconciliations = 0

    package var job: ProviderBackgroundJob { ProviderBackgroundJob(id: id, command: command) }

    package init(id: String, command: String, processID: String? = nil, output: String = "", result: ProviderBackgroundJobResult? = nil, isConfirmedBackground: Bool = false, missedReconciliations: Int = 0) {
        self.id = id
        self.command = command
        self.processID = processID
        self.output = output
        self.result = result
        self.isConfirmedBackground = isConfirmedBackground
        self.missedReconciliations = missedReconciliations
    }
}

extension CodexAppServerClient {
    package func hasBackgroundWorkToStop(threadID: String) async -> Bool {
        if let owner = activeClient(forThread: threadID), owner !== self {
            return await owner.hasBackgroundWorkToStop(threadID: threadID)
        }
        if backgroundWaitThreadIDs.contains(threadID) { return true }
        guard activeTurnIdentity(threadID: threadID) != nil else { return false }
        if let terminals = await listBackgroundTerminals(threadID: threadID, timeout: .milliseconds(500)) {
            return !terminals.isEmpty
        }
        return commandJobs[threadID]?.values.contains(where: { $0.result == nil }) == true
    }

    package func stopBackgroundWork(threadID: String) async throws -> Bool {
        if let owner = activeClient(forThread: threadID), owner !== self {
            return try await owner.stopBackgroundWork(threadID: threadID)
        }
        if try await stopBackgroundWait(threadID: threadID) { return true }
        let turnID = activeTurnIdentity(threadID: threadID)
        try await terminateBackgroundJobs(threadID: threadID, turnID: turnID)
        return false
    }

    /// Follows `commandExecution` items by thread, independent of any turn context, so a
    /// command's end is seen after its turn's context is gone.
    package func noteCommandItem(method: String, params: [String: Any]) {
        guard let threadID = params["threadId"] as? String, threadParents[threadID] == nil else { return }
        if method == "item/commandExecution/outputDelta" {
            guard let itemID = params["itemId"] as? String, let delta = params["delta"] as? String,
                  var job = commandJobs[threadID]?[itemID] else { return }
            job.output = String((job.output + delta).suffix(4_000))
            commandJobs[threadID]?[itemID] = job
            return
        }
        guard let item = params["item"] as? [String: Any], item["type"] as? String == "commandExecution",
              let itemID = item["id"] as? String else { return }
        if method == "item/started" {
            var job = commandJobs[threadID]?[itemID] ?? CodexCommandJob(id: itemID, command: item["command"] as? String ?? "")
            job.processID = item["processId"] as? String ?? job.processID
            commandJobs[threadID, default: [:]][itemID] = job
            return
        }
        guard var job = commandJobs[threadID]?[itemID] else { return }
        // A command that ends while a turn of its thread runs is that turn's to read.
        guard !runningTurnThreadIDs.contains(threadID) else {
            commandJobs[threadID]?.removeValue(forKey: itemID)
            return
        }
        let output = (item["aggregatedOutput"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? job.output
        job.result = ProviderBackgroundJobResult(
            job: job.job,
            exitCode: item["exitCode"] as? Int,
            status: item["status"] as? String,
            output: String(output.suffix(4_000))
        )
        commandJobs[threadID]?[itemID] = job
        PlayhouseDiagnostics.record("codex.background_job.finished", fields: diagnosticFields([
            "threadID": threadID,
            "itemID": itemID,
            "status": item["status"] as? String ?? "unknown",
            "exitCode": (item["exitCode"] as? Int).map(String.init) ?? "",
        ]))
    }

    /// The thread's live background terminals, or nil when the app-server couldn't be asked.
    package func listBackgroundTerminals(threadID: String, timeout: Duration = .seconds(15)) async -> [[String: Any]]? {
        var terminals: [[String: Any]] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = ["threadId": threadID, "limit": 200]
            if let cursor { params["cursor"] = cursor }
            guard let response = try? await request(method: "thread/backgroundTerminals/list", params: params, timeout: timeout),
                  let page = response["data"] as? [[String: Any]] else { return nil }
            terminals += page
            cursor = response["nextCursor"] as? String
        } while cursor != nil
        return terminals
    }

    /// Brings the thread's tracked commands in line with the terminals the app-server lists.
    /// Returns false when the app-server couldn't be asked.
    @discardableResult
    package func reconcileBackgroundJobs(threadID: String, missesBeforeUnknown: Int) async -> Bool {
        guard let terminals = await listBackgroundTerminals(threadID: threadID) else { return false }
        let listed = Dictionary(terminals.compactMap { terminal in
            (terminal["itemId"] as? String).map { ($0, terminal) }
        }, uniquingKeysWith: { first, _ in first })
        for (itemID, tracked) in commandJobs[threadID] ?? [:] where tracked.result == nil {
            var job = tracked
            if let terminal = listed[itemID] {
                job.isConfirmedBackground = true
                job.missedReconciliations = 0
                job.processID = terminal["processId"] as? String ?? job.processID
                if job.command.isEmpty { job.command = terminal["command"] as? String ?? "" }
                commandJobs[threadID]?[itemID] = job
            } else if !job.isConfirmedBackground {
                // Never a background terminal: an item whose end this client didn't see.
                commandJobs[threadID]?.removeValue(forKey: itemID)
            } else {
                // Its `item/completed` may still be on its way; only a command that stays
                // gone with no result has an unknown one.
                job.missedReconciliations += 1
                if job.missedReconciliations >= missesBeforeUnknown {
                    job.result = ProviderBackgroundJobResult(job: job.job, isKnown: false)
                }
                commandJobs[threadID]?[itemID] = job
            }
        }
        return true
    }

    package func takeBackgroundWork(threadID: String, known: [ProviderBackgroundJob]) async -> ProviderBackgroundWork {
        for job in known where commandJobs[threadID]?[job.id] == nil {
            var adopted = CodexCommandJob(id: job.id, command: job.command)
            adopted.isConfirmedBackground = true
            commandJobs[threadID, default: [:]][job.id] = adopted
        }
        guard !(commandJobs[threadID] ?? [:]).isEmpty else { return ProviderBackgroundWork() }
        // A command gone from the list gets a moment for its completion event to land.
        for attempt in 0..<4 {
            let reconciled = await reconcileBackgroundJobs(threadID: threadID, missesBeforeUnknown: 4)
            let pendingEvent = (commandJobs[threadID] ?? [:]).values.contains { $0.result == nil && $0.missedReconciliations > 0 }
            guard reconciled, pendingEvent, attempt < 3 else { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        var work = ProviderBackgroundWork()
        for job in (commandJobs[threadID] ?? [:]).values.sorted(by: { $0.id < $1.id }) {
            if let result = job.result {
                work.finished.append(result)
                commandJobs[threadID]?.removeValue(forKey: job.id)
            } else if job.isConfirmedBackground {
                work.running.append(job.job)
            }
        }
        return work
    }

    package func waitForBackgroundJobs(threadID: String, timeout: TimeInterval, shouldStop: @escaping () -> Bool) async -> ProviderBackgroundWaitEnd {
        let waitID = "background-wait-\(UUID().uuidString)"
        backgroundWaitThreadIDs.insert(threadID)
        backgroundWaitStopRequests.remove(threadID)
        Self.processActiveThreadIDs.insert(threadID)
        Self.activeClientsByThreadID[threadID] = self
        // Another Playhouse process stops the wait through the same mailbox it stops a turn with.
        ConversationSteerMailbox.publishActiveTurn(threadID: threadID, turnID: waitID)
        defer {
            backgroundWaitThreadIDs.remove(threadID)
            backgroundWaitStopRequests.remove(threadID)
            if activeTurnID(for: threadID) == nil {
                Self.processActiveThreadIDs.remove(threadID)
                ConversationSteerMailbox.clearActiveTurn(threadID: threadID)
                if Self.activeClientsByThreadID[threadID] === self {
                    Self.activeClientsByThreadID.removeValue(forKey: threadID)
                }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var nextReconciliation = Date()
        var failedReconciliations = 0
        while true {
            await ConversationSteerMailbox.service(threadID: threadID, turnID: waitID) { _, _ in
                false
            } interrupt: {
                try await self.interruptActiveTurn(threadID: threadID)
            }
            if backgroundWaitStopsInFlight.contains(threadID) {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            if backgroundWaitStopRequests.contains(threadID) || shouldStop() { return .stopped }
            let running = (commandJobs[threadID] ?? [:]).values.filter { $0.result == nil }
            if running.isEmpty { return .finished }
            if threadStatuses[threadID] == "systemError" {
                return .providerLost("the Codex app-server reported a system error for the thread")
            }
            if Date() >= deadline { return .timedOut }
            if Date() >= nextReconciliation {
                nextReconciliation = Date().addingTimeInterval(Self.backgroundJobReconciliationInterval)
                if await reconcileBackgroundJobs(threadID: threadID, missesBeforeUnknown: 2) {
                    failedReconciliations = 0
                } else {
                    failedReconciliations += 1
                    if failedReconciliations >= 5, !backgroundWaitStopsInFlight.contains(threadID) {
                        return .providerLost("the Codex app-server stopped answering")
                    }
                }
                continue
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    package static var backgroundJobReconciliationInterval: TimeInterval {
        PlayhouseProcessEnvironment.current["PLAYHOUSE_E2E_CODEX_BACKGROUND_RECONCILE_SECONDS"].flatMap(TimeInterval.init) ?? 2
    }

    package func forgetBackgroundJobs(threadID: String) {
        commandJobs.removeValue(forKey: threadID)
    }

    /// Stop during a background wait: there is no turn to interrupt, so the commands the
    /// wait is for are ended instead, and the wait with them.
    package func stopBackgroundWait(threadID: String) async throws -> Bool {
        guard backgroundWaitThreadIDs.contains(threadID) else { return false }
        guard backgroundWaitStopsInFlight.insert(threadID).inserted else { return false }
        defer { backgroundWaitStopsInFlight.remove(threadID) }
        let tracked = commandJobs[threadID] ?? [:]
        let waitID = activeTurnIdentity(threadID: threadID)
        try await terminateBackgroundJobs(threadID: threadID, turnID: waitID)
        wasLastTurnInterrupted = true
        interruptedThreadIDs.insert(threadID)
        backgroundWaitStopRequests.insert(threadID)
        commandJobs.removeValue(forKey: threadID)
        PlayhouseDiagnostics.record("codex.background_wait.stopped", fields: diagnosticFields([
            "threadID": threadID,
            "jobCount": String(tracked.count),
        ]))
        return true
    }

    private func terminateBackgroundJobs(threadID: String, turnID: String?) async throws {
        guard let terminals = await listBackgroundTerminals(threadID: threadID, timeout: .seconds(2)) else {
            throw ClientError.protocolFailure("Codex didn't report which background commands are running.")
        }
        for terminal in terminals {
            guard activeTurnIdentity(threadID: threadID) == turnID else {
                throw BridgeCommandError(code: "invalid_transition", message: "The conversation changed while stopping its background work.")
            }
            guard let processID = terminal["processId"] as? String else {
                throw ClientError.protocolFailure("Codex did not identify a running background command.")
            }
            let result = try await request(
                method: "thread/backgroundTerminals/terminate",
                params: ["threadId": threadID, "processId": processID], timeout: .seconds(2)
            )
            if result["terminated"] as? Bool != true,
               await listBackgroundTerminals(threadID: threadID, timeout: .seconds(2))?.contains(where: { $0["processId"] as? String == processID }) != false {
                throw ClientError.protocolFailure("Codex did not stop a background command.")
            }
        }
    }
}
