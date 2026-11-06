import AppKit
import SwiftUI

/// Which plugin view a plugin window shows.
struct PluginViewRef: Codable, Hashable {
    var directory: String
    var pluginID: String
    var viewID: String
    var title: String
}

extension Notification.Name {
    /// Posted with the plugin's folder path as the object; open windows of that plugin reload.
    static let playhouseReloadPlugin = Notification.Name("playhouseReloadPlugin")
}

/// The installed plugins in `<data directory>/Plugins`, for the Plugins menu. It lists
/// and validates them through the same `PluginManager` as `playhouse-cli plugin list`,
/// so the menu and the CLI agree on which plugins have problems.
@MainActor
final class PluginLibraryModel: ObservableObject {
    struct Entry: Identifiable {
        var id: String { directory.path }
        var directory: URL
        var pluginID: String
        var name: String
        var views: [PluginManifest.ViewContribution]
        var problem: String?
    }

    @Published private(set) var entries: [Entry] = []
    let pluginsDirectory: URL
    private let manager: PluginManager
    private var listing: [String] = []
    private var timer: Timer?
    private var refreshGeneration = 0

    init() {
        manager = PluginPaths.manager()
        pluginsDirectory = manager.pluginsDirectory
        refresh()
        // Plugin folders added, removed or edited while the app runs show up in the menu.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfChanged() }
        }
    }

    func refresh() {
        listing = currentListing()
        refreshGeneration += 1
        let generation = refreshGeneration
        let manager = manager
        // Validation runs logic.js checks in child processes, so it stays off the main actor.
        Task.detached(priority: .utility) {
            let found = manager.entries().map { entry in
                Entry(directory: entry.directory, pluginID: entry.id, name: entry.name, views: entry.views, problem: entry.issues.first?.summary)
            }
            await MainActor.run { [weak self] in
                guard let self, generation == refreshGeneration else { return }
                entries = found
            }
        }
    }

    func revealPluginsFolder() {
        try? FileManager.default.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([pluginsDirectory])
    }

    private func refreshIfChanged() {
        if currentListing() != listing { refresh() }
    }

    private func currentListing() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: pluginsDirectory.path)) ?? []
        return names.sorted().map { name in
            "\(name):\(PluginLoader.fingerprint(directory: pluginsDirectory.appendingPathComponent(name)))"
        }
    }
}

/// A window showing one installed plugin's view. Plugin files are watched, so
/// edits show up without reopening the window.
struct PluginWindowView: View {
    let ref: PluginViewRef
    @StateObject private var model: PluginViewModel
    @AppStorage(WorkspaceSettings.appearanceKey, store: WorkspaceSettings.preferencesStore) private var appearance = "dark"

    init(ref: PluginViewRef) {
        self.ref = ref
        _model = StateObject(wrappedValue: PluginViewModel(directory: URL(fileURLWithPath: ref.directory), viewID: ref.viewID, watchFiles: true))
    }

    var body: some View {
        ScrollView {
            PluginStageView(model: model)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 360, minHeight: 240)
        .accessibilityIdentifier("plugin-window-\(ref.pluginID)-\(ref.viewID)")
        .navigationTitle(ref.title)
        .tint(WorkspaceTheme.accent)
        .preferredColorScheme(appearance == "light" ? .light : .dark)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .playhouseReloadPlugin)) { notification in
            if (notification.object as? String) == ref.directory { model.reload() }
        }
    }
}
