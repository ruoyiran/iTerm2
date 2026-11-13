import importlib.util
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_build", ROOT / "tools/build_release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class ReleaseInstallTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory()
        root = Path(cls.fixture.name)
        source = root / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        cls.executable = root / "iTerm2"
        subprocess.run(["xcrun", "clang", str(source), "-o", str(cls.executable)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name).resolve()
        self.applications = self.root / "Applications with spaces"
        self.applications.mkdir()
        self.source = self.bundle(self.root / "output" / "iTerm2.app", "new")
        self.destination = self.bundle(self.applications / "iTerm2.app", "old")

    def tearDown(self):
        self.directory.cleanup()

    def bundle(self, path, marker):
        contents = path / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        shutil.copy2(self.executable, contents / "MacOS/iTerm2")
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.googlecode.iterm2",
            "CFBundleExecutable": "iTerm2",
            "CFBundlePackageType": "APPL",
            "CFBundleName": "iTerm2",
            "CFBundleVersion": "1",
        }))
        (contents / "Resources").mkdir()
        (contents / "Resources/marker").write_text(marker)
        release.sign_app(path)
        return path

    def test_install_replaces_complete_bundle_and_preserves_old_version(self):
        installed, backup = release.install_app(self.source, self.applications)
        self.assertEqual(installed, self.destination)
        self.assertEqual((installed / "Contents/Resources/marker").read_text(), "new")
        self.assertEqual((backup / "Contents/Resources/marker").read_text(), "old")
        self.assertFalse(list(self.applications.glob(".iterm2-install-*")))
        release.verify_app(installed)

    def test_invalid_signature_leaves_installed_version_untouched(self):
        (self.source / "Contents/Resources/marker").write_text("modified after signing")
        with self.assertRaises(subprocess.CalledProcessError):
            release.install_app(self.source, self.applications)
        self.assertEqual((self.destination / "Contents/Resources/marker").read_text(), "old")
        self.assertFalse((self.applications / ".iterm2-build-backups").exists())

    def test_failed_final_rename_restores_previous_install(self):
        original_replace = release.os.replace

        def fail_final_rename(source, destination):
            if Path(destination) == self.destination and ".iterm2-install-" in str(source):
                raise OSError("injected installation failure")
            return original_replace(source, destination)

        with patch.object(release.os, "replace", side_effect=fail_final_rename):
            with self.assertRaises(OSError):
                release.install_app(self.source, self.applications)
        self.assertEqual((self.destination / "Contents/Resources/marker").read_text(), "old")
        release.verify_app(self.destination)
        self.assertFalse(list(self.applications.glob(".iterm2-install-*")))

    def test_install_refuses_symlink_destination(self):
        shutil.rmtree(self.destination)
        elsewhere = self.bundle(self.root / "elsewhere.app", "other")
        self.destination.symlink_to(elsewhere, target_is_directory=True)
        with self.assertRaises(ValueError):
            release.install_app(self.source, self.applications)
        self.assertEqual((elsewhere / "Contents/Resources/marker").read_text(), "other")


class NativeCacheTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name).resolve()
        self.repo = self.root / "repo"
        self.origin = self.root / "library"
        for directory in [self.repo, self.origin]:
            directory.mkdir()
            self.git(directory, "init", "--quiet")
            self.git(directory, "config", "user.name", "Build test")
            self.git(directory, "config", "user.email", "build@example.test")
        (self.origin / "Native.swift").write_text("first")
        self.git(self.origin, "add", ".")
        self.git(self.origin, "commit", "--quiet", "-m", "first")
        self.git(self.repo, "-c", "protocol.file.allow=always", "submodule", "add", "--quiet", str(self.origin), "submodules/Library")
        self.git(self.repo, "commit", "--quiet", "-am", "library")
        self.library = self.repo / "submodules/Library"

    def tearDown(self):
        self.directory.cleanup()

    def git(self, directory, *args):
        return subprocess.check_output(["git", "-C", str(directory), *args], stderr=subprocess.PIPE, text=True).strip()

    def test_command_cwd_is_also_exported_for_make_prefixes(self):
        output = self.root / "pwd"
        release.run(["python3", "-c", "import os, pathlib, sys; pathlib.Path(sys.argv[1]).write_text(os.environ['PWD'])", str(output)], cwd=self.repo)
        self.assertEqual(Path(output.read_text()), self.repo)

    def test_signature_tracks_actual_submodule_head_and_repeated_dirty_edits(self):
        initial = release.native_signature(self.repo, "toolchain")
        (self.library / "Native.swift").write_text("second")
        self.git(self.library, "-c", "user.name=Build test", "-c", "user.email=build@example.test", "commit", "--quiet", "-am", "second")
        current = release.native_signature(self.repo, "toolchain")
        self.assertNotEqual(initial, current)
        (self.library / "Native.swift").write_text("third")
        third = release.native_signature(self.repo, "toolchain")
        (self.library / "Native.swift").write_text("fourth")
        self.assertNotEqual(current, third)
        self.assertNotEqual(third, release.native_signature(self.repo, "toolchain"))

    def test_initialization_preserves_an_already_checked_out_submodule(self):
        (self.library / "Native.swift").write_text("local revision")
        self.git(self.library, "-c", "user.name=Build test", "-c", "user.email=build@example.test", "commit", "--quiet", "-am", "local revision")
        head = self.git(self.library, "rev-parse", "HEAD")
        release.initialize_missing_submodules(self.repo, self.root / "submodules.log")
        self.assertEqual(self.git(self.library, "rev-parse", "HEAD"), head)
        self.assertEqual((self.library / "Native.swift").read_text(), "local revision")

    def test_cache_miss_rebuilds_even_when_repository_xcode_stamp_matches(self):
        toolchain = subprocess.check_output(["xcodebuild", "-version"], text=True)
        (self.repo / "last-xcode-version").write_text(toolchain)
        (self.repo / "ThirdParty").mkdir()
        (self.repo / "ThirdParty/artifact").write_text("old prebuilt")
        (self.repo / "sources").mkdir()
        (self.repo / "sources/app").write_text("first application")
        self.git(self.repo, "add", "last-xcode-version", "ThirdParty", "sources")
        self.git(self.repo, "commit", "--quiet", "-m", "build inputs")
        cache = self.root / "cache"
        cache.mkdir()
        original_run = release.run

        def compiler_boundary(command, **kwargs):
            if command[0] == "/usr/bin/sandbox-exec":
                (kwargs["cwd"] / "ThirdParty/artifact").write_text("new compiled")
            else:
                original_run(command, **kwargs)

        with patch.object(release, "run", side_effect=compiler_boundary):
            source = release.prepare_source(self.repo, cache)
        self.assertEqual((source / "ThirdParty/artifact").read_text(), "new compiled")
        (self.repo / "sources/app").write_text("updated application")
        source = release.prepare_source(self.repo, cache)
        self.assertEqual((source / "ThirdParty/artifact").read_text(), "new compiled")
        self.assertEqual((source / "sources/app").read_text(), "updated application")


if __name__ == "__main__":
    unittest.main()
