---
name: add-plugin-component
description: Add a new component to Playhouse's plugin component catalog (spec, SwiftUI renderer, Component Catalog showcase) and verify it. Use when asked to add, extend or fix a plugin UI component.
---

# Add a plugin component

Follow `docs/plugins/adding-a-component.md`. In short:

1. **Spec.** Add a `PluginComponentSpec` to `PluginComponentCatalog.components` in `Playhouse/App/Plugins/Core/PluginComponentCatalog.swift`, in the right section, with typed props, defaults, docs, its own events and its wave. The core must keep using only Foundation and JavaScriptCore.
2. **Renderer.** Add `Playhouse/App/Plugins/Renderer/Components/<Name>Component.swift` conforming to `PluginComponent`, and list it in `PluginComponentRegistry.components`. Read props through `ctx`; common props and the `plugin-node-<n>` identifier are applied for you. Buttons need `.buttonHoverPointer()` and `.nativeHelp(...)`.
3. **Showcase.** `playhouse-cli plugin new --id <id> --template showcase --section <section> --path Playhouse/Resources/Showcase`, then edit it while running `playhouse-plugin-dev <showcase-dir>`: use `view`, `tap <id>`, `type <id> <text>`, `state` and `log` until it behaves. Components with events or presentation need an interactive showcase (with `logic.js`) showing realistic use.
4. **Check.** `playhouse-cli plugin check-showcases --path Playhouse/Resources/Showcase` must report `valid: true`; `scripts/test-showcases.sh --only <section>/<showcase>` must pass. The Catalog UI case `test_plugin_catalog_showcases_cover_every_component` fails on any unknown-component placeholder.

No Xcode project edit is needed: `Playhouse/App/Plugins` is a synchronized folder.
