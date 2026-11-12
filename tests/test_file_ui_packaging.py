#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent

class FileUIPackagingTests(unittest.TestCase):
    def test_verified_bundle_copies_workers_and_rejects_stale_or_missing_assets(self):
        with tempfile.TemporaryDirectory(prefix='iterm-file-ui-package-') as directory:
            root = Path(directory)
            relative = Path('sources/FileWorkspace/Resources/FileWorkspaceUI')
            shutil.copytree(REPO / relative, root / relative)
            manifest = json.loads((root / relative / 'manifest.json').read_text())
            for entry in manifest['inputs']:
                target = root / entry['path']
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(REPO / entry['path'], target)
            tool = root / 'tools/copy_file_workspace_ui.py'
            tool.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / 'tools/copy_file_workspace_ui.py', tool)
            environment = dict(os.environ, TARGET_BUILD_DIR=str(root / 'build'), UNLOCALIZED_RESOURCES_FOLDER_PATH='iTerm2.app/Contents/Resources')
            copied = subprocess.run(['python3', str(tool)], env=environment, capture_output=True, text=True)
            self.assertEqual(copied.returncode, 0, copied.stderr)
            installed = root / 'build/iTerm2.app/Contents/Resources/FileWorkspaceUI'
            self.assertEqual((installed / 'workers/ts.worker.js').read_bytes(), (root / relative / 'workers/ts.worker.js').read_bytes())
            worker = root / relative / 'workers/editor.worker.js'
            original = worker.read_bytes()
            worker.write_bytes(original + b'corrupt')
            rejected = subprocess.run(['python3', str(tool), '--verify'], capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('Resource hash mismatch', rejected.stderr)
            worker.write_bytes(original)
            source = root / 'sources/FileWorkspace/Resources/src/bridge.mjs'
            source.write_bytes(source.read_bytes() + b'\n')
            rejected = subprocess.run(['python3', str(tool), '--verify'], capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('Stale UI input', rejected.stderr)

if __name__ == '__main__':
    unittest.main()
