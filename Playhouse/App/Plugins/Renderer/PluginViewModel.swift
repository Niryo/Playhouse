import AppKit
import SwiftUI

/// Publishes one plugin session's snapshots to SwiftUI on the main actor.
@MainActor
final class PluginViewModel: ObservableObject {
    @Published private(set) var snapshot = PluginSnapshot()
    let directory: URL
    let viewID: String?
    private let watchFiles: Bool
    private var session: PluginSession?

    init(directory: URL, viewID: String? = nil, watchFiles: Bool = false) {
        self.directory = directory
        self.viewID = viewID
        self.watchFiles = watchFiles
    }

    var log: [PluginLogEntry] { session?.log.entries ?? [] }

    var actions: PluginNodeActions {
        PluginNodeActions(
            tap: { [weak self] id in self?.session?.tap(nodeID: id) },
            input: { [weak self] id, text in self?.session?.input(nodeID: id, text: text) },
            fire: { [weak self] id, event, value in self?.session?.fire(nodeID: id, event: event, value: value) },
            directory: directory
        )
    }

    func start() {
        guard session == nil else { return }
        let session = PluginSession(directory: directory, viewID: viewID, transport: AppDaemonTransport(), watchFiles: watchFiles)
        session.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in self?.apply(snapshot) }
        }
        self.session = session
        session.start()
    }

    func stop() {
        session?.stop()
        session = nil
    }

    /// Starts a fresh copy of the plugin; its state returns to `initialState`.
    func reload() {
        guard let session else { return start() }
        session.reload()
    }

    private func apply(_ snapshot: PluginSnapshot) {
        // Snapshots hop to the main actor one by one and can arrive out of order.
        guard snapshot.revision > self.snapshot.revision || snapshot.loadCount > self.snapshot.loadCount else { return }
        self.snapshot = snapshot
    }
}

/// `api.call` from inside the app goes through the app's own daemon client.
final class AppDaemonTransport: PluginDaemonTransport {
    func call(command: String, arguments: [String: BridgeValue], completion: @escaping (Result<BridgeValue, Error>) -> Void) {
        Task { @MainActor in
            do {
                completion(.success(try await DaemonClient().call(command, arguments)))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

/// A plugin's resolved view, or why it can't show.
struct PluginStageView: View {
    @ObservedObject var model: PluginViewModel
    var showNodeIDs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.snapshot.error {
                PluginPlaceholder(symbol: model.snapshot.hung ? "hourglass" : "exclamationmark.triangle", message: error, identifier: "plugin-error")
            }
            if let actionError = model.snapshot.actionError, model.snapshot.error == nil {
                PluginPlaceholder(symbol: "exclamationmark.bubble", message: actionError, identifier: "plugin-action-error")
            }
            if let tree = model.snapshot.tree {
                PluginNodeView(node: tree, actions: model.actions, showNodeIDs: showNodeIDs)
            } else if model.snapshot.error == nil {
                ProgressView().controlSize(.small)
            }
        }
    }
}

enum PluginPaths {
    /// The plugin manager for the store this window opened; the daemon builds the
    /// same one from each request's data directory.
    @MainActor
    static func manager() -> PluginManager {
        let dataDirectory = ProcessInfo.processInfo.environment["PLAYHOUSE_DATA_DIRECTORY"]
        return PluginManager(storeDirectory: try? PlayhouseStore.storeURL(dataDirectory: dataDirectory).deletingLastPathComponent().path)
    }

    /// The Component Catalog's showcases, bundled with the app.
    static func showcaseDirectory() -> URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Showcase", isDirectory: true)
    }
}
