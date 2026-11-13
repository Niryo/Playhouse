import argparse
import base64
import datetime
import errno
import fcntl
import hashlib
import json
import re
import plistlib
import queue
import os
import select
import signal
import shutil
import shlex
import sqlite3
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
import uuid
import zlib
from pathlib import Path

CONTRACT_PATH = Path(__file__).resolve().parent.parent / "Playhouse/BridgeTests/BridgeTestContracts.json"
MAX_OUTCOME_CONTINUATIONS = 5
arguments = None


def copy_file(source, destination):
    """Copy a fixture and any companion Python modules it imports."""
    source_path = Path(source)
    destination_path = Path(destination)
    copied = shutil.copyfile(source_path, destination_path)
    if source_path.parent == destination_path.parent:
        return copied
    with source_path.open("rb") as handle:
        header = handle.read(512)
    if not any(marker in header for marker in (b"Deterministic stand-in for the `claude` CLI", b"Deterministic app-server peer")):
        return copied
    for companion in source_path.parent.glob("*_fixture_*.py"):
        shutil.copyfile(companion, destination_path.parent / companion.name)
    return copied

class GitConfigReadBarrier:
    """Hold a real Git config read open so a second XPC request can update task state."""

    def __init__(self, repository):
        self.config = Path(repository) / ".git" / "config"
        self.backup = self.config.with_name(f"config.playhouse-test-{uuid.uuid4()}")
        self.contents = self.config.read_bytes()
        self.writer = None
        os.replace(self.config, self.backup)
        try:
            os.mkfifo(self.config)
        except BaseException:
            os.replace(self.backup, self.config)
            raise

    def wait_for_reader(self, timeout=15):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                self.writer = os.open(self.config, os.O_WRONLY | os.O_NONBLOCK)
                return
            except OSError as error:
                if error.errno != errno.ENXIO:
                    raise
                time.sleep(0.005)
        raise TimeoutError(f"Git did not open the owned config FIFO: {self.config}")

    def release(self):
        if self.writer is None and self.config.exists() and stat.S_ISFIFO(self.config.stat().st_mode):
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                try:
                    self.writer = os.open(self.config, os.O_WRONLY | os.O_NONBLOCK)
                    break
                except OSError as error:
                    if error.errno != errno.ENXIO:
                        raise
                    time.sleep(0.005)
        if self.config.exists() and stat.S_ISFIFO(self.config.stat().st_mode):
            self.config.unlink()
        if self.backup.exists():
            os.replace(self.backup, self.config)
        if self.writer is not None:
            try:
                os.write(self.writer, self.contents)
            finally:
                os.close(self.writer)
                self.writer = None
class TaskOperationLockBarrier:
    """Hold the real per-task advisory lock while another XPC operation runs."""

    def __init__(self, data_directory, task_id):
        directory = Path(data_directory) / "task-operation-locks"
        directory.mkdir(parents=True, exist_ok=True)
        self.descriptor = os.open(directory / f"{task_id}.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.lockf(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB, 0, 0, os.SEEK_SET)
        except BaseException:
            os.close(self.descriptor)
            self.descriptor = None
            raise

    def release(self):
        if self.descriptor is None:
            return
        fcntl.lockf(self.descriptor, fcntl.LOCK_UN, 0, 0, os.SEEK_SET)
        os.close(self.descriptor)
        self.descriptor = None
class TaskStoreWriteLockBarrier:
    """Hold the real shared task-store write lock across a final conversation save."""

    def __init__(self, data_directory):
        self.descriptor = os.open(Path(data_directory) / "store-write.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.lockf(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB, 0, 0, os.SEEK_SET)
        except BaseException:
            os.close(self.descriptor)
            self.descriptor = None
            raise

    def release(self):
        if self.descriptor is None:
            return
        fcntl.lockf(self.descriptor, fcntl.LOCK_UN, 0, 0, os.SEEK_SET)
        os.close(self.descriptor)
        self.descriptor = None
class ConversationTurnLockBarrier:
    """Hold the real per-task conversation-turn reservation across XPC requests."""

    def __init__(self, data_directory, task_id):
        directory = Path(data_directory) / "conversation-turn-locks"
        directory.mkdir(parents=True, exist_ok=True)
        self.descriptor = os.open(directory / f"{task_id}.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.lockf(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB, 0, 0, os.SEEK_SET)
        except BaseException:
            os.close(self.descriptor)
            self.descriptor = None
            raise

    def release(self):
        if self.descriptor is None:
            return
        fcntl.lockf(self.descriptor, fcntl.LOCK_UN, 0, 0, os.SEEK_SET)
        os.close(self.descriptor)
        self.descriptor = None
class RepositoryAllocationLockBarrier:
    """Hold the real repository-wide allocation lock across concurrent XPC requests."""

    def __init__(self, data_directory, repository):
        canonical_path = os.path.abspath(os.path.normpath(repository))
        lock_hash = 14695981039346656037
        for byte in os.fsencode(canonical_path):
            lock_hash = ((lock_hash ^ byte) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
        directory = Path(data_directory) / "repository-allocation-locks"
        directory.mkdir(parents=True, exist_ok=True)
        self.descriptor = os.open(directory / f"{lock_hash:016x}.lock", os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.lockf(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB, 0, 0, os.SEEK_SET)
        except BaseException:
            os.close(self.descriptor)
            self.descriptor = None
            raise

    def release(self):
        if self.descriptor is None:
            return
        fcntl.lockf(self.descriptor, fcntl.LOCK_UN, 0, 0, os.SEEK_SET)
        os.close(self.descriptor)
        self.descriptor = None
def write_noise_png(path, width, height):
    """A valid RGB PNG of random pixels. Noise barely compresses, so the file stays about
    `width * height * 3` bytes, which keeps its data URL far larger than a FIFO's buffer."""
    rows = b"".join(b"\x00" + os.urandom(width * 3) for _ in range(height))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b""))
def ordinary_messages(messages):
    """History without the status nudges Playhouse sent and the agent's replies to them."""
    kept, in_nudge = [], False
    for message in messages:
        if message["role"] == "user":
            in_nudge = "Playhouse internal outcome nudge:" in message["text"]
        if not in_nudge:
            kept.append(message)
    return kept
class DrainedPopen(subprocess.Popen):
    """A Popen whose output pipes are read while it runs.

    A held turn streams every event to its CLI, and a nudge shown in the conversation streams its
    own, so an unread pipe fills and blocks the CLI, which in turn blocks the daemon's socket write.
    """

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._drained = {}
        self._drain_threads = []
        for name in ("stdout", "stderr"):
            stream = getattr(self, name)
            if stream is None:
                continue
            thread = threading.Thread(target=lambda n=name, s=stream: self._drained.__setitem__(n, s.read()), daemon=True)
            thread.start()
            self._drain_threads.append(thread)

    def communicate(self, input=None, timeout=None):
        self.wait(timeout=timeout)
        for thread in self._drain_threads:
            thread.join(timeout=timeout)
        return self._drained.get("stdout", ""), self._drained.get("stderr", "")
