import AppKit
import SwiftData
import SwiftUI

@main
struct StationAIApp: App {
    @NSApplicationDelegateAdaptor(StationAIApplicationDelegate.self) private var applicationDelegate
    private let modelContainer: ModelContainer
    private let appPreferences: UserDefaults
    @StateObject private var codexClient: CodexAppServerClient
    @StateObject private var claudeClient: ClaudeCodeClient

    private var windowTitle: String {
        let configuredTitle = ProcessInfo.processInfo.environment["STATIONAI_WINDOW_TITLE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let configuredTitle, !configuredTitle.isEmpty { return configuredTitle }
        let label = ProcessInfo.processInfo.environment["STATIONAI_WORKTREE_LABEL"]
            .flatMap { $0.isEmpty ? nil : $0 }
        return label.map { "StationAI — \($0)" } ?? "StationAI"
    }

    init() {
        let environment = ProcessInfo.processInfo.environment
        _codexClient = StateObject(wrappedValue: CodexAppServerClient(
            codexExecutableOverride: environment["STATIONAI_E2E_CODEX_EXECUTABLE"],
            goalRuntimeEnabled: true
        ))
        _claudeClient = StateObject(wrappedValue: ClaudeCodeClient())
        StationAIApplicationDelegate.terminationHandler = { [weak codex = _codexClient.wrappedValue, weak claude = _claudeClient.wrappedValue] in
            // Both runtimes drain within their own bounded deadlines.
            await codex?.prepareForApplicationTermination()
            await claude?.prepareForApplicationTermination()
        }
        #if DEBUG
        if let suiteName = environment["STATIONAI_E2E_DEFAULTS_SUITE"],
           let isolatedPreferences = UserDefaults(suiteName: suiteName) {
            appPreferences = isolatedPreferences
            if let parentPath = environment["STATIONAI_E2E_DEFAULT_PARENT_FOLDER"] {
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
            modelContainer = try StationAIStore.makeContainer(
                dataDirectory: ProcessInfo.processInfo.environment["STATIONAI_DATA_DIRECTORY"]
            )
        } catch {
            fatalError("Couldn't open the StationAI task store: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        Window(windowTitle, id: "main") {
            mainWindowContent
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentSize)

        Settings {
            WorkspaceSettingsView()
                .defaultAppStorage(appPreferences)
        }
    }

    private var mainWindowContent: some View {
        MainWindowView()
            .modelContainer(modelContainer)
            .environmentObject(codexClient)
            .environmentObject(claudeClient)
            .defaultAppStorage(appPreferences)
    }
}

@MainActor
private final class StationAIApplicationDelegate: NSObject, NSApplicationDelegate {
    static var terminationHandler: (() async -> Void)?

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
    @State private var lifecycleError: String?
    @State private var isLifecycleReady = false

    var body: some View {
        Group {
            if isLifecycleReady {
                KanbanBoardView()
            } else if let lifecycleError {
                ContentUnavailableView(
                    "Couldn't prepare StationAI",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(lifecycleError)
                )
            } else {
                ProgressView("Preparing StationAI…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .tint(WorkspaceTheme.accent)
        .preferredColorScheme(appearance == "light" ? .light : .dark)
        .task {
            guard !isLifecycleReady else { return }
            do {
                try await StationAIStore.prepareLifecycle(
                    container: modelContext.container,
                    dataDirectory: ProcessInfo.processInfo.environment["STATIONAI_DATA_DIRECTORY"]
                )
                isLifecycleReady = true
            } catch {
                lifecycleError = error.localizedDescription
            }
        }
    }
}
