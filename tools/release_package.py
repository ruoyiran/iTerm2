#!/usr/bin/env python3
"""Prepare a release bundle, preserving symbols outside the application."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca",
    "cafebabf", "bfbafeca",
)}


def bundle_files(app):
    for directory, folders, files in os.walk(app, followlinks=False):
        for name in sorted(files):
            path = Path(directory) / name
            if not path.is_symlink():
                yield path


def is_macho(path):
    with path.open("rb") as data:
        return data.read(4) in MACHO_MAGICS


def binary_uuids(path):
    output = subprocess.check_output(["xcrun", "dwarfdump", "--uuid", str(path)], text=True)
    return {arch: uuid for uuid, arch in re.findall(r"UUID: (\S+) \(([^)]+)\)", output)}


def archive_binary(path, app, symbols):
    destination = symbols / "unstripped" / path.relative_to(app)
    uuids = binary_uuids(path)
    if not uuids:
        raise ValueError(f"Executable has no UUID: {path}")
    # An incremental packaging run must not replace the original symbol-bearing
    # binary with its already-stripped counterpart.
    if destination.exists():
        archived = binary_uuids(destination)
        if all(archived.get(arch) == uuid for arch, uuid in uuids.items()):
            return uuids
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, destination)
    return uuids


def thin_local_executable(path, architectures):
    present = binary_uuids(path)
    architectures = set(architectures)
    if not architectures or not architectures.issubset(present):
        raise ValueError(f"Local executable does not support the application architectures: {path}")
    if architectures == set(present):
        return present
    # These helpers execute locally. Universal app builds retain both slices;
    # SSH delivery uses the separate it2.py interpreter and it2-remote wrapper.
    with tempfile.TemporaryDirectory(prefix=".it2-thin-", dir=path.parent) as directory:
        output = Path(directory) / path.name
        options = ["-thin", next(iter(architectures))] if len(architectures) == 1 else [
            value for arch in sorted(architectures) for value in ("-extract", arch)]
        subprocess.run(["lipo", str(path), *options, "-output", str(output)], check=True)
        shutil.copymode(path, output)
        os.replace(output, path)
    return {arch: present[arch] for arch in architectures}


def compact_localization(path):
    before = subprocess.check_output(["plutil", "-convert", "xml1", "-o", "-", str(path)])
    binary = subprocess.check_output(["plutil", "-convert", "binary1", "-o", "-", str(path)])
    if plistlib.loads(before) != plistlib.loads(binary):
        raise ValueError(f"Localization changed during conversion: {path}")
    path.write_bytes(binary)


def prepare_app(app, symbols, dsym_roots=()):
    app, symbols = Path(app), Path(symbols)
    if app.is_symlink() or not app.is_dir():
        raise ValueError(f"Not an application bundle: {app}")
    app = app.resolve()
    symbols = symbols.resolve()
    if symbols == app or app in symbols.parents:
        raise ValueError("Release symbols must be stored outside the application")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.googlecode.iterm2" or info.get("CFBundleExecutable") != "iTerm2":
        raise ValueError(f"Not an iTerm2 application: {app}")
    main = app / "Contents/MacOS/iTerm2"
    if main.is_symlink():
        raise ValueError(f"Main executable must not be a symlink: {main}")
    uuids = binary_uuids(main)
    dsym = app.parent / (app.name + ".dSYM")
    if dsym.is_symlink() or not dsym.is_dir() or not uuids or binary_uuids(dsym) != uuids:
        raise ValueError(f"Missing or mismatched main executable dSYM: {dsym}")

    paths = [path for path in bundle_files(app) if path.name != "iterm2-test-adapter"]
    binaries = [path for path in paths if is_macho(path)]
    wanted = {item for path in binaries for item in binary_uuids(path).items()}
    sources = set(app.parent.glob("*.dSYM"))
    for root in dsym_roots:
        sources.update(Path(root).rglob("*.dSYM"))
    sources = sorted(source.resolve() for source in sources if source.is_dir() and not source.is_symlink())
    for source in sources:
        if source == symbols or source in symbols.parents or symbols in source.parents:
            raise ValueError(f"Release symbols overlap an input dSYM: {source}")
        destination = symbols / "dSYMs" / source.name
        resolved = destination.resolve()
        if destination.is_symlink() or resolved == source or resolved in source.parents or source in resolved.parents:
            raise ValueError(f"Release symbols overlap an input dSYM: {source}")
    for source in sources:
        if not wanted.intersection(binary_uuids(source).items()):
            continue  # Ignore stale dependency dSYMs from another build.
        destination = symbols / "dSYMs" / source.name
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(source, destination)

    (app / "Contents/MacOS/iterm2-test-adapter").unlink(missing_ok=True)
    local_helpers = {"Contents/Resources/utilities/it2", "Contents/MacOS/iterm2-bitwarden-adapter",
                     "Contents/MacOS/iterm2-keepassxc-adapter", "Contents/MacOS/iterm2-keeper-adapter"}
    for path in binaries:
        before = archive_binary(path, app, symbols)
        if str(path.relative_to(app)) in local_helpers:
            before = thin_local_executable(path, uuids)
        subprocess.run(["xcrun", "strip", "-x", str(path)], check=True)
        if binary_uuids(path) != before:
            raise ValueError(f"Executable architectures or UUIDs changed while stripping: {path}")
    for path in paths:
        if path.suffix in {".strings", ".stringsdict"}:
            compact_localization(path)


def write_size_report(app, destination):
    app = Path(app)
    files = [{"path": str(path.relative_to(app)), "bytes": path.stat().st_size} for path in bundle_files(app)]
    groups = {}
    for entry in files:
        group = "/".join(entry["path"].split("/")[:2])
        groups[group] = groups.get(group, 0) + entry["bytes"]
    total = sum(entry["bytes"] for entry in files)
    report = {"app": str(app.resolve()), "bytes": total, "mib": total / 1024 ** 2,
              "groups": groups, "files": sorted(files, key=lambda entry: -entry["bytes"])}
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2) + "\n")
    return report


def check_size(report, max_mib):
    if max_mib is not None and report["bytes"] > max_mib * 1024 ** 2:
        raise ValueError(f"Release bundle is {report['mib']:.2f} MiB; limit is {max_mib:g} MiB")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--symbols-dir", type=Path)
    parser.add_argument("--dsym-root", type=Path, action="append")
    parser.add_argument("--max-mib", type=float)
    parser.add_argument("--sign-identity", default=None)
    arguments = parser.parse_args()
    # Preserve the selected release signing identity when invoked after a signed
    # Xcode build. Unsigned contributor builds receive an ad-hoc signature.
    signature = subprocess.run(["codesign", "-d", "--verbose=4", str(arguments.app)], capture_output=True, text=True)
    authorities = re.findall(r"^Authority=(.+)$", signature.stderr, re.MULTILINE)
    identity = arguments.sign_identity or (authorities[0] if authorities else "-")
    symbols = arguments.symbols_dir or arguments.app.parent / "ReleaseSymbols"
    repository = Path(__file__).resolve().parents[1]
    roots = arguments.dsym_root if arguments.dsym_root is not None else [repository / name for name in (
        "ThirdParty", "BetterFontPicker", "ColorPicker", "SearchableComboListView")]
    prepare_app(arguments.app, symbols, dsym_roots=roots)
    from build_release import sign_app, verify_app
    sign_app(arguments.app, identity=identity)
    verify_app(arguments.app)
    report = write_size_report(arguments.app, symbols / "size.json")
    print(f"Release bundle: {report['mib']:.2f} MiB; symbols: {symbols}")
    check_size(report, arguments.max_mib)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"release packaging: {error}", file=sys.stderr)
        sys.exit(1)
