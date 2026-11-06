import AppKit
import SwiftUI

/// The app menu's Plugins menu: the Component Catalog, one submenu per installed
/// plugin, and the plugins folder.
struct PluginsMenuContent: View {
    @ObservedObject var library: PluginLibraryModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Component Catalog…") { openWindow(id: "component-catalog") }
            .buttonHoverPointer()
            .help("Browse every component plugins can use, with live showcases")
        Divider()
        if library.entries.isEmpty {
            Button("No Plugins Installed") {}
                .disabled(true)
                .buttonHoverPointer()
                .help("Add a plugin folder to the plugins folder to see it here")
        }
        ForEach(library.entries) { entry in
            Menu(entry.name) {
                if let problem = entry.problem {
                    Button(problem) {}
                        .disabled(true)
                        .buttonHoverPointer()
                        .help("This plugin has a problem; run playhouse-cli plugin validate for details")
                }
                ForEach(entry.views, id: \.id) { view in
                    Button("Open \"\(view.title)\"") {
                        openWindow(id: "plugin", value: PluginViewRef(
                            directory: entry.directory.path,
                            pluginID: entry.pluginID,
                            viewID: view.id,
                            title: "\(entry.name) — \(view.title)"
                        ))
                    }
                    .buttonHoverPointer()
                    .help("Open this plugin view in its own window")
                }
                Divider()
                Button("Reload") {
                    library.refresh()
                    NotificationCenter.default.post(name: .playhouseReloadPlugin, object: entry.directory.path)
                }
                .buttonHoverPointer()
                .help("Load this plugin's files again; open views restart from initialState")
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.directory]) }
                    .buttonHoverPointer()
                    .help("Show this plugin's folder in Finder")
            }
        }
        Divider()
        Button("Open Plugins Folder") { library.revealPluginsFolder() }
            .buttonHoverPointer()
            .help("Show the folder Playhouse loads plugins from")
        Button("Reload Plugins") { library.refresh() }
            .buttonHoverPointer()
            .help("Scan the plugins folder again")
    }
}
