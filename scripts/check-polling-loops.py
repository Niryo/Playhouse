#!/usr/bin/env python3
"""Reject `for _ in … where COND` loops in Swift sources.

A `where` clause filters iterations; it does not end the loop. With `_` as the loop
variable the clause can never depend on the iteration, so it is always a stop
condition in the wrong place: once COND is false, the loop keeps evaluating it for
every remaining iteration. In the UI tests COND is an accessibility query, and one
such loop idled for about 150 seconds in a single case. Write the stop condition as
`guard COND else { break }` at the top of the body instead.
"""

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
FILES = tuple(sorted((ROOT / "Playhouse").rglob("*.swift")))
POLLING_LOOP = re.compile(r"\bfor\s+_\s+in\s+[^{]*?\bwhere\b")


def main() -> int:
    violations = []
    for path in FILES:
        lines = path.read_text(encoding="utf-8").splitlines()
        # Blank comment lines but keep their places, so a match spanning lines (a `where` on the
        # line after `for _ in …`) is still found and reported at the line of its `for`.
        text = "\n".join("" if line.lstrip().startswith("//") else line for line in lines)
        for match in POLLING_LOOP.finditer(text):
            number = text.count("\n", 0, match.start()) + 1
            violations.append(f"{path.relative_to(ROOT)}:{number}: {lines[number - 1].strip()}")
    if violations:
        print("`for _ in … where COND` keeps evaluating COND after it fails; use `guard COND else { break }`:", file=sys.stderr)
        print("\n".join(violations), file=sys.stderr)
        return 1
    print(f"Polling loops passed: {len(FILES)} Swift files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
