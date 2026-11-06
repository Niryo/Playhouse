import Foundation

/// How the core reaches the Playhouse daemon. The app implements it with
/// `DaemonClient`; the dev runner with `BridgeClient`. Both talk to the real daemon.
///
/// The second seam, for calls that only exist inside the app window (opening a
/// task or a terminal panel, which the dev runner logs instead of running),
/// arrives with the first such API.
protocol PluginDaemonTransport: AnyObject {
    /// Called on the plugin thread; `completion` may run on any thread.
    func call(command: String, arguments: [String: BridgeValue], completion: @escaping (Result<BridgeValue, Error>) -> Void)
}
