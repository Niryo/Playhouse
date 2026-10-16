#!/usr/bin/env python3

import ast
import json
import re
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
CONTRACT_PATH = REPOSITORY_ROOT / "StationAI/BridgeTests/BridgeTestContracts.json"
CLI_TEST_PATH = REPOSITORY_ROOT / "scripts/test-bridge.py"
UI_TEST_PATH = REPOSITORY_ROOT / "StationAI/StationAIUITests/StationAIUITests.swift"
CONTRACT_ANNOTATION = re.compile(r"^\s*# case-contract: (test_[A-Za-z0-9_]+) \| (.+)$")
SWIFT_ANNOTATION = re.compile(r"^\s*// case-contract: (test_[A-Za-z0-9_]+) \| (.+)$")


def python_cases(path: Path) -> tuple[set[str], dict[str, str]]:
    source = path.read_text(encoding="utf-8")
    tree = ast.parse(source, filename=str(path))
    names = {
        node.name
        for node in ast.walk(tree)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        and node.name.startswith("test_")
    }
    all_names = [
        node.name
        for node in ast.walk(tree)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        and node.name.startswith("test_")
    ]
    if len(all_names) != len(set(all_names)):
        raise SystemExit("CLI suite contains duplicate test case names.")
    annotations: dict[str, str] = {}
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


def swift_cases(path: Path) -> tuple[set[str], dict[str, str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    all_names = re.findall(r"\bfunc\s+(test_[A-Za-z0-9_]+)\s*\(", "\n".join(lines))
    if len(all_names) != len(set(all_names)):
        raise SystemExit("UI suite contains duplicate test case names.")
    names = set(all_names)
    annotations: dict[str, str] = {}
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
    cli_names, cli_contracts = python_cases(CLI_TEST_PATH)
    ui_names, ui_contracts = swift_cases(UI_TEST_PATH)

    problems = []
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
