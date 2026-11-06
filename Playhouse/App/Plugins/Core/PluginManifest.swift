import Foundation

/// `plugin.json`.
struct PluginManifest: Codable, Equatable {
    struct ViewContribution: Codable, Equatable {
        var id: String
        var title: String
    }

    var id: String
    var name: String
    var version: String
    var description: String?
    /// A showcase that needs the real daemon; the showcase smoke test skips it.
    var live: Bool?
    var views: [ViewContribution]

    /// The manifest as written on disk, kept for validating reserved and unknown keys.
    var raw: [String: BridgeValue]

    static func parse(_ value: BridgeValue) throws -> PluginManifest {
        guard let object = value.object else { throw PluginLoadError("plugin.json must contain a JSON object.") }
        let contributes = object["contributes"]?.object ?? [:]
        let views = (contributes["views"]?.array ?? []).compactMap { view -> ViewContribution? in
            guard let entry = view.object, let id = entry["id"]?.string else { return nil }
            return ViewContribution(id: id, title: entry["title"]?.string ?? id)
        }
        return PluginManifest(
            id: object["id"]?.string ?? "",
            name: object["name"]?.string ?? "",
            version: object["version"]?.string ?? "",
            description: object["description"]?.string,
            live: object["live"]?.bool,
            views: views,
            raw: object
        )
    }

    private enum CodingKeys: String, CodingKey { case id, name, version, description, live, views }

    init(id: String, name: String, version: String, description: String?, live: Bool?, views: [ViewContribution], raw: [String: BridgeValue]) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.live = live
        self.views = views
        self.raw = raw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        live = try container.decodeIfPresent(Bool.self, forKey: .live)
        views = try container.decode([ViewContribution].self, forKey: .views)
        raw = [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(live, forKey: .live)
        try container.encode(views, forKey: .views)
    }
}

/// One element of `view.json` before bindings are resolved.
struct PluginViewNode: Equatable {
    var type: String
    var props: [String: BridgeValue]
    var children: [PluginViewNode]
    /// The JSON path of this node in view.json, for validation messages.
    var path: String

    static func parse(_ value: BridgeValue, path: String) throws -> PluginViewNode {
        guard let object = value.object else { throw PluginLoadError("\(path) must be an object with a \"type\".") }
        guard let type = object["type"]?.string, !type.isEmpty else {
            throw PluginLoadError("\(path) is missing its \"type\".")
        }
        let children = try (object["children"]?.array ?? []).enumerated().map { index, child in
            try parse(child, path: "\(path).children[\(index)]")
        }
        return PluginViewNode(type: type, props: object["props"]?.object ?? [:], children: children, path: path)
    }

    /// Every node in this subtree, depth first.
    var allNodes: [PluginViewNode] { [self] + children.flatMap(\.allNodes) }
}

/// A plugin folder read from disk: the manifest, its view trees and its logic source.
struct PluginBundle {
    var directory: URL
    var manifest: PluginManifest
    var views: [String: PluginViewNode]
    var logicSource: String?

    static let manifestFile = "plugin.json"
    static let viewFile = "view.json"
    static let logicFile = "logic.js"
}

struct PluginLoadError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// One problem found in a plugin, pointing at the file and JSON path it comes from.
struct PluginIssue: Codable, Equatable {
    var file: String
    var path: String?
    var message: String

    var summary: String { path.map { "\(file) \($0): \(message)" } ?? "\(file): \(message)" }
}

enum PluginLoader {
    static func load(directory: URL) throws -> PluginBundle {
        let manifestURL = directory.appendingPathComponent(PluginBundle.manifestFile)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw PluginLoadError("\(directory.lastPathComponent) has no plugin.json.")
        }
        let manifest = try PluginManifest.parse(readJSON(manifestURL, file: PluginBundle.manifestFile))
        let viewURL = directory.appendingPathComponent(PluginBundle.viewFile)
        var views: [String: PluginViewNode] = [:]
        if FileManager.default.fileExists(atPath: viewURL.path) {
            guard let object = try readJSON(viewURL, file: PluginBundle.viewFile).object else {
                throw PluginLoadError("view.json must be an object of view trees keyed by view id.")
            }
            for (viewID, tree) in object {
                views[viewID] = try PluginViewNode.parse(tree, path: viewID)
            }
        }
        let logicURL = directory.appendingPathComponent(PluginBundle.logicFile)
        let logic = FileManager.default.fileExists(atPath: logicURL.path)
            ? try String(contentsOf: logicURL, encoding: .utf8)
            : nil
        return PluginBundle(directory: directory, manifest: manifest, views: views, logicSource: logic)
    }

    /// The plugin folders directly inside `root`, each loaded or with the reason it couldn't be.
    static func discover(root: URL) -> [(directory: URL, result: Result<PluginBundle, Error>)] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { directory in (directory, Result { try load(directory: directory) }) }
    }

    /// Modification stamps of the files that define a plugin, for change detection.
    static func fingerprint(directory: URL) -> String {
        [PluginBundle.manifestFile, PluginBundle.viewFile, PluginBundle.logicFile].map { name in
            let path = directory.appendingPathComponent(name).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "\(name):-" }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            return "\(name):\(modified):\(size)"
        }.joined(separator: "|")
    }

    private static func readJSON(_ url: URL, file: String) throws -> BridgeValue {
        let text = try String(contentsOf: url, encoding: .utf8)
        do {
            return try BridgeValue.parsingJSON(text)
        } catch {
            throw PluginLoadError("\(file) is not valid JSON: \(Self.describe(error))")
        }
    }

    private static func describe(_ error: Error) -> String {
        if case DecodingError.dataCorrupted(let context) = error {
            return (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String ?? context.debugDescription
        }
        return error.localizedDescription
    }
}
