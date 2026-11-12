#!/usr/bin/env python3
"""Verify and copy the offline file UI; never install packages during Xcode builds."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

REPO = Path(__file__).resolve().parent.parent
SOURCE = REPO / 'sources/FileWorkspace/Resources/FileWorkspaceUI'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def checked_path(root, relative):
    path = root / relative
    if not relative or Path(relative).is_absolute() or '..' in Path(relative).parts or path.is_symlink() or path.resolve() != path.absolute() or not path.is_file():
        raise ValueError('Invalid resource path: ' + relative)
    return path

def verify():
    manifest = json.loads((SOURCE / 'manifest.json').read_text())
    if manifest['version'] != 1:
        raise ValueError('Unsupported resource manifest')
    names = set()
    for record in manifest['files']:
        path = checked_path(SOURCE, record['path'])
        if record['path'] in names or path.stat().st_size != record['bytes'] or digest(path) != record['sha256']:
            raise ValueError('Resource hash mismatch: ' + record['path'])
        names.add(record['path'])
    required = {'index.html', 'app.js', 'app.css', 'workers/editor.worker.js', 'workers/json.worker.js', 'workers/css.worker.js', 'workers/html.worker.js', 'workers/ts.worker.js', 'licenses/Orca-MIT.txt', 'licenses/Monaco-MIT.txt', 'licenses/Lucide.txt', 'licenses/Geist-OFL.txt', 'licenses/DOMPurify.txt'}
    if not required <= names:
        raise ValueError('Missing required workers, UI assets, or licenses')
    actual = {str(p.relative_to(SOURCE)) for p in SOURCE.rglob('*') if p.is_file()} - {'manifest.json'}
    if actual != names:
        raise ValueError('Unmanifested resource files')
    for record in manifest['inputs']:
        if digest(checked_path(REPO, record['path'])) != record['sha256']:
            raise ValueError('Stale UI input: ' + record['path'])
    return manifest

try:
    manifest = verify()
except (OSError, ValueError, KeyError) as error:
    print('error: File workspace UI verification: ' + str(error), file=sys.stderr)
    print('Rebuild with: npm --prefix tools/file-workspace-ui ci && npm --prefix tools/file-workspace-ui run build', file=sys.stderr)
    sys.exit(1)

try:
    if '--verify' not in sys.argv:
        destination = Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / 'FileWorkspaceUI'
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(SOURCE, destination)
    print(f"Verified {len(manifest['files'])} file UI resources")
except (OSError, ValueError, KeyError) as error:
    print('error: File workspace UI copy: ' + str(error), file=sys.stderr)
    print('The Copy File Workspace UI phase must declare its owned FileWorkspaceUI output directory, including directory cleanup.', file=sys.stderr)
    sys.exit(1)
