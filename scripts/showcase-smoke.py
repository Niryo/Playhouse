#!/usr/bin/env python3
"""Drive every Component Catalog showcase through playhouse-plugin-dev.

One generic driver for all showcases, with no per-showcase scripts: it loads the
showcase, checks the tree has no error elements, then taps every element with an
onTap action and types into every element with an onChange action, re-reading the
tree after each so newly revealed elements are exercised too. Any failed action,
JS exception, error element or invalid state fails the run. Live showcases
(`"live": true`, which need the real daemon) are skipped.
"""

import argparse
import json
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

MAX_INTERACTIONS = 60
REPLY_TIMEOUT = 75
LOAD_TIMEOUT = 20
TYPED_TEXT = "smoke test"


class RunnerSession:
    def __init__(self, runner, directory):
        self.process = subprocess.Popen(
            [str(runner), str(directory), "--json"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        self.lines = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.process.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def next_message(self, timeout):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("playhouse-plugin-dev did not reply in time")
            line = self.lines.get(timeout=remaining)
            if line is None:
                raise RuntimeError("playhouse-plugin-dev exited: " + self.process.stderr.read())
            line = line.strip()
            if line:
                return json.loads(line)

    def wait_for_load(self):
        message = self.next_message(LOAD_TIMEOUT)
        if message.get("event") != "loaded":
            raise RuntimeError(f"expected the loaded event, got {message}")
        if not message.get("ok", True):
            raise RuntimeError(f"the showcase failed to load: {message.get('error')}")
        return message

    def send(self, command):
        self.process.stdin.write(command + "\n")
        self.process.stdin.flush()
        name = command.split(" ", 1)[0]
        while True:
            message = self.next_message(REPLY_TIMEOUT)
            if message.get("event") == "hung":
                raise RuntimeError(f"the plugin hung: {message.get('error')}")
            if "event" in message:
                continue
            if message.get("command") == name:
                return message

    def close(self):
        try:
            self.process.stdin.write("quit\n")
            self.process.stdin.flush()
            self.process.wait(timeout=10)
        except Exception:
            self.process.kill()


def walk(node):
    yield node
    for child in node.get("children", []):
        yield from walk(child)


def is_truthy(value):
    return value not in (None, False, 0, "", [], {})


def check_tree(tree, label):
    for node in walk(tree):
        if node.get("error"):
            raise RuntimeError(f"{label}: element {node['id']} ({node['type']}) has an error: {node['error']}")


def interactions(tree):
    for node in walk(tree):
        if is_truthy(node.get("props", {}).get("disabled")):
            continue
        events = node.get("events", {})
        if "onTap" in events:
            yield (node["id"], "tap")
        if "onChange" in events:
            yield (node["id"], "type")


def smoke(runner, directory):
    session = RunnerSession(runner, directory)
    count = 0
    try:
        session.wait_for_load()
        view = session.send("view")
        if not view.get("ok"):
            raise RuntimeError(f"view failed: {view.get('error')}")
        check_tree(view["tree"], "initial view")
        done = set()
        while count < MAX_INTERACTIONS:
            pending = [item for item in interactions(view["tree"]) if item not in done]
            if not pending:
                break
            node_id, kind = pending[0]
            done.add((node_id, kind))
            command = f"tap {node_id}" if kind == "tap" else f"type {node_id} {TYPED_TEXT}"
            reply = session.send(command)
            count += 1
            if not reply.get("ok"):
                raise RuntimeError(f"{command} failed: {reply.get('error')}")
            view = session.send("view")
            if not view.get("ok"):
                raise RuntimeError(f"view after {command} failed: {view.get('error')}")
            check_tree(view["tree"], f"after {command}")
        log = session.send("log 1000")
        exceptions = [entry["message"] for entry in log.get("log", []) if entry["level"] == "exception"]
        if exceptions:
            raise RuntimeError("JavaScript exceptions: " + " | ".join(exceptions))
        state = session.send("state")
        if not state.get("ok") or "state" not in state:
            raise RuntimeError(f"state failed: {state}")
        json.dumps(state["state"])
    finally:
        session.close()
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", required=True, help="Path to playhouse-plugin-dev")
    parser.add_argument("--showcases", required=True, help="The Showcase root folder")
    parser.add_argument("--only", action="append", default=[], help="Run only <section>/<showcase> (repeatable)")
    arguments = parser.parse_args()

    root = Path(arguments.showcases)
    showcases = sorted(path.parent for path in root.glob("*/*/plugin.json"))
    if arguments.only:
        selected = set(arguments.only)
        showcases = [path for path in showcases if f"{path.parent.name}/{path.name}" in selected]
        missing = selected - {f"{path.parent.name}/{path.name}" for path in showcases}
        if missing:
            raise SystemExit("Unknown showcases: " + ", ".join(sorted(missing)))
    if not showcases:
        raise SystemExit(f"No showcases found under {root}")

    failures = []
    passed = skipped = 0
    for directory in showcases:
        label = f"{directory.parent.name}/{directory.name}"
        manifest = json.loads((directory / "plugin.json").read_text(encoding="utf-8"))
        if manifest.get("live"):
            skipped += 1
            print(f"showcase={label} skipped=live")
            continue
        started = time.monotonic()
        try:
            count = smoke(arguments.runner, directory)
            passed += 1
            print(f"showcase={label} interactions={count} elapsed_seconds={time.monotonic() - started:.2f} ok")
        except Exception as error:  # noqa: BLE001 - every failure is reported, then the run fails
            failures.append(label)
            print(f"showcase={label} FAILED: {error}")
    print(f"Showcase smoke: total={len(showcases)} passed={passed} skipped={skipped} failed={len(failures)}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
