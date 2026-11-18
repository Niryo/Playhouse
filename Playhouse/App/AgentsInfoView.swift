import SwiftUI

/// The window's feed of the daemon's usage store, for the board sidebar's
/// bottom plugins (`props.agents.usage`). The daemon owns the providers and
/// receives their pushes, so this reads its state over the bridge once, then
/// follows the store's changes as the providers push them or the daemon
/// refreshes them periodically. A plugin asks for a fresh read itself
/// (`usage.get` with refresh, as the Agents info plugin does on `app.launched`).
@MainActor
final class AgentUsageModel: ObservableObject {
    /// The report as `usage.get` returns it, nil before the first read.
    @Published private(set) var usage: PluginValue?
    private var report: AgentUsageReport?
    let client: DaemonClient
    private var loop: Task<Void, Never>?

    init(client: DaemonClient) {
        self.client = client
    }

    /// Reads once, then follows the daemon's changes; reconnects if the daemon
    /// goes away. The daemon refreshes while the subscription is open.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // A daemon that restarted knows nothing until a read loads its
                // saved state, so read before following it.
                await self.load()
                do {
                    try await self.client.call("usage.subscribe") { event in
                        guard event.type == "usage_state",
                              let next = try? event.payload.decoded(AgentUsageReport.self) else { return }
                        self.apply(next)
                    }
                } catch {
                    PlayhouseDiagnostics.record("usage.subscription_failed", fields: PlayhouseDiagnostics.errorFields(error))
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Stops following the daemon, once no plugin reads the usage.
    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Only a changed report re-renders the sections.
    private func apply(_ next: AgentUsageReport) {
        var comparable = next
        comparable.generatedAt = report?.generatedAt ?? next.generatedAt
        guard comparable != report else { return }
        report = next
        usage = (try? JSONEncoder().encode(next)).flatMap { try? JSONDecoder().decode(PluginValue.self, from: $0) }
    }

    private func load() async {
        guard let value = try? await client.call("usage.get", ["refresh": .boolean(false)]),
              let next = try? value.decoded(AgentUsageReport.self) else { return }
        apply(next)
    }
}

/// The board sidebar's bottom (`PluginPlacement.mainSidebarBottom`), with
/// `props.agents` from the app's usage feed and the board's running tasks.
/// A view of its own, so a usage change re-renders only these sections.
struct BoardSidebarBottomSlot: View {
    /// Tasks running per provider.
    let runningProviders: [ConversationProvider: Int]
    let appearance: String
    let actions: PluginUIActions
    let add: (PluginPlacement) -> Void
    /// App-wide, so returning to the board shows what is known instead of reading again.
    @EnvironmentObject private var usage: AgentUsageModel
    @Environment(PluginRegistry.self) private var registry

    var body: some View {
        let agents = PluginAgentsContext(
            usage: usage.usage,
            runningTasks: Dictionary(uniqueKeysWithValues: runningProviders.map { ($0.key.rawValue, $0.value) })
        )
        let hasSections = !registry.sectionPlugins(for: .mainSidebarBottom).isEmpty
        PluginSectionSlot(
            placement: .mainSidebarBottom,
            props: { PluginContext.props(plugin: $0, appearance: appearance, task: nil, composer: nil, agents: agents) },
            actions: actions,
            add: add
        )
        // The feed runs only while a plugin here can read it.
        .task(id: hasSections) {
            if hasSections { usage.start() } else { usage.stop() }
        }
    }
}

/// What the Agents info section shows, already derived from the usage
/// report at one moment: plain values the native section and the catalog's
/// JavaScript copy (catalog/AgentsInfo.js, as `Playhouse.props.agentsInfo`)
/// compose the same way. `id` prefixes every
/// accessibility identifier ("agents-info" on the board).
struct AgentsInfoModel: Codable, Equatable {
    /// One usage window row: its label and percent, the bar, and when it resets.
    struct Window: Codable, Equatable {
        var id: String
        var label: String
        /// "22%", or "–" when the provider reported no percent.
        var percent: String
        var percentColor: String
        /// 0...1.
        var fraction: Double
        var barColor: String
        var reset: String
        var help: String
    }

    struct Status: Codable, Equatable {
        var text: String
        var color: String
    }

    /// One agent's block, top to bottom: the header, then either the Log in
    /// button, the usage rows, or "No data yet".
    struct Agent: Codable, Equatable {
        var provider: String
        var name: String
        var icon: String
        /// The account and plan on the row beneath the name.
        var identity: String?
        var identityHelp: String?
        var canSwitch: Bool
        var signedOut: Bool
        var loginPending: Bool
        var hasUsage: Bool
        var windows: [Window]
        var credits: String?
        var status: Status?
        var updated: String?
    }

    var id: String
    var title: String
    var agents: [Agent]
    var errorMessage: String?
}

extension AgentsInfoModel {
    /// Providers whose CLI is installed, in display order; none until the first read.
    static func visibleProviders(_ report: AgentUsageReport?) -> [AgentProviderUsage] {
        guard let report else { return [] }
        return [ConversationProvider.claude, .codex].compactMap { provider in
            report.providers.first { $0.provider == provider.rawValue && $0.installed }
        }
    }

    init(report: AgentUsageReport?, runningProviders: [ConversationProvider: Int], errorMessage: String?, now: Date) {
        id = "agents-info"
        title = "Agents info"
        self.errorMessage = errorMessage
        agents = Self.visibleProviders(report).compactMap { usage in
            guard let provider = ConversationProvider(rawValue: usage.provider) else { return nil }
            return Self.agent(provider: provider, usage: usage, hasRunningTask: (runningProviders[provider] ?? 0) > 0, now: now)
        }
    }

    private static func agent(provider: ConversationProvider, usage: AgentProviderUsage, hasRunningTask: Bool, now: Date) -> Agent {
        let identity = [usage.account, usage.plan].compactMap { $0 }
        var agent = Agent(
            provider: provider.rawValue,
            name: provider.displayName,
            icon: provider == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right",
            identity: identity.isEmpty ? nil : identity.joined(separator: " "),
            identityHelp: identity.isEmpty ? nil : identity.joined(separator: " · "),
            canSwitch: usage.loggedIn != nil,
            signedOut: usage.loggedIn == false,
            loginPending: usage.loginInProgress,
            hasUsage: false,
            windows: []
        )
        guard !agent.signedOut,
              let snapshot = usage.snapshot?.effective(now: now.timeIntervalSince1970),
              !snapshot.windows.isEmpty || snapshot.credits != nil else { return agent }
        agent.hasUsage = true
        agent.windows = snapshot.windows.map { window(provider: provider, $0, now: now) }
        agent.credits = snapshot.credits.flatMap(creditsText)
        if let status = snapshot.status, status != .allowed {
            agent.status = status == .rejected ? Status(text: "Limit reached", color: "red") : Status(text: "Near limit", color: "orange")
        }
        // Shown when the numbers are not being kept live by a running task.
        let age = now.timeIntervalSince1970 - snapshot.updatedAt
        if age > 120, !hasRunningTask {
            agent.updated = "Updated \(AgentUsageFormat.duration(age)) ago"
        }
        return agent
    }

    private static func window(provider: ConversationProvider, _ window: AgentUsageWindow, now: Date) -> Window {
        let percent = min(100, max(0, window.usedPercent ?? 0))
        let level = percent >= 100 ? "red" : percent >= AgentUsageSnapshot.warningPercent ? "orange" : nil
        let reset: String
        if window.isReset {
            reset = "Reset"
        } else if let resetsAt = window.resetsAt {
            reset = "Resets in \(AgentUsageFormat.duration(resetsAt - now.timeIntervalSince1970))"
        } else {
            reset = "Reset time unknown"
        }
        let help: String
        if let resetsAt = window.resetsAt {
            help = "\(window.label) resets \(Date(timeIntervalSince1970: resetsAt).formatted(date: .abbreviated, time: .shortened))"
        } else {
            help = window.isReset ? "\(window.label) window has reset" : window.label
        }
        return Window(
            id: window.id,
            label: window.label,
            percent: window.usedPercent == nil ? "–" : "\(Int(percent.rounded()))%",
            percentColor: level ?? "primary",
            fraction: percent / 100,
            barColor: level ?? "accent",
            reset: reset,
            help: help
        )
    }

    static func creditsText(_ credits: AgentUsageCredits) -> String? {
        if credits.unlimited { return "Credits: unlimited" }
        if let balance = credits.balance, !balance.isEmpty { return "Credits: \(balance)" }
        return credits.hasCredits ? "Credits available" : nil
    }
}

/// What the section's controls do, by provider id ("claude", "codex").
struct AgentsInfoActions {
    var login: (String) -> Void = { _ in }
    var switchAccount: (String) -> Void = { _ in }
}

/// The Agents info section's content, composed only of plugin atoms
/// (Plugins/Atoms), so a plugin building it from the same atoms looks
/// identical: one Panel per agent, then any error. The collapsible header is
/// the section's host's (`PluginSectionSlot`), or the Disclosure the
/// catalog's copy wraps it in; its views flatten into that container.
struct AgentsInfoSection: View {
    let model: AgentsInfoModel
    var actions = AgentsInfoActions()

    private var id: String { model.id }

    var body: some View {
        ForEach(model.agents, id: \.provider) { agent in
            block(agent)
        }
        if let message = model.errorMessage {
            AtomText(props: TextProps(text: message, size: 9, color: "red", lineLimit: 3), common: AtomCommon(testID: "\(id)-error"))
        }
    }

    private func block(_ agent: AgentsInfoModel.Agent) -> some View {
        let prefix = "\(id)-\(agent.provider)"
        return AtomPanel(props: PanelProps(spacing: 4), common: AtomCommon(testID: prefix, fillWidth: true, padding: 8)) {
            header(agent)
            if agent.signedOut {
                AtomStack(props: StackProps(axis: "v", spacing: 4, align: "leading")) {
                    if agent.loginPending {
                        AtomText(props: TextProps(text: "Waiting for sign-in…", size: 9, color: "secondary"), common: AtomCommon(testID: "\(prefix)-login-pending"))
                    }
                    AtomButton(
                        common: AtomCommon(testID: "\(id)-login-\(agent.provider)", label: "Log in to \(agent.name)", help: "Log in to \(agent.name)", fillWidth: true),
                        action: { actions.login(agent.provider) }
                    ) {
                        AtomPanel(props: PanelProps(fill: "accent", fillOpacity: 0.18, cornerRadius: 5), common: AtomCommon(fillWidth: true, padding: 3)) {
                            AtomStack(props: StackProps(axis: "h")) {
                                AtomSpacer(props: SpacerProps(minLength: 0))
                                AtomText(props: TextProps(text: "Log in", size: 10, weight: "medium"))
                                AtomSpacer(props: SpacerProps(minLength: 0))
                            }
                        }
                    }
                }
            } else if agent.hasUsage {
                ForEach(agent.windows, id: \.id) { window in
                    windowRow(window, prefix: prefix)
                }
                if let credits = agent.credits {
                    AtomText(props: TextProps(text: credits, size: 9, color: "secondary"), common: AtomCommon(testID: "\(prefix)-credits"))
                }
                if let status = agent.status {
                    AtomText(props: TextProps(text: status.text, size: 9, weight: "semibold", color: status.color), common: AtomCommon(testID: "\(prefix)-status"))
                }
                if let updated = agent.updated {
                    AtomText(props: TextProps(text: updated, size: 9, color: "tertiary"), common: AtomCommon(testID: "\(prefix)-updated"))
                }
            } else {
                AtomText(props: TextProps(text: "No data yet", size: 9, color: "secondary"), common: AtomCommon(testID: "\(prefix)-empty"))
            }
        }
    }

    private func header(_ agent: AgentsInfoModel.Agent) -> some View {
        AtomStack(props: StackProps(axis: "h", spacing: 5, align: "top")) {
            AtomIcon(props: IconProps(name: agent.icon, size: 9, weight: "semibold", color: "secondary"))
            AtomStack(props: StackProps(axis: "v", spacing: 1, align: "leading")) {
                AtomText(props: TextProps(text: agent.name, size: 11, weight: "semibold"))
                if let identity = agent.identity {
                    AtomText(
                        props: TextProps(text: identity, size: 9, color: "secondary", lineLimit: 1, truncation: "middle"),
                        common: AtomCommon(testID: "\(id)-\(agent.provider)-account", help: agent.identityHelp)
                    )
                }
            }
            AtomSpacer(props: SpacerProps(minLength: 0))
            if agent.canSwitch {
                AtomButton(
                    common: AtomCommon(testID: "\(id)-switch-\(agent.provider)", label: "Switch \(agent.name) account", help: "Switch \(agent.name) account", width: 16, height: 16),
                    action: { actions.switchAccount(agent.provider) }
                ) {
                    AtomIcon(props: IconProps(name: "person.2", size: 9, color: "secondary"))
                }
            }
        }
    }

    private func windowRow(_ window: AgentsInfoModel.Window, prefix: String) -> some View {
        AtomStack(
            props: StackProps(axis: "v", spacing: 2, align: "leading", combine: true),
            common: AtomCommon(testID: "\(prefix)-window-\(window.id)", help: window.help)
        ) {
            AtomStack(props: StackProps(axis: "h", spacing: 4)) {
                AtomText(props: TextProps(text: window.label, size: 10, lineLimit: 1))
                AtomSpacer(props: SpacerProps(minLength: 0))
                AtomText(props: TextProps(text: window.percent, size: 10, weight: "medium", color: window.percentColor, monospacedDigits: true))
            }
            AtomMeter(props: MeterProps(fraction: window.fraction, color: window.barColor))
            AtomText(props: TextProps(text: window.reset, size: 9, color: "secondary"))
        }
    }
}

enum AgentUsageFormat {
    /// "2h 14m", "3d 4h", "45m": the two largest units of a span, at least a minute.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.down)))
        let days = minutes / 1_440, hours = (minutes % 1_440) / 60, mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(mins)m"
    }
}
