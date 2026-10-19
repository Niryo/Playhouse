import SwiftData
import SwiftUI

@main
struct StationAIApp: App {
    private let modelContainer: ModelContainer
    private let appPreferences: UserDefaults
    @StateObject private var codexClient: CodexAppServerClient

    init() {
        let environment = ProcessInfo.processInfo.environment
        _codexClient = StateObject(wrappedValue: CodexAppServerClient(
            codexExecutableOverride: environment["STATIONAI_E2E_CODEX_EXECUTABLE"]
        ))
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
        WindowGroup {
            MainWindowView()
                .modelContainer(modelContainer)
                .environmentObject(codexClient)
                .defaultAppStorage(appPreferences)
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentSize)

        Settings {
            WorkspaceSettingsView()
                .defaultAppStorage(appPreferences)
        }
    }
}

private struct MainWindowView: View {
    @AppStorage(WorkspaceSettings.appearanceKey, store: WorkspaceSettings.preferencesStore) private var appearance = "dark"

    var body: some View {
        KanbanBoardView()
            .tint(WorkspaceTheme.accent)
            .preferredColorScheme(appearance == "light" ? .light : .dark)
    }
}
