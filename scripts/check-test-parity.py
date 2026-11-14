#!/usr/bin/env python3

import ast
import json
import re
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
CONTRACT_PATH = REPOSITORY_ROOT / "Playhouse/BridgeTests/BridgeTestContracts.json"
CLI_TEST_PATHS = [
    REPOSITORY_ROOT / "scripts/test-bridge.py",
    *sorted((REPOSITORY_ROOT / "scripts/bridge_test_cases").glob("cases_*.py")),
]
UI_TEST_PATHS = sorted((REPOSITORY_ROOT / "Playhouse/PlayhouseUITests").glob("PlayhouseUITests*.swift"))
CONTRACT_ANNOTATION = re.compile(r"^\s*# case-contract: (test_[A-Za-z0-9_]+) \| (.+)$")
SWIFT_ANNOTATION = re.compile(r"^\s*// case-contract: (test_[A-Za-z0-9_]+) \| (.+)$")


def python_cases(paths: list[Path]) -> tuple[set[str], dict[str, str]]:
    names: set[str] = set()
    annotations: dict[str, str] = {}
    for path in paths:
        source = path.read_text(encoding="utf-8")
        tree = ast.parse(source, filename=str(path))
        all_names = [
            node.name
            for node in ast.walk(tree)
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            and node.name.startswith("test_")
        ]
        if names.intersection(all_names) or len(all_names) != len(set(all_names)):
            raise SystemExit("CLI suite contains duplicate test case names.")
        names.update(all_names)
        lines = source.splitlines()
        for index, line in enumerate(lines):
            match = CONTRACT_ANNOTATION.match(line)
            if not match:
                continue
            case_id, expectation = match.groups()
            next_code = index + 1
            while next_code < len(lines) and not lines[next_code].strip():
                next_code += 1
            if next_code >= len(lines) or not re.match(r"\s*def " + re.escape(case_id) + r"\s*\(", lines[next_code]):
                raise SystemExit(f"CLI contract annotation for {case_id} must immediately precede its test.")
            if case_id in annotations:
                raise SystemExit(f"CLI has duplicate contract annotations for {case_id}.")
            annotations[case_id] = expectation
    return names, annotations


def swift_cases(paths: list[Path]) -> tuple[set[str], dict[str, str]]:
    names: set[str] = set()
    annotations: dict[str, str] = {}
    for path in paths:
        lines = path.read_text(encoding="utf-8").splitlines()
        all_names = re.findall(r"\bfunc\s+(test_[A-Za-z0-9_]+)\s*\(", "\n".join(lines))
        if names.intersection(all_names) or len(all_names) != len(set(all_names)):
            raise SystemExit("UI suite contains duplicate test case names.")
        names.update(all_names)
        for index, line in enumerate(lines):
            match = SWIFT_ANNOTATION.match(line)
            if not match:
                continue
            case_id, expectation = match.groups()
            next_code = index + 1
            while next_code < len(lines) and not lines[next_code].strip():
                next_code += 1
            if next_code >= len(lines) or not re.match(r"\s*func " + re.escape(case_id) + r"\s*\(", lines[next_code]):
                raise SystemExit(f"UI contract annotation for {case_id} must immediately precede its test.")
            if case_id in annotations:
                raise SystemExit(f"UI suite has duplicate contract annotations for {case_id}.")
            annotations[case_id] = expectation
    return names, annotations


def composer_coverage_problems(source: str) -> list[str]:
    """Catch known false-positive UI checks; reviewers still assess behavior."""
    case_id = "test_conversation_composer_rejects_blank_and_supports_live_turn_controls"
    match = re.search(r"func " + case_id + r"\(\).*?(?=\n    func test_|\Z)", source, re.S)
    if not match:
        return ["Composer UI coverage case is missing."]
    body = match.group(0)
    problems = []
    if re.search(r"\bapp\.scrollBars", body):
        problems.append("Composer/transcript scrollbar assertions must be scoped to their own scroll view.")
    if "composer.frame.height" in body:
        problems.append("Composer growth assertions must measure the viewport, not the text document.")
    required = {
        'editorViewport.frame.height >= 205': "initial expansion of a restored long draft",
        'editorViewport.frame.height > fiveLineHeight': "visible growth beyond five lines",
        'editorViewport.frame.height > shortHeight': "growth from wrapped text",
        'editorViewport.frame.height < 60': "shrinking after replacement",
        'editorViewport.scrollBars.firstMatch': "the composer scrollbar",
        'transcriptScrollView.scrollBars.firstMatch': "the transcript scrollbar",
        'editorViewport.swipeUp()': "scrolling to later draft content",
        'editorViewport.swipeDown()': "scrolling to earlier draft content",
        'draftEditor.frame.minY < draftTopPosition': "asserted movement to later draft content",
        'draftEditor.frame.minY > draftLowerPosition': "asserted movement to earlier draft content",
        'titleComposer.typeKey(.return, modifierFlags: [])': "Return submission",
        '"Before\\nAfter"': "newline insertion at the caret",
    }
    for marker, behavior in required.items():
        if marker not in body:
            problems.append(f"Composer UI coverage is missing {behavior}.")
    return problems


def main() -> None:
    contracts = json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))
    contract_names = [contract.get("id") for contract in contracts]
    if not contract_names or any(not isinstance(name, str) for name in contract_names):
        raise SystemExit("The shared bridge/UI test contract list must contain named cases.")
    if len(contract_names) != len(set(contract_names)):
        raise SystemExit("The shared bridge/UI test contract list contains duplicate case IDs.")
    expectations = {contract["id"]: contract.get("expectation") for contract in contracts}
    if any(not isinstance(text, str) or not text.strip() for text in expectations.values()):
        raise SystemExit("Every shared test contract must have a non-empty expectation.")

    expected = set(contract_names)
    cli_names, cli_contracts = python_cases(CLI_TEST_PATHS)
    ui_names, ui_contracts = swift_cases(UI_TEST_PATHS)

    ui_source = "\n".join(path.read_text(encoding="utf-8") for path in UI_TEST_PATHS)
    problems = composer_coverage_problems(ui_source)
    for label, actual, annotated in [
        ("CLI", cli_names, cli_contracts),
        ("UI", ui_names, ui_contracts),
    ]:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        if missing:
            problems.append(f"{label} suite is missing cases: {', '.join(missing)}")
        if extra:
            problems.append(f"{label} suite has unpaired cases: {', '.join(extra)}")
        missing_annotations = sorted(expected - set(annotated))
        extra_annotations = sorted(set(annotated) - expected)
        if missing_annotations:
            problems.append(f"{label} suite is missing shared expectation annotations: {', '.join(missing_annotations)}")
        if extra_annotations:
            problems.append(f"{label} suite has unpaired expectation annotations: {', '.join(extra_annotations)}")
        for case_id in sorted(expected & set(annotated)):
            if annotated[case_id] != expectations[case_id]:
                problems.append(f"{label} expectation for {case_id} does not match the shared contract.")

    if problems:
        raise SystemExit("CLI/UI test parity failed:\n- " + "\n- ".join(problems))

    print(f"CLI/UI parity passed: {len(expected)} identical named cases and shared expectations.")


if __name__ == "__main__":
    main()
