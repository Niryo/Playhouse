import AppKit

/// Loads the pictures `Image` atoms show and keeps them, so a re-render or
/// another mounted copy of the same URL never loads it again: decoded images
/// stay in memory, and responses in a URL cache on disk that honors the
/// server's cache headers (a Slack profile picture's). Concurrent loads of one
/// URL share a single request. A failed load is remembered for
/// `retryInterval`, so the placeholder a failure shows doesn't trigger a
/// request on every mount.
@MainActor
final class AtomImageLoader {
    static let shared = AtomImageLoader()

    /// The largest picture it loads, as `fetch`'s largest response.
    nonisolated static let maxBytes = PluginNetwork.maxResponseBytes
    static let retryInterval: TimeInterval = 60

    private let memory = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<Data?, Never>] = [:]
    private var failures: [URL: Date] = [:]
    private let session: URLSession

    private init() {
        memory.totalCostLimit = 64 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        // No cookies or credentials shared with anything else, as for `fetch`.
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = PluginNetwork.defaultTimeout
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Playhouse", isDirectory: true)
            .appendingPathComponent("PluginImages", isDirectory: true)
        configuration.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024, directory: directory)
        configuration.requestCachePolicy = .useProtocolCachePolicy
        session = URLSession(configuration: configuration)
    }

    /// The picture already loaded for `url`, read synchronously so a newly
    /// mounted copy draws it at once instead of its placeholder.
    func cached(_ url: URL) -> NSImage? {
        memory.object(forKey: url as NSURL)
    }

    /// The picture at `url`, or nil when it can't be loaded or isn't an image.
    func load(_ url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        if let failed = failures[url], Date().timeIntervalSince(failed) < Self.retryInterval { return nil }
        let task: Task<Data?, Never>
        if let running = inFlight[url] {
            task = running
        } else {
            let session = session
            task = Task.detached { await Self.data(at: url, session: session) }
            inFlight[url] = task
        }
        let data = await task.value
        // A later load may have started a newer request; leave that one in place.
        if inFlight[url] == task { inFlight[url] = nil }
        // Another waiter on the same request may have decoded it already.
        if let image = cached(url) { return image }
        guard let data, let image = NSImage(data: data), image.isValid else {
            failures[url] = Date()
            return nil
        }
        failures[url] = nil
        memory.setObject(image, forKey: url as NSURL, cost: data.count)
        return image
    }

    private nonisolated static func data(at url: URL, session: URLSession) async -> Data? {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            return data.count <= maxBytes ? data : nil
        } catch {
            return nil
        }
    }
}
