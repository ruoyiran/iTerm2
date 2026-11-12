#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
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

    def test_declared_outputs_allow_sandboxed_clean_and_incremental_copy_only_in_owned_tree(self):
        with tempfile.TemporaryDirectory(prefix='iterm-file-ui-sandbox-') as directory:
            fixture = Path(directory).resolve()
            root = fixture / 'repo'
            relative = Path('sources/FileWorkspace/Resources/FileWorkspaceUI')
            shutil.copytree(REPO / relative, root / relative)
            manifest = json.loads((root / relative / 'manifest.json').read_text())
            for entry in manifest['inputs']:
                target = root / entry['path']
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(REPO / entry['path'], target)
            tool = root / 'tools/copy_file_workspace_ui.py'
            shutil.copyfile(REPO / 'tools/copy_file_workspace_ui.py', tool)
            build = fixture / 'build'
            resources = build / 'iTerm2.app/Contents/Resources'
            resources.mkdir(parents=True)
            destination = resources / 'FileWorkspaceUI'
            sibling = resources / 'other-feature.txt'
            sibling.write_text('keep')
            replacements = {'$(SRCROOT)': str(root), '$(TARGET_BUILD_DIR)': str(build), '$(UNLOCALIZED_RESOURCES_FOLDER_PATH)': 'iTerm2.app/Contents/Resources'}
            def expanded(name):
                lines = (REPO / ('tools/file-workspace-ui/' + name + '.xcfilelist')).read_text().splitlines()
                for key, value in replacements.items():
                    lines = [line.replace(key, value) for line in lines]
                return [Path(line) for line in lines if line]
            inputs, outputs = expanded('inputs'), expanded('outputs')
            # Xcode's generated .sb grants subpaths for declared files and read-only ancestors.
            rules = ['(version 1)', '(allow default)', '(deny file-read* file-write* (subpath ' + json.dumps(str(root)) + ') (subpath ' + json.dumps(str(build)) + '))']
            ancestors = {str(parent) for path in inputs + outputs for parent in path.parents}
            rules += ['(allow file-read* (literal ' + json.dumps(path) + '))' for path in sorted(ancestors)]
            rules += ['(allow file-read* (subpath ' + json.dumps(str(path)) + '))' for path in inputs]
            rules += ['(allow file-read* file-write* (subpath ' + json.dumps(str(path)) + '))' for path in outputs]
            policy = fixture / 'copy.sb'
            policy.write_text('\n'.join(rules))
            environment = dict(os.environ, TARGET_BUILD_DIR=str(build), UNLOCALIZED_RESOURCES_FOLDER_PATH='iTerm2.app/Contents/Resources', PYTHONDONTWRITEBYTECODE='1')
            command = ['/usr/bin/sandbox-exec', '-f', str(policy), sys.executable, str(tool)]
            first = subprocess.run(command, env=environment, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            stale = destination / 'chunks/stale-from-previous-build.js'
            stale.write_text('stale')
            second = subprocess.run(command, env=environment, capture_output=True, text=True)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertFalse(stale.exists())
            self.assertTrue((destination / 'licenses/Monaco-MIT.txt').is_file())
            self.assertEqual(sibling.read_text(), 'keep')
            denied = subprocess.run(['/usr/bin/sandbox-exec', '-f', str(policy), sys.executable, '-c', 'import pathlib; pathlib.Path(' + repr(str(sibling)) + ').write_text("bad")'], env=environment, capture_output=True, text=True)
            self.assertNotEqual(denied.returncode, 0)
            self.assertEqual(sibling.read_text(), 'keep')

if __name__ == '__main__':
    unittest.main()
