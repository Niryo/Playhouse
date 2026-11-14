import Foundation
import AppKit
import SwiftData
import Darwin

extension ClaudeCodeClient {
    var isInstalled: Bool { executablePath != nil }

    /// Reads the sign-in state with `claude auth status`, a local call that
    /// needs no network, then the plan's usage.
    func refreshAgentUsage() async {
        let store = AgentUsageStore.shared(scope: runtimeScope)
        store.setInstalled(.claude, isInstalled)
        guard isInstalled else { return }
        guard let output = await runAuthCommand(["auth", "status", "--json"]),
              let status = try? JSONSerialization.jsonObject(with: output.data) as? [String: Any],
              let loggedIn = status["loggedIn"] as? Bool else {
            // Status and usage are independent provider operations. Preserve the
            // known identity when status fails and try reading usage anyway.
            await readPlanUsage()
            return
        }
        let subscription = (status["subscriptionType"] as? String).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        store.setAuth(
            .claude,
            loggedIn: loggedIn,
            account: (status["email"] as? String) ?? (status["authMethod"] as? String),
            plan: subscription
        )
        if loggedIn { await readPlanUsage() }
    }

    /// Reads the plan's usage with Claude Code's `get_usage` control request, in
    /// a session that never receives a prompt, so no model request is made.
    /// The stream's `rate_limit_event` is sent only when a limit's status
    /// changes, and carries no utilization at all for a usage-based plan, so
    /// this read is what keeps the numbers current after each turn. Reads asked
    /// for while one runs share one follow-up read.
    func readPlanUsage() async {
        if let running = planUsageRead {
            planUsageReadQueued = true
            await running.value
            return
        }
        let read = Task { @MainActor in
            repeat {
                planUsageReadQueued = false
                await readPlanUsageOnce()
            } while planUsageReadQueued
            planUsageRead = nil
        }
        planUsageRead = read
        await read.value
    }

    func readPlanUsageOnce() async {
        guard isInstalled, let workspace = try? ConversationWorkspaceContext(roots: []) else { return }
        do {
            let response = try await withMetadataSession(workspace: workspace) { runner in
                // A reply that never comes (a stalled usage service, or a CLI that ignores
                // the request) must not hold every later read: stopping the session fails it.
                let timeout = Task { @MainActor in
                    try await Task.sleep(for: Self.planUsageReadTimeout)
                    runner.shutdown()
                }
                defer { timeout.cancel() }
                return try await runner.controlRequest(["subtype": "get_usage", "skip_behaviors": true])
            }
            AgentUsageStore.shared(scope: runtimeScope).recordClaudeRead(response.extra)
        } catch {
            // An older Claude Code without `get_usage` still reports through the stream.
            PlayhouseDiagnostics.record("claude.usage.read_failed", fields: PlayhouseDiagnostics.errorFields(error))
        }
    }

    /// Starts `claude auth login`, which opens the browser itself and exits once
    /// the sign-in finishes; the block refreshes then.
    func startAccountLogin() throws {
        guard loginProcess?.isRunning != true else { return }
        let process = try makeAuthProcess(["auth", "login"])
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let store = AgentUsageStore.shared(scope: runtimeScope)
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.loginProcess = nil
                store.setLoginInProgress(.claude, false)
                await self?.refreshAgentUsage()
            }
        }
        try process.run()
        loginProcess = process
        store.setLoginInProgress(.claude, true)
    }

    /// Signs out through the CLI. The state shown afterwards is read back from
    /// `claude auth status`, so a logout that failed is reported, not assumed.
    func logoutAccount() async throws {
        guard await runAuthCommand(["auth", "logout"]) != nil else {
            throw ClientError.protocolFailure("Claude Code could not sign out.")
        }
        await refreshAgentUsage()
    }

    func makeAuthProcess(_ arguments: [String]) throws -> Process {
        guard let executable = executablePath else { throw ClientError.cliNotFound }
        let command = ConversationProviderFixture.launchCommand(executable: executable, arguments: arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        var environment = PlayhouseProcessEnvironment.current
        environment["PATH"] = Self.expandedSearchPath(environment["PATH"])
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        ConversationProcessEnvironment.forwardPlayhouseBridgeEnvironment(&environment, dataDirectoryOverride: dataDirectoryOverride)
        if let configDirectoryOverride { environment["CLAUDE_CONFIG_DIR"] = configDirectoryOverride }
        process.environment = environment
        return process
    }

    /// Runs a short `claude` command and returns its output, or nil if it could
    /// not start, failed, or did not finish within `timeout`.
    func runAuthCommand(_ arguments: [String], timeout: TimeInterval = 20) async -> (data: Data, status: Int32)? {
        guard let process = try? makeAuthProcess(arguments) else { return nil }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                do { try process.run() } catch { continuation.resume(returning: nil); return }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: process.terminationStatus == 0 ? (data, process.terminationStatus) : nil)
            }
        }
    }
}
