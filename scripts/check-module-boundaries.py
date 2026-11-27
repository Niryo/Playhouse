#!/usr/bin/env python3
"""Keep macOS-only code in the places a Linux port replaces (docs/linux-port-readiness.md).

- PlayhouseCore (Playhouse/Core) imports only Foundation-level modules. A platform framework
  (CryptoKit, JavaScriptCore, Security, CoreServices, OSLog, notify) is imported only under
  `#if canImport(...)`, and the C library only in Core/Platform/POSIX.swift, which is also the
  only file that may write `Darwin.` or `Glibc.`.
- PlayhouseUI (Playhouse/UI) imports SwiftUI or AppKit only inside an `#if canImport(SwiftUI)` or
  `#if os(macOS)` block, so its Apple implementation stays separable from the shared parts.
- The atoms and composites (Playhouse/Atoms, Playhouse/Views) import no UI framework at all: they
  name PlayhouseUI's types, use its shims for what SwiftCrossUI lacks (context menus, shadows,
  hover tracking, continuous corners, materials, masks), name icons by `PHIcon`, and reach AppKit
  only through `PHNative…` views and `Platform.services`.
- Nothing in the app uses SwiftData, Combine or ObservableObject.
- Package.swift keeps its dependency direction: app -> Views -> Atoms -> UI -> Core.

The compiler enforces the same boundaries where it can: Core is built with AppKit, SwiftUI and
SwiftData aliased away (Package.swift), and the Linux CI job builds Core and PlayhouseUI.
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Playhouse"

CORE_ALLOWED = {"Foundation", "FoundationNetworking", "Observation", "Dispatch", "GRDB", "GRDBSQLite"}
CORE_GUARDED = {"CryptoKit", "JavaScriptCore", "Security", "CoreServices", "OSLog", "notify"}
LIBC = {"Darwin", "Glibc", "Musl"}
NEVER = {"AppKit", "SwiftUI", "SwiftData", "Combine", "UIKit", "WebKit", "SwiftTerm", "ServiceManagement", "Cocoa"}
VIEW_ALLOWED = {"Foundation", "Observation", "PlayhouseCore", "PlayhouseUI", "PlayhouseAtoms"}
TEST_ALLOWED = {"XCTest", "GRDB", "PlayhouseCore"}

# SwiftUI forms SwiftCrossUI lacks; atoms and composites use PlayhouseUI's shim instead.
UNSHIMMED = [
    (re.compile(r"\.contextMenu\b"), "use .phContextMenu"),
    (re.compile(r"\.shadow\("), "use .phShadow"),
    (re.compile(r"\.onHover\b|\.onContinuousHover\b"), "use .phOnHover"),
    (re.compile(r"\.mask\("), "use .phMask"),
    (re.compile(r"style:\s*\.continuous\b"), "use PHRoundedRectangle.phContinuous"),
    (re.compile(r"\b(?:ultraThin|thin|regular|thick|ultraThick)Material\b|\.background\(\.bar\)"), "use .phMaterialBackground"),
    (re.compile(r"\b(?:systemName|systemImage):"), "name the icon with PHIcon"),
    (re.compile(r"\bNSViewRepresentable\b|\bNSHosting(?:View|Controller)\b"), "put the AppKit view behind a PHNative… view or a PlayhouseUI shim"),
]
# AppKit types. Foundation's NS types (NSRange, NSString, NSAttributedString, …) are fine.
APPKIT_TYPE = re.compile(
    r"\bNS(?:View|Window|Event|Color|Font|Image|Pasteboard|Workspace|App|Application|Cursor|TextView|ScrollView|"
    r"OpenPanel|SavePanel|Alert|Screen|Popover|Menu|Sound|Bezier|Graphics|BitmapImageRep|TrackingArea|Responder|"
    r"Layout(?:Manager|Constraint)|Dragging|DragOperation|Slider|Button|TextField|Accessibility)\w*\b"
)
# An icon written as an SF Symbol name in an atom's props.
ICON_LITERAL = re.compile(r"\b(?:icon|badgeIcon):\s*\"[a-z0-9]+(?:\.[a-z0-9]+)*\"|\b(?:IconProps\(name|ImageProps\([^)]*placeholder):\s*\"[a-z0-9.]+\"")
FORBIDDEN_EVERYWHERE = [
    (re.compile(r"^\s*(?:@preconcurrency\s+)?import\s+(SwiftData|Combine)\b", re.M), "imports {0}"),
    (re.compile(r"@Model\b"), "uses SwiftData's @Model"),
    (re.compile(r"\bObservableObject\b|@Published\b|@StateObject\b|@ObservedObject\b|@EnvironmentObject\b"), "uses ObservableObject; use @Observable"),
]

IMPORT = re.compile(r"^\s*(?:@preconcurrency\s+|@_exported\s+)?import\s+(?:struct\s+|class\s+|enum\s+|func\s+)?(\w+)", re.M)


def strip_comments_and_strings(source: str) -> str:
    """Blank comments and string literals, keeping line structure, so patterns only see code."""
    out = []
    i, n = 0, len(source)
    while i < n:
        if source.startswith("//", i):
            j = source.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i)); i = j; continue
        if source.startswith("/*", i):
            j = source.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join(c if c == "\n" else " " for c in source[i:j])); i = j; continue
        if source.startswith('"""', i):
            j = source.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append("".join(c if c == "\n" else " " for c in source[i:j])); i = j; continue
        if source[i] == '"':
            j = i + 1
            while j < n and source[j] not in '"\n':
                j += 2 if source[j] == "\\" else 1
            j = min(n, j + 1)
            out.append('"' + " " * max(0, j - i - 2) + ('"' if j - i >= 2 else "")); i = j; continue
        out.append(source[i]); i += 1
    return "".join(out)


def guarded_imports(source: str) -> dict[int, list[str]]:
    """For each line, the `#if` conditions in force there."""
    conditions: list[str] = []
    result = {}
    for number, line in enumerate(source.split("\n"), 1):
        stripped = line.strip()
        if stripped.startswith("#if "):
            conditions.append(stripped[4:])
        elif stripped.startswith("#elseif "):
            if conditions: conditions[-1] = stripped[8:]
        elif stripped.startswith("#else"):
            if conditions: conditions[-1] = "!(" + conditions[-1] + ")"
        elif stripped.startswith("#endif"):
            if conditions: conditions.pop()
        result[number] = list(conditions)
    return result


def check_imports(path: Path, source: str, errors: list[str], allowed: set[str], guarded: set[str], ui: bool = False):
    name = path.relative_to(ROOT).as_posix()
    conditions = guarded_imports(source)
    for match in IMPORT.finditer(source):
        module = match.group(1)
        line = source.count("\n", 0, match.start()) + 1
        where = f"{name}:{line}"
        in_force = conditions.get(line, [])
        if module in allowed:
            continue
        if module in LIBC:
            if path != SOURCES / "Core" / "Platform" / "POSIX.swift":
                errors.append(f"{where}: imports {module}; call the C library through POSIX (Core/Platform/POSIX.swift)")
            continue
        if ui and module in {"SwiftUI", "AppKit", "QuartzCore", "ImageIO", "UniformTypeIdentifiers", "ObjectiveC"}:
            if not any(re.search(r"canImport\((SwiftUI|AppKit)\)|os\(macOS\)", c) for c in in_force):
                errors.append(f"{where}: imports {module} outside an #if canImport(SwiftUI) / #if os(macOS) block")
            continue
        if module in guarded:
            if not any(f"canImport({module})" in c for c in in_force):
                errors.append(f"{where}: imports {module} outside #if canImport({module})")
            continue
        errors.append(f"{where}: imports {module}, which this module must not use")


def main() -> int:
    errors: list[str] = []
    counts = {"core": 0, "ui": 0, "views": 0}

    for path in sorted((SOURCES / "Core").rglob("*.swift")):
        counts["core"] += 1
        source = path.read_text(encoding="utf-8")
        check_imports(path, source, errors, CORE_ALLOWED, CORE_GUARDED)
        if path != SOURCES / "Core" / "Platform" / "POSIX.swift":
            code = strip_comments_and_strings(source)
            for match in re.finditer(r"\b(Darwin|Glibc)\.\w", code):
                line = code.count("\n", 0, match.start()) + 1
                errors.append(f"{path.relative_to(ROOT)}:{line}: calls {match.group(1)} directly; go through POSIX")

    for path in sorted((SOURCES / "UI").rglob("*.swift")):
        counts["ui"] += 1
        check_imports(path, path.read_text(encoding="utf-8"), errors, {"Foundation", "Observation", "PlayhouseCore"}, set(), ui=True)

    for folder in ("Atoms", "Views"):
        for path in sorted((SOURCES / folder).rglob("*.swift")):
            counts["views"] += 1
            source = path.read_text(encoding="utf-8")
            allowed = VIEW_ALLOWED - ({"PlayhouseAtoms"} if folder == "Atoms" else set())
            check_imports(path, source, errors, allowed, set())
            code = strip_comments_and_strings(source)
            raw = source
            for pattern, advice in UNSHIMMED:
                for match in pattern.finditer(code):
                    line = code.count("\n", 0, match.start()) + 1
                    errors.append(f"{path.relative_to(ROOT)}:{line}: {match.group(0).strip()} — {advice}")
            for match in APPKIT_TYPE.finditer(code):
                line = code.count("\n", 0, match.start()) + 1
                errors.append(f"{path.relative_to(ROOT)}:{line}: names AppKit's {match.group(0)}; use a PlayhouseUI type or Platform.services")
            for match in ICON_LITERAL.finditer(raw):
                line = raw.count("\n", 0, match.start()) + 1
                errors.append(f"{path.relative_to(ROOT)}:{line}: {match.group(0)} — name the icon with PHIcon (PHIcon.x.name in plugin props)")

    # The CLI and the daemon's entry point are Foundation programs over PlayhouseCore.
    for folder in ("CLI", "Bridge"):
        for path in sorted((SOURCES / folder).rglob("*.swift")):
            check_imports(path, path.read_text(encoding="utf-8"), errors, {"Foundation", "PlayhouseCore"}, set())

    for path in sorted((SOURCES / "CoreTests").rglob("*.swift")):
        check_imports(path, path.read_text(encoding="utf-8"), errors, CORE_ALLOWED | TEST_ALLOWED, set())

    for path in sorted(SOURCES.rglob("*.swift")):
        if "PlayhouseUITests" in path.parts or "BridgeTests" in path.parts:
            continue
        code = strip_comments_and_strings(path.read_text(encoding="utf-8"))
        for pattern, message in FORBIDDEN_EVERYWHERE:
            for match in pattern.finditer(code):
                line = code.count("\n", 0, match.start()) + 1
                detail = message.format(*match.groups()) if match.groups() else message
                errors.append(f"{path.relative_to(ROOT)}:{line}: {detail}")

    manifest = (SOURCES / "Package.swift").read_text(encoding="utf-8")
    expected = {
        "PlayhouseCore": set(),
        "PlayhouseUI": {"PlayhouseCore"},
        "PlayhouseAtoms": {"PlayhouseUI"},
        "PlayhouseViews": {"PlayhouseAtoms"},
    }
    for target, dependencies in expected.items():
        match = re.search(r'\.target\(\s*name:\s*"' + target + r'",\s*dependencies:\s*\[([^\]]*)\]', manifest)
        if not match:
            errors.append(f"Playhouse/Package.swift: target {target} is missing or has no dependency list")
            continue
        found = set(re.findall(r'"(Playhouse\w+)"', match.group(1)))
        if found != dependencies:
            errors.append(f"Playhouse/Package.swift: {target} depends on {sorted(found)}, expected {sorted(dependencies)}")

    if errors:
        print("Module boundary check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"Module boundaries passed: {counts['core']} core, {counts['ui']} PlayhouseUI and {counts['views']} atom/composite files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
