import AppKit
import SwiftUI

/// Plugins ▸ Component Catalog: one page per section, each a stack of live
/// showcases. Every showcase is a real plugin folder from the app's bundled
/// Showcase directory, run by the same core and renderer as installed plugins.
struct ComponentCatalogView: View {
    @AppStorage(WorkspaceSettings.appearanceKey, store: WorkspaceSettings.preferencesStore) private var appearance = "dark"
    @State private var sections: [PluginShowcaseSection] = []
    @State private var selection: String?
    @State private var search = ""

    private var matchingSections: [PluginShowcaseSection] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return sections }
        return sections.filter { section in
            section.title.lowercased().contains(query)
                || section.showcases.contains { $0.componentTypes.contains { $0.lowercased().contains(query) } }
        }
    }

    /// The component a search names, so its section page scrolls to a showcase using it.
    private var focusedComponent: String? {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return nil }
        return PluginComponentCatalog.components.map(\.type).first { $0.lowercased().contains(query) }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(matchingSections, id: \.id) { section in
                    HStack {
                        Text(section.title)
                        Spacer()
                        Text("\(componentCount(section))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .tag(section.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("catalog-section-\(section.id)")
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search components")
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .accessibilityIdentifier("catalog-sidebar")
        } detail: {
            if let section = sections.first(where: { $0.id == selection }) {
                CatalogSectionPage(section: section, focusedComponent: focusedComponent)
                    .id(section.id)
            } else {
                ContentUnavailableView("No section selected", systemImage: "square.grid.2x2", description: Text("Pick a section on the left."))
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .navigationTitle("Component Catalog")
        .tint(WorkspaceTheme.accent)
        .preferredColorScheme(appearance == "light" ? .light : .dark)
        .onAppear {
            guard sections.isEmpty else { return }
            sections = PluginPaths.showcaseDirectory().map { PluginShowcaseLibrary.load(root: $0) } ?? []
            selection = selection ?? sections.first?.id
        }
        .onChange(of: search) { _, _ in
            if let first = matchingSections.first, !matchingSections.contains(where: { $0.id == selection }) {
                selection = first.id
            }
        }
    }

    private func componentCount(_ section: PluginShowcaseSection) -> Int {
        PluginComponentCatalog.components.filter { $0.section == section.id }.count
    }
}

private struct CatalogSectionPage: View {
    let section: PluginShowcaseSection
    let focusedComponent: String?

    private var specs: [PluginComponentSpec] { PluginComponentCatalog.components.filter { $0.section == section.id } }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title).font(.largeTitle.bold())
                        Text(section.summary).foregroundStyle(.secondary)
                    }
                    ForEach(section.showcases, id: \.id) { showcase in
                        ShowcaseStage(showcase: showcase).id(showcase.id)
                    }
                    if !specs.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Reference").font(.title2.weight(.semibold))
                            ForEach(specs, id: \.type) { spec in ComponentReference(spec: spec) }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                guard let focusedComponent,
                      let showcase = section.showcases.first(where: { $0.componentTypes.contains(focusedComponent) }) else { return }
                proxy.scrollTo(showcase.id, anchor: .top)
            }
        }
        .accessibilityIdentifier("catalog-page-\(section.id)")
    }
}

/// One live showcase with its toolbar: Reset, Show Source and Show Node IDs.
private struct ShowcaseStage: View {
    let showcase: PluginShowcase
    @StateObject private var model: PluginViewModel
    @State private var showSource = false
    @State private var showNodeIDs = false

    init(showcase: PluginShowcase) {
        self.showcase = showcase
        _model = StateObject(wrappedValue: PluginViewModel(directory: showcase.directory))
    }

    private var identifier: String { "catalog-stage-\(showcase.sectionID)-\(showcase.id)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(showcase.manifest?.name ?? showcase.id).font(.headline)
                    if let description = showcase.manifest?.description {
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Reset") { model.reload() }
                    .buttonStyle(.borderless)
                    .buttonHoverPointer()
                    .nativeHelp("Reload this showcase so its state starts over")
                    .accessibilityIdentifier("\(identifier)-reset")
                Button(showSource ? "Hide Source" : "Show Source") { showSource.toggle() }
                    .buttonStyle(.borderless)
                    .buttonHoverPointer()
                    .nativeHelp("Show this showcase's view.json and logic.js")
                    .accessibilityIdentifier("\(identifier)-source")
                Button(showNodeIDs ? "Hide Node IDs" : "Show Node IDs") { showNodeIDs.toggle() }
                    .buttonStyle(.borderless)
                    .buttonHoverPointer()
                    .nativeHelp("Show each element's number, as playhouse-plugin-dev prints it")
                    .accessibilityIdentifier("\(identifier)-node-ids")
            }
            PluginStageView(model: model, showNodeIDs: showNodeIDs)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkspaceTheme.panelBackground, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
            if showSource {
                ShowcaseSource(directory: showcase.directory)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

private struct ShowcaseSource: View {
    let directory: URL

    private var files: [(name: String, text: String)] {
        [PluginBundle.viewFile, PluginBundle.logicFile].compactMap { name in
            (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)).map { (name, $0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(files, id: \.name) { file in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(file.name).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(file.text, forType: .string)
                        }
                        .buttonStyle(.borderless)
                        .buttonHoverPointer()
                        .nativeHelp("Copy \(file.name) to the clipboard")
                    }
                    ScrollView(.horizontal) {
                        Text(file.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(WorkspaceTheme.inputBackground, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }
}

/// A component's props and events, generated from its catalog spec.
private struct ComponentReference: View {
    let spec: PluginComponentSpec

    var body: some View {
        DisclosureGroup {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(spec.props, id: \.name) { prop in
                    GridRow {
                        Text(prop.name).font(.system(.callout, design: .monospaced)) + Text(prop.required ? " *" : "").foregroundColor(.orange)
                        Text(prop.kind.label).font(.callout).foregroundStyle(.secondary)
                        Text(prop.defaultValue.map(\.jsonText) ?? "—").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                        Text(prop.doc).font(.callout)
                    }
                }
                ForEach(spec.events, id: \.name) { event in
                    GridRow {
                        Text(event.name).font(.system(.callout, design: .monospaced))
                        Text("event").font(.callout).foregroundStyle(.secondary)
                        Text("—").foregroundStyle(.secondary)
                        Text(event.doc).font(.callout)
                    }
                }
            }
            .padding(.vertical, 6)
        } label: {
            HStack(spacing: 8) {
                Text(spec.type).font(.system(.body, design: .monospaced).weight(.semibold))
                Text(spec.summary).foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("catalog-reference-\(spec.type)")
    }
}
