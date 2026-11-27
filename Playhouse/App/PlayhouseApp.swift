import AppKit
import SwiftUI
import PlayhouseCore
import PlayhouseViews
import PlayhouseAtoms
import PlayhouseUI

@main
struct PlayhouseApp: App {
    @NSApplicationDelegateAdaptor(PlayhouseApplicationDelegate.self) private var applicationDelegate
    private let modelContainer: PlayhouseModelContainer
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
        Platform.services = MacPlatformServices()
        NativeViews.factory = MacNativeViews()
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
                .environment(updateController)
                .defaultAppStorage(appPreferences)
        }
    }

    private var mainWindowContent: some View {
        MainWindowView()
            .modelContainer(modelContainer)
            .environment(conversationRuntime)
            .environment(cpuUsageModel)
            .environment(agentUsageModel)
            .environment(updateController)
            .environment(pluginRegistry)
            .atomHighlightRoot()
            .defaultAppStorage(appPreferences)
    }
}


@MainActor
private final class PlayhouseApplicationDelegate: NSObject, NSApplicationDelegate {
    static var terminationHandler: (() async -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Monaco loads once per session, so the first diff opens into a warm editor.
        MonacoDiffWebViewHost.shared.prewarm()
        // The first open of a conversation otherwise builds its view's type metadata on the main thread.
        Task.detached(priority: .utility) { _ = TaskConversationView.prepareBodyTypeMetadata() }
        #if PLAYHOUSE_TRANSCRIPT_BENCHMARK
        // Only in scripts/benchmark-transcript.sh's builds.
        TranscriptBenchmark.runIfRequested()
        #endif
        #if PLAYHOUSE_ATOM_BENCHMARK
        // Only in scripts/benchmark-atom-tree.sh's builds.
        AtomTreeBenchmark.runIfRequested()
        #endif
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
    @Environment(ConversationRuntimeModel.self) private var conversationRuntime
    @Environment(TaskCPUUsageModel.self) private var cpuUsageModel
    @Environment(UpdateController.self) private var updateController
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
        .modifier(SuggestionsFolderPromptModifier(isReady: isLifecycleReady))
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
        AtomToggle(
            props: ToggleProps(isOn: isAddModeOn, style: "menuItem"),
            common: AtomCommon(label: "Add Plugin Mode", help: "Show where a new plugin's button can go"),
            onToggle: { PluginRegistry.setAddMode(!isAddModeOn) }
        )
        AtomButton(
            props: ButtonProps(style: "menuItem", title: "Plugin Catalog"),
            common: AtomCommon(help: "Open the Plugin Catalog"),
            action: { openWindow(id: "plugin-catalog") }
        ) { EmptyView() }
        if !registry.builtInPlugins.isEmpty {
            AtomDivider()
            AtomStack(props: StackProps(sectionTitle: "Built-in Plugins", layout: "section")) {
                ForEach(registry.builtInPlugins) { plugin in
                    pluginMenu(plugin, installed: false)
                }
            }
        }
        if !registry.installedPlugins.isEmpty {
            AtomDivider()
            AtomStack(props: StackProps(sectionTitle: "Installed Plugins", layout: "section")) {
                ForEach(registry.installedPlugins) { plugin in
                    pluginMenu(plugin, installed: true)
                }
            }
        }
        // An unfinished authoring session has a conversation and no plugin folder.
        let unsaved = registry.authoringSessions.filter { session in
            session.authoredPluginID.map { id in !registry.plugins.contains { $0.id == id } } ?? false
        }
        if !unsaved.isEmpty {
            AtomDivider()
            AtomStack(props: StackProps(sectionTitle: "Unsaved Plugins", layout: "section")) {
                ForEach(unsaved, id: \.id) { session in
                    if let pluginID = session.authoredPluginID {
                        let placement = session.pluginPlacement.flatMap(PluginPlacement.init(rawValue:))?.title ?? session.pluginPlacement ?? ""
                        AtomMenu(props: MenuProps(
                            icon: PHIcon.squareDashed.name, text: "\(session.title) — \(placement) (Unsaved)",
                            items: [[
                                .init(id: "edit", title: "Edit…", help: "Open this plugin's editor"),
                                .init(id: "delete", title: "Delete…", help: "Delete this unsaved plugin and its conversation"),
                            ]],
                            style: "submenu"
                        )) { action in
                            if action == "edit" {
                                edit(pluginID)
                            } else if action == "delete" {
                                confirmDelete(pluginID, name: session.title, detail: "It was never saved. Its draft and editor conversation are removed.")
                            }
                        }
                    }
                }
            }
        }
        AtomDivider()
        AtomButton(
            props: ButtonProps(style: "menuItem", title: "Reload Plugins"),
            common: AtomCommon(help: "Read the plugins folder again"),
            action: { Task { await registry.reload() } }
        ) { EmptyView() }
    }

    private func pluginMenu(_ plugin: PluginRecord, installed: Bool) -> some View {
        let placement = plugin.hasSurface ? PluginPlacement(rawValue: plugin.placement)?.title ?? plugin.placement : PluginPresentation.headless.title
        var items: [MenuProps.Item] = []
        if installed, let problem = plugin.errors.first {
            items.append(.init(id: "error", title: problem, informational: true))
        }
        items.append(.init(
            id: "enable",
            title: plugin.enabled ? "Disable" : "Enable",
            help: plugin.enabled ? "Hide this plugin and stop running it" : "Show and run this plugin again"
        ))
        if installed {
            items += [
                .init(id: "edit", title: "Edit…", help: "Open this plugin's editor"),
                .init(id: "delete", title: "Delete…", help: "Delete this plugin's folder"),
                .init(id: "settings", title: "Settings…", help: "Plugin settings are not available yet", disabled: true),
            ]
        }
        return AtomMenu(props: MenuProps(
            icon: plugin.valid ? plugin.icon : PHIcon.exclamationmarkTriangle.name,
            text: "\(plugin.name) — \(placement)\(plugin.enabled ? "" : " (Disabled)")",
            items: [items], style: "submenu"
        )) { action in
            switch action {
            case "enable":
                Task { @MainActor in
                    do {
                        try await registry.setEnabled(plugin.id, !plugin.enabled)
                    } catch {
                        NSAlert(error: error).runModal()
                    }
                }
            case "edit":
                edit(plugin.id)
            case "delete":
                confirmDelete(plugin.id, name: plugin.name, detail: "Its folder is removed: \(plugin.folder)")
            default:
                break
            }
        }
    }

    private func edit(_ pluginID: String) {
        PluginManagement.edit(pluginID, registry: registry)
    }

    private func confirmDelete(_ pluginID: String, name: String, detail: String) {
        PluginManagement.confirmDelete(pluginID, name: name, detail: detail, registry: registry)
    }
}
/// The app menu's Check for Updates… item.
struct CheckForUpdatesMenuItem: View {
    var updates: UpdateController

    var body: some View {
        Button("Check for Updates…") { Task { await updates.checkNow() } }
            .help("Check GitHub for a newer Playhouse release")
            .disabled(!updates.isRelease || updates.isWorking)
    }
}
