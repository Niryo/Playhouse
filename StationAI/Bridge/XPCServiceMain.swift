import Foundation

private final class StationAIBridgeService: NSObject, StationAIBridgeProtocol {
    private weak var connection: NSXPCConnection?

    init(connection: NSXPCConnection) {
        self.connection = connection
    }

    func perform(
        _ requestData: Data,
        reply: @escaping (Data) -> Void
    ) {
        let request: BridgeRequest
        do {
            request = try JSONDecoder().decode(BridgeRequest.self, from: requestData)
        } catch {
            let invalid = BridgeRequest(command: "")
            let response = BridgeResponse.failure(
                invalid,
                code: "invalid_request",
                message: "Request JSON is invalid: \(error.localizedDescription)"
            )
            reply((try? JSONEncoder().encode(response)) ?? Data())
            return
        }

        Task { @MainActor in
            let response = await StationAIBridgeRuntime().perform(request) { event in
                guard let data = try? JSONEncoder().encode(event) else { return }
                guard let client = self.connection?.remoteObjectProxy as? StationAIBridgeClientProtocol else { return }
                client.receiveEvent(data)
            }
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}

private final class StationAIBridgeListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: StationAIBridgeProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: StationAIBridgeClientProtocol.self)
        connection.exportedObject = StationAIBridgeService(connection: connection)
        connection.resume()
        return true
    }
}

@main
enum StationAIBridgeServiceMain {
    static func main() {
        let listener = NSXPCListener.service()
        let delegate = StationAIBridgeListenerDelegate()
        listener.delegate = delegate
        listener.resume()
        RunLoop.current.run()
    }
}
