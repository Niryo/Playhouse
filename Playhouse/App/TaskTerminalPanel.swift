import AppKit
import SwiftTerm
import SwiftUI

/// One task's shell. The session outlives the panel: hiding the panel keeps the shell and its
/// scrollback, and only closing the task's conversation (or restarting after an exit) ends it.
@MainActor
final class TaskTerminalSession: ObservableObject {
    @Published private(set) var launch: TaskTerminalLaunch?
    @Published private(set) var launchError: String?
    @Published private(set) var exitStatus: String?
    @Published private(set) var currentDirectory: String?
    private(set) var terminalView: PlayhouseTerminalView?
    private var processObserver: ProcessObserver?
    private(set) var taskID: UUID?

    var isRunning: Bool { terminalView?.process?.running == true }

    /// Starts the shell the first time the panel opens for this task; later calls reuse it.
    func startIfNeeded(taskID: UUID, workspaceManager: WorkspaceManager) {
        if self.taskID != taskID { terminate() }
        guard terminalView == nil else { return }
        self.taskID = taskID
        exitStatus = nil
        do {
            let launch = try workspaceManager.terminalLaunch(for: taskID)
            let view = PlayhouseTerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
            view.font = TerminalTheme.font
            view.optionAsMetaKey = false
            view.setAccessibilityIdentifier("task-terminal-view")
            let observer = ProcessObserver(session: self)
            view.processDelegate = observer
            var environment = ProcessInfo.processInfo.environment
            environment.merge(launch.environment) { _, playhouse in playhouse }
            view.startProcess(
                executable: launch.shell,
                args: launch.arguments,
                environment: environment.map { "\($0.key)=\($0.value)" },
                currentDirectory: launch.directory
            )
            processObserver = observer
            terminalView = view
            self.launch = launch
            currentDirectory = launch.directory
            launchError = nil
            PlayhouseDiagnostics.record("terminal.session.started", fields: [
                "taskID": taskID.uuidString,
                "directory": launch.directory,
                "shell": launch.shell
            ])
        } catch {
            launch = nil
            launchError = error.localizedDescription
        }
    }

    func restart(workspaceManager: WorkspaceManager) {
        guard let taskID else { return }
        terminate()
        startIfNeeded(taskID: taskID, workspaceManager: workspaceManager)
    }

    func terminate() {
        if isRunning { terminalView?.terminate() }
        terminalView?.processDelegate = nil
        terminalView?.removeFromSuperview()
        terminalView = nil
        processObserver = nil
        launch = nil
        currentDirectory = nil
    }

    fileprivate func processExited(_ source: TerminalView, code: Int32?) {
        // A shell replaced by Restart can report its exit after the new one started.
        guard source === terminalView else { return }
        exitStatus = code.map { "Shell exited with status \($0)." } ?? "Shell exited."
        if let taskID {
            PlayhouseDiagnostics.record("terminal.session.exited", fields: [
                "taskID": taskID.uuidString,
                "exitCode": code.map(String.init) ?? "unknown"
            ])
        }
    }

    fileprivate func directoryChanged(_ source: TerminalView, _ directory: String?) {
        guard source === terminalView, let directory, let url = URL(string: directory), url.isFileURL else { return }
        currentDirectory = url.path
    }

    /// SwiftTerm's delegate is a non-isolated protocol, so a small object relays its callbacks.
    private final class ProcessObserver: LocalProcessTerminalViewDelegate {
        weak var session: TaskTerminalSession?
        init(session: TaskTerminalSession) { self.session = session }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            Task { @MainActor [weak session] in session?.directoryChanged(source, directory) }
        }
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor [weak session] in session?.processExited(source, code: exitCode) }
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

/// The terminal panel that slides in from the right edge of a task's conversation.
struct TaskTerminalPanel: View {
    @ObservedObject var session: TaskTerminalSession
    let onRestart: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Terminal")
                    .font(.system(size: 13, weight: .semibold))
                    .accessibilityIdentifier("task-terminal-title")
                if let directory = session.currentDirectory {
                    Text(Self.abbreviated(directory))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .help(directory)
                        .accessibilityIdentifier("task-terminal-directory")
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .buttonHoverPointer()
                .nativeHelp("Hide the terminal")
                .accessibilityLabel("Hide terminal")
                .accessibilityIdentifier("close-terminal-button")
            }
            .padding(.horizontal, 14)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)

            if let launchError = session.launchError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.orange)
                    Text("Couldn't open a terminal")
                        .font(.system(size: 12, weight: .medium))
                    Text(launchError)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("task-terminal-error-message")
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("task-terminal-error")
            } else if let terminalView = session.terminalView {
                TerminalViewHost(view: terminalView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        if let exitStatus = session.exitStatus {
                            HStack(spacing: 10) {
                                Text(exitStatus)
                                    .font(.system(size: 11, weight: .medium))
                                    .accessibilityIdentifier("task-terminal-exit-status")
                                Spacer(minLength: 0)
                                Button("Restart", action: onRestart)
                                    .controlSize(.small)
                                    .buttonHoverPointer()
                                    .nativeHelp("Start a new shell in the task's folder")
                                    .accessibilityIdentifier("restart-terminal-button")
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.regularMaterial)
                        }
                    }
            }
        }
        // Clear profiles blur what lies behind their translucent background.
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("task-terminal-panel")
    }

    private static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// The look of macOS Terminal's built-in Clear Dark and Clear Light profiles: a slightly
/// translucent background over a blur, with soft, desaturated ANSI colors. It follows the
/// app's appearance between the two. Values are from the profiles Terminal.app ships in
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
                background: hex(0x212734), backgroundOpacity: 0.95,
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
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}
