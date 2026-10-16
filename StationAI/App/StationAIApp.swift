import SwiftData
import SwiftUI

@main
struct StationAIApp: App {
    private let modelContainer: ModelContainer
    private let appPreferences: UserDefaults
    @StateObject private var codexClient = CodexAppServerClient()

    init() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
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
            KanbanBoardView()
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
