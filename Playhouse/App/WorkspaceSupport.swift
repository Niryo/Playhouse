import AppKit
import Darwin
import Foundation
import OSLog
import SwiftUI

/// Shows `cursor` while the pointer is over the view, keeping the cursor stack balanced:
/// repeated hover events are ignored, and a view that disappears under the pointer pops it.
private struct HoverCursor: ViewModifier {
    let cursor: NSCursor
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .onHover { isInside in
                guard isInside != isHovering else { return }
                isHovering = isInside
                if isInside {
                    cursor.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                if isHovering {
                    NSCursor.pop()
                    isHovering = false
                }
            }
    }
}

extension View {
    func buttonHoverPointer() -> some View {
        hoverCursor(.pointingHand)
    }

    func hoverCursor(_ cursor: NSCursor) -> some View {
        modifier(HoverCursor(cursor: cursor))
    }
}

private struct ActionButtonHoverEmphasis: ViewModifier {
    @State private var isHovering = false
    var padding: CGFloat = 4

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                Capsule()
                    .fill(Color.accentColor.opacity(isHovering ? 0.14 : 0))
            }
            .scaleEffect(isHovering ? 1.06 : 1)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

/// A native AppKit tooltip for `text`, carried by a click-through view behind the content.
/// SwiftUI's `.help` alone never presented a tooltip for most of the main window's controls (the
/// board header and the Done panel among them); an `NSView` with its own `toolTip` does.
private struct NativeToolTip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = ClickThroughView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if nsView.toolTip != text { nsView.toolTip = text }
    }

    private final class ClickThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func isAccessibilityElement() -> Bool { false }
    }
}

extension View {
    /// `.help` that reliably shows a native tooltip on macOS; keeps `.help` for accessibility.
    func nativeHelp(_ text: String) -> some View {
        // Hidden from accessibility so the extra view cannot become, or resize, the control's element.
        help(text).background(NativeToolTip(text: text).accessibilityHidden(true))
    }
}

extension View {
    func actionButtonHoverEmphasis(padding: CGFloat = 4) -> some View {
        modifier(ActionButtonHoverEmphasis(padding: padding))
    }
}

enum WorkspaceSettings {
    static let defaultParentFolderKey = "defaultWorkspaceParentFolderPath"
    static let lastSelectedRepositoriesKey = "lastSelectedRepositories"
    static let recentRepositoriesKey = "recentRepositories"
    /// How many recently selected repositories are remembered and offered by the repository picker.
    static let recentRepositoryHistoryLimit = 20
    static let appearanceKey = "appearance"
    /// Whether the task view's sidebar is hidden to a narrow rail; one value shared by every task.
    static let taskSidebarCollapsedKey = "taskSidebarCollapsed"
    /// Whether the Changes section inside the task sidebar is collapsed; one value shared by every task.
    static let workspaceChangesSectionCollapsedKey = "workspaceChangesSectionCollapsed"
    /// Whether the Agents info section at the bottom of the board sidebar is minimized.
    static let agentsInfoSectionCollapsedKey = "agentsInfoSectionCollapsed"
    static let defaultConversationProviderKey = "defaultConversationProvider"
    static let tokenUsageColorMaxKey = "tokenUsageColorMax"
    static let defaultTokenUsageColorMax = TokenUsageHeatmap.defaultColorMax
    static let cpuUsageColorMaxKey = "cpuUsageColorMax"
    static let defaultCPUUsageColorMax = CPUUsageHeatmap.defaultColorMax
    /// Automatic context compaction settings shared by Claude and Codex task sessions.
    static let autoCompactionEnabledKey = "autoCompactionEnabled"
    static let autoCompactionThresholdKey = "autoCompactionThresholdTokens"
    static let autoCompactionIdleMinutesKey = "autoCompactionIdleMinutes"
    static let autoCompactionMinimumKey = "autoCompactionMinimumTokens"
    /// Add Plugin mode: the window shows "Add here" placeholders at every plugin placement.
    static let pluginAddModeKey = "pluginAddMode"
    /// Bumped whenever the plugins folder changes (`plugin refresh`, `plugin delete`), so
    /// the window reloads its installed plugins.
    static let pluginsRevisionKey = "pluginsRevision"

    static var preferencesStore: UserDefaults {
        #if DEBUG
        if let suiteName = PlayhouseProcessEnvironment.current["PLAYHOUSE_E2E_DEFAULTS_SUITE"],
           let suite = UserDefaults(suiteName: suiteName) {
            return suite
        }
        #endif
        return .standard
    }

    static func validDirectoryURL(for path: String) -> URL? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }
}

enum WorkspaceTheme {
    static let windowBackground = adaptive(dark: (0x1E, 0x1E, 0x1E), light: .windowBackgroundColor)
    static let panelBackground = adaptive(dark: (0x25, 0x25, 0x26), light: .controlBackgroundColor)
    static let inputBackground = adaptive(dark: (0x3C, 0x3C, 0x3C), light: .textBackgroundColor)
    static let conversationText = adaptive(dark: (0xC5, 0xC5, 0xC5), light: .labelColor)
    static let accent = Color(nsColor: NSColor(srgbRed: 0, green: 122.0 / 255.0, blue: 204.0 / 255.0, alpha: 1))

    private static func adaptive(dark: (UInt8, UInt8, UInt8), light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua else { return light }
            return NSColor(
                srgbRed: CGFloat(dark.0) / 255,
                green: CGFloat(dark.1) / 255,
                blue: CGFloat(dark.2) / 255,
                alpha: 1
            )
        })
    }
}

struct ConversationWorkspaceContext {
    let roots: [URL]
    let cwd: URL
    /// The skill folders each provider needs passed so it sees the whole
    /// gallery. Only a turn's own launch sets it.
    var skillBridge: SkillBridgeLaunch?
    /// The rule files each provider is handed or told to skip. Only a turn's own launch sets it.
    var ruleBridge: RuleBridgeLaunch?
    /// The MCP servers each provider is passed or told to skip. Only a turn's own launch sets it.
    var mcpBridge: McpBridgeLaunch?
    /// A side chat's turns may read the workspace and run the Playhouse CLI but never
    /// change files (see `SideChatReadOnlyPolicy`): Codex runs them in its read-only sandbox,
    /// whose CLI calls the daemon limits to board requests, and Claude Code, which has no
    /// sandbox, checks every tool call in a hook that runs before the user's own allow rules.
    /// MCP tools stay available on both providers, as Codex's sandbox does not cover them.
    var isReadOnly = false
    /// The auto-compact window Claude Code is launched with, in tokens; nil
    /// leaves Claude Code's own default. Only a task turn's own launch sets it.
    var claudeAutoCompactWindowTokens: Int?

    /// One Codex thread config joining what skills and MCP servers each need.
    var codexThreadConfig: [String: Any]? {
        var config = skillBridge?.codexThreadConfig ?? [:]
        if let servers = mcpBridge?.codexServers { config["mcp_servers"] = servers }
        return config.isEmpty ? nil : config
    }

    init(roots: [URL]) throws {
        let normalized = roots.map(\.standardizedFileURL)
        guard normalized.allSatisfy({ WorkspaceSettings.validDirectoryURL(for: $0.path) != nil }) else {
            throw WorkspaceError.unavailableRoot
        }
        let uniqueRoots = Array(NSOrderedSet(array: normalized.map(\.path))).compactMap {
            ($0 as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        self.roots = uniqueRoots
        if let firstRoot = uniqueRoots.first {
            cwd = firstRoot
        } else {
            cwd = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        }
    }
}

enum WorkspaceError: LocalizedError {
    case unavailableRoot

    var errorDescription: String? {
        switch self {
        case .unavailableRoot:
            "One or more working folders are unavailable. Edit the task folders and try again."
        }
    }
}


enum RepositoryScanner {
    static func scan(parent: URL) async -> [URL] {
        await Task.detached(priority: .utility) {
            scanSynchronously(parent: parent)
        }.value
    }

    static func scanSynchronously(parent: URL) -> [URL] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = manager.enumerator(
                at: parent,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [],
                errorHandler: { _, _ in true }
              ) else { return [] }

        let markerAtParent = parent.appendingPathComponent(".git", isDirectory: false)
        if manager.fileExists(atPath: markerAtParent.path) {
            return [parent.standardizedFileURL]
        }

        var repositories: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isDirectory == true else { continue }

            let marker = url.appendingPathComponent(".git", isDirectory: false)
            if manager.fileExists(atPath: marker.path) {
                repositories.append(url.standardizedFileURL)
                enumerator.skipDescendants()
            }
        }
        return repositories.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}

/// The environment work should run with. The bridge daemon scopes each request
/// to its caller's environment (`BridgeRequest.environment`) for the life of
/// that request's task, including across suspension points while other requests
/// interleave on the main actor. Outside a request, such as in the GUI app, this
/// is simply this process's own environment.
enum PlayhouseProcessEnvironment {
    @TaskLocal static var requestEnvironment: [String: String]?

    static var current: [String: String] {
        requestEnvironment ?? ProcessInfo.processInfo.environment
    }
}

/// One bridge request's diagnostics routing. A single daemon process serves
/// requests for different stores, so each request keeps its own store-directory
/// selection (as each XPC service process once had), and records it makes
/// before choosing that directory wait for it instead of landing elsewhere.
/// Only touched on the main actor.
final class PlayhouseDiagnosticsScope: @unchecked Sendable {
    let id = UUID()
    var directoryOverride: URL?
    var awaitingDirectory = true
}

/// What a request's background work needs to keep behaving as part of that
/// request after the request has returned: its environment and its diagnostics
/// scope. `Task.detached` doesn't inherit task-local values.
struct PlayhouseRequestContext: Sendable {
    @TaskLocal static var diagnosticsScope: PlayhouseDiagnosticsScope?

    let environment: [String: String]?
    let scope: PlayhouseDiagnosticsScope?

    @MainActor static func capture() -> PlayhouseRequestContext {
        PlayhouseRequestContext(environment: PlayhouseProcessEnvironment.requestEnvironment, scope: diagnosticsScope)
    }

    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await PlayhouseProcessEnvironment.$requestEnvironment.withValue(environment) {
            try await Self.$diagnosticsScope.withValue(scope) {
                try await operation()
            }
        }
    }
}

enum PlayhouseAppIdentity {
    static var applicationIdentifier: String {
        Bundle.main.infoDictionary?["PlayhouseApplicationBundleIdentifier"] as? String
            ?? Bundle.main.bundleIdentifier ?? ""
    }

    static var isTestBundle: Bool {
        BridgeContract.isTestBundle(applicationIdentifier)
    }

    static var worktreeKey: String? {
        let prefix = "com.playhouse.app.worktree."
        guard applicationIdentifier.hasPrefix(prefix) else { return nil }
        let remainder = String(applicationIdentifier.dropFirst(prefix.count))
        let key = String(remainder.prefix(17))
        guard key.count == 17, key.first == "w",
              key.dropFirst().allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        let suffix = remainder.dropFirst(key.count)
        guard suffix.isEmpty || (isTestBundle && suffix.hasPrefix(".e2e.")) else { return nil }
        return key
    }

    static func defaultDataDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Playhouse", isDirectory: true)
        guard let worktreeKey else { return support }
        return support.appendingPathComponent("Worktrees", isDirectory: true)
            .appendingPathComponent(worktreeKey, isDirectory: true)
    }
}


struct WorkspaceRootSelector: View {
    let parentFolderURL: URL?
    @Binding var roots: [URL]
    var displayNames: [String: String] = [:]
    @State private var repositories: [URL] = []
    @State private var searchText = ""
    @State private var isScanning = false

    private var filteredRepositories: [URL] {
        let available = repositories.filter { candidate in
            !roots.contains(where: { $0.standardizedFileURL.path == candidate.standardizedFileURL.path })
        }
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return available }
        let query = searchText.lowercased()
        return available.filter {
            $0.lastPathComponent.lowercased().contains(query) || $0.path.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Working folders")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: browseForFolders) {
                    Label("Browse…", systemImage: "folder")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonHoverPointer()
                .nativeHelp("Browse folders")
                .buttonStyle(.bordered)
                .accessibilityIdentifier("browse-workspace-roots-button")
            }

            if roots.isEmpty {
                Text("Choose one or more folders. Git repositories under your parent folder appear as suggestions.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 7) {
                    ForEach(roots, id: \.standardizedFileURL.path) { root in
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 10))
                            Text(displayNames[root.standardizedFileURL.path] ?? (root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent))
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Button {
                                roots.removeAll { $0.standardizedFileURL.path == root.standardizedFileURL.path }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                            }
                            .buttonHoverPointer()
                            .buttonStyle(.plain)
                            .nativeHelp("Remove \(displayNames[root.standardizedFileURL.path] ?? root.path)")
                            .accessibilityLabel("Remove \(displayNames[root.standardizedFileURL.path] ?? root.lastPathComponent)")
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                    }
                }
            }

            TextField("Search suggested repositories…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("workspace-repository-search")

            if isScanning {
                ProgressView("Finding Git repositories…")
                    .controlSize(.small)
                    .font(.system(size: 11))
            } else if filteredRepositories.isEmpty {
                Text(parentFolderURL == nil ? "Choose a default parent folder in Settings to see repository suggestions." : "No matching repositories. Browse to add any folder.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredRepositories, id: \.path) { repository in
                            Button {
                                add(repository)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repository.lastPathComponent)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Text(repository.path)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonHoverPointer()
                            .nativeHelp("Add repository \(repository.lastPathComponent)")
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("repository-suggestion-\(repository.lastPathComponent)")
                        }
                    }
                    .hoverRevealScrollers()
                }
                .frame(maxHeight: 142)
                .background(WorkspaceTheme.panelBackground.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task(id: parentFolderURL?.path) {
            guard let parentFolderURL else {
                repositories = []
                return
            }
            isScanning = true
            repositories = (try? await WorkspaceManager().suggestedRepositories(parentPath: parentFolderURL.path).map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }) ?? []
            isScanning = false
        }
    }

    private func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !roots.contains(where: { $0.standardizedFileURL.path == path }) else { return }
        roots.append(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func browseForFolders() {
        let panel = NSOpenPanel()
        panel.title = "Choose working folders"
        panel.message = "Choose one or more folders Codex should use as task context."
        panel.prompt = "Add Folders"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = parentFolderURL
        panel.begin { response in
            guard response == .OK else { return }
            DispatchQueue.main.async {
                panel.urls.forEach(add)
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(maxWidth, x), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
