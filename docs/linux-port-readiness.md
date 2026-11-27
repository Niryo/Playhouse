# Linux port readiness

Playhouse is a macOS app. This document describes how its code is structured so that a later Linux port, built on our fork of SwiftCrossUI, mostly adds code instead of rewriting it. Nothing here runs on Linux as an app yet. On macOS the app builds, runs, looks and behaves the same as before the restructuring.

## Modules

The code sits in four layers. Each layer depends only on the layers below it:

```
Playhouse (macOS app target, Playhouse/App)
  └─ PlayhouseViews (Playhouse/Views)   composites: board, conversation, settings, skills/rules/MCP, plugin host
       └─ PlayhouseAtoms (Playhouse/Atoms)   the atoms plugins compose, and the native-view seams
            └─ PlayhouseUI (Playhouse/UI)   SwiftUI's names as PH… typealiases, plus shims
                 └─ PlayhouseCore (Playhouse/Core)   Foundation only: models, store, bridge, providers, plugin runtime
```

`Playhouse/Package.swift` declares the modules. PlayhouseAtoms and PlayhouseViews are declared only on macOS, because they need a SwiftUI-compatible PlayhouseUI. The Xcode app target links all four and builds with `SWIFT_PACKAGE_NAME = playhouse`, so the modules share declarations with `package` access rather than `public`. The bridge daemon and the CLI are built by `scripts/build-bridge.sh` from PlayhouseCore. The daemon also compiles the macOS `PlatformServices` implementation.

| Module | May import | Holds |
| --- | --- | --- |
| PlayhouseCore | Foundation, FoundationNetworking, Dispatch, Observation, GRDB. CryptoKit, JavaScriptCore, Security, CoreServices, OSLog and notify only under `#if canImport(...)`. The C library only in `Core/Platform/POSIX.swift`. | Board and task models, the GRDB store and SwiftData migration, the bridge and CLI command catalog, the Claude/Codex/OpenCode providers, the plugin runtime and services, `PlatformServices`, `POSIX`, `Hashing` |
| PlayhouseUI | Foundation, Observation, PlayhouseCore. SwiftUI, AppKit and their helpers only inside `#if canImport(SwiftUI)` / `#if os(macOS)` (all of `UI/SwiftUI`). | `PH…` typealiases (`PlayhouseUITypes.swift`), shims for what SwiftCrossUI lacks (`PlayhouseUIShims.swift`, `MacViewShims.swift`, `MacInteractionShims.swift`), platform text types, `PHScrollSurface`, and the neutral `PHIcon` and `PHMaterial` (`UI/Neutral`, which also build on Linux) |
| PlayhouseAtoms | Foundation, Observation, PlayhouseCore, PlayhouseUI | The atom views, `AtomRegistry`, Markdown rendering, and `NativeViews` |
| PlayhouseViews | The same, plus PlayhouseAtoms | Every composite: the task card, Kanban board and columns, Done archive, composer, task conversation and transcript, Agents info, Token Stats, settings, skills, rules and MCP pages, repository chips, plugin host and built-in plugins, Plugin Catalog |
| App | Anything | `PlayhouseApp`, windows and menus, `MacPlatformServices`, the AppKit native views (`App/NativeViews`), the SwiftTerm terminal, the Monaco diff editor, the updater UI |

## Rules and how they are enforced

- **Imports and dependency direction.** `scripts/check-module-boundaries.py` checks every Swift file's imports against the table above. It also checks the target dependencies in `Package.swift`. It runs as the first build phase of the Xcode app target, in `scripts/test-e2e.sh`, and in the `Module boundaries` job of `.github/workflows/linux-core.yml`.
- **No SwiftUI in Core.** PlayhouseCore builds with `-module-alias` flags that redirect `AppKit`, `SwiftUI` and `SwiftData` to modules that don't exist, so an accidental import fails to compile. Combine can't be aliased this way, because Foundation loads it on macOS. The lint catches Combine instead.
- **No AppKit or SwiftUI names in atoms and composites.** The lint rejects these in `Playhouse/Atoms` and `Playhouse/Views`:
  - `import SwiftUI`;
  - AppKit types (`NSView`, `NSColor`, `NSPasteboard`, `NSWorkspace`, …);
  - `NSViewRepresentable` and `NSHosting…`;
  - SF Symbol names written as `systemName:`/`systemImage:` or as icon literals in atom props;
  - the SwiftUI modifiers SwiftCrossUI lacks: `.contextMenu`, `.shadow`, `.onHover`, `.mask`, `.continuous` corners and materials. Composites use the `ph…` shims (`.phContextMenu`, `.phShadow`, `.phOnHover`, `.phMask`, `PHRoundedRectangle.phContinuous`, `.phMaterialBackground`). A port reimplements the shims once instead of every call site.
- **Composites are made of atoms.** Every view in `Playhouse/Views`, and the app's ordinary UI (the Plugins menu, the terminal panel's chrome, the updater's settings and release notes), is composed of the atoms in `Playhouse/Atoms` and styled only through their props, so a port reimplements the atoms (and the `ph…` shims) once and every composite follows. `scripts/check-atom-composites.py` rejects raw views an atom stands for (`PHText`, `PHHStack`, `PHVStack`, `PHZStack`, `PHButton`, shapes, controls), styling modifiers and raw colors there, with a short allowlist naming each native exception. It runs beside the module boundary lint: in the app's first build phase, in `scripts/test-e2e.sh` and in the `Module boundaries` CI job. See "Composites" in `Playhouse/Core/Plugins/README.md`.
- **No SwiftData, ObservableObject or Combine** anywhere in the app. The lint checks this too. Models and view models use `@Observable`. `ModelQuery` replaces `@Query`. `View.onNotification` replaces Combine's NotificationCenter publishers.
- **Linux builds.** `scripts/test-linux-core.sh` builds PlayhouseCore and PlayhouseUI and runs the PlayhouseCore tests (`Playhouse/CoreTests`) on Linux. It runs in the Linux UI spike's image: `spikes/linux-ui/Dockerfile`, Ubuntu 25.10 with swift.org Swift 6.3.2. The `Build and test on Linux` CI job runs the same script.

## Interfaces a port implements

### Storage: GRDB instead of SwiftData

`Core/Storage/ModelStore.swift` is a small model store over GRDB (SQLite):

- `PersistentModel` classes (`BoardTask`, `StandaloneChat`) declare their columns in a property table.
- `PlayhouseModelContainer` owns the database pool.
- `@Observable PlayhouseModelContext` keeps an identity map. A save writes only the changed columns, in one transaction. Each save bumps a store-wide revision and records tombstones for deleted rows.
- `ModelFetch` / `ModelFilter` express queries, and `ModelQuery` lets a view observe a query result.

The app and the bridge daemon share the store file `Playhouse-v3.sqlite`. Each signals the other through `StoreChangeSignal`, a Darwin notification named after the store path; the receiver then calls `refreshFromStore()`.

**Migration from SwiftData** (`Core/Storage/SwiftDataStoreMigration.swift`) runs once, when there is no `Playhouse-v3.sqlite` yet:

- It reads the newest existing SwiftData store directly as SQLite. That is `Playhouse-v2.store`, or else the legacy `Playhouse.store`.
- It reads its Core Data tables from a snapshot copy, so the original store is never changed.
- It writes every task and standalone chat into a staged file, then moves the file into place.

Tests cover the migration against real SwiftData stores that the previous release wrote: `Playhouse/CoreTests/Fixtures/swiftdata-stores` and the bridge cases `test_task_store_migrates_current_swiftdata_store` and `test_task_store_migrates_legacy_swiftdata_store`.

### PlatformServices

`Core/Platform/PlatformServices.swift` is the single protocol for operating-system services. It covers:

- the clipboard;
- opening files and URLs, and revealing files in the file browser;
- application lookup and the system sound;
- cursors;
- the key window and screen frames, and mouse-button state;
- alerts and confirmations, and activating or terminating the app;
- file choosers and attachment images;
- the scheduler login item (`SMAppService`) and its settings.

`Platform.services` holds the implementation. The macOS implementation is `App/Platform/MacPlatformServices.swift`, which the app and daemon install at launch. Until something is installed, `UnavailablePlatformServices` answers safely.

### POSIX

`Core/Platform/POSIX.swift` is the only place that imports `Darwin` or `Glibc`. It provides:

- C-function forwarders, file locks, atomic file swaps, extended attributes and sockets;
- process spawn and introspection, and `ProcessExitWatch` / `FileWriteWatch`.

On Linux, process introspection reads `/proc`. The two watches use dispatch sources that exist only on Darwin; on Linux they never fire yet (`FileWriteWatch` callers also poll slowly; `ProcessExitWatch` reports only a process already gone). `Core/Platform/Hashing.swift` uses CryptoKit when it exists and a portable SHA-256/SHA-1 otherwise.

### Native views

`Atoms/NativeViews.swift` declares `NativeViewFactory`. Atoms and composites reach AppKit-backed views only through it, using stand-in views (`PHNative…`):

- the chat composer's text editor and the effort slider;
- selectable and annotated transcript text, and code-block text;
- the skill/rule text editor;
- the terminal session and panel (`NativeTerminalSession`);
- the Monaco diff editor;
- the settings section the app adds.

The app installs `MacNativeViews` (`App/NativeViews/MacNativeViews.swift`), which wraps the existing `NSTextView`, SwiftTerm and WKWebView implementations.

### ScriptEngine

`Core/Plugins/Runtime/ScriptEngine.swift` is the protocol `PluginRuntime` uses to run plugin scripts. It can evaluate a script, set globals, call a global function, and define native objects that call back into Swift. `ScriptEngines.make(name:)` returns `JavaScriptCoreScriptEngine` where JavaScriptCore exists. `PluginValueJavaScript.swift` is the only other file that touches JavaScriptCore.

### Icons

`UI/Neutral/PHIcon.swift` names every icon the atoms and composites use as an enum case. `named(_:)` covers plugin-supplied names. Each case has `sfSymbolName` for macOS and `iconThemeName`, a freedesktop icon-theme name a GTK backend can use. Plugins keep passing icon names as strings, and the names are still SF Symbol names.

## Where the boundaries are weaker than they look

- **PlayhouseUI's surface is SwiftUI's.** The `PH…` names are typealiases to SwiftUI, and Swift resolves members through the aliased type. So atoms and composites use far more SwiftUI than the shims listed above, and no compiler check stops them: accessibility modifiers, `PHLayout`, preference keys and anchors, `PHTimelineView`, `PHScrollViewReader`, focus state, `.onKeyPress`, drop delegates, `.matchedGeometryEffect`, `.popover` and `.sheet`. The same goes for AppKit API reached through `PHPlatformColor` and `PHPlatformFont` (`NSColor` and `NSFont`), such as `.labelColor` and `.systemFont(ofSize:)`. The lint only matches AppKit type names. On Linux, PlayhouseUI compiles only `UI/Neutral`, so CI doesn't prove that atoms or composites build against another toolkit. Before porting, turn on `MemberImportVisibility` for PlayhouseAtoms and PlayhouseViews, or inventory the members they use, and give SwiftCrossUI each one, or a shim for it.
- **`WorkspaceTheme`, the shared palette, sits in a macOS shim file** (`UI/SwiftUI/MacInteractionShims.swift`). Its color values are neutral; only the adaptive-color bridging is platform-specific.
- **`PlatformServices` is one protocol, as the task asked, but it mixes two layers.** The clipboard, opening files and URLs, sounds and the login item are system services that Core and the daemon use. Cursors, window and screen frames, mouse-button state, synchronous alerts (`confirmAlert -> Bool`) and file choosers are UI services, which only Views uses. GTK4 on Wayland has no blocking dialogs and no global window, screen or mouse state, so a port should split the protocol (system services in Core, window services in PlayhouseUI) and make confirmation asynchronous. The daemon installs `MacPlatformServices` but never calls its window members.
- **The model store knows its two models** (`ModelStoreSchema.tables`). Tombstones in `deleted_models` are never pruned, and a context's identity map keeps every row it has fetched. None of this affects correctness.
- **`NativeViewFactory.settingsSection()`** injects an app composite (the updater's settings), not a native control. `MacNativeViews.terminalPanel` expects the session type it made itself.

## What a Linux port still has to do

- Close the gaps above, starting with PlayhouseUI's real surface. Then typealias PlayhouseUI's `PH…` names to the SwiftCrossUI fork. Implement the shims there: context menu, shadow, hover tracking, continuous corners, materials, mask, hover popovers, press areas, escape-key and outside-click monitors, scroll surface, and drag-and-drop move. Then lift the `#if os(macOS)` from PlayhouseAtoms and PlayhouseViews in `Package.swift`.
- A Linux `PlatformServices`: clipboard, `xdg-open`, file chooser, alerts, cursors, and window frames through the toolkit. For the login item, a systemd user unit or an XDG autostart entry.
- A Linux `NativeViewFactory`: GTK text views for the composer, transcript and editors, a VTE terminal, and the diff view in WebKitGTK.
- A `ScriptEngine` for plugins: JavaScriptCore from WebKitGTK, or QuickJS.
- A cross-process store change signal in place of Darwin notifications, for example inotify on the store's WAL file or a socket message from the daemon. Without it, the app sees daemon writes only when it refreshes for another reason.
- A workspace file watcher in place of FSEvents (`WorkspaceChanges` builds without FSEvents on Linux and stops watching). inotify would replace it.
- `ProcessExitWatch` with `pidfd_open` and `FileWriteWatch` with inotify; on Linux they never fire today.
- Logging through something other than OSLog (it falls back to standard error).
- Streaming HTTP (OpenCode's server-sent events, updates) without `URLSession.bytes`. FoundationNetworking on Linux doesn't stream; the code falls back to whole-body reads.
- The updater: signature checks (Security framework) and installing the app bundle are macOS-only.
- Packaging, the daemon's launch as a user service, and the CLI's install path.
