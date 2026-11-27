#!/usr/bin/env python3
"""Keep the composites built from atoms (Playhouse/Core/Plugins/README.md, "Composites").

Every view in Playhouse/Views, and the ordinary app UI listed in APP_VIEWS, is composed of the
atoms in Playhouse/Atoms (AtomStack, AtomText, AtomButton, ...), styled through their props. So a
Linux port reimplements the atoms once and every composite follows. This rejects there:

- raw views that an atom stands for: text, stacks, buttons, shapes, images, labels, spacers,
  dividers and the standard controls (PHText, PHHStack, PHVStack, PHZStack, PHButton,
  PHRectangle, PHTextField, PHToggle, PHPicker, PHProgressView, ...);
- styling modifiers, whose job is an atom prop's (.font, .padding, .frame, .background,
  .foregroundStyle, .overlay, .clipShape, .lineLimit, .buttonStyle, .opacity, .phShadow, ...),
  and tooltips and hover pointers, which the atoms' `help` prop and Button already give.

Behavior stays native around the atoms: gestures, drag and drop, keyboard handling, focus,
alerts and sheets, animations and transitions, geometry reading, and the scroll engines of the
transcript. Native views the atoms don't draw (the text editors, the terminal and the Monaco
diff, reached through NativeViews.factory) are framed by the allowlist below, which names each
exception, the file it lives in and why.
"""

from __future__ import annotations

from pathlib import Path
import importlib.util
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Playhouse"

_spec = importlib.util.spec_from_file_location("boundaries", ROOT / "scripts" / "check-module-boundaries.py")
_boundaries = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_boundaries)
strip_comments_and_strings = _boundaries.strip_comments_and_strings

# The ordinary app UI held to the same rule: (file, view). The rest of App/ is windows, menus,
# AppKit views and platform services, which a port replaces rather than reuses.
APP_VIEWS = [
    ("App/PlayhouseApp.swift", "PluginsMenuContent"),
    ("App/TaskTerminalPanel.swift", "TaskTerminalPanel"),
    ("App/TaskTerminalPanel.swift", "TerminalPaneView"),
    ("App/UpdateController.swift", "ReleaseNotesView"),
    ("App/UpdateController.swift", "UpdateSettingsSection"),
]

RAW_VIEWS = (
    "Text|HStack|VStack|ZStack|Button|Rectangle|RoundedRectangle|UnevenRoundedRectangle|Capsule|Circle|Ellipse|"
    "Image|Label|Spacer|Divider|ProgressView|Toggle|TextField|SecureField|Picker|DatePicker|Menu|Link|Form|Section|"
    "List|GroupBox|DisclosureGroup|Grid|GridRow|LabeledContent|ScrollView|LazyVStack|LazyHStack|NavigationSplitView|TabView"
)
RAW_VIEW = re.compile(rf"\bPH(?:{RAW_VIEWS})\b(?=\s*[(.{{])")
RAW_APP_VIEW = re.compile(rf"\b(?:{RAW_VIEWS})\b(?=\s*[(.{{])")
STYLING = (
    "font|fontWeight|fontDesign|padding|frame|background|foregroundStyle|foregroundColor|overlay|clipShape|clipped|"
    "cornerRadius|border|fill|stroke|strokeBorder|opacity|tint|lineLimit|lineSpacing|tracking|kerning|truncationMode|"
    "multilineTextAlignment|textSelection|monospacedDigit|fixedSize|layoutPriority|contentShape|buttonStyle|"
    "textFieldStyle|pickerStyle|toggleStyle|labelStyle|datePickerStyle|menuStyle|controlSize|imageScale|"
    "symbolRenderingMode|phShadow|phMaterialBackground|nativeHelp|help|buttonHoverPointer|plainButtonHoverPointer|"
    "labelsHidden|scaleEffect"
)
STYLING_MODIFIER = re.compile(rf"\.(?:{STYLING})\b(?=\s*\()|\.(?:background|overlay)\b(?=\s*{{)")
# A shape or color used as a view, or a color chained into a style.
RAW_COLOR = re.compile(r"\b(?:PHColor|WorkspaceTheme)\.\w+")

# Native framework boundaries that need a concrete SwiftUI view, not a nested composite.
# Each exemption is tied to its file, token, and the expression on that source line.
ALLOWLIST = {
    ("Views/KanbanBoardView.swift", ".clipShape"): ".clipShape(ChatSidebarClip(",
    ("Views/PluginCatalogView.swift", "PHNavigationSplitView"): "PHNavigationSplitView {",
    ("Views/TaskConversationRendering.swift", ".background"): ".background {",
    ("Views/TaskConversationTranscriptView.swift", "PHScrollView"): "PHScrollView {",
    ("Views/TranscriptLayout.swift", "PHColor.clear"): "PHColor.clear.accessibilityHidden(true)",
    ("Views/WorkspaceSettingsView.swift", "PHTabView"): "PHTabView {",
    ("Views/WorkspaceSettingsView.swift", ".background"): ".background {",
}

# SwiftUI presents system alerts/dialogs with Text and Button values, including cancel and
# destructive roles. Permit those controls only in the trailing closures of those APIs.
DIALOG_TOKENS = {"PHButton", "PHText", ".buttonHoverPointer", ".nativeHelp"}


def matching_end(code: str, start: int) -> int | None:
    depth = 1
    opening = code[start]
    closing = {"(": ")", "{": "}"}[opening]
    for index in range(start + 1, len(code)):
        char = code[index]
        depth += (char == opening) - (char == closing)
        if depth == 0:
            return index + 1
    return None


def native_dialog_bodies(code: str) -> list[range]:
    paths = []
    for dialog in re.finditer(r"\.(?:alert|confirmationDialog)\s*\(", code):
        after_arguments = matching_end(code, dialog.end() - 1)
        if after_arguments is None:
            continue
        actions = re.match(r"\s*\{", code[after_arguments:])
        if not actions:
            continue
        start = after_arguments + actions.end() - 1
        end = matching_end(code, start)
        if end is None:
            continue
        message = re.match(r"\s*message:\s*\{", code[end:])
        if message:
            end = matching_end(code, end + message.end() - 1) or end
        paths.append(range(start, end))
    return paths


def scoped(code: str, views: list[str]) -> str:
    """Only the named structs of `code`, everything else blanked, keeping line numbers."""
    keep = [False] * len(code)
    for view in views:
        match = re.search(rf"\bstruct\s+{view}\b[^{{]*{{", code)
        if not match:
            continue
        depth, i = 1, match.end()
        while i < len(code) and depth:
            depth += {"{": 1, "}": -1}.get(code[i], 0)
            i += 1
        for j in range(match.start(), i):
            keep[j] = True
    return "".join(c if keep[i] or c == "\n" else " " for i, c in enumerate(code))


def violations(path: Path) -> list[tuple[int, str]]:
    code = strip_comments_and_strings(path.read_text(encoding="utf-8"))
    name = path.relative_to(SOURCES).as_posix()
    views = [view for file, view in APP_VIEWS if file == name]
    if views:
        code = scoped(code, views)
    dialogs = native_dialog_bodies(code)
    lines = code.splitlines()
    found = []
    patterns = [RAW_VIEW, STYLING_MODIFIER, RAW_COLOR]
    if views:
        patterns.append(RAW_APP_VIEW)
    allowed = set()
    for pattern in patterns:
        for match in pattern.finditer(code):
            token = match.group(0)
            if token == ".frame" and re.match(r"\s*\(\s*in:", code[match.end():]):
                continue
            line = code.count("\n", 0, match.start()) + 1
            if token in DIALOG_TOKENS and any(match.start() in body for body in dialogs):
                continue
            key = (name, token)
            expression = ALLOWLIST.get(key)
            if expression and key not in allowed and expression in lines[line - 1]:
                allowed.add(key)
                continue
            found.append((line, token))
    return sorted(found)


def checked_files(arguments: list[str]) -> list[Path]:
    if arguments:
        return [Path(argument).resolve() for argument in arguments]
    return sorted((SOURCES / "Views").rglob("*.swift")) + sorted({SOURCES / name for name, _ in APP_VIEWS})


def main() -> int:
    summary = "--summary" in sys.argv
    files = checked_files([argument for argument in sys.argv[1:] if not argument.startswith("--")])
    errors: list[str] = []
    for path in files:
        name = path.relative_to(SOURCES).as_posix()
        found = violations(path)
        if summary:
            if found:
                print(f"{len(found):5}  {name}")
            continue
        for line, token in found:
            errors.append(f"Playhouse/{name}:{line}: {token} in a composite; compose atoms and style them with their props")
    if summary:
        return 0
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        print(f"{len(errors)} raw UI parts in composites (scripts/check-atom-composites.py)", file=sys.stderr)
        return 1
    print(f"Composites are built from atoms ({len(files)} files).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
