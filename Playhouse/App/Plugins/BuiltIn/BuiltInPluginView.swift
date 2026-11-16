import SwiftUI

/// A built-in plugin's native view (`BuiltInPlugins`), mounted wherever an
/// installed plugin's `PluginSurfaceView` would be. It gets the same props
/// and answers its host calls through the same `PluginHost`.
struct BuiltInPluginView: View {
    let plugin: PluginRecord
    let props: [String: PluginValue]
    let actions: PluginUIActions

    var body: some View {
        let host = PluginHost(plugin: plugin, actions: actions)
        switch plugin.id {
        case BuiltInPlugins.changesID:
            ChangesPlugin(host: host, props: props)
        case BuiltInPlugins.pullRequestModeID:
            PullRequestModePlugin(host: host, props: props)
        case BuiltInPlugins.pullRequestsID:
            PullRequestsPlugin(host: host, props: props)
        default:
            AtomText(props: TextProps(text: "Unknown built-in plugin \(plugin.id).", size: 11, color: "red"), common: AtomCommon(testID: "plugin-error"))
        }
    }
}
