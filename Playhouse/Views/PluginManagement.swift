import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI



/// Editing and deleting a plugin, shared by the Plugins menu and the composer's `/plugin` list.
@MainActor
package enum PluginManagement {
    /// Opens the plugin's editor conversation, creating it the first time.
    ///
    /// An existing editor opens at once, so a turn running in it shows live; the bridge call
    /// that refreshes its draft follows and may wait behind a Save or Discard of the plugin.
    package static func edit(_ pluginID: String, registry: PluginRegistry) {
        let existing = registry.authoringSessions.first(where: { $0.authoredPluginID == pluginID })?.id
        if let existing { NotificationCenter.default.post(name: .playhouseEditPlugin, object: existing) }
        Task { @MainActor in
            do {
                let id = try await registry.edit(pluginID)
                if id != existing { NotificationCenter.default.post(name: .playhouseEditPlugin, object: id) }
            } catch {
                Platform.services.showErrorAlert(error)
            }
        }
    }

    /// A plugin's `ui.confirm` as an alert over the window.
    package static func confirm(_ question: PluginConfirmation) -> Bool {
        Platform.services.confirmAlert(
            title: question.title, message: question.message, confirmTitle: question.confirm, destructive: question.destructive
        )
    }

    /// Lets the plugin's editor conversation, if one is open, let go of its folder before it is deleted.
    package static func prepareDelete(_ pluginID: String, registry: PluginRegistry) async {
        guard let session = registry.authoringSessions.first(where: { $0.authoredPluginID == pluginID }) else { return }
        NotificationCenter.default.post(name: .playhousePreparePluginDelete, object: session.id)
        await Task.yield()
    }

    /// Asks first, then deletes the plugin's folder and its editor conversation.
    package static func confirmDelete(_ pluginID: String, name: String, detail: String, registry: PluginRegistry) {
        guard Platform.services.confirmAlert(
            title: "Delete the plugin \(name)?", message: detail, confirmTitle: "Delete", destructive: true
        ) else { return }
        Task { @MainActor in
            do {
                await prepareDelete(pluginID, registry: registry)
                try await registry.delete(pluginID)
            } catch {
                Platform.services.showErrorAlert(error)
            }
        }
    }
}
