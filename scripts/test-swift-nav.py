#!/usr/bin/env python3
"""Focused smoke tests for scripts/swift-nav.py (requires Xcode sourcekit-lsp)."""
import os
import pathlib
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI = ROOT / "scripts" / "swift-nav.py"
FIXTURE = ROOT / "scripts" / "fixtures" / "swift-nav"


def run(*args, env=None, check=True):
    merged = os.environ.copy()
    merged["SWIFT_NAV_RUNTIME_DIR"] = str(runtime)
    if env:
        merged.update(env)
    result = subprocess.run([str(CLI), *map(str, args)], cwd=ROOT, env=merged,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode:
        raise AssertionError(f"{args}: {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result


def process_running(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="],
                            text=True, capture_output=True)
    state = result.stdout.strip()
    return bool(state) and not state.startswith("Z")


with tempfile.TemporaryDirectory(prefix="swnav-") as temp:
    # AF_UNIX socket paths are short on macOS; keep the isolated runtime shallow.
    runtime = pathlib.Path(temp)
    ledger = FIXTURE / "Ledger.swift"
    users = FIXTURE / "LedgerUser.swift"

    outline = run("outline", ledger)
    assert "5-21 struct SwiftNavFixtureLedger" in outline.stdout
    assert "  6-9 enum Entry" in outline.stdout
    assert "23-36 ext SwiftNavFixtureLedger" in outline.stdout
    assert "  33-35 func summary(prefix:)" in outline.stdout

    # Check exact declaration lines and qualified lookup in an extension.
    show = run("show", ledger, "record", "--line", 18)
    assert "18\t    mutating func record(_ amount: Int) {\n19\t        record(amount >= 0 ? .credit(amount) : .debit(-amount))\n20\t    }" in show.stdout
    extension_method = run("show", ledger, "SwiftNavFixtureLedger.summary(prefix:)")
    assert "33\t    func summary(prefix: String) -> String {\n34\t        \"\\(prefix) \\(balance)\"\n35\t    }" in extension_method.stdout

    ambiguous = run("show", ledger, "record", check=False)
    assert ambiguous.returncode != 0 and "matches 2 symbols" in (ambiguous.stdout + ambiguous.stderr)

    refs = run("refs", "SwiftNavFixtureLedger", "--path", FIXTURE)
    assert "definitions (2):" in refs.stdout
    assert "uses (1):\n  scripts/fixtures/swift-nav/LedgerUser.swift:5  [in SwiftNavFixtureReport.make()]  var ledger = SwiftNavFixtureLedger()" in refs.stdout
    assert "best-effort" in refs.stdout.lower()

    # Structural coverage against the large production source files.
    bridge = ROOT / "Playhouse" / "App" / "BridgeCore.swift"
    bridge_outline = run("outline", bridge, "--max-lines", 150)
    assert len(bridge_outline.stdout.encode()) < 8192
    required = run("show", bridge, "BridgeRequest.requiredInt")
    assert "requiredInt" in required.stdout

    # The first call starts one helper; subsequent calls reuse its PID.
    run("outline", ledger)
    first = run("status").stdout
    run("outline", users)
    second = run("status").stdout
    first_pid = next(line.split("pid ", 1)[1].split()[0] for line in first.splitlines() if "pid " in line)
    second_pid = next(line.split("pid ", 1)[1].split()[0] for line in second.splitlines() if "pid " in line)
    assert first_pid == second_pid

    # Server crashes are recovered, and every request observes current file contents.
    os.kill(int(second_pid), signal.SIGKILL)
    recovered = run("outline", ledger)
    assert "SwiftNavFixtureLedger" in recovered.stdout
    recovered_status = run("status").stdout
    recovered_pid = next(line.split("pid ", 1)[1].split()[0] for line in recovered_status.splitlines() if "pid " in line)
    assert recovered_pid != second_pid
    edited = pathlib.Path(temp) / "EditedLedger.swift"
    edited.write_text("\n" + ledger.read_text())
    fresh = run("show", edited, "SwiftNavFixtureLedger.summary(prefix:)")
    assert "34-36 func SwiftNavFixtureLedger.summary(prefix:)" in fresh.stdout

    stopped = run("stop")
    assert "stopped" in stopped.stdout
    per_call = run("outline", ledger, env={"SWIFT_NAV_NO_DAEMON": "1"})
    assert "SwiftNavFixtureLedger" in per_call.stdout

    # Invalid/unwritable background runtime storage must fall back to this call.
    runtime_blocker = pathlib.Path(temp) / "not-a-directory"
    runtime_blocker.write_text("block")
    fallback = run("outline", ledger, env={"SWIFT_NAV_RUNTIME_DIR": str(runtime_blocker)})
    assert "SwiftNavFixtureLedger" in fallback.stdout
    assert "background helper unavailable" in fallback.stderr

    # Concurrent cold callers serialize startup and all complete successfully.
    concurrent_runtime = pathlib.Path(temp) / "concurrent"
    concurrent_env = os.environ.copy()
    concurrent_env["SWIFT_NAV_RUNTIME_DIR"] = str(concurrent_runtime)
    commands = [[str(CLI), "outline", str(ledger)] for _ in range(3)]
    processes = [subprocess.Popen(command, cwd=ROOT, env=concurrent_env, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                 for command in commands]
    for process in processes:
        stdout, stderr = process.communicate(timeout=30)
        assert process.returncode == 0, f"concurrent caller failed: {stdout}\n{stderr}"
        assert "SwiftNavFixtureLedger" in stdout
    concurrent_status = subprocess.run([str(CLI), "status"], cwd=ROOT, env=concurrent_env,
                                        text=True, capture_output=True, check=True).stdout
    assert sum("pid " in line for line in concurrent_status.splitlines()) == 1
    concurrent_stop = subprocess.run([str(CLI), "stop"], cwd=ROOT, env=concurrent_env,
                                     text=True, capture_output=True, check=True)
    assert "stopped" in concurrent_stop.stdout

    # The configured idle timeout is honored by the detached helper.
    idle_runtime = pathlib.Path(temp) / "idle"
    idle_env = os.environ.copy()
    idle_env.update({"SWIFT_NAV_RUNTIME_DIR": str(idle_runtime), "SWIFT_NAV_IDLE_SECONDS": "2"})
    subprocess.run([str(CLI), "outline", str(ledger)], cwd=ROOT, env=idle_env,
                   text=True, capture_output=True, check=True)
    idle_status = subprocess.run([str(CLI), "status"], cwd=ROOT, env=idle_env,
                                 text=True, capture_output=True, check=True).stdout
    assert "pid " in idle_status
    idle_pid = int(next(line.split("pid ", 1)[1].split()[0]
                        for line in idle_status.splitlines() if "pid " in line))
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline and process_running(idle_pid):
        time.sleep(0.1)
    assert not process_running(idle_pid), "helper process did not exit at its idle timeout"
    assert not list(idle_runtime.glob("*.json")), "helper did not exit at its idle timeout"

    # A missing file must be a clean, nonzero error rather than a traceback.
    missing = run("show", ledger, "NoSuchSymbol", check=False)
    assert missing.returncode and "Traceback" not in missing.stderr

print("swift-nav smoke tests passed")
