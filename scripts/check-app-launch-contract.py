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
env['STATIONAI_DATA_DIRECTORY'] = str(data)
env.pop('STATIONAI_BRIDGE_SERVICE_NAME', None)
validator = [sys.executable, str(root / 'scripts/validate-app-launch.py'), str(bundle), str(root), profile['bundleID'], profile['dataDirectory']]
subprocess.run(validator, env=env, check=True, capture_output=True)
copy = data / 'launch-check.app'
if copy.exists():
    raise RuntimeError('Refusing to replace an existing app fixture')
shutil.copytree(bundle, copy, symlinks=True)
try:
    info_path = copy / 'Contents/Info.plist'
    original = plistlib.loads(info_path.read_bytes())
    cases = [
        ('StationAIStoreCompatibilityVersion', None, 'predates store isolation'),
        ('StationAISourceWorktree', '/another-worktree', 'another source worktree'),
        ('CFBundleIdentifier', 'com.stationai.foreign', 'different identities'),
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
        env['STATIONAI_APP_PATH'] = str(copy)
        result = subprocess.run(['bash', str(root / 'scripts/stationai.sh'), 'task', 'list'], env=env, capture_output=True, text=True, timeout=15)
        assert result.returncode == 2 and not result.stdout and reason in result.stderr, result.stderr
    info_path.write_bytes(plistlib.dumps(original))
    env['STATIONAI_DATA_DIRECTORY'] = str(Path.home() / 'Library/Application Support/StationAI')
    result = subprocess.run(['bash', str(root / 'scripts/stationai.sh'), 'task', 'list'], env=env, capture_output=True, text=True, timeout=15)
    assert result.returncode == 2 and not result.stdout and 'isolated temporary' in result.stderr, result.stderr
    assert (diagnostics.read_bytes() if diagnostics.exists() else None) == diagnostics_before, 'Rejected launch reached bridge diagnostics'
    assert snapshots == {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in data.glob('*.store*') if p.is_file()}, 'Rejected launch changed the task store'
finally:
    shutil.rmtree(copy)
print('Launch compatibility, worktree, identity, and data-directory checks passed.')
