import AppKit
import SwiftData
import SwiftUI

@main
struct PlayhouseApp: App {
    @NSApplicationDelegateAdaptor(PlayhouseApplicationDelegate.self) private var applicationDelegate
    private let modelContainer: ModelContainer
    private let appPreferences: UserDefaults
    @StateObject private var conversationRuntime: ConversationRuntimeModel
    @StateObject private var cpuUsageModel: TaskCPUUsageModel
    @StateObject private var agentUsageModel = AgentUsageModel(client: DaemonClient())
    @State private var pluginRegistry = PluginRegistry()

    private var windowTitle: String {
        let configuredTitle = ProcessInfo.processInfo.environment["PLAYHOUSE_WINDOW_TITLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let configuredTitle, !configuredTitle.isEmpty { return configuredTitle }
        let label = ProcessInfo.processInfo.environment["PLAYHOUSE_WORKTREE_LABEL"]
            .flatMap { $0.isEmpty ? nil : $0 }
        return label.map { "Playhouse — \($0)" } ?? "Playhouse"
    }

    init() {
        let environment = ProcessInfo.processInfo.environment
        let runtime = ConversationRuntimeModel(client: DaemonClient())
        _conversationRuntime = StateObject(wrappedValue: runtime)
        let cpuUsage = TaskCPUUsageModel(client: DaemonClient())
        _cpuUsageModel = StateObject(wrappedValue: cpuUsage)
        // The bridge daemon owns every provider turn, so quitting the window
        // doesn't stop one; it just stops watching.
        PlayhouseApplicationDelegate.terminationHandler = { [weak runtime, weak cpuUsage] in
            runtime?.stop()
            cpuUsage?.stop()
        }
        #if DEBUG
        if let suiteName = environment["PLAYHOUSE_E2E_DEFAULTS_SUITE"],
           let isolatedPreferences = UserDefaults(suiteName: suiteName) {
            appPreferences = isolatedPreferences
            if let parentPath = environment["PLAYHOUSE_E2E_DEFAULT_PARENT_FOLDER"] {
                let configuredPath = parentPath == "__unset__" ? "" : parentPath
                isolatedPreferences.set(configuredPath, forKey: WorkspaceSettings.defaultParentFolderKey)
            }
        } else {
            appPreferences = .standard
        }
        #else
        appPreferences = .standard
        #endif

        do {
            modelContainer = try PlayhouseStore.makeContainer(
                dataDirectory: ProcessInfo.processInfo.environment["PLAYHOUSE_DATA_DIRECTORY"]
            )
        } catch {
            fatalError("Couldn't open the Playhouse task store: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        Window(windowTitle, id: "main") {
            mainWindowContent
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Search Tasks") {
                    NotificationCenter.default.post(name: .playhouseShowBoardSearch, object: nil)
                }
                .buttonHoverPointer()
                .help("Search tasks")
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandMenu("Plugins") { PluginsMenuContent(registry: pluginRegistry) }
            CommandMenu("Debug") {
                DebugConversationImportMenu(modelContainer: modelContainer) // DEBUG-IMPORT:
                #if DEBUG
                AtomHighlightMenuItem()
                    .defaultAppStorage(appPreferences)
                #endif
            }
        }

        Window("Plugin Catalog", id: "plugin-catalog") {
            PluginCatalogView()
                .atomHighlightRoot()
                .defaultAppStorage(appPreferences)
        }
        .defaultSize(width: 1000, height: 760)

        Settings {
            WorkspaceSettingsView()
                .defaultAppStorage(appPreferences)
        }
    }

    private var mainWindowContent: some View {
        MainWindowView()
            .modelContainer(modelContainer)
            .environmentObject(conversationRuntime)
            .environment(\.conversationRuntimeModel, conversationRuntime)
            .environmentObject(cpuUsageModel)
            .environmentObject(agentUsageModel)
            .environment(pluginRegistry)
            .atomHighlightRoot()
            .defaultAppStorage(appPreferences)
    }
}

extension Notification.Name {
    static let playhouseShowBoardSearch = Notification.Name("playhouseShowBoardSearch")
}

@MainActor
private final class PlayhouseApplicationDelegate: NSObject, NSApplicationDelegate {
    static var terminationHandler: (() async -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Monaco loads once per session, so the first diff opens into a warm editor.
        MonacoDiffWebViewHost.shared.prewarm()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let terminationHandler = Self.terminationHandler else { return .terminateNow }
        Task {
            await terminationHandler()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct MainWindowView: View {
    @AppStorage(WorkspaceSettings.appearanceKey, store: WorkspaceSettings.preferencesStore) private var appearance = "dark"
    @AppStorage(WorkspaceSettings.pluginAddModeKey, store: WorkspaceSettings.preferencesStore) private var isPluginAddModeOn = false
    @AppStorage(WorkspaceSettings.pluginsRevisionKey, store: WorkspaceSettings.preferencesStore) private var pluginsRevision = 0
    @Environment(PluginRegistry.self) private var pluginRegistry
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var conversationRuntime: ConversationRuntimeModel
    @EnvironmentObject private var cpuUsageModel: TaskCPUUsageModel
    @State private var lifecycleError: String?
    @State private var isLifecycleReady = false

    var body: some View {
        VStack(spacing: 0) {
            if isPluginAddModeOn, isLifecycleReady {
                PluginModeBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content
        }
        .animation(.easeInOut(duration: 0.2), value: isPluginAddModeOn)
        .task(id: pluginsRevision) { await pluginRegistry.reload() }
    }

    private var content: some View {
        Group {
            if isLifecycleReady {
                KanbanBoardView()
            } else if let lifecycleError {
                ContentUnavailableView(
                    "Couldn't prepare Playhouse",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(lifecycleError)
                )
            } else {
                ProgressView("Preparing Playhouse…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(WorkspaceTheme.accent)
        .preferredColorScheme(appearance == "light" ? .light : .dark)
        .task {
            guard !isLifecycleReady else { return }
            do {
                try await PlayhouseStore.prepareLifecycle(
                    container: modelContext.container,
                    dataDirectory: ProcessInfo.processInfo.environment["PLAYHOUSE_DATA_DIRECTORY"]
                )
                conversationRuntime.start()
                cpuUsageModel.start()
                isLifecycleReady = true
            } catch {
                lifecycleError = error.localizedDescription
            }
        }
    }
}

/// The app menu's Plugins menu: Add Plugin mode, the Plugin Catalog, the
/// built-in plugins with Enable or Disable, and each installed plugin with its
/// placement, its first error, Enable or Disable, and Delete. A built-in
/// plugin is compiled into the app, so it can't be edited or deleted.
struct PluginsMenuContent: View {
    let registry: PluginRegistry
    @Environment(\.openWindow) private var openWindow
    @AppStorage(WorkspaceSettings.pluginAddModeKey, store: WorkspaceSettings.preferencesStore) private var isAddModeOn = false

    var body: some View {
        Toggle("Add Plugin Mode", isOn: Binding(get: { isAddModeOn }, set: { PluginRegistry.setAddMode($0) }))
            .help("Show where a new plugin's button can go")
        Button("Plugin Catalog") { openWindow(id: "plugin-catalog") }
            .buttonHoverPointer()
            .help("Open the Plugin Catalog")
        if !registry.builtInPlugins.isEmpty {
            Divider()
            Section("Built-in Plugins") {
                ForEach(registry.builtInPlugins) { plugin in
                    Menu {
                        enableButton(plugin)
                    } label: {
                        pluginLabel(plugin)
                    }
                        // no-pointer: native submenu triggers use AppKit's menu tracking and cursor.
                        // no-tooltip: the plugin name, placement and submenu chevron already identify this action.
                }
            }
        }
        if !registry.installedPlugins.isEmpty {
            Divider()
            Section("Installed Plugins") {
                ForEach(registry.installedPlugins) { plugin in
                    Menu {
                        if let problem = plugin.errors.first {
                            Text(problem)
                        }
                        enableButton(plugin)
                        Button("Edit…") { edit(plugin.id) }
                            // no-pointer: native submenu actions use AppKit's menu tracking and cursor.
                            .help("Open this plugin's editor")
                        Button("Delete…") { confirmDelete(plugin) }
                            // no-pointer: native submenu actions use AppKit's menu tracking and cursor.
                            .help("Delete this plugin's folder")
                        Button("Settings…") {}
                            // no-pointer: native submenu actions use AppKit's menu tracking and cursor.
                            .disabled(true)
                            .help("Plugin settings are not available yet")
                    } label: {
                        pluginLabel(plugin)
                    }
                        // no-pointer: native submenu triggers use AppKit's menu tracking and cursor.
                        // no-tooltip: the plugin name, placement and submenu chevron already identify this action.
                }
            }
        }
        Divider()
        Button("Reload Plugins") { Task { await registry.reload() } }
            .buttonHoverPointer()
            .help("Read the plugins folder again")
        ForEach(registry.authoringSessions.filter { session in
            !registry.plugins.contains { $0.id == session.authoredPluginID }
        }, id: \.id) { session in
            if let pluginID = session.authoredPluginID {
                Button("Edit \(session.title)…") { edit(pluginID) }
                    .buttonHoverPointer()
                    .help("Open this plugin's editor")
            }
        }
    }

    private func pluginLabel(_ plugin: PluginRecord) -> some View {
        let placement = PluginPlacement(rawValue: plugin.placement)?.title ?? plugin.placement
        return Label("\(plugin.name) — \(placement)\(plugin.enabled ? "" : " (Disabled)")",
                     systemImage: plugin.valid ? plugin.icon : "exclamationmark.triangle")
    }

    /// A disabled plugin is hidden from every placement and never runs until it's enabled again.
    private func enableButton(_ plugin: PluginRecord) -> some View {
        Button(plugin.enabled ? "Disable" : "Enable") {
            Task { @MainActor in
                do {
                    try await registry.setEnabled(plugin.id, !plugin.enabled)
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
            // no-pointer: native submenu actions use AppKit's menu tracking and cursor.
            .help(plugin.enabled ? "Hide this plugin and stop running it" : "Show and run this plugin again")
    }

    private func edit(_ pluginID: String) {
        Task { @MainActor in
            do {
                if let existing = registry.authoringSessions.first(where: { $0.authoredPluginID == pluginID }) {
                    NotificationCenter.default.post(name: .playhousePreparePluginEdit, object: existing.id)
                    await Task.yield()
                }
                let id = try await registry.edit(pluginID)
                NotificationCenter.default.post(name: .playhouseEditPlugin, object: id)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func confirmDelete(_ plugin: PluginRecord) {
        let alert = NSAlert()
        alert.messageText = "Delete the plugin \(plugin.name)?"
        alert.informativeText = "Its folder is removed: \(plugin.folder)"
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            do {
                if let session = registry.authoringSessions.first(where: { $0.authoredPluginID == plugin.id }) {
                    NotificationCenter.default.post(name: .playhousePreparePluginEdit, object: session.id)
                    await Task.yield()
                }
                try await registry.delete(plugin.id)
            } catch {
                let failure = NSAlert(error: error)
                failure.runModal()
            }
        }
    }
}
