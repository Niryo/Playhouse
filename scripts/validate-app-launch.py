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
    identifier = app['CFBundleIdentifier']
    # The bridge daemon and CLI ship flat in Contents/MacOS (no separate XPC
    # bundle/Info.plist anymore) and resolve their identity from this same
    # Info.plist via `Bundle.main`, so there's nothing to cross-check them
    # against: a single identifier now governs the app, the CLI, and the
    # daemon by construction.
    if app.get('PlayhouseStoreCompatibilityVersion') != '2':
        raise ValueError('The selected app predates store isolation version 2. Rebuild it with scripts/run.sh.')
    if Path(app.get('PlayhouseSourceWorktree', '/')).resolve() != root:
        raise ValueError('The selected app was built from another source worktree.')
    override = os.environ.get('PLAYHOUSE_BRIDGE_SERVICE_NAME')
    if override and override != identifier + '.bridge':
        raise ValueError('The bridge service override does not match the selected app.')
    data = Path(os.environ.get('PLAYHOUSE_DATA_DIRECTORY') or expected_data).resolve()
    if '.e2e.' in identifier:
        if not os.environ.get('PLAYHOUSE_DATA_DIRECTORY') or not any(data.is_relative_to(p.resolve()) and data != p.resolve() for p in (Path('/tmp'), Path(tempfile.gettempdir()))):
            raise ValueError('A test app requires an explicit isolated temporary data directory.')
        if not (
            identifier.startswith(expected_id + '.e2e.')
        ):
            raise ValueError('Unexpected test app identity.')
    elif identifier != expected_id or data != expected_data:
        raise ValueError('The selected app or data directory does not match this worktree profile.')
    print(data)


try:
    validate()
except (OSError, KeyError, ValueError, plistlib.InvalidFileException) as error:
    print(f'Playhouse launch rejected: {error}', file=sys.stderr)
    sys.exit(2)
