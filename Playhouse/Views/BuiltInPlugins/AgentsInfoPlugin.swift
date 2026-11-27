import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// The board sidebar's Agents info section (`BuiltInPlugins.agentsInfoID`):
/// each installed agent's account and usage from `props.agents`, under the
/// collapsible header its section host draws. It refreshes the usage once per
/// launch (`app.launched`), re-derives reset times on a slow tick, signs in
/// with `usage.login` and `ui.openURL`, and asks with `ui.confirm` before
/// switching an account that has tasks running. With no agent installed it
/// renders nothing, so its section hides.
package struct AgentsInfoPlugin: PHView {
    package let host: PluginHost
    package let props: [String: PluginValue]
    @PHState private var errorMessage: String?
    @PHState private var now = Date()

    private var agents: [String: PluginValue] { props["agents"]?.object ?? [:] }

    private var report: AgentUsageReport? {
        guard let usage = agents["usage"], usage != .null else { return nil }
        return try? PluginValueDecoder.decode(AgentUsageReport.self, from: usage)
    }

    private func runningTasks(_ provider: String) -> Int {
        agents["runningTasks"]?.object?[provider]?.int ?? 0
    }

    private var runningProviders: [ConversationProvider: Int] {
        Dictionary(uniqueKeysWithValues: [ConversationProvider.claude, .codex].map { ($0, runningTasks($0.rawValue)) })
    }

    package var body: some PHView {
        let report = report
        let hasAgents = !AgentsInfoModel.visibleProviders(report).isEmpty
        PHVStack(alignment: .leading, spacing: 6) {
            if hasAgents {
                AgentsInfoSection(
                    model: AgentsInfoModel(report: report, runningProviders: runningProviders, errorMessage: errorMessage, now: now),
                    actions: AgentsInfoActions(
                        login: { provider in Task { await login(provider) } },
                        switchAccount: { provider in Task { await switchAccount(provider) } }
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .preference(key: PluginSectionContentKey.self, value: hasAgents)
        .task {
            if PluginLaunch.claim(BuiltInPlugins.agentsInfoID) { await refresh() }
        }
        // Re-derived on a slow tick so reset times and "updated" hints stay current.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = Date()
            }
        }
    }

    /// Both accounts' sign-in state and Codex's snapshot, read again; the
    /// result reaches `props.agents` through the window's usage feed.
    private func refresh() async {
        try? await host.call("bridge", "usage.get", ["refresh": .bool(true)])
    }

    /// Starts the sign-in, opens Codex's URL, and re-reads the account while
    /// the daemon waits for the browser step to finish.
    private func login(_ provider: String) async {
        await run("usage.login", provider: provider)
    }

    /// Signing out affects the provider's running tasks, so those ask first.
    private func switchAccount(_ provider: String) async {
        let count = runningTasks(provider)
        if count > 0 {
            let name = ConversationProvider(rawValue: provider)?.displayName ?? provider
            let answer = await host.answer(kind: "ui", name: "confirm", arguments: .object([
                "title": .string("Switch \(name) account?"),
                "message": .string("\(count) \(name) task\(count == 1 ? " is" : "s are") running. Signing out affects running tasks."),
                "confirm": .string("Switch Account"),
                "destructive": .bool(true)
            ]))
            guard case .success(.bool(true)) = answer else { return }
        }
        await run("usage.switch-account", provider: provider)
    }

    private func run(_ command: String, provider: String) async {
        errorMessage = nil
        do {
            let result = try await host.bridge(command, ["provider": .string(provider)], as: LoginResult.self)
            if let url = result.loginURL {
                try await host.call("ui", "openURL", ["url": .string(url)])
            }
        } catch {
            errorMessage = (error as? PluginHostError)?.message ?? error.localizedDescription
        }
        await refresh()
    }

    private struct LoginResult: Decodable {
        var loginURL: String?
    }

    package init(host: PluginHost, props: [String: PluginValue]) {
        self.host = host
        self.props = props
    }
}
