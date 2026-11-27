import Foundation
import PlayhouseAtoms
import PlayhouseCore
import PlayhouseUI

/// A built-in plugin's native view (`BuiltInPlugins`), mounted wherever an
/// installed plugin's `PluginSurfaceView` would be. It gets the same props
/// and answers its host calls through the same `PluginHost`.
package struct BuiltInPluginView: PHView {
    package let plugin: PluginRecord
    package let props: [String: PluginValue]
    package let actions: PluginUIActions

    package var body: some PHView {
        let host = PluginHost(plugin: plugin, actions: actions)
        switch plugin.id {
        case BuiltInPlugins.changesID:
            ChangesPlugin(host: host, props: props)
        case BuiltInPlugins.pullRequestModeID:
            PullRequestModePlugin(host: host, props: props)
        case BuiltInPlugins.pullRequestsID:
            PullRequestsPlugin(host: host, props: props)
        case BuiltInPlugins.agentsInfoID:
            AgentsInfoPlugin(host: host, props: props)
        case BuiltInPlugins.scheduledTasksID:
            ScheduledTasksPlugin(host: host, props: props)
        default:
            AtomText(props: TextProps(text: "Unknown built-in plugin \(plugin.id).", size: 11, color: "red"), common: AtomCommon(testID: "plugin-error"))
        }
    }

    package init(plugin: PluginRecord, props: [String: PluginValue], actions: PluginUIActions) {
        self.plugin = plugin
        self.props = props
        self.actions = actions
    }
}
