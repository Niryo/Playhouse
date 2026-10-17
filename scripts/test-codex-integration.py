#!/usr/bin/env python3

import json
import os
import plistlib
import shutil
import subprocess
import tempfile
import uuid
from pathlib import Path


MARKER_NAME = ".stationai-codex-integration-owner"
MARKER_VALUE = "StationAI Codex integration suite owns this disposable workspace (v1).\n"


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def response_from(completed, command):
    lines = [line for line in completed.stdout.splitlines() if line.strip()]
    require(lines, f"No JSON response for {command}: {completed.stderr}")
    try:
        response = json.loads(lines[-1])
    except json.JSONDecodeError as error:
        raise AssertionError(f"Final CLI output was not JSON: {lines[-1]!r}") from error
    require(completed.returncode == 0 and response.get("ok"), f"{command} failed: {response}")
    return response["result"]


def main():
    if os.environ.get("STATIONAI_RUN_CODEX_INTEGRATION") != "1":
        raise SystemExit(
            "This suite makes live Codex turns. Set STATIONAI_RUN_CODEX_INTEGRATION=1 after confirming `codex login` works."
        )

    repository_root = Path(__file__).resolve().parent.parent
    app_bundle = Path(os.environ.get(
        "STATIONAI_APP_PATH",
        str(Path(tempfile.gettempdir()) / "StationAI-DerivedData/Build/Products/Debug/StationAI.app"),
    ))
    cli = app_bundle / "Contents/MacOS/stationai-cli"
    service_info = app_bundle / "Contents/XPCServices/StationAIBridge.xpc/Contents/Info.plist"
    fixture = Path("/tmp/stationai-bridge-workspaces")
    require(cli.is_file(), f"Bundled CLI is missing: {cli}; run scripts/run.sh first.")
    require((fixture / ".stationai-bridge-fixture").is_file(), "Run scripts/prepare-e2e-fixture.py before this suite.")

    root = Path(tempfile.mkdtemp(prefix="stationai-codex-integration-"))
    marker = root / MARKER_NAME
    marker.write_text(MARKER_VALUE, encoding="utf-8")
    first = root / "primary"
    second = root / "secondary"
    shutil.copytree(fixture / "suggested-parent/primary", first)
    shutil.copytree(fixture / "suggested-parent/group/secondary", second)
    data_directory = root / "stationai-data"
    data_directory.mkdir()
    environment = os.environ.copy()
    environment["STATIONAI_DATA_DIRECTORY"] = str(data_directory)
    environment["STATIONAI_E2E_DEFAULTS_SUITE"] = f"com.stationai.codex-integration.{uuid.uuid4()}"
    with service_info.open("rb") as plist_file:
        environment["STATIONAI_BRIDGE_SERVICE_NAME"] = plistlib.load(plist_file)["CFBundleIdentifier"]

    def run_cli(*command):
        result = subprocess.run(
            [str(cli), *map(str, command)],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
            timeout=180,
        )
        return response_from(result, command)

    def stream_turn(task_id, message, mode="default"):
        process = subprocess.Popen(
            [str(cli), "conversation", "send", task_id, "--message", message, "--mode", mode],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=environment,
            bufsize=1,
        )
        events = []
        final = None
        assert process.stdout is not None
        for line in process.stdout:
            if not line.strip():
                continue
            value = json.loads(line)
            if value.get("ok") is not None and "version" in value:
                final = value
            else:
                events.append(value)
        stderr = process.stderr.read() if process.stderr else ""
        exit_code = process.wait(timeout=30)
        require(exit_code == 0 and final and final.get("ok"), f"Codex turn failed: {final}; {stderr}")
        text_events = [event for event in events if event.get("type") == "text_delta"]
        require(text_events, "Codex produced no streamed assistant text delta before its final response.")
        require(any(event.get("requestID") == final.get("id") for event in events), "Stream events did not match the request ID.")
        return final["result"], events

    try:
        created = run_cli("task", "create", "--title", "Two-root Codex integration", "--root", first, "--root", second)
        task_id = created["id"]
        primary_marker = "StationAI primary integration marker 7F34C2"
        secondary_marker = "StationAI secondary integration marker A19D06"
        primary_file = first / "stationai-primary.txt"
        secondary_file = second / "stationai-secondary.txt"
        primary_baseline = primary_file.read_text(encoding="utf-8")
        secondary_baseline = secondary_file.read_text(encoding="utf-8")
        plan_history, plan_events = stream_turn(
            task_id,
            f"Plan how you would append exactly the line '{primary_marker}' to stationai-primary.txt. Inspect the repository as needed, but do not edit any files. Reply with a concise plan.",
            mode="plan",
        )
        require(primary_file.read_text(encoding="utf-8") == primary_baseline, "Plan mode changed the primary repository file.")
        require(secondary_file.read_text(encoding="utf-8") == secondary_baseline, "Plan mode changed the secondary repository file.")
        require(plan_history.get("messages"), "Plan mode did not return conversation messages.")
        require(any(event.get("type") == "text_delta" for event in plan_events), "Plan mode produced no streamed assistant text.")

        first_history, first_events = stream_turn(
            task_id,
            f"Edit the committed baseline files in both selected repositories. In {first.name}, append exactly the line '{primary_marker}' to stationai-primary.txt. In {second.name}, append exactly the line '{secondary_marker}' to stationai-secondary.txt. Then run a shell command that prints STATIONAI_FIRST_TURN_COMMAND_OK. Do not edit other files. Reply with a short summary.",
        )

        first_file = primary_file
        second_file = secondary_file
        require(primary_marker in first_file.read_text(encoding="utf-8"), "First Codex turn did not change the primary repository file.")
        require(secondary_marker in second_file.read_text(encoding="utf-8"), "First Codex turn did not change the secondary repository file.")
        require(any(event.get("type") == "activity" and "STATIONAI_FIRST_TURN_COMMAND_OK" in json.dumps(event) for event in first_events), "First turn did not stream the shell command output.")
        require(first_history.get("messages"), "First turn did not return conversation messages.")
        first_diff = first_history.get("diff", {}).get("unifiedDiff", "")
        require(primary_marker in first_diff and secondary_marker in first_diff, "First turn diff omitted the actual changed lines from both repositories.")
        changed_rows = [
            event for event in first_events
            if event.get("type") == "activity"
            and ("editing" in json.dumps(event).lower() or "stationai-primary.txt" in json.dumps(event) or "stationai-secondary.txt" in json.dumps(event))
        ]
        require(changed_rows, "First turn did not report a file-change activity row.")

        followup_marker = "StationAI resumed integration marker 38BC11"
        second_history, second_events = stream_turn(
            task_id,
            f"Continue from the instruction and changes in the previous turn. Append exactly the line '{followup_marker}' to stationai-secondary.txt only, then run a shell command that prints STATIONAI_RESUMED_COMMAND_OK. Reply with a short summary.",
        )
        require(followup_marker in second_file.read_text(encoding="utf-8"), "Resumed Codex turn did not update the secondary repository file.")
        require(any(event.get("type") == "activity" and "STATIONAI_RESUMED_COMMAND_OK" in json.dumps(event) for event in second_events), "Resumed turn did not stream its command output.")
        require(len(second_history.get("messages", [])) >= len(first_history.get("messages", [])) + 2, "Resumed history did not retain both turns.")
        second_diff = second_history.get("diff", {}).get("unifiedDiff", "")
        require(followup_marker in second_diff, "Resumed turn diff omitted its changed line.")

        reopened = run_cli("conversation", "history", task_id)
        require(len(reopened.get("messages", [])) == len(second_history.get("messages", [])), "Fresh CLI/XPC connection did not reload the complete conversation history.")
        print("Codex integration passed: Plan mode left both roots unchanged, Code mode streamed turns and changed files in two roots, command output and diffs were captured, the thread resumed, and fresh history reloaded.")
    finally:
        current_marker = root / MARKER_NAME
        if current_marker.is_file() and current_marker.read_text(encoding="utf-8") == MARKER_VALUE:
            shutil.rmtree(root)
        else:
            raise RuntimeError(f"Refusing to remove integration workspace without its ownership marker: {root}")


if __name__ == "__main__":
    main()
