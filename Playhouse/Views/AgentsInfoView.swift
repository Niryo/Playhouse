import Foundation
import Observation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// The window's feed of the daemon's usage store, for the board sidebar's
/// bottom plugins (`props.agents.usage`). The daemon owns the providers and
/// receives their pushes, so this reads its state over the bridge once, then
/// follows the store's changes as the providers push them or the daemon
/// refreshes them periodically. A plugin asks for a fresh read itself
/// (`usage.get` with refresh, as the Agents info plugin does on `app.launched`).
@MainActor
@Observable
package final class AgentUsageModel {
    /// The report as `usage.get` returns it, nil before the first read.
    package private(set) var usage: PluginValue?
    @ObservationIgnored private var report: AgentUsageReport?
    @ObservationIgnored package let client: DaemonClient
    @ObservationIgnored private var loop: Task<Void, Never>?

    package init(client: DaemonClient) {
        self.client = client
    }

    /// Reads once, then follows the daemon's changes; reconnects if the daemon
    /// goes away. The daemon refreshes while the subscription is open.
    package func start() {
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
    package func stop() {
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
package struct BoardSidebarBottomSlot: PHView {
    /// Tasks running per provider.
    package let runningProviders: [ConversationProvider: Int]
    package let appearance: String
    package let actions: PluginUIActions
    package let add: (PluginPlacement) -> Void
    /// App-wide, so returning to the board shows what is known instead of reading again.
    @PHEnvironment(AgentUsageModel.self) private var usage
    @PHEnvironment(PluginRegistry.self) private var registry

    package var body: some PHView {
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

    package init(runningProviders: [ConversationProvider: Int], appearance: String, actions: PluginUIActions, add: @escaping (PluginPlacement) -> Void) {
        self.runningProviders = runningProviders
        self.appearance = appearance
        self.actions = actions
        self.add = add
    }
}

/// What the Agents info section shows, already derived from the usage
/// report at one moment: plain values the native section and the catalog's
/// JavaScript copy (catalog/AgentsInfo.js, as `Playhouse.props.agentsInfo`)
/// compose the same way. `id` prefixes every
/// accessibility identifier ("agents-info" on the board).
package struct AgentsInfoModel: Codable, Equatable {
    /// One usage window row: its label and percent, the bar, and when it resets.
    package struct Window: Codable, Equatable {
        package var id: String
        package var label: String
        /// "22%", or "–" when the provider reported no percent.
        package var percent: String
        package var percentColor: String
        /// 0...1.
        package var fraction: Double
        package var barColor: String
        package var reset: String
        package var help: String

        package init(id: String, label: String, percent: String, percentColor: String, fraction: Double, barColor: String, reset: String, help: String) {
            self.id = id
            self.label = label
            self.percent = percent
            self.percentColor = percentColor
            self.fraction = fraction
            self.barColor = barColor
            self.reset = reset
            self.help = help
        }
    }

    package struct Status: Codable, Equatable {
        package var text: String
        package var color: String

        package init(text: String, color: String) {
            self.text = text
            self.color = color
        }
    }

    /// One agent's block, top to bottom: the header, then either the Log in
    /// button, the usage rows, or "No data yet".
    package struct Agent: Codable, Equatable {
        package var provider: String
        package var name: String
        package var icon: String
        /// The account and plan on the row beneath the name.
        package var identity: String?
        package var identityHelp: String?
        package var canSwitch: Bool
        package var signedOut: Bool
        package var loginPending: Bool
        package var hasUsage: Bool
        package var windows: [Window]
        package var credits: String?
        package var status: Status?
        package var updated: String?

        package init(provider: String, name: String, icon: String, identity: String? = nil, identityHelp: String? = nil, canSwitch: Bool, signedOut: Bool, loginPending: Bool, hasUsage: Bool, windows: [Window], credits: String? = nil, status: Status? = nil, updated: String? = nil) {
            self.provider = provider
            self.name = name
            self.icon = icon
            self.identity = identity
            self.identityHelp = identityHelp
            self.canSwitch = canSwitch
            self.signedOut = signedOut
            self.loginPending = loginPending
            self.hasUsage = hasUsage
            self.windows = windows
            self.credits = credits
            self.status = status
            self.updated = updated
        }
    }

    package var id: String
    package var title: String
    package var agents: [Agent]
    package var errorMessage: String?

    package init(id: String, title: String, agents: [Agent], errorMessage: String? = nil) {
        self.id = id
        self.title = title
        self.agents = agents
        self.errorMessage = errorMessage
    }
}

extension AgentsInfoModel {
    /// Providers whose CLI is installed, in display order; none until the first read.
    package static func visibleProviders(_ report: AgentUsageReport?) -> [AgentProviderUsage] {
        guard let report else { return [] }
        return [ConversationProvider.claude, .codex, .opencode].compactMap { provider in
            report.providers.first { $0.provider == provider.rawValue && $0.installed }
        }
    }

    package init(report: AgentUsageReport?, runningProviders: [ConversationProvider: Int], errorMessage: String?, now: Date) {
        id = "agents-info"
        title = "Agents info"
        self.errorMessage = errorMessage
        agents = Self.visibleProviders(report).compactMap { usage in
            guard let provider = ConversationProvider(rawValue: usage.provider) else { return nil }
            return Self.agent(provider: provider, usage: usage, hasRunningTask: (runningProviders[provider] ?? 0) > 0, now: now)
        }
    }

    private static func icon(_ provider: ConversationProvider) -> String {
        switch provider {
        case .claude: PHIcon.sparkle.name
        case .codex: PHIcon.chevronLeftForwardslashChevronRight.name
        case .opencode: PHIcon.squareDashedInsetFilled.name
        }
    }

    private static func agent(provider: ConversationProvider, usage: AgentProviderUsage, hasRunningTask: Bool, now: Date) -> Agent {
        let identity = [usage.account, usage.plan].compactMap { $0 }
        var agent = Agent(
            provider: provider.rawValue,
            name: provider.displayName,
            icon: icon(provider),
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

    package static func creditsText(_ credits: AgentUsageCredits) -> String? {
        if credits.unlimited { return "Credits: unlimited" }
        if let balance = credits.balance, !balance.isEmpty { return "Credits: \(balance)" }
        return credits.hasCredits ? "Credits available" : nil
    }
}

/// What the section's controls do, by provider id ("claude", "codex").
package struct AgentsInfoActions {
    package var login: (String) -> Void = { _ in }
    package var switchAccount: (String) -> Void = { _ in }

    package init(login: @escaping (String) -> Void = { _ in }, switchAccount: @escaping (String) -> Void = { _ in }) {
        self.login = login
        self.switchAccount = switchAccount
    }
}

/// The Agents info section's content, composed only of plugin atoms
/// (Plugins/Atoms), so a plugin building it from the same atoms looks
/// identical: one Panel per agent, then any error. The collapsible header is
/// the section's host's (`PluginSectionSlot`), or the Disclosure the
/// catalog's copy wraps it in; its views flatten into that container.
package struct AgentsInfoSection: PHView {
    package let model: AgentsInfoModel
    package var actions = AgentsInfoActions()

    private var id: String { model.id }

    package var body: some PHView {
        PHForEach(model.agents, id: \.provider) { agent in
            block(agent)
        }
        if let message = model.errorMessage {
            AtomText(props: TextProps(text: message, size: 9, color: "red", lineLimit: 3), common: AtomCommon(testID: "\(id)-error"))
        }
    }

    private func block(_ agent: AgentsInfoModel.Agent) -> some PHView {
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
                PHForEach(agent.windows, id: \.id) { window in
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

    private func header(_ agent: AgentsInfoModel.Agent) -> some PHView {
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
                    AtomIcon(props: IconProps(name: PHIcon.personTwo.name, size: 9, color: "secondary"))
                }
            }
        }
    }

    private func windowRow(_ window: AgentsInfoModel.Window, prefix: String) -> some PHView {
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

    package init(model: AgentsInfoModel, actions: AgentsInfoActions = AgentsInfoActions()) {
        self.model = model
        self.actions = actions
    }
}

package enum AgentUsageFormat {
    /// "2h 14m", "3d 4h", "45m": the two largest units of a span, at least a minute.
    package static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded(.down)))
        let days = minutes / 1_440, hours = (minutes % 1_440) / 60, mins = minutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h" }
        return "\(mins)m"
    }
}
