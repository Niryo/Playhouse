#!/usr/bin/env python3
"""Validate a selected bundle before executing any of its code."""
import os
from pathlib import Path
import plistlib
import sys
import tempfile


def validate():
    bundle = Path(sys.argv[1]).resolve()
    root = Path(sys.argv[2]).resolve()
    expected_id = sys.argv[3]
    expected_data = Path(sys.argv[4]).resolve()
    app = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    bridge = plistlib.loads((bundle / 'Contents/XPCServices/StationAIBridge.xpc/Contents/Info.plist').read_bytes())
    identifier = app['CFBundleIdentifier']
    for info in (app, bridge):
        if info.get('StationAIStoreCompatibilityVersion') != '2':
            raise ValueError('The selected app predates store isolation version 2. Rebuild it with scripts/run.sh.')
        if Path(info.get('StationAISourceWorktree', '/')).resolve() != root:
            raise ValueError('The selected app was built from another source worktree.')
    if bridge.get('StationAIApplicationBundleIdentifier') != identifier or bridge.get('CFBundleIdentifier') != identifier + '.bridge':
        raise ValueError('The selected app and bridge have different identities.')
    override = os.environ.get('STATIONAI_BRIDGE_SERVICE_NAME')
    if override and override != bridge['CFBundleIdentifier']:
        raise ValueError('The bridge service override does not match the selected app.')
    data = Path(os.environ.get('STATIONAI_DATA_DIRECTORY') or expected_data).resolve()
    if '.e2e.' in identifier:
        if not os.environ.get('STATIONAI_DATA_DIRECTORY') or not any(data.is_relative_to(p.resolve()) and data != p.resolve() for p in (Path('/tmp'), Path(tempfile.gettempdir()))):
            raise ValueError('A test app requires an explicit isolated temporary data directory.')
        if not (
            identifier.startswith(expected_id + '.e2e.')
            or identifier.startswith('com.stationai.app.e2e.')
            or identifier.startswith('com.stationai.app.worktree.') and '.e2e.' in identifier
        ):
            raise ValueError('Unexpected test app identity.')
    elif identifier != expected_id or data != expected_data:
        raise ValueError('The selected app or data directory does not match this worktree profile.')
    print(data)


try:
    validate()
except (OSError, KeyError, ValueError, plistlib.InvalidFileException) as error:
    print(f'StationAI launch rejected: {error}', file=sys.stderr)
    sys.exit(2)
