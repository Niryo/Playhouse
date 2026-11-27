import AppKit
import SwiftTerm
import SwiftUI
import PlayhouseCore
import PlayhouseViews
import PlayhouseAtoms
import PlayhouseUI

/// One task's shells: one pane per created repository worktree, so a multi-repository task opens
/// a split view. The session outlives the panel: hiding the panel keeps the shells and their
/// scrollback, and only closing the task's conversation (or restarting after an exit) ends them.
@MainActor
@Observable
final class TaskTerminalSession {
    private(set) var panes: [TaskTerminalPane] = []
    private(set) var launchError: String?
    private(set) var taskID: UUID?

    /// Starts the shells the first time the panel opens for this task. Later calls reuse running
    /// shells, open a pane for a worktree created since, and close the pane of a worktree the
    /// task no longer has.
    func startIfNeeded(taskID: UUID, workspaceManager: WorkspaceManager) {
        if self.taskID != taskID { terminate() }
        self.taskID = taskID
        do {
            let launch = try workspaceManager.terminalLaunch(for: taskID)
            launchError = nil
            sync(launch)
        } catch {
            // Shells already running stay open, and a pane left without one closes; the error
            // replaces the panes only once none runs.
            guard !panes.contains(where: \.isRunning) else {
                panes.removeAll { $0.terminalView == nil }
                return
            }
            terminate()
            launchError = error.localizedDescription
        }
    }

    private func sync(_ launch: TaskTerminalLaunch) {
        let existing = panes
        for pane in existing where !launch.panes.contains(where: { $0.directory == pane.directory }) {
            pane.terminate()
        }
        panes = launch.panes.map { spec in
            let pane = existing.first { $0.directory == spec.directory } ?? TaskTerminalPane(spec, taskID: launch.taskID)
            if pane.terminalView == nil { pane.start(launch) }
            return pane
        }
    }

    /// Starts every pane again from a fresh launch, as Try Again after a launch error does.
    func restart(workspaceManager: WorkspaceManager) {
        guard let taskID else { return }
        terminate()
        startIfNeeded(taskID: taskID, workspaceManager: workspaceManager)
    }

    /// Starts a new shell in one pane's worktree, leaving the other panes' shells running.
    func restart(_ pane: TaskTerminalPane, workspaceManager: WorkspaceManager) {
        guard let taskID else { return }
        pane.terminate()
        startIfNeeded(taskID: taskID, workspaceManager: workspaceManager)
    }

    func terminate() {
        panes.forEach { $0.terminate() }
        panes = []
    }
}

/// One shell in the terminal panel, running in one repository worktree.
@MainActor
@Observable
final class TaskTerminalPane: Identifiable {
    let repositoryPath: String
    let name: String
    /// The worktree the shell starts in, which identifies the pane across launches.
    let directory: String
    let taskID: UUID
    private(set) var exitStatus: String?
    private(set) var currentDirectory: String?
    private(set) var terminalView: PlayhouseTerminalView?
    @ObservationIgnored private var processObserver: ProcessObserver?

    nonisolated var id: String { directory }
    var isRunning: Bool { terminalView?.process?.running == true }

    init(_ spec: TaskTerminalLaunch.Pane, taskID: UUID) {
        repositoryPath = spec.repositoryPath
        name = spec.name
        directory = spec.directory
        self.taskID = taskID
    }

    fileprivate func start(_ launch: TaskTerminalLaunch) {
        let view = PlayhouseTerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        view.font = TerminalTheme.font
        view.optionAsMetaKey = false
        view.setAccessibilityIdentifier("task-terminal-view")
        let observer = ProcessObserver(pane: self)
        view.processDelegate = observer
        var environment = ProcessInfo.processInfo.environment
        environment.merge(launch.environment) { _, playhouse in playhouse }
        view.startProcess(
            executable: launch.shell,
            args: launch.arguments,
            environment: environment.map { "\($0.key)=\($0.value)" },
            currentDirectory: directory
        )
        processObserver = observer
        terminalView = view
        exitStatus = nil
        currentDirectory = directory
        PlayhouseDiagnostics.record("terminal.session.started", fields: [
            "taskID": taskID.uuidString,
            "directory": directory,
            "shell": launch.shell
        ])
    }

    fileprivate func terminate() {
        if isRunning { terminalView?.terminate() }
        terminalView?.processDelegate = nil
        terminalView?.removeFromSuperview()
        terminalView = nil
        processObserver = nil
        currentDirectory = nil
    }

    fileprivate func processExited(_ source: TerminalView, code: Int32?) {
        // A shell replaced by Restart can report its exit after the new one started.
        guard source === terminalView else { return }
        exitStatus = code.map { "Shell exited with status \($0)." } ?? "Shell exited."
        PlayhouseDiagnostics.record("terminal.session.exited", fields: [
            "taskID": taskID.uuidString,
            "directory": directory,
            "exitCode": code.map(String.init) ?? "unknown"
        ])
    }

    fileprivate func directoryChanged(_ source: TerminalView, _ directory: String?) {
        guard source === terminalView, let directory, let url = URL(string: directory), url.isFileURL else { return }
        currentDirectory = url.path
    }

    /// SwiftTerm's delegate is a non-isolated protocol, so a small object relays its callbacks.
    private final class ProcessObserver: LocalProcessTerminalViewDelegate {
        weak var pane: TaskTerminalPane?
        init(pane: TaskTerminalPane) { self.pane = pane }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            Task { @MainActor [weak pane] in pane?.directoryChanged(source, directory) }
        }
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor [weak pane] in pane?.processExited(source, code: exitCode) }
        }
    }
}

/// SwiftTerm draws its grid without exposing it to accessibility on macOS, so the view
/// reports itself as a text area whose value is the scrollback and screen text.
final class PlayhouseTerminalView: LocalProcessTerminalView {
    /// The theme last applied, so appearance updates only reinstall colors when they change.
    var theme: TerminalTheme?

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Terminal" }
    override func accessibilityValue() -> Any? { logicalText() }

    /// The buffer as the lines the shell wrote: rows the terminal soft-wrapped at its width
    /// are joined back, so a long line reads as one line rather than screen-width pieces.
    private func logicalText() -> String {
        let terminal = getTerminal()
        var lines: [String] = []
        var row = terminal.buffer.totalLinesTrimmed
        while let line = terminal.getScrollInvariantLine(row: row) {
            let continues = terminal.getScrollInvariantLine(row: row + 1)?.isWrapped == true
            let text = line.translateToString(trimRight: !continues)
            if line.isWrapped, !lines.isEmpty {
                lines[lines.count - 1] += text
            } else {
                lines.append(text)
            }
            row += 1
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
/// The terminal panel that slides in from the right edge of a task's conversation. A task with
/// several repository worktrees shows one shell per worktree, stacked in a resizable split view.
struct TaskTerminalPanel: View {
    var session: TaskTerminalSession
    let onRestart: () -> Void
    let onRestartPane: (TaskTerminalPane) -> Void
    let onClose: () -> Void

    var body: some View {
        // Clear profiles blur what lies behind their translucent background.
        AtomStack(props: StackProps(spacing: 0, group: true, material: "ultraThin"), common: AtomCommon(testID: "task-terminal-panel")) {
            AtomStack(props: StackProps(axis: "h", spacing: 8), common: AtomCommon(paddingX: 14, paddingTop: 16, paddingBottom: 10)) {
                AtomIcon(props: IconProps(name: PHIcon.terminal.name, size: 11, weight: "semibold", color: "secondary"))
                AtomText(props: TextProps(text: "Terminal", size: 13, weight: "semibold"), common: AtomCommon(testID: "task-terminal-title"))
                if session.panes.count == 1, let pane = session.panes.first {
                    TerminalPaneDirectory(pane: pane)
                }
                AtomSpacer(props: SpacerProps(minLength: 0))
                AtomButton(
                    common: AtomCommon(testID: "close-terminal-button", label: "Hide terminal", help: "Hide the terminal", width: 24, height: 24),
                    action: onClose
                ) {
                    AtomIcon(props: IconProps(name: PHIcon.xmark.name, size: 11, weight: "medium"))
                }
            }

            AtomStack(props: StackProps(fill: "primary", fillOpacity: 0.07), common: AtomCommon(height: 1, fillWidth: true)) {
                PHEmptyView()
            }

            if let launchError = session.launchError {
                AtomStack(
                    props: StackProps(spacing: 8, group: true),
                    common: AtomCommon(testID: "task-terminal-error", fillWidth: true, fillHeight: true, frameAlign: "center", paddingX: 16, paddingY: 16)
                ) {
                    AtomIcon(props: IconProps(name: PHIcon.exclamationmarkTriangleFill.name, size: 18, color: "orange"))
                    AtomText(props: TextProps(text: "Couldn't open a terminal", size: 12, weight: "medium"))
                    AtomText(props: TextProps(text: launchError, size: 11, color: "secondary", align: "center"), common: AtomCommon(testID: "task-terminal-error-message"))
                    AtomButton(
                        props: ButtonProps(style: "automatic", controlSize: "small"),
                        common: AtomCommon(testID: "retry-terminal-button", help: "Try opening the terminal again"),
                        action: onRestart
                    ) {
                        AtomText(props: TextProps(text: "Try Again"))
                    }
                }
            } else if session.panes.count == 1, let pane = session.panes.first {
                TerminalPaneView(pane: pane, showsHeader: false, focusesOnAttach: true) { onRestartPane(pane) }
            } else if !session.panes.isEmpty {
                AtomStack(props: StackProps(group: true), common: AtomCommon(testID: "task-terminal-split")) {
                    // The split view itself stays native: no atom divides its room between resizable panes.
                    VSplitView {
                        ForEach(session.panes) { pane in
                            AtomStack(common: AtomCommon(minHeight: Double(TerminalPanelLayout.minimumPaneHeight), fillHeight: true, frameAlign: "center")) {
                                TerminalPaneView(pane: pane, showsHeader: true, focusesOnAttach: pane === session.panes.first) {
                                    onRestartPane(pane)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A pane's current folder, abbreviated against the home folder.
private struct TerminalPaneDirectory: View {
    var pane: TaskTerminalPane

    var body: some View {
        if let directory = pane.currentDirectory {
            AtomText(
                props: TextProps(text: Self.abbreviated(directory), size: 11, color: "secondary", lineLimit: 1, truncation: "head"),
                common: AtomCommon(testID: "task-terminal-directory", help: directory)
            )
        }
    }

    private static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// One worktree's shell; in a split view it carries a header naming its repository.
private struct TerminalPaneView: View {
    var pane: TaskTerminalPane
    let showsHeader: Bool
    let focusesOnAttach: Bool
    let onRestart: () -> Void

    var body: some View {
        AtomStack(props: StackProps(spacing: 0, group: true), common: AtomCommon(testID: "task-terminal-pane", label: pane.name)) {
            if showsHeader {
                AtomStack(props: StackProps(axis: "h", spacing: 6, fill: "primary", fillOpacity: 0.04), common: AtomCommon(paddingX: 12, paddingY: 5)) {
                    AtomIcon(props: IconProps(name: PHIcon.folder.name, size: 10, weight: "medium", color: "secondary"))
                    AtomText(props: TextProps(text: pane.name, size: 11, weight: "semibold", lineLimit: 1), common: AtomCommon(testID: "task-terminal-pane-name"))
                    TerminalPaneDirectory(pane: pane)
                    AtomSpacer(props: SpacerProps(minLength: 0))
                }
            }
            if let terminalView = pane.terminalView {
                // The terminal itself stays native, framed by a Stack; an exited shell's bar sits over its bottom.
                AtomStack(props: StackProps(axis: "z", align: "bottom")) {
                    AtomStack(common: AtomCommon(fillWidth: true, fillHeight: true, frameAlign: "center")) {
                        TerminalViewHost(view: terminalView, focusesOnAttach: focusesOnAttach)
                    }
                    if let exitStatus = pane.exitStatus {
                        AtomStack(props: StackProps(axis: "h", spacing: 10, material: "regular"), common: AtomCommon(paddingX: 12, paddingY: 8)) {
                            AtomText(props: TextProps(text: exitStatus, size: 11, weight: "medium"), common: AtomCommon(testID: "task-terminal-exit-status"))
                            AtomSpacer(props: SpacerProps(minLength: 0))
                            AtomButton(
                                props: ButtonProps(style: "automatic", controlSize: "small"),
                                common: AtomCommon(testID: "restart-terminal-button", help: "Start a new shell in this worktree"),
                                action: onRestart
                            ) {
                                AtomText(props: TextProps(text: "Restart"))
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The look of macOS Terminal's built-in Clear Dark and Clear Light profiles: soft,
/// desaturated ANSI colors, following the app's appearance between the two. Dark uses a solid
/// black background in place of Clear Dark's translucent slate; light keeps Clear Light's
/// translucent white over a blur. Values are from the profiles Terminal.app ships in
/// Contents/Resources/Initial Settings.
struct TerminalTheme: Equatable {
    let foreground: NSColor
    let background: NSColor
    /// Only the default background is translucent; text and colored cells stay opaque.
    let backgroundOpacity: CGFloat
    let cursor: NSColor
    let selection: NSColor
    let ansi: [NSColor]

    /// Terminal.app's profile font: the system monospaced face (SF Mono) at 12 points.
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    static func terminalClear(dark: Bool) -> TerminalTheme {
        dark
            ? TerminalTheme(
                foreground: hex(0xE6E6E6),
                background: hex(0x000000), backgroundOpacity: 1,
                cursor: hex(0xE6E6E6), selection: hex(0x334E5E),
                ansi: [
                    0x35424C, 0xB45648, 0x6CAA71, 0xC4AC62, 0x6D96B4, 0xBD7BCD, 0x7CCBCD, 0xDEE5EB,
                    0x465C6D, 0xDF6C5A, 0x79BE7E, 0xE5C872, 0x67B5ED, 0xD389E5, 0x84DDE0, 0xE5EFF5
                ].map(hex)
            )
            : TerminalTheme(
                foreground: hex(0x3A4851),
                background: hex(0xFFFFFF), backgroundOpacity: 0.93,
                cursor: hex(0x919191), selection: hex(0xE5ECF1),
                ansi: [
                    0x2D3840, 0xB45648, 0x6CAA71, 0xC4AC62, 0x5685A8, 0xAD64BE, 0x69C6C9, 0xC1C8CC,
                    0x506573, 0xDF6C5A, 0x79BE7E, 0xE5C872, 0x49A2E1, 0xD389E5, 0x77E1E5, 0xD8E1E7
                ].map(hex)
            )
    }

    func apply(to view: TerminalView) {
        view.installColors(ansi.map { color in
            let rgb = color.usingColorSpace(.sRGB) ?? color
            return Color(
                red: UInt16(rgb.redComponent * 65535),
                green: UInt16(rgb.greenComponent * 65535),
                blue: UInt16(rgb.blueComponent * 65535)
            )
        })
        view.nativeForegroundColor = foreground
        view.nativeBackgroundColor = background.withAlphaComponent(backgroundOpacity)
        view.caretColor = cursor
        view.selectedTextBackgroundColor = selection
    }

    private static func hex(_ value: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Hosts the session's long-lived terminal view, so hiding and reshowing the panel
/// reattaches the same shell instead of starting a new one.
private struct TerminalViewHost: NSViewRepresentable {
    let view: PlayhouseTerminalView
    /// Opening the panel focuses one shell: the only one, or the split's first.
    let focusesOnAttach: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container { attach(to: container) }
        let theme = TerminalTheme.terminalClear(dark: colorScheme == .dark)
        // The inset around the grid shares the terminal's translucent background.
        container.layer?.backgroundColor = theme.background.withAlphaComponent(theme.backgroundOpacity).cgColor
        if view.theme != theme {
            theme.apply(to: view)
            view.theme = theme
        }
    }

    private func attach(to container: NSView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        // Opening the panel is a request to type in it.
        guard focusesOnAttach else { return }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}
