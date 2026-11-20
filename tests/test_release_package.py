import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("release_package", ROOT / "tools/release_package.py")
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class ReleasePackageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = tempfile.TemporaryDirectory()
        root = Path(cls.fixture.name)
        source = root / "main.c"
        source.write_text("static volatile int answer = 42;\nint main(void) { return answer == 42 ? 0 : 1; }\n")
        cls.executable = root / "iTerm2"
        object_file = root / "main.o"
        subprocess.run(["xcrun", "clang", "-g", "-c", str(source), "-o", str(object_file)], check=True)
        subprocess.run(["xcrun", "clang", "-g", str(object_file), "-o", str(cls.executable)], check=True)
        cls.dsym = root / "iTerm2.app.dSYM"
        subprocess.run(["xcrun", "dsymutil", str(cls.executable), "-o", str(cls.dsym)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.fixture.cleanup()

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name).resolve()
        self.app = self.root / "output with spaces/iTerm2.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        shutil.copy2(self.executable, self.app / "Contents/MacOS/iTerm2")
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.googlecode.iterm2",
            "CFBundleExecutable": "iTerm2",
        }))
        shutil.copytree(self.dsym, self.app.parent / self.dsym.name)
        self.resources = self.app / "Contents/Resources"
        self.resources.mkdir()
        self.symbols = self.root / "symbols"

    def tearDown(self):
        self.directory.cleanup()

    def test_preparation_archives_matching_symbols_before_stripping_and_keeps_executable_working(self):
        executable = self.app / "Contents/MacOS/iTerm2"
        original = executable.read_bytes()
        before_uuid = package.binary_uuids(executable)
        package.prepare_app(self.app, self.symbols)
        self.assertEqual(package.binary_uuids(executable), before_uuid)
        self.assertEqual(package.binary_uuids(self.symbols / "dSYMs/iTerm2.app.dSYM"), before_uuid)
        debug_info = subprocess.check_output(["xcrun", "dwarfdump", "--debug-info", str(self.symbols / "dSYMs/iTerm2.app.dSYM")], text=True)
        self.assertIn('"answer"', debug_info)
        self.assertEqual((self.symbols / "unstripped/Contents/MacOS/iTerm2").read_bytes(), original)
        self.assertLess(executable.stat().st_size, len(original))
        subprocess.run([str(executable)], check=True)
        symbols = subprocess.check_output(["xcrun", "nm", "-a", str(executable)], text=True)
        self.assertNotIn("_answer", symbols)
        self.assertIn("_main", symbols)
        package.prepare_app(self.app, self.symbols)
        self.assertEqual((self.symbols / "unstripped/Contents/MacOS/iTerm2").read_bytes(), original)

    def test_localizations_are_lossless_binary_plists_including_plurals(self):
        locale = self.resources / "zh-Hans.lproj"
        locale.mkdir()
        translations = {"greeting": "你好，%@！", "escaped": "line\n\"quote\""}
        plural = {"items": {"NSStringLocalizedFormatKey": "%#@count@", "count": {
            "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
            "NSStringFormatValueTypeKey": "d", "other": "%d 项",
        }}}
        raw = plistlib.dumps(translations).decode().encode("utf-16")
        (locale / "Localizable.strings").write_bytes(raw)
        (locale / "Localizable.stringsdict").write_bytes(plistlib.dumps(plural))
        package.prepare_app(self.app, self.symbols)
        for name, expected in [("Localizable.strings", translations), ("Localizable.stringsdict", plural)]:
            data = (locale / name).read_bytes()
            self.assertTrue(data.startswith(b"bplist00"))
            self.assertEqual(plistlib.loads(data), expected)

    def test_excludes_only_test_adapter_and_does_not_follow_symlinks(self):
        executable = self.app / "Contents/MacOS/iTerm2"
        for name in ["iterm2-test-adapter", "iterm2-keeper-adapter"]:
            shutil.copy2(self.executable, executable.parent / name)
        outside = self.root / "outside.strings"
        outside.write_bytes(plistlib.dumps({"keep": "original"}))
        original = outside.read_bytes()
        (self.resources / "external.strings").symlink_to(outside)
        package.prepare_app(self.app, self.symbols)
        self.assertFalse((executable.parent / "iterm2-test-adapter").exists())
        self.assertTrue((executable.parent / "iterm2-keeper-adapter").exists())
        self.assertEqual(outside.read_bytes(), original)

    def test_refuses_missing_or_mismatched_dsym_without_mutating_app(self):
        executable = self.app / "Contents/MacOS/iTerm2"
        original = executable.read_bytes()
        shutil.rmtree(self.app.parent / self.dsym.name)
        with self.assertRaisesRegex(ValueError, "dSYM"):
            package.prepare_app(self.app, self.symbols)
        self.assertEqual(executable.read_bytes(), original)

    def test_symbols_must_be_outside_the_app(self):
        with self.assertRaises(ValueError):
            package.prepare_app(self.app, self.resources / "symbols")

    def test_mismatched_dsym_is_rejected_before_any_product_changes(self):
        source = self.root / "different.c"
        source.write_text("int main(void) { return 7; }\n")
        object_file = self.root / "different.o"
        different = self.root / "different"
        subprocess.run(["xcrun", "clang", "-g", "-c", str(source), "-o", str(object_file)], check=True)
        subprocess.run(["xcrun", "clang", "-g", str(object_file), "-o", str(different)], check=True)
        dsym = self.app.parent / self.dsym.name
        shutil.rmtree(dsym)
        subprocess.run(["xcrun", "dsymutil", str(different), "-o", str(dsym)], check=True)
        executable = self.app / "Contents/MacOS/iTerm2"
        original = executable.read_bytes()
        with self.assertRaisesRegex(ValueError, "mismatched"):
            package.prepare_app(self.app, self.symbols)
        self.assertEqual(executable.read_bytes(), original)
        self.assertFalse(self.symbols.exists())

    def test_size_report_counts_files_once_and_rejects_oversized_bundle(self):
        (self.resources / "payload").write_bytes(b"x" * 1024)
        (self.resources / "alias").symlink_to("payload")
        expected = sum(p.stat().st_size for p in self.app.rglob("*") if p.is_file() and not p.is_symlink())
        report = package.write_size_report(self.app, self.root / "size.json")
        self.assertEqual(report["bytes"], expected)
        self.assertEqual(json.loads((self.root / "size.json").read_text())["bytes"], expected)
        with self.assertRaisesRegex(ValueError, "MiB"):
            package.check_size(report, max_mib=0.001)

    def test_archives_matching_dependency_dsyms_from_explicit_roots(self):
        dependency = self.root / "ThirdParty/Helper.framework.dSYM"
        shutil.copytree(self.dsym, dependency)
        package.prepare_app(self.app, self.symbols, dsym_roots=[dependency.parent])
        self.assertEqual(package.binary_uuids(self.symbols / "dSYMs/Helper.framework.dSYM"),
                         package.binary_uuids(self.app / "Contents/MacOS/iTerm2"))

    def test_rejects_symbol_output_overlapping_an_input_dsym(self):
        dsym = self.app.parent / self.dsym.name
        original = (self.app / "Contents/MacOS/iTerm2").read_bytes()
        with self.assertRaisesRegex(ValueError, "overlap"):
            package.prepare_app(self.app, dsym / "output")
        self.assertEqual((self.app / "Contents/MacOS/iTerm2").read_bytes(), original)
        self.assertFalse((dsym / "output").exists())

    def test_resigning_cannot_replace_archived_original_with_larger_stripped_binary(self):
        executable = self.app / "Contents/MacOS/iTerm2"
        original = executable.read_bytes()
        package.prepare_app(self.app, self.symbols)
        entitlements = self.root / "entitlements.plist"
        entitlements.write_bytes(plistlib.dumps({"com.example.fixture": "x" * 100000}))
        subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(executable)],
                       check=True, capture_output=True)
        self.assertGreater(executable.stat().st_size, len(original))
        package.prepare_app(self.app, self.symbols)
        self.assertEqual((self.symbols / "unstripped/Contents/MacOS/iTerm2").read_bytes(), original)

    def test_local_cli_matches_app_architectures_and_remote_wrapper_is_unchanged(self):
        other = self.root / "other-architecture"
        architecture = "arm64" if "x86_64" in package.binary_uuids(self.executable) else "x86_64"
        subprocess.run(["xcrun", "clang", "-arch", architecture, "-x", "c", "-", "-o", str(other)],
                       input="int main(void) { return 0; }\n", text=True, check=True)
        utilities = self.resources / "utilities"
        utilities.mkdir()
        cli = utilities / "it2"
        subprocess.run(["lipo", "-create", str(self.executable), str(other), "-output", str(cli)], check=True)
        original = cli.read_bytes()
        (self.resources / "it2.py").write_text("remote interpreter fixture\n")
        (utilities / "it2-remote").write_text("remote wrapper fixture\n")
        package.prepare_app(self.app, self.symbols)
        self.assertEqual(set(package.binary_uuids(cli)), set(package.binary_uuids(self.app / "Contents/MacOS/iTerm2")))
        self.assertEqual((self.symbols / "unstripped/Contents/Resources/utilities/it2").read_bytes(), original)
        self.assertEqual((self.resources / "it2.py").read_text(), "remote interpreter fixture\n")
        self.assertEqual((utilities / "it2-remote").read_text(), "remote wrapper fixture\n")
        subprocess.run([str(cli)], check=True)
        package.prepare_app(self.app, self.symbols)
        self.assertEqual((self.symbols / "unstripped/Contents/Resources/utilities/it2").read_bytes(), original)

    def test_universal_cli_keeps_both_slices_when_app_supports_both(self):
        other = self.root / "other-architecture"
        architecture = "arm64" if "x86_64" in package.binary_uuids(self.executable) else "x86_64"
        subprocess.run(["xcrun", "clang", "-arch", architecture, "-x", "c", "-", "-o", str(other)],
                       input="int main(void) { return 0; }\n", text=True, check=True)
        cli = self.root / "universal-it2"
        subprocess.run(["lipo", "-create", str(self.executable), str(other), "-output", str(cli)], check=True)
        original = cli.read_bytes()
        package.thin_local_cli(cli, {"arm64", "x86_64"})
        self.assertEqual(cli.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
