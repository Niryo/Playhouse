import AppKit
import SwiftUI
import PlayhouseCore
import PlayhouseViews
import PlayhouseAtoms
import PlayhouseUI

/// The window's side of updates. The daemon's `UpdateManager` checks, downloads
/// and starts the installer; this asks it to, shows where it is, and quits the
/// app when the installer asks so the bundle can be replaced.
@MainActor
@Observable
final class UpdateController {
    private(set) var status: UpdateStatus?
    /// What the last install did, shown once after the app restarts.
    private(set) var notice: UpdateInstallRecord?
    private(set) var isWorking = false
    private(set) var lastError: String?

    @ObservationIgnored let client: DaemonClient
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var quitObserver: NSObjectProtocol?

    /// How often the window asks the daemon to run its scheduled check, which
    /// reaches the network at most once a day.
    static let checkInterval: Duration = .seconds(60 * 60)
    /// How often the window follows an update that is waiting for agents or
    /// installing; the daemon does the work either way.
    static let followInterval: Duration = .seconds(2)

    init(client: DaemonClient) {
        self.client = client
    }

    var isRelease: Bool { status.map { $0.phase != "development" && $0.phase != "misplaced" } ?? false }

    func start() {
        guard loop == nil else { return }
        quitObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(PlayhouseRelease.quitNotification),
            object: PlayhouseRelease.realPath(Bundle.main.bundlePath),
            queue: .main
        ) { _ in
            // Terminating defers to the delegate, whose reply runs on the main
            // queue; quitting from inside this main-queue block would wait on
            // itself, so the run loop starts it once the block returns.
            MainActor.assumeIsolated {
                Platform.services.terminateApp()
            }
        }
        loop = Task { [weak self] in
            await self?.reportLaunched()
            // The first check after launch always asks the feed; the hourly ones after it
            // reach the network at most once a day.
            var atLaunch = true
            while !Task.isCancelled {
                guard let self else { return }
                if self.isRelease {
                    await self.run("update.check", ["kind": .string(atLaunch ? "launch" : "automatic")], quietly: true)
                    atLaunch = false
                }
                // An install the previous version started finishes after this
                // launch, so its result arrives a little later.
                if self.isFollowing {
                    await self.follow()
                    continue
                }
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        installWatch?.cancel()
        if let quitObserver { DistributedNotificationCenter.default().removeObserver(quitObserver) }
        quitObserver = nil
    }

    func checkNow() async {
        await run("update.check", ["kind": .string("manual")])
    }

    /// The notice was opened or dismissed; the daemon stops offering it.
    func dismissNotice() async {
        notice = nil
        await run("update.dismiss-notice", [:], quietly: true)
    }

    /// Stops the download the pill started; the release stays offered.
    func cancelDownload() async {
        do {
            status = try await client.call("update.cancel").decoded(UpdateStatus.self)
        } catch {
            await fail(error)
        }
    }

    /// The pill's action: download if needed, then restart into the new
    /// version as soon as no agent is running a turn.
    func update() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        lastError = nil
        if status?.phase != "ready" {
            do {
                let value = try await client.call("update.download") { [weak self] event in
                    guard event.type == "update_progress", let progress = event.payload.object?["progress"]?.double else { return }
                    self?.status?.phase = "downloading"
                    self?.status?.progress = progress
                }
                status = try value.decoded(UpdateStatus.self)
            } catch let error as BridgeCommandError where error.code == "update_cancelled" {
                await run("update.status", [:], quietly: true)
                return
            } catch {
                await fail(error)
                return
            }
        }
        await install(whenIdle: true)
    }

    /// Restarts into the downloaded version now; running agents keep working
    /// and the new version reattaches them.
    func restartNow() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await install(whenIdle: false)
    }

    private func install(whenIdle: Bool) async {
        do {
            let value = try await client.call("update.install", ["whenIdle": .boolean(whenIdle)])
            let result = value.object ?? [:]
            if let next = try? result["status"]?.decoded(UpdateStatus.self) { status = next }
            watchInstall()
        } catch {
            await fail(error)
        }
    }

    private var isFollowing: Bool { status?.phase == "waiting" || status?.phase == "installing" }

    private var installWatch: Task<Void, Never>?

    /// The daemon installs a waiting update once agents finish, and normally
    /// the installer quits this app. When it can't get that far (the download
    /// fails its last check) or installs somewhere else, the result arrives
    /// while this window is still open.
    private func watchInstall() {
        installWatch?.cancel()
        installWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isFollowing else { return }
                await self.follow()
            }
        }
    }

    private func follow() async {
        try? await Task.sleep(for: Self.followInterval)
        guard !Task.isCancelled else { return }
        if status?.phase == "waiting" {
            await run("update.status", [:], quietly: true)
        } else {
            await reportLaunched()
        }
    }

    private func reportLaunched() async {
        do {
            let value = try await client.call("update.launched")
            let next = try value.decoded(UpdateStatus.self)
            status = next
            if let record = next.lastInstall { notice = record }
        } catch {
            PlayhouseDiagnostics.record("update.launched_failed", fields: PlayhouseDiagnostics.errorFields(error))
        }
    }

    private func run(_ command: String, _ arguments: [String: BridgeValue], quietly: Bool = false) async {
        do {
            let value = try await client.call(command, arguments)
            status = try value.decoded(UpdateStatus.self)
            if !quietly { lastError = nil }
        } catch {
            if quietly {
                PlayhouseDiagnostics.record("\(command).failed", fields: PlayhouseDiagnostics.errorFields(error))
            } else {
                await fail(error)
            }
        }
    }

    private func fail(_ error: Error) async {
        lastError = error.localizedDescription
        if let value = try? await client.call("update.status"), let next = try? value.decoded(UpdateStatus.self) {
            status = next
        }
    }
}

/// The update button at the trailing end of the main window's title bar, built
/// from the plugin atoms. Hidden on development builds and when there is nothing to say.
struct UpdatePill: View {
    @Environment(UpdateController.self) private var updates

    var body: some View {
        if let notice = updates.notice {
            noticePill(notice)
        } else if let status = updates.status, let release = status.available, status.phase != "development" {
            actionPill(status: status, release: release)
        }
    }

    @ViewBuilder
    private func actionPill(status: UpdateStatus, release: ReleaseInfo) -> some View {
        let state = pillState(status: status, release: release)
        AtomButton(
            props: ButtonProps(disabled: state.disabled),
            common: AtomCommon(testID: "update-pill", label: state.title, value: status.phase, help: state.help),
            action: state.action
        ) {
            AtomStack(props: StackProps(axis: "h", spacing: 5)) {
                if state.busy {
                    // The spinner's own (empty) value would replace the button's phase.
                    AtomSpinner(props: SpinnerProps(size: "mini"))
                        .accessibilityHidden(true)
                }
                AtomText(props: TextProps(
                    text: state.text ?? state.title,
                    size: 12,
                    weight: "medium",
                    color: state.prominent ? "white" : nil,
                    lineLimit: 1,
                    monospacedDigits: true
                ))
            }
            .modifier(TitlebarPillChrome(tint: state.prominent ? WorkspaceTheme.accent : .secondary, filled: state.prominent))
        }
    }

    private struct PillState {
        /// The accessibility label; also the visible text unless `text` is set.
        var title: String
        var text: String?
        var help: String
        var prominent = true
        var busy = false
        var disabled = false
        var action: () -> Void = {}
    }

    private func pillState(status: UpdateStatus, release: ReleaseInfo) -> PillState {
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let released = release.publishedDay.map { ", released \($0)" } ?? ""
        let summary = "Playhouse \(release.version)\(released)" + (notes.isEmpty ? "" : "\n\n\(notes)")
        switch status.phase {
        case "waiting":
            return PillState(
                title: "Restart to update",
                help: "Playhouse \(release.version) is downloaded. \(Self.waitReason(status)), so Playhouse restarts by itself when \(Self.waitEnd(status)). Click to restart now; running agents keep working.",
                disabled: updates.isWorking,
                action: { Task { await updates.restartNow() } }
            )
        case "downloading":
            let percent = Int(((status.progress ?? 0) * 100).rounded())
            return PillState(
                title: "Downloading \(percent)%",
                help: "Downloading Playhouse \(release.version) in the background. Click to cancel.",
                prominent: false,
                busy: true,
                action: { Task { await updates.cancelDownload() } }
            )
        case "installing":
            return PillState(title: "Updating…", help: "Installing Playhouse \(release.version). Playhouse restarts when it's done.", prominent: false, busy: true, disabled: true)
        case "failed":
            return PillState(
                title: "Update failed",
                help: "\(status.error ?? updates.lastError ?? "The update didn't finish.")\n\nClick to try again.",
                prominent: false,
                disabled: updates.isWorking,
                action: { Task { await updates.update() } }
            )
        case "ready":
            return PillState(
                title: "Restart to update",
                help: "Playhouse \(release.version) is downloaded. Click to restart into it once no agent is running.",
                busy: updates.isWorking,
                disabled: updates.isWorking,
                action: { Task { await updates.update() } }
            )
        default:
            return PillState(
                title: "Update to \(release.version)",
                text: "Update",
                help: summary,
                busy: updates.isWorking,
                disabled: updates.isWorking,
                action: { Task { await updates.update() } }
            )
        }
    }

    /// Why a downloaded update is waiting, as a sentence's start such as "1 agent is still working".
    static func waitReason(_ status: UpdateStatus) -> String {
        var reasons: [String] = []
        let turns = status.activeTurns ?? 0
        let drafts = status.unsentDrafts ?? 0
        if turns > 0 { reasons.append(turns == 1 ? "1 agent is still working" : "\(turns) agents are still working") }
        if drafts > 0 { reasons.append(drafts == 1 ? "a message is being written" : "\(drafts) messages are being written") }
        let reason = reasons.isEmpty ? "agents are still working" : reasons.joined(separator: " and ")
        return reason.prefix(1).uppercased() + reason.dropFirst()
    }

    private static func waitEnd(_ status: UpdateStatus) -> String {
        let turns = status.activeTurns ?? 0
        let drafts = status.unsentDrafts ?? 0
        let minutes = Int(BoardTaskManager.draftWritingInterval / 60)
        if drafts > 0 && turns == 0 { return "no message has been edited for \(minutes) minutes" }
        if drafts > 0 { return "agents finish and no message has been edited for \(minutes) minutes" }
        return "they finish"
    }

    @State private var showsNotes = false

    private func noticePill(_ record: UpdateInstallRecord) -> some View {
        let installed = record.status == "installed"
        let title = installed ? "Updated to \(record.toVersion)" : "Update didn't install"
        let help = installed
            ? "Playhouse was updated from \(record.fromVersion) to \(record.toVersion). Click to see what's new."
            : "\(record.message ?? "The update didn't install.") Click to dismiss."
        return AtomButton(
            props: ButtonProps(),
            common: AtomCommon(testID: "update-notice", label: title, value: record.status, help: help),
            action: {
                if installed {
                    showsNotes = true
                } else {
                    Task { await updates.dismissNotice() }
                }
            }
        ) {
            AtomLabel(props: LabelProps(
                text: title,
                icon: installed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                size: 12,
                weight: "medium",
                color: installed ? "green" : "orange"
            ))
            .modifier(TitlebarPillChrome(tint: installed ? .green : .orange, filled: false))
        }
        .popover(isPresented: $showsNotes, arrowEdge: .bottom) {
            ReleaseNotesView(record: record)
        }
        .onChange(of: showsNotes) { _, shown in
            // Opening the notes is what the notice was for; it doesn't come back.
            if !shown { Task { await updates.dismissNotice() } }
        }
    }
}

/// The title-bar pill's quiet rounded capsule: a muted fill of `tint` for the
/// offer, a faint wash for status text, each a shade stronger on hover.
private struct TitlebarPillChrome: ViewModifier {
    let tint: Color
    let filled: Bool
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 9)
            .frame(height: 21)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(filled ? (isHovering ? 0.62 : 0.48) : (isHovering ? 0.2 : 0.12)))
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// What's new in the version Playhouse just updated to.
private struct ReleaseNotesView: View {
    let record: UpdateInstallRecord

    var body: some View {
        let notes = record.notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        VStack(alignment: .leading, spacing: 8) {
            Text("What's new in Playhouse \(record.toVersion)")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityIdentifier("update-notes-title")
            ScrollView {
                Text(notes.isEmpty ? "This release has no notes." : notes)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("update-notes-body")
                    .hoverRevealScrollers()
            }
            .frame(maxHeight: 240)
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// Settings → Updates.
struct UpdateSettingsSection: View {
    @Environment(UpdateController.self) private var updates

    var body: some View {
        Section("Updates") {
            if let status = updates.status, status.phase == "misplaced" {
                Text(PlayhouseRelease.moveToApplicationsMessage)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("update-settings-summary")
            } else if let status = updates.status, status.phase != "development" {
                HStack {
                    Text("Playhouse \(status.currentVersion)")
                        .accessibilityIdentifier("update-current-version")
                    Spacer()
                    Button("Check Now") { Task { await updates.checkNow() } }
                        .buttonHoverPointer()
                        .nativeHelp("Check GitHub for a newer Playhouse release")
                        .disabled(updates.isWorking)
                        .accessibilityIdentifier("update-check-now-button")
                }
                Text(summary(status))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("update-settings-summary")
            } else {
                Text("This is a development build. It updates from source, not from releases.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("update-settings-summary")
            }
        }
    }

    private func summary(_ status: UpdateStatus) -> String {
        if let error = updates.lastError ?? status.error { return error }
        if let release = status.available { return "Playhouse \(release.version) is available." }
        guard let checked = status.lastCheckedAt else { return "Not checked yet." }
        return "Up to date. Last checked \(checked.formatted(date: .abbreviated, time: .shortened))."
    }
}

/// Puts the update pill at the trailing end of its window's title bar, on the
/// window's top border rather than among the board's own buttons.
struct UpdateTitlebarAccessory: NSViewRepresentable {
    let updates: UpdateController
    let preferences: UserDefaults

    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        anchor.install = { window in context.coordinator.install(in: window, updates: updates, preferences: preferences) }
        return anchor
    }

    func updateNSView(_ nsView: Anchor, context: Context) {}

    static func dismantleNSView(_ nsView: Anchor, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Installs the accessory once it is in a window.
    final class Anchor: NSView {
        var install: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { install?(window) }
        }
    }

    @MainActor
    final class Coordinator {
        private static let identifier = NSUserInterfaceItemIdentifier("update-titlebar-accessory")
        private var accessory: NSTitlebarAccessoryViewController?

        func install(in window: NSWindow, updates: UpdateController, preferences: UserDefaults) {
            guard accessory == nil else { return }
            // A rebuilt window root replaces the accessory its predecessor left, so
            // the window has one, and that predecessor's removal can't take it away.
            for stale in window.titlebarAccessoryViewControllers where stale.identifier == Self.identifier {
                stale.removeFromParent()
            }
            let host = NSHostingView(rootView: AnyView(EmptyView()))
            host.sizingOptions = [.intrinsicContentSize]
            let controller = NSTitlebarAccessoryViewController()
            controller.identifier = Self.identifier
            controller.layoutAttribute = .trailing
            controller.view = host
            // The title bar sizes a trailing accessory by its frame, so the frame
            // follows the pill's own width as its text changes or it hides; the pill
            // takes that width rather than shrinking to the frame it is given. The
            // host is its own SwiftUI root, so it gets the window content's environment here.
            host.rootView = AnyView(
                UpdatePill()
                    .fixedSize(horizontal: true, vertical: false)
                    .environment(updates)
                    .tint(WorkspaceTheme.accent)
                    .padding(.trailing, 10)
                    .frame(maxHeight: .infinity)
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { [weak host] width in
                        host?.setFrameSize(NSSize(width: width, height: host?.frame.height ?? 0))
                    }
                    .atomHighlightRoot()
                    .defaultAppStorage(preferences)
            )
            window.addTitlebarAccessoryViewController(controller)
            accessory = controller
        }

        func remove() {
            accessory?.removeFromParent()
            accessory = nil
        }
    }
}
