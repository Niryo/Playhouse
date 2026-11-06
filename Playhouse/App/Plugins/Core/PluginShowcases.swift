import Foundation

/// The Component Catalog's examples. Each showcase is a real plugin folder under
/// `Showcase/<section-id>/NN-<id>/`, built and run with the same tools plugin
/// authors use; `section.json` gives each section's title and summary.
struct PluginShowcase {
    var id: String
    var sectionID: String
    var directory: URL
    var manifest: PluginManifest?
    var interactive: Bool
    var live: Bool
    var componentTypes: Set<String>
    var issues: [PluginIssue]
}

struct PluginShowcaseSection {
    var id: String
    var title: String
    var summary: String
    var directory: URL
    var showcases: [PluginShowcase]
}

struct PluginShowcaseReport {
    var sections: [PluginShowcaseSection]
    var issues: [(showcase: String?, issue: PluginIssue)]
    var valid: Bool { issues.isEmpty }

    var value: BridgeValue {
        .object([
            "valid": .boolean(valid),
            "sectionCount": .integer(sections.count),
            "showcaseCount": .integer(sections.reduce(0) { $0 + $1.showcases.count }),
            "componentCount": .integer(PluginComponentCatalog.components.count),
            "sections": .array(sections.map { section in
                .object([
                    "id": .string(section.id),
                    "title": .string(section.title),
                    "showcases": .array(section.showcases.map { showcase in
                        .object([
                            "id": .string(showcase.id),
                            "name": .string(showcase.manifest?.name ?? showcase.id),
                            "directory": .string(showcase.directory.path),
                            "interactive": .boolean(showcase.interactive),
                            "live": .boolean(showcase.live),
                            "components": .array(showcase.componentTypes.sorted().map(BridgeValue.string)),
                        ])
                    }),
                ])
            }),
            "issues": .array(issues.map { entry in
                .object([
                    "showcase": entry.showcase.map(BridgeValue.string) ?? .null,
                    "file": .string(entry.issue.file),
                    "path": entry.issue.path.map(BridgeValue.string) ?? .null,
                    "message": .string(entry.issue.message),
                ])
            }),
        ])
    }
}

enum PluginShowcaseLibrary {
    static let sectionFile = "section.json"

    /// Reads every section and showcase under `root`, in catalog section order.
    static func load(root: URL, validation: PluginValidator.LogicCheck? = nil) -> [PluginShowcaseSection] {
        let order = Dictionary(uniqueKeysWithValues: PluginComponentCatalog.sections.enumerated().map { ($1.id, $0) })
        let directories = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { (order[$0.lastPathComponent] ?? .max, $0.lastPathComponent) < (order[$1.lastPathComponent] ?? .max, $1.lastPathComponent) }
        return directories.map { directory in
            let sectionID = directory.lastPathComponent
            let info = (try? BridgeValue.parsingJSON(String(contentsOf: directory.appendingPathComponent(sectionFile), encoding: .utf8)))?.object ?? [:]
            let catalog = PluginComponentCatalog.section(sectionID)
            let showcases = PluginLoader.discover(root: directory).map { entry -> PluginShowcase in
                switch entry.result {
                case .success(let bundle):
                    return PluginShowcase(
                        id: entry.directory.lastPathComponent,
                        sectionID: sectionID,
                        directory: entry.directory,
                        manifest: bundle.manifest,
                        interactive: bundle.logicSource != nil,
                        live: bundle.manifest.live == true,
                        componentTypes: Set(bundle.views.values.flatMap(\.allNodes).map(\.type)),
                        issues: validation.map { PluginValidator.validate(bundle, logic: $0) } ?? []
                    )
                case .failure(let error):
                    return PluginShowcase(
                        id: entry.directory.lastPathComponent, sectionID: sectionID, directory: entry.directory,
                        manifest: nil, interactive: false, live: false, componentTypes: [],
                        issues: [PluginIssue(file: PluginBundle.manifestFile, path: nil, message: error.localizedDescription)]
                    )
                }
            }
            return PluginShowcaseSection(
                id: sectionID,
                title: info["title"]?.string ?? catalog?.title ?? sectionID,
                summary: info["summary"]?.string ?? catalog?.summary ?? "",
                directory: directory,
                showcases: showcases
            )
        }
    }

    /// `plugin check-showcases`: every showcase validates, every component appears
    /// in a showcase, and components with their own events or presentation get an
    /// interactive one.
    static func check(root: URL, logic: PluginValidator.LogicCheck) -> PluginShowcaseReport {
        var issues: [(showcase: String?, issue: PluginIssue)] = []
        guard FileManager.default.fileExists(atPath: root.path) else {
            return PluginShowcaseReport(sections: [], issues: [(nil, PluginIssue(file: root.path, path: nil, message: "The showcase folder doesn't exist."))])
        }
        let sections = load(root: root, validation: logic)
        for section in sections {
            if PluginComponentCatalog.section(section.id) == nil {
                issues.append((nil, PluginIssue(file: "\(section.id)/", path: nil, message: "\"\(section.id)\" isn't a catalog section.")))
            }
            if !FileManager.default.fileExists(atPath: section.directory.appendingPathComponent(sectionFile).path) {
                issues.append((nil, PluginIssue(file: "\(section.id)/\(sectionFile)", path: nil, message: "Each section folder needs a section.json with its title and summary.")))
            }
            if section.showcases.isEmpty {
                issues.append((nil, PluginIssue(file: "\(section.id)/", path: nil, message: "The section has no showcases.")))
            }
            for showcase in section.showcases {
                let name = "\(section.id)/\(showcase.id)"
                if showcase.id.range(of: #"^[0-9]{2}-[a-z0-9-]+$"#, options: .regularExpression) == nil {
                    issues.append((name, PluginIssue(file: name, path: nil, message: "Showcase folders are named NN-<id>, for example 02-progress-simulate.")))
                }
                issues += showcase.issues.map { (name, $0) }
            }
        }
        let all = sections.flatMap(\.showcases)
        for spec in PluginComponentCatalog.components {
            let users = all.filter { $0.componentTypes.contains(spec.type) }
            if users.isEmpty {
                issues.append((nil, PluginIssue(file: spec.section, path: spec.type, message: "\(spec.type) isn't used by any showcase.")))
            } else if spec.needsInteractiveShowcase, !users.contains(where: \.interactive) {
                issues.append((nil, PluginIssue(file: spec.section, path: spec.type, message: "\(spec.type) has events, so it needs an interactive showcase with a logic.js.")))
            }
        }
        return PluginShowcaseReport(sections: sections, issues: issues)
    }
}

/// `plugin new`: writes a small working plugin to start from.
enum PluginScaffold {
    enum Template: String, CaseIterable { case view, showcase }

    /// Creates the plugin folder and returns it. For a showcase, `parent` is the
    /// showcase root and the folder lands in `<parent>/<section>/NN-<id>`.
    static func create(id: String, template: Template, parent: URL, section: String?) throws -> URL {
        guard id.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil else {
            throw PluginLoadError("The id must be lowercase letters, digits and dashes.")
        }
        let fileManager = FileManager.default
        var directory = parent.appendingPathComponent(id, isDirectory: true)
        if template == .showcase {
            guard let section, let catalogSection = PluginComponentCatalog.section(section) else {
                throw PluginLoadError("A showcase needs --section with one of: \(PluginComponentCatalog.sections.map(\.id).joined(separator: ", ")).")
            }
            let sectionDirectory = parent.appendingPathComponent(section, isDirectory: true)
            try fileManager.createDirectory(at: sectionDirectory, withIntermediateDirectories: true)
            let sectionInfo = sectionDirectory.appendingPathComponent(PluginShowcaseLibrary.sectionFile)
            if !fileManager.fileExists(atPath: sectionInfo.path) {
                let info = BridgeValue.object(["title": .string(catalogSection.title), "summary": .string(catalogSection.summary)])
                try (info.jsonText + "\n").write(to: sectionInfo, atomically: true, encoding: .utf8)
            }
            let existing = (try? fileManager.contentsOfDirectory(atPath: sectionDirectory.path)) ?? []
            if existing.contains(where: { $0.hasSuffix("-\(id)") }) {
                throw PluginLoadError("The section already has a showcase named \(id).")
            }
            let next = (existing.compactMap { Int($0.prefix(2)) }.max() ?? 0) + 1
            directory = sectionDirectory.appendingPathComponent(String(format: "%02d-%@", next, id), isDirectory: true)
        }
        guard !fileManager.fileExists(atPath: directory.path) else {
            throw PluginLoadError("\(directory.path) already exists.")
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = id.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        let manifest = """
        {
          "id": "\(id)",
          "name": "\(name)",
          "version": "0.1.0",
          "description": "Describe what this \(template == .showcase ? "showcase demonstrates" : "plugin does").",
          "contributes": { "views": [ { "id": "main", "title": "\(name)" } ] }
        }

        """
        let view = """
        {
          "main": {
            "type": "vstack",
            "props": { "spacing": 12, "padding": 16 },
            "children": [
              { "type": "heading", "props": { "text": "\(name)" } },
              { "type": "text", "props": { "text": "Clicked {{count}} times" } },
              { "type": "button", "props": { "title": "Click me", "onTap": { "action": "increment" } } }
            ]
          }
        }

        """
        let logic = """
        export const initialState = { count: 0 };

        export const actions = {
          increment(state) {
            state.count += 1;
          }
        };

        """
        try manifest.write(to: directory.appendingPathComponent(PluginBundle.manifestFile), atomically: true, encoding: .utf8)
        try view.write(to: directory.appendingPathComponent(PluginBundle.viewFile), atomically: true, encoding: .utf8)
        try logic.write(to: directory.appendingPathComponent(PluginBundle.logicFile), atomically: true, encoding: .utf8)
        return directory
    }
}
