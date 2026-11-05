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
            CommandMenu("Debug") { DebugConversationImportMenu(modelContainer: modelContainer) } // DEBUG-IMPORT:
        }

        Settings {
            WorkspaceSettingsView()
                .defaultAppStorage(appPreferences)
        }
    }

    private var mainWindowContent: some View {
        MainWindowView()
            .modelContainer(modelContainer)
            .environmentObject(conversationRuntime)
            .environmentObject(cpuUsageModel)
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
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var conversationRuntime: ConversationRuntimeModel
    @EnvironmentObject private var cpuUsageModel: TaskCPUUsageModel
    @State private var lifecycleError: String?
    @State private var isLifecycleReady = false

    var body: some View {
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
