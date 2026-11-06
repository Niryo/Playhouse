import AppKit
import SwiftUI

/// The window's view of the daemon's usage store. The daemon owns the
/// providers and receives their pushes, so this reads its state over the bridge:
/// once with a refresh at launch and after a login (Codex's snapshot and both
/// accounts' sign-in state), then follows the store's changes as the providers
/// push them. Nothing here asks a provider, or the daemon, on a timer.
@MainActor
final class AgentUsageModel: ObservableObject {
    @Published private(set) var report: AgentUsageReport?
    @Published private(set) var errorMessage: String?
    let client: DaemonClient
    private var loop: Task<Void, Never>?

    init(client: DaemonClient) {
        self.client = client
    }

    /// Reads once with a refresh, then follows the daemon's changes; reconnects
    /// if the daemon goes away. Nothing is asked of the providers after that.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.load(refresh: true)
            var reconnecting = false
            while !Task.isCancelled {
                guard let self else { return }
                // A daemon that restarted knows nothing until a read loads its
                // saved state, so read once before following it again.
                if reconnecting { await self.load(refresh: false) }
                reconnecting = true
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

    /// Only a changed report re-renders the section.
    private func apply(_ next: AgentUsageReport) {
        var comparable = next
        comparable.generatedAt = report?.generatedAt ?? next.generatedAt
        if comparable != report { report = next }
    }

    func load(refresh: Bool) async {
        guard let value = try? await client.call("usage.get", ["refresh": .boolean(refresh)]),
              let next = try? value.decoded(AgentUsageReport.self) else { return }
        apply(next)
    }

    func login(_ provider: ConversationProvider) async {
        await run(command: "usage.login", provider: provider)
    }

    func switchAccount(_ provider: ConversationProvider) async {
        await run(command: "usage.switch-account", provider: provider)
    }

    /// Starts the sign-in, opens Codex's URL, and re-reads the account while the
    /// daemon waits for the browser step to finish.
    private func run(command: String, provider: ConversationProvider) async {
        errorMessage = nil
        do {
            let value = try await client.call(command, ["provider": .string(provider.rawValue)])
            // A test build never opens a browser.
            if let link = value.object?["loginURL"]?.string, let url = URL(string: link),
               !BridgeContract.isTestBundle(PlayhouseAppIdentity.applicationIdentifier) {
                NSWorkspace.shared.open(url)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        await load(refresh: true)
    }
}

struct AgentsInfoView: View {
    /// App-wide, so returning to the board shows what is known instead of reading again.
    @EnvironmentObject private var model: AgentUsageModel
    /// Providers that have a task running, which a sign-out would affect.
    let runningProviders: [ConversationProvider: Int]
    @State private var providerAwaitingSwitch: ConversationProvider?
    /// Whether the user minimized the section; one value kept across launches, open by default.
    @AppStorage(WorkspaceSettings.agentsInfoSectionCollapsedKey, store: WorkspaceSettings.preferencesStore) private var isCollapsed = false

    init(runningProviders: [ConversationProvider: Int]) {
        self.runningProviders = runningProviders
    }

    /// Providers whose CLI is installed, in display order; none until the first read.
    private var visibleProviders: [AgentProviderUsage] {
        guard let report = model.report else { return [] }
        return [ConversationProvider.claude, .codex].compactMap { provider in
            report.providers.first { $0.provider == provider.rawValue && $0.installed }
        }
    }

    var body: some View {
        // A stack, not a Group: the load below has to run while there is nothing to show yet.
        VStack(spacing: 0) {
            if !visibleProviders.isEmpty {
                // Re-evaluated on a slow tick so reset times and "updated" hints stay current.
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.22)) { isCollapsed.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .accessibilityHidden(true)
                                Text("Agents info")
                                    .font(.system(size: 10, weight: .semibold))
                                    .textCase(.uppercase)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .buttonHoverPointer()
                        .nativeHelp(isCollapsed ? "Expand Agents info" : "Collapse Agents info")
                        .accessibilityLabel("Agents info")
                        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("agents-info-toggle")
                        if !isCollapsed {
                            ForEach(visibleProviders, id: \.provider) { usage in
                                if let provider = ConversationProvider(rawValue: usage.provider) {
                                    AgentUsageBlock(
                                        provider: provider,
                                        usage: usage,
                                        now: timeline.date,
                                        hasRunningTask: (runningProviders[provider] ?? 0) > 0,
                                        onLogin: { Task { await model.login(provider) } },
                                        onSwitch: {
                                            if (runningProviders[provider] ?? 0) > 0 { providerAwaitingSwitch = provider }
                                            else { Task { await model.switchAccount(provider) } }
                                        }
                                    )
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                                }
                            }
                            if let message = model.errorMessage {
                                Text(message)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.red)
                                    .lineLimit(3)
                                    .accessibilityIdentifier("agents-info-error")
                            }
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("agents-info")
            }
        }
        .task { model.start() }
        .confirmationDialog(
            "Switch \(providerAwaitingSwitch?.displayName ?? "") account?",
            isPresented: Binding(get: { providerAwaitingSwitch != nil }, set: { if !$0 { providerAwaitingSwitch = nil } }),
            titleVisibility: .visible
        ) {
            Button("Switch Account", role: .destructive) {
                guard let provider = providerAwaitingSwitch else { return }
                providerAwaitingSwitch = nil
                Task { await model.switchAccount(provider) }
            }
            .buttonHoverPointer()
            .nativeHelp("Sign out and sign in again")
            Button("Cancel", role: .cancel) { providerAwaitingSwitch = nil }
                .buttonHoverPointer()
                .nativeHelp("Keep the current account")
        } message: {
            let count = providerAwaitingSwitch.flatMap { runningProviders[$0] } ?? 0
            Text("\(count) \(providerAwaitingSwitch?.displayName ?? "") task\(count == 1 ? " is" : "s are") running. Signing out affects running tasks.")
        }
    }
}

private struct AgentUsageBlock: View {
    let provider: ConversationProvider
    let usage: AgentProviderUsage
    let now: Date
    let hasRunningTask: Bool
    let onLogin: () -> Void
    let onSwitch: () -> Void

    private var snapshot: AgentUsageSnapshot? { usage.snapshot?.effective(now: now.timeIntervalSince1970) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if usage.loggedIn == false {
                signedOut
            } else if let snapshot, !snapshot.windows.isEmpty || snapshot.credits != nil {
                ForEach(snapshot.windows, id: \.id) { window in
                    WindowRow(provider: provider, window: window, status: snapshot.status, now: now)
                }
                if let credits = snapshot.credits, let text = Self.creditsText(credits) {
                    Text(text)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("agents-info-\(provider.rawValue)-credits")
                }
                if let status = snapshot.status, status != .allowed {
                    Text(status == .rejected ? "Limit reached" : "Near limit")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(status == .rejected ? Color.red : Color.orange)
                        .accessibilityIdentifier("agents-info-\(provider.rawValue)-status")
                }
                if let hint = staleHint(snapshot) {
                    Text(hint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .accessibilityIdentifier("agents-info-\(provider.rawValue)-updated")
                }
            } else {
                Text(provider == .claude ? "No data yet. Updates while a task runs." : "No data yet")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agents-info-\(provider.rawValue)-empty")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agents-info-\(provider.rawValue)")
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: provider == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(provider.displayName)
                .font(.system(size: 11, weight: .semibold))
            if let identity = [usage.account, usage.plan].compactMap({ $0 }).first {
                Text(identity)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .nativeHelp([usage.account, usage.plan].compactMap { $0 }.joined(separator: " · "))
                    .accessibilityIdentifier("agents-info-\(provider.rawValue)-account")
            }
            Spacer(minLength: 0)
            if usage.loggedIn != nil {
                Button(action: onSwitch) {
                    Image(systemName: "person.2")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .buttonHoverPointer()
                .nativeHelp("Switch \(provider.displayName) account")
                .accessibilityLabel("Switch \(provider.displayName) account")
                .accessibilityIdentifier("agents-info-switch-\(provider.rawValue)")
            }
        }
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 4) {
            if usage.loginInProgress {
                Text("Waiting for sign-in…")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("agents-info-\(provider.rawValue)-login-pending")
            }
            Button(action: onLogin) {
                Text("Log in")
                    .font(.system(size: 10, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .buttonHoverPointer()
            .nativeHelp("Log in to \(provider.displayName)")
            .accessibilityLabel("Log in to \(provider.displayName)")
            .accessibilityIdentifier("agents-info-login-\(provider.rawValue)")
        }
    }

    /// Shown when the numbers are not being kept live by a running task.
    private func staleHint(_ snapshot: AgentUsageSnapshot) -> String? {
        let age = now.timeIntervalSince1970 - snapshot.updatedAt
        guard age > 120, !hasRunningTask else { return nil }
        return "Updated \(AgentUsageFormat.duration(age)) ago"
    }

    static func creditsText(_ credits: AgentUsageCredits) -> String? {
        if credits.unlimited { return "Credits: unlimited" }
        if let balance = credits.balance, !balance.isEmpty { return "Credits: \(balance)" }
        return credits.hasCredits ? "Credits available" : nil
    }
}

private struct WindowRow: View {
    let provider: ConversationProvider
    let window: AgentUsageWindow
    let status: AgentUsageStatus?
    let now: Date

    private var percent: Double { min(100, max(0, window.usedPercent ?? 0)) }

    private var tint: Color {
        if percent >= 100 { return .red }
        if percent >= AgentUsageSnapshot.warningPercent { return .orange }
        return .accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(window.label)
                    .font(.system(size: 10))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(window.usedPercent == nil ? "–" : "\(Int(percent.rounded()))%")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(percent >= 100 ? Color.red : percent >= AgentUsageSnapshot.warningPercent ? Color.orange : Color.primary)
            }
            // Drawn rather than a ProgressView: an AppKit progress indicator per row
            // makes every accessibility query of the window slow.
            Capsule()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(tint).frame(width: proxy.size.width * percent / 100)
                    }
                }
                .accessibilityHidden(true)
            Text(resetText)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .nativeHelp(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agents-info-\(provider.rawValue)-window-\(window.id)")
    }

    private var resetText: String {
        if window.isReset { return "Reset" }
        guard let resetsAt = window.resetsAt else { return "Reset time unknown" }
        return "Resets in \(AgentUsageFormat.duration(resetsAt - now.timeIntervalSince1970))"
    }

    private var tooltip: String {
        guard let resetsAt = window.resetsAt else { return window.isReset ? "\(window.label) window has reset" : window.label }
        let formatted = Date(timeIntervalSince1970: resetsAt).formatted(date: .abbreviated, time: .shortened)
        return "\(window.label) resets \(formatted)"
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
