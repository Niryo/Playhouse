# Adding a plugin component

Every component plugins can use is defined once in the plugin core's catalog, drawn by one renderer file, and shown in at least one Component Catalog showcase. `Playhouse/App/Plugins` is a synchronized Xcode folder, so new files there need no project edit.

## 1. Add the spec

Add a `PluginComponentSpec` to `PluginComponentCatalog.components` in `Playhouse/App/Plugins/Core/PluginComponentCatalog.swift`: its `type`, `section` (one of the catalog's section ids), `summary`, typed `props` (with `required`, `defaultValue` and `doc`), its own `events`, `acceptsChildren`, `presentation` for modal-like components, and its `wave`. The spec drives validation, `plugin components`, the docs and the Catalog's reference tables.

## 2. Add the renderer

Add `Playhouse/App/Plugins/Renderer/Components/<Name>Component.swift`:

```swift
import SwiftUI

enum BadgeComponent: PluginComponent {
    static let type = "badge"

    static func render(_ ctx: PluginRenderContext) -> AnyView {
        AnyView(Text(ctx.string("text") ?? "").font(.caption.weight(.semibold)).padding(.horizontal, 6))
    }
}
```

Events that carry a value declare its kind (`PluginEventSpec.valueKind`, and `valueFrom` naming the array prop of allowed values, such as a picker's `options`); the renderer reports it with `ctx.fire("onChange", value: …)`, and the core refuses a value of another kind. A modal-like component sets `presentation: true` with a required `open` prop: its content is dropped from the tree and its events are refused while closed (`anchorChildren` keeps a popover's anchor). `childTypes`, `parentTypes`, `minChildren` and `needsOneOf` make `plugin validate` reject misuse, and a `.file` prop must name a file in the plugin folder (`ctx.fileURL`).

Then list it in `PluginComponentRegistry.components` in `Renderer/PluginRenderer.swift`. Read props through `ctx` (`string`, `number`, `bool`, `color`, `alignment`), place children with `ctx.children`, and report input with `ctx.tap()` or `ctx.input(text)`. The common props (padding, frame, colors, border, tooltip, `onTap` on any component) and the `plugin-node-<n>` accessibility identifier are applied for you. A control that handles its own clicks and help text, like a button or a field, declares `static let handlesOwnInput = true` so the common `onTap` and `tooltip` aren't layered on top. A `Button` needs `.buttonHoverPointer()` and `.nativeHelp(...)` (`scripts/check-button-feedback.py`). Structural components (`if`, `list`) are resolved by the core and have no renderer.

## 3. Add a showcase

Showcases are plugins in `Playhouse/Resources/Showcase/<section>/NN-<id>/`:

```bash
playhouse-cli plugin new --id badge-styles --template showcase --section data --path Playhouse/Resources/Showcase
playhouse-plugin-dev Playhouse/Resources/Showcase/data/01-badge-styles
```

A component with its own events, or a presentation component, needs an interactive showcase with a `logic.js` that shows realistic use, such as a delete button that opens a confirmation dialog and shows the result. Keep showcases self-contained (no `api` calls unless the manifest says `"live": true`) and settling within about 5 seconds.

## 4. Check it

```bash
playhouse-cli plugin check-showcases --path Playhouse/Resources/Showcase   # every component has a showcase; every showcase validates
scripts/test-showcases.sh --only data/01-badge-styles                     # taps and types through every showcase with playhouse-plugin-dev
scripts/test-ui-tart.sh --case test_plugin_catalog_showcases_cover_every_component   # every Catalog page renders with no placeholders
```

A spec without a renderer shows as an "Unknown component" placeholder in the Catalog, which fails the UI case.
