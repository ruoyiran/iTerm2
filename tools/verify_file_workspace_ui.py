#!/usr/bin/env python3
"""Verify offline UI inputs; native Copy Bundle Resources owns all bundle writes."""
import hashlib
import json
import os
from pathlib import Path
import sys
import zlib

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
    if manifest['version'] not in (1, 2):
        raise ValueError('Unsupported resource manifest')
    names, stored_names = set(), set()
    total = 0
    for record in manifest['files']:
        logical = record['path']
        if not isinstance(logical, str) or not logical or any(part in ('', '.', '..') for part in logical.split('/')) or '\\' in logical or '\0' in logical:
            raise ValueError('Invalid logical resource path')
        stored = record['storagePath'] if manifest['version'] == 2 else logical
        if not isinstance(record.get('mime'), str) or '\r' in record['mime'] or '\n' in record['mime']:
            raise ValueError('Invalid resource MIME type')
        path = checked_path(SOURCE, stored)
        if type(record['bytes']) is not int or not 0 <= record['bytes'] <= 32 * 1024 * 1024:
            raise ValueError('Invalid stored resource size')
        if stored in stored_names:
            raise ValueError('Duplicate resource storage path')
        stored_names.add(stored)
        if record['path'] in names or path.stat().st_size != record['bytes'] or digest(path) != record['sha256']:
            raise ValueError('Resource hash mismatch: ' + record['path'])
        names.add(record['path'])
        encoding = record.get('encoding')
        if encoding not in (None, 'gzip') or (encoding is not None and manifest['version'] != 2):
            raise ValueError('Unsupported resource encoding')
        decoded_bytes = record.get('decodedBytes') if encoding else record['bytes']
        if type(decoded_bytes) is not int or not 0 <= decoded_bytes <= 32 * 1024 * 1024:
            raise ValueError('Invalid decoded resource size')
        total += decoded_bytes
        if total > 128 * 1024 * 1024:
            raise ValueError('Resource size limit exceeded')
        if encoding:
            decoder = zlib.decompressobj(31)
            decoded = decoder.decompress(path.read_bytes(), decoded_bytes + 1)
            if len(decoded) != decoded_bytes or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
                raise ValueError('Invalid gzip resource')
            if hashlib.sha256(decoded).hexdigest() != record.get('decodedSHA256'):
                raise ValueError('Decoded resource hash mismatch')
    required = {'index.html', 'app.js', 'app.css', 'workers/editor.worker.js', 'workers/json.worker.js', 'workers/css.worker.js', 'workers/html.worker.js', 'workers/ts.worker.js', 'licenses/Orca-MIT.txt', 'licenses/Monaco-MIT.txt', 'licenses/Lucide.txt', 'licenses/Geist-OFL.txt', 'licenses/DOMPurify.txt'}
    if not required <= names:
        raise ValueError('Missing required workers, UI assets, or licenses')
    actual = {str(p.relative_to(SOURCE)) for p in SOURCE.rglob('*') if p.is_file()} - {'manifest.json'}
    if actual != stored_names:
        raise ValueError('Unmanifested resource files')
    for record in manifest['inputs']:
        if digest(checked_path(REPO, record['path'])) != record['sha256']:
            raise ValueError('Stale UI input: ' + record['path'])
    return manifest

try:
    manifest = verify()
except (OSError, ValueError, KeyError, zlib.error) as error:
    print('error: File workspace UI verification: ' + str(error), file=sys.stderr)
    print('Rebuild with: npm --prefix tools/file-workspace-ui ci && npm --prefix tools/file-workspace-ui run build', file=sys.stderr)
    sys.exit(1)

try:
    if '--stamp' in sys.argv:
        index = sys.argv.index('--stamp')
        stamp = Path(sys.argv[index + 1])
        stamp.write_text(digest(SOURCE / 'manifest.json') + '\n')
    print(f"Verified {len(manifest['files'])} file UI resources")
except (OSError, ValueError, IndexError) as error:
    print('error: File workspace UI verification stamp: ' + str(error), file=sys.stderr)
    sys.exit(1)
