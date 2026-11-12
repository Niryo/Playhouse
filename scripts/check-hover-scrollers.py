#!/usr/bin/env python3
"""Verify every app scroll view reveals its scrollers only on hover (see HoverRevealScrollers.swift).

A SwiftUI ScrollView, List, or Form must carry `.hoverRevealScrollers()` inside its content,
and a file that builds an AppKit scroll view must call `HoverRevealScrollers.install(on:)`.
SwiftUI's TextEditor hides its scroll view, so the app uses SkillTextEditor instead.
"""

from pathlib import Path
import importlib.util
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Playhouse" / "App"
FILES = tuple(sorted(APP.rglob("*.swift")))
CONTAINER = re.compile(r"(?<![A-Za-z.])(ScrollView|List|Form)\s*(?:\(|\{)")
APPKIT_SCROLL_VIEW = re.compile(r"\bscrollableTextView\(\)|\b\w*ScrollView\(\)|\bNSScrollView\(frame")
TEXT_EDITOR = re.compile(r"(?<![A-Za-z])TextEditor\s*\(")

_spec = importlib.util.spec_from_file_location("button_feedback", ROOT / "scripts" / "check-button-feedback.py")
_button_feedback = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_button_feedback)
matching = _button_feedback.matching


def content_range(source: str, match: re.Match) -> tuple[int, int] | None:
    index = match.end() - 1
    if source[index] == "(":
        closing = matching(source, "(", ")", index)
        if closing is None:
            return None
        index = closing + 1
        while index < len(source) and source[index].isspace():
            index += 1
    if index >= len(source) or source[index] != "{":
        return None
    closing = matching(source, "{", "}", index)
    return (index, closing) if closing is not None else None


def main() -> int:
    errors: list[str] = []
    containers = 0
    for path in FILES:
        name = path.relative_to(APP).as_posix()
        source = path.read_text(encoding="utf-8")
        for match in CONTAINER.finditer(source):
            span = content_range(source, match)
            if span is None:
                continue
            containers += 1
            if ".hoverRevealScrollers()" not in source[span[0] : span[1]]:
                line = source.count("\n", 0, match.start()) + 1
                errors.append(f"{name}:{line}: {match.group(1)} content lacks .hoverRevealScrollers()")
        for match in TEXT_EDITOR.finditer(source):
            line = source.count("\n", 0, match.start()) + 1
            errors.append(f"{name}:{line}: TextEditor's scroll view can't reveal on hover; use SkillTextEditor")
        if APPKIT_SCROLL_VIEW.search(source) and "HoverRevealScrollers.install(on:" not in source:
            errors.append(f"{name}: builds an AppKit scroll view without HoverRevealScrollers.install(on:)")
    if errors:
        print("Hover-revealed scroller check failed:", file=sys.stderr)
        for error in errors:
            print(f"  {error}", file=sys.stderr)
        return 1
    print(f"Hover-revealed scrollers: {containers} SwiftUI scroll containers reveal their scrollers on hover.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
