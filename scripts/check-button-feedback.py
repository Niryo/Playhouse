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

    if kind == "Button" and opening_paren >= 0 and (opening_brace < 0 or opening_paren < opening_brace):
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
            if ".buttonHoverPointer()" not in chain:
                errors.append(f"{location}: {kind} is missing buttonHoverPointer()")
            # Window controls use `.nativeHelp`: SwiftUI's `.help` alone does not present its
            # tooltip for most controls in the main window. Menu items (menu-bar commands and
            # `Menu`/`.contextMenu` content) are native menu items and keep `.help`.
            in_menu = name in MENU_BAR_FILES or any(a < start < b for a, b in menus)
            help_modifier = r"\.help" if in_menu else r"\.nativeHelp"
            help_match = re.search(help_modifier + r"\(\s*(\"(?:\\.|[^\"\\])*\"|[^)\n]+)\s*\)", chain)
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

    support = (APP / "WorkspaceSupport.swift").read_text(encoding="utf-8")
    for required in (".onHover", "cursor.push()", "NSCursor.pop()", ".onDisappear"):
        if required not in support:
            errors.append(f"Shared cursor handler is missing {required}")
    # Buttons get the pointing hand through the shared, stack-balanced cursor handler.
    if "hoverCursor(.pointingHand)" not in support:
        errors.append("buttonHoverPointer() does not use the shared handler with NSCursor.pointingHand")

    if errors:
        print("Button feedback check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print(f"Button feedback check passed for {controls_seen} app action controls.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
