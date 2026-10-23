import Foundation

final class BridgeClient {
    func send(_ request: BridgeRequest, onEvent: @escaping (BridgeEvent) -> Void) throws -> BridgeResponse {
        let serviceName = ProcessInfo.processInfo.environment["STATIONAI_BRIDGE_SERVICE_NAME"]
            ?? Self.bundledServiceName()
            ?? BridgeContract.serviceName
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.exportedInterface = NSXPCInterface(with: StationAIBridgeClientProtocol.self)
        let receiver = BridgeEventReceiver(onEvent: onEvent)
        connection.exportedObject = receiver
        connection.remoteObjectInterface = NSXPCInterface(with: StationAIBridgeProtocol.self)
        connection.invalidationHandler = {}
        connection.interruptionHandler = {}
        connection.resume()
        defer { connection.invalidate() }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var responseData: Data?
        var transportError: Error?
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            lock.lock()
            transportError = error
            lock.unlock()
            semaphore.signal()
        }) as? StationAIBridgeProtocol else {
            throw BridgeClientError.connection
        }

        let requestData = try Self.encoder.encode(request)
        proxy.perform(requestData, reply: { data in
            lock.lock()
            responseData = data
            lock.unlock()
            semaphore.signal()
        })

        if semaphore.wait(timeout: .now() + 24 * 60 * 60) == .timedOut {
            throw BridgeClientError.timeout
        }
        lock.lock()
        let data = responseData
        let error = transportError
        lock.unlock()
        if let error { throw error }
        guard let data else { throw BridgeClientError.connection }
        return try Self.decoder.decode(BridgeResponse.self, from: data)
    }

    private static func bundledServiceName() -> String? {
        guard let executablePath = CommandLine.arguments.first, !executablePath.isEmpty else { return nil }
        let executableURL = URL(fileURLWithPath: executablePath).standardizedFileURL
        let appBundleURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceBundleURL = appBundleURL.appendingPathComponent(
            "Contents/XPCServices/StationAIBridge.xpc",
            isDirectory: true
        )
        return Bundle(url: serviceBundleURL)?.bundleIdentifier
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private final class BridgeEventReceiver: NSObject, StationAIBridgeClientProtocol {
    private let onEvent: (BridgeEvent) -> Void

    init(onEvent: @escaping (BridgeEvent) -> Void) {
        self.onEvent = onEvent
    }

    func receiveEvent(_ eventData: Data) {
        guard let event = try? JSONDecoder().decode(BridgeEvent.self, from: eventData) else { return }
        onEvent(event)
    }
}

enum BridgeClientError: LocalizedError {
    case connection
    case timeout

    var errorDescription: String? {
        switch self {
        case .connection: "Couldn't connect to StationAI's bundled XPC service. Confirm StationAI is running and use the CLI bundled in that app."
        case .timeout: "StationAI's XPC service did not respond before the request timed out."
        }
    }
}
