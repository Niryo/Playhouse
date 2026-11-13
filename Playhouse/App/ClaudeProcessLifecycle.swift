import Foundation
import AppKit
import SwiftData
import Darwin

extension ClaudeSessionRunner {
    func waitForTurnCompletion() async throws {
        if isTurnSettled {
            if let error = turnCompletion.resultError { throw error }
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            turnWaiter = continuation
        }
    }

    func finishTurn(_ result: Result<Void, Error>) {
        guard let waiter = turnWaiter else {
            if case .failure(let error) = result {
                turnCompletion.resultReceived = true
                turnCompletion.resultError = error
            }
            return
        }
        turnWaiter = nil
        switch result {
        case .success: waiter.resume()
        case .failure(let error): waiter.resume(throwing: error)
        }
    }

    func stopProcess() {
        if let agentRun {
            self.agentRun = nil
            let threadID = sessionID
            Task { await TaskCPUUsageSampler.shared.forget(threadID: threadID) }
            let stopped = ClientError.processExited("Playhouse stopped Claude Code.")
            for continuation in pendingControlRequests.values { continuation.resume(throwing: stopped) }
            pendingControlRequests.removeAll()
            if turnWaiter != nil { finishTurn(.failure(stopped)) }
            // Its input never ends while it holds its own writer, so it is stopped by signal.
            Task { await agentRun.terminateAndRemove() }
            return
        }
        guard let process else { return }
        self.process = nil
        let threadID = sessionID
        Task { await TaskCPUUsageSampler.shared.forget(threadID: threadID) }
        let stopped = ClientError.processExited("Playhouse stopped Claude Code.")
        for continuation in pendingControlRequests.values { continuation.resume(throwing: stopped) }
        pendingControlRequests.removeAll()
        if turnWaiter != nil { finishTurn(.failure(stopped)) }
        try? inputPipe?.fileHandleForWriting.close()
        inputPipe = nil
        let deadline = Date().addingTimeInterval(1.0)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < killDeadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
    }

    func processDidTerminate(_ terminated: Process) {
        // A process stopped by `stopProcess` (or replaced by a relaunch) is no
        // longer this runner's; its late termination must not fail new requests.
        guard process === terminated else { return }
        PlayhouseDiagnostics.record("claude.process.exited", fields: diagnosticFields([
            "processID": String(terminated.processIdentifier),
            "exitStatus": String(terminated.terminationStatus)
        ]))
        let error: Error = sessionWasMissing || stderrTail.contains("No conversation found with session ID")
            ? ClientError.sessionNotFound
            : ClaudeCodeClient.classifyFailure(ClientError.processExited(stderrSummary(status: terminated.terminationStatus)), text: stderrTail)
        for continuation in pendingControlRequests.values { continuation.resume(throwing: error) }
        pendingControlRequests.removeAll()
        if !turnCompletion.resultReceived || turnWaiter != nil {
            finishTurn(.failure(error))
        }
        process = nil
        inputPipe = nil
    }

    func followAgentRun(_ run: ClaudeAgentRun) {
        let requestContext = PlayhouseRequestContext.capture()
        run.follow(onLines: { [weak self, weak run] lines, end in
            await requestContext.run {
                guard let self else { return }
                for line in lines {
                    guard !line.isEmpty, let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    await self.handle(message)
                }
                // Committed once the batch's transcript writes and replies are done.
                run?.commit(offset: end)
            }
        }, onExit: { [weak self, weak run] status in
            await requestContext.run {
                guard let self, let run else { return }
                self.agentRunDidExit(run, status: status)
            }
        })
    }

    func agentRunDidExit(_ run: ClaudeAgentRun, status: Int32?) {
        guard agentRun === run else { return }
        stderrTail = run.stderrTail
        let exitCode = status.map { ($0 >> 8) & 0xFF }
        PlayhouseDiagnostics.record("claude.process.exited", fields: diagnosticFields([
            "processID": String(run.identity?.pid ?? -1),
            "exitStatus": exitCode.map(String.init) ?? "unknown",
        ]))
        let error: Error = if let inputFailure = run.inputFailure {
            // Playhouse stopped an agent that wouldn't take its input; say so, not "it exited".
            ClientError.protocolFailure(inputFailure.localizedDescription)
        } else if sessionWasMissing || stderrTail.contains("No conversation found with session ID") {
            ClientError.sessionNotFound
        } else {
            ClaudeCodeClient.classifyFailure(ClientError.processExited(stderrSummary(status: exitCode)), text: stderrTail)
        }
        if let inputFailure = run.inputFailure {
            PlayhouseDiagnostics.record("claude.input.failed", fields: diagnosticFields([
                "processID": String(run.identity?.pid ?? -1),
                "reason": inputFailure.localizedDescription,
            ]))
        }
        for continuation in pendingControlRequests.values { continuation.resume(throwing: error) }
        pendingControlRequests.removeAll()
        if !turnCompletion.resultReceived || turnWaiter != nil {
            finishTurn(.failure(error))
        }
    }

    /// Carries on a turn whose run outlived the daemon that started it. The lines that daemon
    /// already handled are replayed without side effects to rebuild this turn's state (its
    /// result, activities, background tasks, and any unanswered question); the rest of the log
    /// is handled live, and the run is followed to the turn's end.
    func reattach(
        _ run: ClaudeAgentRun,
        onAttached: () -> Void
    ) async throws -> ConversationReattachResult {
        activeMode = ConversationMode(rawValue: run.manifest.mode) ?? .code
        wakeGrace = ClaudeSessionRunner.graceOverride(
            "PLAYHOUSE_E2E_CLAUDE_WAKE_GRACE_SECONDS", default: ClaudeSessionRunner.parentWakeGracePeriod
        )
        wokenSilenceGrace = ClaudeSessionRunner.graceOverride(
            "PLAYHOUSE_E2E_CLAUDE_WOKEN_SILENCE_GRACE_SECONDS", default: ClaudeSessionRunner.wokenTurnSilenceGracePeriod
        )
        agentRun = run
        nextControlRequestID = ClaudeRunFiles.firstRequestID(afterReattaching: run.manifest.maxRequestID)
        sessionExists = true
        turnCompletion = TurnCompletion()
        parentWakeBackstopGeneration += 1
        let handlers = (deltaHandler, finalMessageHandler, progressMessageHandler, steerMessageHandler,
                        activityHandler, actionRequestHandler, userInputHandler, tokenUsageHandler)
        (deltaHandler, finalMessageHandler, progressMessageHandler, steerMessageHandler) = (nil, nil, nil, nil)
        (activityHandler, actionRequestHandler, userInputHandler, tokenUsageHandler) = (nil, nil, nil, nil)
        isReplaying = true
        for line in run.handledLines() {
            guard !line.isEmpty, let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            await handle(message)
        }
        isReplaying = false
        (deltaHandler, finalMessageHandler, progressMessageHandler, steerMessageHandler,
         activityHandler, actionRequestHandler, userInputHandler, tokenUsageHandler) = handlers
        // A line cut off mid-write ends the run at its next input, so the turn can't go on.
        if run.manifest.writeInProgress {
            PlayhouseDiagnostics.record("claude.turn.reattach_cut_off_write", fields: diagnosticFields([:]))
            agentRun = nil
            await run.terminateAndRemove()
            return .agentGone
        }
        let turnID = UUID().uuidString.lowercased()
        activeTurnID = turnID
        isTurnActive = true
        owner?.runnerStateChanged(self)
        ClaudeCodeClient.markProcessActive(sessionID: sessionID)
        ConversationSteerMailbox.publishActiveTurn(threadID: sessionID, turnID: turnID)
        PlayhouseDiagnostics.record("claude.turn.reattached", fields: diagnosticFields([
            "threadID": sessionID,
            "turnID": turnID,
            "processAlive": String(run.isRunning),
            "consumedOffset": String(run.manifest.consumedOffset),
        ]))
        if let request = pendingUserInputRequest {
            let handler = userInputHandler
            Task { @MainActor in await handler?(request) }
        }
        onAttached()
        followAgentRun(run)
        let mailboxTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.activeTurnID == turnID {
                await ConversationSteerMailbox.service(threadID: self.sessionID, turnID: turnID) { text, images in
                    let accepted = try await self.sendSteerInput(text: text, imageDataURLs: images)
                    if accepted { self.steerMessageHandler?(text, images) }
                    return accepted
                } interrupt: {
                    try await self.interrupt()
                }
                try? await Task.sleep(for: .milliseconds(75))
            }
        }
        defer { mailboxTask.cancel() }
        try await waitForTurnCompletion()
        PlayhouseDiagnostics.record("claude.turn.ended", fields: diagnosticFields([
            "threadID": sessionID, "turnID": turnID, "turnStatus": "completed"
        ]))
        return .finished
    }

    func stderrSummary(status: Int32? = nil) -> String {
        let detail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).suffix(3).joined(separator: " ")
        let exit = status.map { "Claude Code exited with status \($0)." } ?? "Restart Playhouse and try again."
        return detail.isEmpty ? exit : "\(exit) \(detail)"
    }

    func consumeOutput(_ data: Data) async {
        stdoutBuffer.append(data)
        while let range = stdoutBuffer.range(of: Data([0x0A])) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
            guard !line.isEmpty, let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            await handle(message)
        }
    }
}
