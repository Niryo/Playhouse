#!/usr/bin/env python3
"""Exercise launcher rejection using a copy of the real built app, never a fake CLI."""
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

bundle, root, data = map(Path, sys.argv[1:])
profile = subprocess.run(['bash', str(root / 'scripts/app-profile.sh'), str(root)], check=True, capture_output=True, text=True)
import json
profile = json.loads(profile.stdout)
env = os.environ.copy()
env['PLAYHOUSE_DATA_DIRECTORY'] = str(data)
env.pop('PLAYHOUSE_BRIDGE_SERVICE_NAME', None)
validator = [sys.executable, str(root / 'scripts/validate-app-launch.py'), str(bundle), str(root), profile['bundleID'], profile['dataDirectory']]
validation = subprocess.run(validator, env=env, capture_output=True, text=True)
if validation.returncode != 0:
    detail = validation.stderr or validation.stdout or f"validator exited with {validation.returncode}"
    raise RuntimeError(f"App launch validation failed: {detail}")
copy = data / 'launch-check.app'
if copy.exists():
    raise RuntimeError('Refusing to replace an existing app fixture')
shutil.copytree(bundle, copy, symlinks=True)
try:
    info_path = copy / 'Contents/Info.plist'
    original = plistlib.loads(info_path.read_bytes())
    foreign_test_id = (
        'com.playhouse.app.e2e.foreign'
        if profile['kind'] == 'linked'
        else 'com.playhouse.app.worktree.w0000000000000000.e2e.foreign'
    )
    # The daemon and CLI ship flat in Contents/MacOS and resolve their identity
    # from this same Info.plist via `Bundle.main` (no separate XPC bundle to
    # tamper with independently anymore), so every identity/compatibility
    # check collapses onto this one file.
    cases = [
        ('PlayhouseStoreCompatibilityVersion', None, 'predates store isolation'),
        ('PlayhouseSourceWorktree', '/another-worktree', 'another source worktree'),
        ('CFBundleIdentifier', 'com.playhouse.foreign', 'does not match this worktree profile'),
        ('CFBundleIdentifier', foreign_test_id, 'Unexpected test app identity'),
    ]
    diagnostics = data / 'Diagnostics.jsonl'
    diagnostics_before = diagnostics.read_bytes() if diagnostics.exists() else None
    snapshots = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in data.glob('*.store*') if p.is_file()}
    for key, value, reason in cases:
        info = dict(original)
        if value is None:
            info.pop(key, None)
        else:
            info[key] = value
        info_path.write_bytes(plistlib.dumps(info))
        env['PLAYHOUSE_APP_PATH'] = str(copy)
        result = subprocess.run(['bash', str(root / 'scripts/playhouse.sh'), 'task', 'list'], env=env, capture_output=True, text=True, timeout=15)
        assert result.returncode == 2 and not result.stdout and reason in result.stderr, result.stderr
    info_path.write_bytes(plistlib.dumps(original))
    env['PLAYHOUSE_DATA_DIRECTORY'] = str(Path.home() / 'Library/Application Support/Playhouse')
    result = subprocess.run(['bash', str(root / 'scripts/playhouse.sh'), 'task', 'list'], env=env, capture_output=True, text=True, timeout=15)
    assert result.returncode == 2 and not result.stdout and 'isolated temporary' in result.stderr, result.stderr
    diagnostics_after = diagnostics.read_bytes() if diagnostics.exists() else None
    assert diagnostics_after == diagnostics_before, 'Rejected launch reached bridge diagnostics: ' + (diagnostics_after or b'')[len(diagnostics_before or b''):].decode('utf-8', 'replace')[-1500:]
    assert snapshots == {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in data.glob('*.store*') if p.is_file()}, 'Rejected launch changed the task store'
finally:
    shutil.rmtree(copy)
print('Launch compatibility, worktree, identity, and data-directory checks passed.')
