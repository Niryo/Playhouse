import SwiftData
import SwiftUI

@main
struct StationAIApp: App {
    private let modelContainer: ModelContainer

    init() {
        let schema = Schema([BoardTask.self])
        let configuration: ModelConfiguration

        if let directoryPath = ProcessInfo.processInfo.environment["STATIONAI_DATA_DIRECTORY"] {
            let directoryURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
            } catch {
                fatalError("Couldn't prepare the StationAI data directory: \(error.localizedDescription)")
            }

            configuration = ModelConfiguration(
                "StationAI",
                schema: schema,
                url: directoryURL.appendingPathComponent("StationAI.store"),
                cloudKitDatabase: .none
            )
        } else {
            configuration = ModelConfiguration(
                "StationAI",
                schema: schema,
                isStoredInMemoryOnly: false,
                cloudKitDatabase: .none
            )
        }

        do {
            modelContainer = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Couldn't open the StationAI task store: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            KanbanBoardView()
                .modelContainer(modelContainer)
        }
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentSize)
    }
}
