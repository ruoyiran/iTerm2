#!/usr/bin/env python3
"""Exercise the actual command-line sanitizer on nested native file arrangements."""
import pathlib
import plistlib
import subprocess
import tempfile
import unittest


class FileSessionSanitizerTests(unittest.TestCase):
    def test_file_descriptors_are_removed_without_dropping_pane_identity(self):
        repo = pathlib.Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "source.plist"
            output = pathlib.Path(directory) / "output.plist"
            session = {"Session Stable ID": "pane-stable", "File Session": {
                "version": 1, "filePath": "/private/project/secret.txt", "rootDirectory": "/private/project",
                "documentIdentifier": "shared-document", "viewState": {"scrollTop": 10.0}}}
            source.write_bytes(plistlib.dumps({"New Bookmarks": [], "Window Arrangements": [{"Tabs": [{"Root": {"Session": session}}]}]}))
            result = subprocess.run(["python3", str(repo / "tools/sanitize_iterm2_plist.py"), str(source), "-o", str(output)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            data = output.read_bytes()
            self.assertNotIn(b"secret.txt", data)
            self.assertNotIn(b"/private/project", data)
            self.assertIn(b"pane-stable", data)
            dry = subprocess.run(["python3", str(repo / "tools/sanitize_iterm2_plist.py"), str(source), "--dry-run"], capture_output=True, text=True)
            self.assertEqual(dry.returncode, 0, dry.stderr)


if __name__ == "__main__":
    unittest.main()
