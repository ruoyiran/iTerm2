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
RESOURCE = Path('sources/FileWorkspace/Resources/FileWorkspaceUI')
TOOL = Path('tools/verify_file_workspace_ui.py')


def copy_fixture(root):
    shutil.copytree(REPO / RESOURCE, root / RESOURCE)
    manifest = json.loads((root / RESOURCE / 'manifest.json').read_text())
    for entry in manifest['inputs']:
        target = root / entry['path']
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(REPO / entry['path'], target)
    shutil.copyfile(REPO / TOOL, root / TOOL)
    shutil.copyfile(REPO / 'tools/file-workspace-ui/inputs.xcfilelist', root / 'tools/file-workspace-ui/inputs.xcfilelist')
    return manifest


class FileUIPackagingTests(unittest.TestCase):
    def test_verifier_rejects_corrupt_and_stale_inputs_before_publishing_stamp(self):
        with tempfile.TemporaryDirectory(prefix='iterm-file-ui-verify-') as directory:
            root = Path(directory).resolve()
            copy_fixture(root)
            stamp = root / 'verified.stamp'
            command = [sys.executable, str(root / TOOL), '--verify', '--stamp', str(stamp)]
            verified = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(verified.returncode, 0, verified.stderr)
            stamp.write_text('previous verification')
            worker = root / RESOURCE / 'workers/editor.worker.js'
            original = worker.read_bytes()
            worker.write_bytes(original + b'corrupt')
            rejected = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('Resource hash mismatch', rejected.stderr)
            self.assertEqual(stamp.read_text(), 'previous verification')
            worker.write_bytes(original)
            source = root / 'sources/FileWorkspace/Resources/src/bridge.mjs'
            source.write_bytes(source.read_bytes() + b'\n')
            rejected = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('Stale UI input', rejected.stderr)
            self.assertEqual(stamp.read_text(), 'previous verification')

    def test_verifier_runs_with_actual_literal_permissions_and_cannot_write_resources(self):
        with tempfile.TemporaryDirectory(prefix='iterm-file-ui-literal-') as directory:
            fixture = Path(directory).resolve()
            root, build = fixture / 'repo', fixture / 'build'
            copy_fixture(root)
            target_temp = build / 'Target.build'
            target_temp.mkdir(parents=True)
            stamp = target_temp / 'file-workspace-ui.verified'
            resources = build / 'iTerm2.app/Contents/Resources/FileWorkspaceUI'
            resources.mkdir(parents=True)
            canary = resources / 'do-not-write.txt'
            canary.write_text('keep')
            inputs = [Path(line.replace('$(SRCROOT)', str(root))) for line in (root / 'tools/file-workspace-ui/inputs.xcfilelist').read_text().splitlines() if line]
            outputs = [stamp]
            rules = ['(version 1)', '(allow default)', '(deny file-read* file-write* (subpath ' + json.dumps(str(root)) + ') (subpath ' + json.dumps(str(build)) + '))']
            ancestors = {str(parent) for path in inputs + outputs for parent in path.parents}
            rules += ['(allow file-read* (literal ' + json.dumps(path) + '))' for path in sorted(ancestors)]
            # Xcode's actual profile uses literal grants, including directory paths.
            rules += ['(allow file-read* (literal ' + json.dumps(str(path)) + '))' for path in inputs]
            rules += ['(allow file-read* file-write* (literal ' + json.dumps(str(path)) + '))' for path in outputs]
            policy = fixture / 'verify.sb'
            policy.write_text('\n'.join(rules))
            environment = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
            prefix = ['/usr/bin/sandbox-exec', '-f', str(policy), sys.executable]
            command = prefix + [str(root / TOOL), '--verify', '--stamp', str(stamp)]
            for _ in range(2):
                result = subprocess.run(command, env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(stamp.is_file())
            denied = subprocess.run(prefix + ['-c', 'import pathlib; pathlib.Path(' + repr(str(canary)) + ').write_text("bad")'], env=environment, capture_output=True, text=True)
            self.assertNotEqual(denied.returncode, 0)
            self.assertEqual(canary.read_text(), 'keep')

    def test_native_resource_copy_verifies_first_and_removes_stale_files_on_incremental_build(self):
        with tempfile.TemporaryDirectory(prefix='iterm-file-ui-native-') as directory:
            root = Path(directory).resolve()
            copy_fixture(root)
            ruby = r'''
require 'xcodeproj'
original = Xcodeproj::Project.open(ARGV[0] + '/iTerm2.xcodeproj')
app = original.targets.find { |target| target.name == 'iTerm2' }
verification = app.shell_script_build_phases.find { |phase| phase.name == 'Verify File Workspace UI' }
resource = app.resources_build_phase.files_references.find { |ref| ref.display_name == 'FileWorkspaceUI' }
raise 'Missing native folder resource' unless resource && resource.last_known_file_type == 'folder'
raise 'Verification must precede resource copy' unless app.build_phases.index(verification) < app.build_phases.index(app.resources_build_phase)
project = Xcodeproj::Project.new(ARGV[1] + '/ResourceFixture.xcodeproj')
target = project.new_target(:bundle, 'FileUIResourceFixture', :osx, '13.0')
target.build_configurations.each { |config| config.build_settings.merge!({'GENERATE_INFOPLIST_FILE'=>'YES', 'CODE_SIGNING_ALLOWED'=>'NO', 'PRODUCT_BUNDLE_IDENTIFIER'=>'com.iterm2.file-ui-resource-test', 'ENABLE_USER_SCRIPT_SANDBOXING'=>'YES', 'ONLY_ACTIVE_ARCH'=>'NO'}) }
ref = project.main_group.new_file('sources/FileWorkspace/Resources/FileWorkspaceUI')
ref.name = 'FileWorkspaceUI'
ref.last_known_file_type = resource.last_known_file_type
target.resources_build_phase.add_file_reference(ref)
phase = target.new_shell_script_build_phase(verification.name)
phase.shell_script = verification.shell_script
phase.shell_path = verification.shell_path
phase.input_file_list_paths = verification.input_file_list_paths
phase.output_paths = verification.output_paths
phase.output_file_list_paths = verification.output_file_list_paths
phase.always_out_of_date = verification.always_out_of_date
target.build_phases.delete(phase)
target.build_phases.insert(target.build_phases.index(target.resources_build_phase), phase)
project.save
'''
            generated = subprocess.run(['ruby', '-', str(REPO), str(root)], input=ruby, capture_output=True, text=True)
            self.assertEqual(generated.returncode, 0, generated.stderr)
            command = ['xcodebuild', '-project', str(root / 'ResourceFixture.xcodeproj'), '-target', 'FileUIResourceFixture', '-configuration', 'Debug', 'SYMROOT=' + str(root / 'build'), 'OBJROOT=' + str(root / 'objects'), 'DSTROOT=' + str(root / 'install'), 'CODE_SIGNING_ALLOWED=NO']
            def run_build(name):
                result = subprocess.run(command, capture_output=True, text=True)
                output = result.stdout + result.stderr
                (Path(tempfile.gettempdir()) / ('file-ui-r2-fixture-' + name + '.log')).write_text(output)
                self.assertEqual(result.returncode, 0, output[-5000:])
                self.assertIn('sandbox-exec', output)
                self.assertIn('CpResource ', output)
                self.assertLess(output.index('PhaseScriptExecution Verify'), output.index('CpResource '))
                self.assertNotIn('warning:', output)
            run_build('clean')
            destination = root / 'build/Debug/FileUIResourceFixture.bundle/Contents/Resources/FileWorkspaceUI'
            self.assertEqual((destination / 'manifest.json').read_bytes(), (root / RESOURCE / 'manifest.json').read_bytes())
            stale = destination / 'chunks/stale-generated.js'
            stale.write_text('stale')
            sibling = destination.parent / 'other-feature.txt'
            sibling.write_text('keep')
            os.utime(root / RESOURCE / 'manifest.json', None)
            run_build('incremental')
            self.assertFalse(stale.exists())
            self.assertTrue((destination / 'licenses/Monaco-MIT.txt').is_file())
            self.assertEqual(sibling.read_text(), 'keep')


if __name__ == '__main__':
    unittest.main()
