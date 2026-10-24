import Foundation

enum BridgeContract {
    static let currentVersion = 1
    static let serviceName = "com.stationai.app.bridge"

    /// The bundled XPC service is named after its app (see scripts/build-bridge.sh).
    static func serviceName(forApplication applicationIdentifier: String) -> String {
        applicationIdentifier.isEmpty ? serviceName : applicationIdentifier + ".bridge"
    }
}

enum BridgeValue: Codable, Equatable {
    case string(String)
    case integer(Int)
    case decimal(Double)
    case boolean(Bool)
    case array([BridgeValue])
    case object([String: BridgeValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .decimal(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([BridgeValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: BridgeValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .decimal(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .boolean(let value) = self { value } else { nil } }
    var strings: [String]? {
        guard case .array(let values) = self else { return nil }
        let strings = values.compactMap(\.string)
        return strings.count == values.count ? strings : nil
    }
    var object: [String: BridgeValue]? { if case .object(let value) = self { value } else { nil } }
}

struct BridgeRequest: Codable {
    var version = BridgeContract.currentVersion
    var id = UUID().uuidString
    var command: String
    var arguments: [String: BridgeValue] = [:]
    var dataDirectory: String?
    var defaultsSuite: String?
    var worktreeDirectory: String?
}

struct BridgeFailure: Codable, Equatable {
    let code: String
    let message: String
}

struct BridgeResponse: Codable {
    let version: Int
    let id: String
    let ok: Bool
    let result: BridgeValue?
    let error: BridgeFailure?

    static func success(_ request: BridgeRequest, result: BridgeValue) -> BridgeResponse {
        BridgeResponse(version: BridgeContract.currentVersion, id: request.id, ok: true, result: result, error: nil)
    }

    static func failure(_ request: BridgeRequest, code: String, message: String) -> BridgeResponse {
        BridgeResponse(
            version: BridgeContract.currentVersion,
            id: request.id,
            ok: false,
            result: nil,
            error: BridgeFailure(code: code, message: message)
        )
    }
}

struct BridgeEvent: Codable {
    let version: Int
    let requestID: String
    let type: String
    let payload: BridgeValue

    init(requestID: String, type: String, payload: BridgeValue) {
        version = BridgeContract.currentVersion
        self.requestID = requestID
        self.type = type
        self.payload = payload
    }
}

@objc protocol StationAIBridgeProtocol {
    func perform(
        _ requestData: Data,
        reply: @escaping (Data) -> Void
    )
}

@objc protocol StationAIBridgeClientProtocol {
    func receiveEvent(_ eventData: Data)
}
