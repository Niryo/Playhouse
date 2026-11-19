import Darwin
import Foundation

extension PlayhouseCLI {
    /// Conversation image flags as data URLs; the bridge validates the image bytes.
    static func imageDataURLs(_ paths: [String]) throws -> [BridgeValue] {
        try paths.map { path in
            let url = URL(fileURLWithPath: path)
            let data = try Data(contentsOf: url)
            guard data.count <= 10_000_000 else { throw CLIError.usage("Each image must be smaller than 10 MB.") }
            let mime = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? "image/jpeg" : "image/png"
            return .string("data:\(mime);base64,\(data.base64EncodedString())")
        }
    }

    static let pluginPlacements = "mainSidebar|conversationSidebar|conversationToolbar|composerActions|taskItem"

    static func parseFlags(_ args: [String], valueFlags: Set<String>) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        var index = 0
        while index < args.count {
            let name = args[index]
            guard valueFlags.contains(name), index + 1 < args.count, !args[index + 1].hasPrefix("--") else {
                throw CLIError.usage("Expected a value after \(name).")
            }
            result[name, default: []].append(args[index + 1])
            index += 2
        }
        return result
    }

    static func requiredFlag(_ name: String, flags: [String: [String]]) throws -> [String] {
        guard let values = flags[name], !values.isEmpty else { throw CLIError.usage("Missing required option \(name).") }
        return values
    }

    static func draftImageDataURL(_ path: String) throws -> BridgeValue {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let mime: String
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { mime = "image/png" }
        else if data.starts(with: [255, 216, 255]) { mime = "image/jpeg" }
        else { throw CLIError.usage("Images must be PNG or JPEG files.") }
        return .string("data:\(mime);base64,\(data.base64EncodedString())")
    }

    static func keyedOptions(_ values: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for value in values {
            guard let separator = value.firstIndex(of: "="), separator != value.startIndex else {
                throw CLIError.usage("Use <repository-path>=<value> for branch options.")
            }
            let path = String(value[..<separator])
            let option = String(value[value.index(after: separator)...])
            guard !option.isEmpty else { throw CLIError.usage("Branch options can't be empty.") }
            result[path] = option
        }
        return result
    }

    static func firstPositional(_ args: [String]) throws -> String {
        guard let value = args.first, args.count == 1 else { throw CLIError.usage("Expected exactly one task ID.") }
        return value
    }

    static func printResponse(_ response: BridgeResponse) { printJSON(response) }

    static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    static func exitStatus(for code: String?) -> Int32 {
        switch code {
        case "invalid_argument", "unsupported_version", "unknown_command": 2
        case "not_found": 3
        case "service_unavailable": 69
        default: 1
        }
    }

    /// The words and audience a help request names, or nil when `args` aren't one: no
    /// arguments, `help ...`, or a command's words and positional arguments followed by
    /// `--help` or `-h`, each optionally with `--for <audience>`. A `--help` after another
    /// option is that option's value, such as a message, so it isn't a help request.
    static func helpRequest(_ args: [String]) throws -> (words: [String], audience: CLIAudience?)? {
        var rest = args
        if args.isEmpty { return ([], nil) }
        if ["help", "--help", "-h"].contains(args[0]) {
            rest.removeFirst()
        } else if let index = args.firstIndex(where: { $0.hasPrefix("-") }), ["--help", "-h"].contains(args[index]) {
            rest.remove(at: index)
        } else {
            return nil
        }
        var audience: CLIAudience?
        if let index = rest.firstIndex(of: "--for") {
            guard index + 1 < rest.count, let named = CLIAudience(rawValue: rest[index + 1]) else {
                throw CLIError.usage("Use `\(CLICommandCatalog.name) help --for <audience>` with one of: \(CLIAudience.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            audience = named
            rest.removeSubrange(index...(index + 1))
        }
        // A command's own words select it; arguments after them, such as a task ID, don't.
        var words: [String] = []
        for word in rest {
            let candidate = words + [word]
            guard CLICommandCatalog.commands.contains(where: { $0.matchesPrefix(candidate, length: candidate.count) }) else { break }
            words = candidate
        }
        if words.isEmpty, let first = rest.first {
            throw CLIError.usage("Unknown command group '\(first)'. Groups: \(CLICommandCatalog.groups.joined(separator: ", ")).")
        }
        return (words, audience)
    }
}

enum CLIError: LocalizedError {
    case usage(String)
    /// Arguments that name no command the parser handles.
    case unknownCommand([String])

    var errorDescription: String? {
        switch self {
        case .usage(let message):
            return message
        case .unknownCommand(let args):
            let name = CLICommandCatalog.name
            // A declared command given arguments its handler can't read gets its usage.
            let matching = CLICommandCatalog.commands.filter { $0.matches(args) }
            if !matching.isEmpty {
                return "Use: " + matching.map { "\(name) \($0.usage)" }.joined(separator: ", or ")
            }
            let group = args.first ?? ""
            guard CLICommandCatalog.groups.contains(group) else {
                return "Unknown command group '\(group)'. Run `\(name) help` to see every command."
            }
            return "Unknown command '\(args.prefix(3).joined(separator: " "))'. Run `\(name) help \(group)` to see the \(group) commands."
        }
    }
}
