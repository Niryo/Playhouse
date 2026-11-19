import AppKit
import SwiftData
import SwiftUI

@main
struct PlayhouseApp: App {
    @NSApplicationDelegateAdaptor(PlayhouseApplicationDelegate.self) private var applicationDelegate
    private let modelContainer: ModelContainer
    private let appPreferences: UserDefaults
    // Held, not observed: each change of an object the app observes rebuilds the scene's menu
    // bar, closing a submenu open under the pointer, and these change on every runtime and CPU
    // update. The window's views and the menu items that show them observe them themselves.
    @State private var conversationRuntime: ConversationRuntimeModel
    @State private var cpuUsageModel: TaskCPUUsageModel
    @State private var agentUsageModel = AgentUsageModel(client: DaemonClient())
    @State private var updateController: UpdateController
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
        _conversationRuntime = State(initialValue: runtime)
        let cpuUsage = TaskCPUUsageModel(client: DaemonClient())
        _cpuUsageModel = State(initialValue: cpuUsage)
        let updates = UpdateController(client: DaemonClient())
        _updateController = State(initialValue: updates)
        // The bridge daemon owns every provider turn, so quitting the window
        // doesn't stop one; it just stops watching.
        PlayhouseApplicationDelegate.terminationHandler = { [weak runtime, weak cpuUsage, weak updates] in
            runtime?.stop()
            cpuUsage?.stop()
            updates?.stop()
        }
        // The built-in plugins' services run in the daemon; a change this
        // window saves itself (a card dragged to Review) reaches them there.
        let eventClient = DaemonClient()
        PluginServiceHost.forward = { event in
            Task { @MainActor in
                do {
                    try await eventClient.call("plugin.event", ["name": .string(event.name), "payload": BridgeValue(plugin: .object(event.payload))])
                } catch {
                    PlayhouseDiagnostics.record("plugin.event.forward.failed", fields: ["name": event.name, "error": "\(error)"])
                }
            }
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
            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuItem(updates: updateController)
            }
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
                .environmentObject(updateController)
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
            .environmentObject(updateController)
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
        // The first open of a conversation otherwise builds its view's type metadata on the main thread.
        Task.detached(priority: .utility) { _ = TaskConversationView.prepareBodyTypeMetadata() }
    }

    /// The reply comes from a main-actor task, so a programmatic quit must not start
    /// inside a main-queue block or task; defer it to the run loop instead.
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
    @EnvironmentObject private var updateController: UpdateController
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
        .background(UpdateTitlebarAccessory(updates: updateController, preferences: WorkspaceSettings.preferencesStore))
        .task {
            guard !isLifecycleReady else { return }
            do {
                try await PlayhouseStore.prepareLifecycle(
                    container: modelContext.container,
                    dataDirectory: ProcessInfo.processInfo.environment["PLAYHOUSE_DATA_DIRECTORY"]
                )
                conversationRuntime.start()
                cpuUsageModel.start()
                updateController.start()
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
                        Button("Delete…") { confirmDelete(plugin.id, name: plugin.name, detail: "Its folder is removed: \(plugin.folder)") }
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
        // A plugin being authored that was never saved has an editor conversation but no folder.
        let unsaved = registry.authoringSessions.filter { session in
            session.authoredPluginID.map { id in !registry.plugins.contains { $0.id == id } } ?? false
        }
        if !unsaved.isEmpty {
            Divider()
            Section("Unsaved Plugins") {
                ForEach(unsaved, id: \.id) { session in
                    if let pluginID = session.authoredPluginID {
                        Menu {
                            Button("Edit…") { edit(pluginID) }
                                // no-pointer: native submenu actions use AppKit's menu tracking and cursor.
                                .help("Open this plugin's editor")
                            Button("Delete…") {
                                confirmDelete(pluginID, name: session.title, detail: "It was never saved. Its draft and editor conversation are removed.")
                            }
                                // no-pointer: native submenu actions use AppKit's menu tracking and cursor.
                                .help("Delete this unsaved plugin and its conversation")
                        } label: {
                            let placement = session.pluginPlacement.flatMap(PluginPlacement.init(rawValue:))?.title ?? session.pluginPlacement ?? ""
                            Label("\(session.title) — \(placement) (Unsaved)", systemImage: "square.dashed")
                        }
                            // no-pointer: native submenu triggers use AppKit's menu tracking and cursor.
                            // no-tooltip: the plugin name, placement and submenu chevron already identify this action.
                    }
                }
            }
        }
        Divider()
        Button("Reload Plugins") { Task { await registry.reload() } }
            .buttonHoverPointer()
            .help("Read the plugins folder again")
    }

    private func pluginLabel(_ plugin: PluginRecord) -> some View {
        let placement = plugin.hasSurface ? PluginPlacement(rawValue: plugin.placement)?.title ?? plugin.placement : PluginPresentation.headless.title
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
        PluginManagement.edit(pluginID, registry: registry)
    }

    private func confirmDelete(_ pluginID: String, name: String, detail: String) {
        PluginManagement.confirmDelete(pluginID, name: name, detail: detail, registry: registry)
    }
}

/// Editing and deleting a plugin, shared by the Plugins menu and the composer's `/plugin` list.
@MainActor
enum PluginManagement {
    /// Opens the plugin's editor conversation, creating it the first time.
    ///
    /// An existing editor opens at once, so a turn running in it shows live; the bridge call
    /// that refreshes its draft follows and may wait behind a Save or Discard of the plugin.
    static func edit(_ pluginID: String, registry: PluginRegistry) {
        let existing = registry.authoringSessions.first(where: { $0.authoredPluginID == pluginID })?.id
        if let existing { NotificationCenter.default.post(name: .playhouseEditPlugin, object: existing) }
        Task { @MainActor in
            do {
                let id = try await registry.edit(pluginID)
                if id != existing { NotificationCenter.default.post(name: .playhouseEditPlugin, object: id) }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    /// A plugin's `ui.confirm` as an alert over the window.
    static func confirm(_ question: PluginConfirmation) -> Bool {
        let alert = NSAlert()
        alert.messageText = question.title
        alert.informativeText = question.message
        alert.addButton(withTitle: question.confirm)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = question.destructive
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Lets the plugin's editor conversation, if one is open, let go of its folder before it is deleted.
    static func prepareDelete(_ pluginID: String, registry: PluginRegistry) async {
        guard let session = registry.authoringSessions.first(where: { $0.authoredPluginID == pluginID }) else { return }
        NotificationCenter.default.post(name: .playhousePreparePluginDelete, object: session.id)
        await Task.yield()
    }

    /// Asks first, then deletes the plugin's folder and its editor conversation.
    static func confirmDelete(_ pluginID: String, name: String, detail: String, registry: PluginRegistry) {
        let alert = NSAlert()
        alert.messageText = "Delete the plugin \(name)?"
        alert.informativeText = detail
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            do {
                await prepareDelete(pluginID, registry: registry)
                try await registry.delete(pluginID)
            } catch {
                let failure = NSAlert(error: error)
                failure.runModal()
            }
        }
    }
}

/// The app menu's Check for Updates… item.
struct CheckForUpdatesMenuItem: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        Button("Check for Updates…") { Task { await updates.checkNow() } }
            .buttonHoverPointer()
            .help("Check GitHub for a newer Playhouse release")
            .disabled(!updates.isRelease || updates.isWorking)
    }
}
