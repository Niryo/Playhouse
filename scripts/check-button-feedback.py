#!/usr/bin/env python3
"""Verify hover feedback is attached to every app action control."""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Playhouse" / "App"
FILES = tuple(sorted(APP.rglob("*.swift")))
# Files whose controls are menu-bar commands rather than views in the window.
MENU_BAR_FILES = {"PlayhouseApp.swift", "DebugConversationImport/DebugConversationImport.swift"}
CONTROL = re.compile(r"\b(Button(?=\s*(?:\(|\{))|Link(?=\s*\()|Menu(?=\s*\{))")
# Selection controls AppKit draws: they need the pointing hand too, and keep their label as the hint.
SELECTION = re.compile(r"\b(Picker|Toggle)(?=\s*\()")


def matching(source: str, opening: str, closing: str, start: int) -> int | None:
    depth = 0
    quoted = False
    escaped = False
    line_comment = False
    block_comment = 0
    index = start
    while index < len(source):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""
        if line_comment:
            if char == "\n":
                line_comment = False
        elif block_comment:
            if char == "/" and next_char == "*":
                block_comment += 1
                index += 1
            elif char == "*" and next_char == "/":
                block_comment -= 1
                index += 1
        elif quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == "/" and next_char == "/":
            line_comment = True
            index += 1
        elif char == "/" and next_char == "*":
            block_comment = 1
            index += 1
        elif char == '"':
            quoted = True
        elif char == opening:
            depth += 1
        elif char == closing:
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return None


def skip_space(source: str, index: int) -> int:
    while index < len(source) and source[index].isspace():
        index += 1
    return index


def control_end(source: str, kind: str, start: int) -> int | None:
    opening_paren = source.find("(", start, start + 80)
    opening_brace = source.find("{", start, start + 350)
    if kind == "Link":
        end = matching(source, "(", ")", opening_paren) if opening_paren >= 0 else None
        if end is None:
            return None
        next_token = skip_space(source, end + 1)
        if next_token < len(source) and source[next_token] == "{":
            return matching(source, "{", "}", next_token)
        return end

    if kind in ("Button", "Picker", "Toggle") and opening_paren >= 0 and (opening_brace < 0 or opening_paren < opening_brace):
        end = matching(source, "(", ")", opening_paren)
        if end is None:
            return None
        next_token = skip_space(source, end + 1)
        if next_token < len(source) and source[next_token] == "{":
            opening_brace = next_token
        else:
            return end

    if opening_brace < 0:
        return None
    end = matching(source, "{", "}", opening_brace)
    if end is None:
        return None

    # Button and Menu use a second closure for the visible label.
    if re.match(r"\s*label\s*:", source[end + 1 : end + 100]):
        label_brace = source.find("{", end + 1, min(len(source), end + 180))
        if label_brace >= 0:
            label_end = matching(source, "{", "}", label_brace)
            if label_end is not None:
                end = label_end
    return end


def modifier_chain(source: str, end: int, declaration_indent: int) -> str:
    line_end = source.find("\n", end)
    if line_end < 0:
        return ""
    lines = source[line_end + 1 :].splitlines(keepends=True)
    chain: list[str] = []
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        indent = len(line) - len(line.lstrip(" \t"))
        if indent <= declaration_indent and not stripped.startswith("."):
            break
        chain.append(line)
    return "".join(chain)


def menu_content_ranges(source: str) -> list[tuple[int, int]]:
    """Spans of `Menu { ... }` and `.contextMenu { ... }` content, whose buttons become menu items."""
    ranges = []
    for match in re.finditer(r"(?<![A-Za-z])Menu\s*\{|\.contextMenu\s*\{", source):
        opening = match.end() - 1
        closing = matching(source, "{", "}", opening)
        if closing is not None:
            ranges.append((opening, closing))
    return ranges


def main() -> int:
    errors: list[str] = []
    controls_seen = 0
    for path in FILES:
        name = path.relative_to(APP).as_posix()
        source = path.read_text(encoding="utf-8")
        menus = menu_content_ranges(source)
        for match in CONTROL.finditer(source):
            kind = match.group(1)
            start = match.start()
            end = control_end(source, kind, start)
            location = f"{name}:{source.count(chr(10), 0, start) + 1}"
            if end is None:
                errors.append(f"{location}: could not locate the end of this {kind}")
                continue
            controls_seen += 1
            line_start = source.rfind("\n", 0, start) + 1
            indent = len(source[line_start:start])
            chain = modifier_chain(source, end, indent)
            # SwiftUI draws a `.plain` button, so its pointer style reaches it without the AppKit
            # cursor view; every other control may be drawn by AppKit and needs that view.
            pointer = "plainButtonHoverPointer" if kind == "Button" and ".buttonStyle(.plain)" in chain else "buttonHoverPointer"
            other = "buttonHoverPointer" if pointer == "plainButtonHoverPointer" else "plainButtonHoverPointer"
            if f".{pointer}()" not in chain and not re.search(r"//\s*no-pointer:\s*\S", chain):
                errors.append(f"{location}: {kind} is missing {pointer}()"
                              + (f" (it has {other}(), which is for " + ("controls AppKit draws)" if pointer == "plainButtonHoverPointer" else "plain buttons SwiftUI draws)") if f".{other}()" in chain else ""))
            # Window controls use `.nativeHelp`: SwiftUI's `.help` alone does not present its
            # tooltip for most controls in the main window. Menu items (menu-bar commands and
            # `Menu`/`.contextMenu` content) are native menu items and keep `.help`.
            in_menu = name in MENU_BAR_FILES or any(a < start < b for a, b in menus)
            # `.shortcutHelp(text, shortcut:)` is `.nativeHelp` naming the control's keyboard shortcut.
            help_modifier = r"\.help" if in_menu else r"\.nativeHelp"
            help_match = (re.search(help_modifier + r"\(\s*(\"(?:\\.|[^\"\\])*\"|[^)\n]+)\s*\)", chain)
                          or (None if in_menu else re.search(r"\.shortcutHelp\(\s*(\"(?:\\.|[^\"\\])*\"|[^\n]+?)\s*,\s*shortcut:", chain)))
            if not help_match and re.search(r"//\s*no-tooltip:\s*\S", chain):
                # Deliberate opt-out for controls whose tooltip would only restate the obvious.
                pass
            elif not help_match:
                errors.append(f"{location}: {kind} is missing a help hint"
                              + ("" if in_menu else " (use .nativeHelp, not .help)"))
            else:
                hint = help_match.group(1).strip().strip('"')
                if not hint or hint == "Activate this button":
                    errors.append(f"{location}: {kind} has a missing or generic help hint")
        for match in SELECTION.finditer(source):
            kind = match.group(1)
            start = match.start()
            if name in MENU_BAR_FILES or any(a < start < b for a, b in menus):
                continue
            end = control_end(source, kind, start)
            location = f"{name}:{source.count(chr(10), 0, start) + 1}"
            if end is None:
                errors.append(f"{location}: could not locate the end of this {kind}")
                continue
            controls_seen += 1
            line_start = source.rfind("\n", 0, start) + 1
            chain = modifier_chain(source, end, len(source[line_start:start]))
            if ".buttonHoverPointer()" not in chain and not re.search(r"//\s*no-pointer:\s*\S", chain):
                errors.append(f"{location}: {kind} is missing buttonHoverPointer()")

        # A view made clickable with a tap gesture is a control too, unless it says why it is not.
        for match in re.finditer(r"\.onTapGesture\b", source):
            start = match.start()
            location = f"{name}:{source.count(chr(10), 0, start) + 1}"
            opening = source.find("{", start)
            end = matching(source, "{", "}", opening) if opening >= 0 else None
            if end is None:
                errors.append(f"{location}: could not locate the end of this onTapGesture")
                continue
            controls_seen += 1
            line_start = source.rfind("\n", 0, start) + 1
            chain = modifier_chain(source, end, len(source[line_start:start]) - 1)
            if ".plainButtonHoverPointer()" not in chain and not re.search(r"//\s*no-pointer:\s*\S", chain):
                errors.append(f"{location}: onTapGesture is missing plainButtonHoverPointer()")

    support = (APP / "WorkspaceSupport.swift").read_text(encoding="utf-8")
    # Buttons get the pointing hand from a cursor the system re-applies (SwiftUI's pointer style,
    # or an AppKit cursor rect before macOS 15). A cursor pushed from `onHover` is replaced by the
    # arrow whenever AppKit re-evaluates the window's cursor, so the hover handler must never push.
    # SwiftUI's pointer style never reaches a control AppKit draws (a bordered button, a segmented
    # picker, a toggle), so over those an overlay that answers the window's cursor updates sets it.
    if "hoverCursor(.pointingHand, overAppKitControl: true)" not in support or "hoverCursor(.pointingHand)\n" not in support:
        errors.append("buttonHoverPointer() and plainButtonHoverPointer() must use the shared hover cursor with .pointingHand")
    hover = re.search(r"func hoverCursor\(_ kind: HoverCursorKind\?, overAppKitControl: Bool = false\)[^{]*\{(.*?)\n    \}", support, re.S)
    if not hover:
        errors.append("WorkspaceSupport.swift does not define hoverCursor(_ kind: HoverCursorKind?, overAppKitControl:)")
    elif hover.group(1).count("pointerStyle(kind?.pointerStyle)") != 2 or hover.group(1).count("overlay(HoverCursorArea(") != 2:
        errors.append("hoverCursor() must use SwiftUI's pointer style, with the cursor-update overlay over AppKit controls and before macOS 15")
    if "case .pointingHand: .link" not in support or "addCursorRect(bounds, cursor: cursor)" not in support:
        errors.append("The hover cursor must map the pointing hand to .link and add its cursor rect")
    if "override func cursorUpdate(with event: NSEvent)" not in support or "event.type == .cursorUpdate, event.window === window" not in support:
        errors.append("HoverCursorArea must take the window's cursor updates, and only those, as the hit view")
    if re.search(r"\.onHover[^\n]*\n(?:[^\n]*\n){0,6}?[^\n]*\.push\(\)", support):
        errors.append("WorkspaceSupport.swift must not push a cursor on hover; a pushed cursor is lost on cursor updates")

    if errors:
        print("Button feedback check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"Button feedback check passed for {controls_seen} app action controls.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
