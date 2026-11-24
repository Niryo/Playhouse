import AppKit
import Foundation

/// OpenCode has no account of its own: it runs models through the providers the user connected
/// with `opencode auth login` (and its free OpenCode Zen models with none). The Agents section
/// shows those connections as the account, and OpenCode reports no plan or usage limits.
extension OpenCodeClient {
    /// Reads the connected providers, a local call that needs no network: OpenCode 2's
    /// `auth list --standalone --format json` (a private server, never the background service),
    /// else OpenCode 1's `auth.json`.
    func refreshAgentUsage() async {
        let store = AgentUsageStore.shared(scope: runtimeScope)
        store.setInstalled(.opencode, isInstalled)
        guard isInstalled else { return }
        let integrations = await connectedIntegrations()
        guard let integrations else { return }
        store.setAuth(
            .opencode,
            loggedIn: !integrations.isEmpty,
            account: integrations.isEmpty ? nil : integrations.joined(separator: ", "),
            plan: nil
        )
    }

    func connectedIntegrations() async -> [String]? {
        if let output = await runAuthCommand(["auth", "list", "--standalone", "--format", "json"]),
           let entries = try? JSONSerialization.jsonObject(with: output) as? [Any] {
            let names = entries.compactMap { entry -> String? in
                if let name = entry as? String { return name }
                guard let object = entry as? [String: Any] else { return nil }
                for key in ["integrationID", "integrationId", "integration", "providerID", "provider", "name", "id"] {
                    if let value = object[key] as? String, !value.isEmpty { return value }
                }
                return nil
            }
            return Array(Set(names)).sorted()
        }
        let dataHome = PlayhouseProcessEnvironment.current["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? NSHomeDirectory() + "/.local/share"
        guard let data = FileManager.default.contents(atPath: dataHome + "/opencode/auth.json"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object.keys.sorted()
    }

    /// `opencode auth login` asks which provider to connect and for its key or sign-in in the
    /// terminal, so it opens in Terminal; the section refreshes when the window comes back.
    func startAccountLogin() throws {
        guard let executable = executablePath else { throw ClientError.cliNotFound }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("playhouse-opencode-login-\(UUID().uuidString.prefix(8)).command")
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try "#!/bin/bash\n\(quoted) auth login\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard NSWorkspace.shared.open(script) else {
            throw ClientError.processStart("Terminal couldn't open `opencode auth login`.")
        }
        AgentUsageStore.shared(scope: runtimeScope).setLoginInProgress(.opencode, true)
    }

    /// OpenCode signs out one connected provider at a time in its own terminal UI, so switching
    /// accounts signs nothing out here: it opens the same login, where the user picks the
    /// provider to connect or replace.
    func logoutAccount() async throws {
        AgentUsageStore.shared(scope: runtimeScope).setLoginInProgress(.opencode, false)
    }

    func runAuthCommand(_ arguments: [String], timeout: TimeInterval = 20) async -> Data? {
        guard let executable = executablePath else { return nil }
        let command = ConversationProviderFixture.launchCommand(executable: executable, arguments: arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        var environment = PlayhouseProcessEnvironment.current
        environment["PATH"] = ClaudeCodeClient.expandedSearchPath(environment["PATH"])
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["OPENCODE_DISABLE_AUTOUPDATE"] = "1"
        ConversationProcessEnvironment.forwardPlayhouseBridgeEnvironment(&environment, dataDirectoryOverride: dataDirectoryOverride)
        process.environment = environment
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
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }
}
