#!/usr/bin/env python3
"""Build Deployment in an isolated cache, sign locally, and install atomically."""

import argparse
import fcntl
from contextlib import contextmanager
from datetime import datetime
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile


REPOSITORY = Path(__file__).resolve().parents[1]
MACHO_MAGICS = {bytes.fromhex(value) for value in (
    "feedface", "cefaedfe", "feedfacf", "cffaedfe", "cafebabe", "bebafeca",
    "cafebabf", "bfbafeca",
)}
NATIVE_PATHS = ["ThirdParty", "submodules", "BetterFontPicker", "ColorPicker",
                "SearchableComboListView", "pwmplugin", "last-xcode-version",
                "Makefile", "deps.sb", "tools/build_release.py"]


def run(command, *, cwd=None, log=None, environment=None):
    if cwd is not None:
        environment = (environment or os.environ).copy()
        # subprocess changes cwd without updating PWD, which Makefile recipes use
        # for install prefixes. Keep both pointed at the isolated source copy.
        environment["PWD"] = str(Path(cwd).resolve())
    if log is None:
        subprocess.run(command, cwd=cwd, env=environment, check=True)
        return
    with log.open("w") as output:
        result = subprocess.run(command, cwd=cwd, env=environment,
                                stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        lines = log.read_text(errors="replace").splitlines()
        errors = [line for line in lines if "error:" in line or "Error " in line]
        for line in (errors or lines[-20:])[-20:]:
            print(line[:1500], file=sys.stderr)
        raise RuntimeError(f"Command failed ({result.returncode}); full log: {log}")


@contextmanager
def build_lock(cache):
    cache.mkdir(parents=True, exist_ok=True)
    with (cache / "build.lock").open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError(f"Another release build is running (cache: {cache})")
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def submodule_paths(repo):
    for row in subprocess.check_output(["git", "ls-files", "--stage", "-z"], cwd=repo).split(b"\0"):
        if row.startswith(b"160000 "):
            yield os.fsdecode(row.split(b"\t", 1)[1])


def initialize_missing_submodules(repo, log):
    # OpenSSL's nested repositories are its upstream interoperability test suites,
    # not inputs to the library build. Avoid downloading them for an app release.
    if repo.name == "openssl":
        return
    for name in submodule_paths(repo):
        directory = repo / name
        root = subprocess.run(["git", "-C", str(directory), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
        valid_head = subprocess.run(["git", "-C", str(directory), "rev-parse", "--verify", "HEAD"], capture_output=True)
        if root.returncode or Path(root.stdout.strip()).resolve() != directory.resolve() or valid_head.returncode:
            run(["git", "submodule", "update", "--init", "--", name], cwd=repo, log=log)
        initialize_missing_submodules(directory, log)


def hash_changed_files(digest, repo, paths):
    for name in paths.split(b"\0"):
        if not name:
            continue
        path = repo / os.fsdecode(name)
        if path.is_dir() and not path.is_symlink():
            continue  # Actual submodule HEAD and dirty files are hashed separately.
        digest.update(name)
        if path.is_symlink():
            digest.update(os.fsencode(os.readlink(path)))
        elif path.is_file():
            with path.open("rb") as data:
                for block in iter(lambda: data.read(1024 * 1024), b""):
                    digest.update(block)


def hash_submodules(digest, repo):
    if repo.name == "openssl":
        return
    for name in submodule_paths(repo):
        directory = repo / name
        digest.update(os.fsencode(name))
        root = subprocess.run(["git", "-C", str(directory), "rev-parse", "--show-toplevel"], capture_output=True, text=True)
        if root.returncode or Path(root.stdout.strip()).resolve() != directory.resolve():
            digest.update(b"uninitialized")
            continue
        digest.update(subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=directory))
        changes = subprocess.check_output(["git", "diff", "HEAD", "--name-only", "-z"], cwd=directory)
        untracked = subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=directory)
        hash_changed_files(digest, directory, changes + untracked)
        hash_submodules(digest, directory)


def native_signature(repo, toolchain):
    digest = hashlib.sha256((toolchain + os.uname().machine).encode())
    digest.update(subprocess.check_output(
        ["git", "ls-files", "--stage", "-z", "--", *NATIVE_PATHS], cwd=repo))
    changed = subprocess.check_output(
        ["git", "diff", "HEAD", "--name-only", "-z", "--", *NATIVE_PATHS], cwd=repo)
    hash_changed_files(digest, repo, changed)
    hash_submodules(digest, repo)
    return digest.hexdigest()


def prepare_source(repo, cache):
    toolchain = subprocess.check_output(["xcodebuild", "-version"], text=True)
    signature = native_signature(repo, toolchain)
    source = cache / "source"
    stamp = cache / "native-signature"
    native_ready = source.is_dir() and stamp.exists() and stamp.read_text() == signature
    if source.is_symlink():
        raise ValueError(f"Build source must not be a symlink: {source}")
    if not native_ready:
        stamp.unlink(missing_ok=True)
        if source.exists():
            shutil.rmtree(source)
    source.mkdir(parents=True, exist_ok=True)
    excludes = [".git", ".superpowers", "tmp", "node_modules", ".build", "build",
                "target", ".iterm2-ai-live.json", "/submodules/openssl/boringssl",
                "/submodules/openssl/krb5", "/submodules/openssl/pyca-cryptography"]
    if native_ready:
        excludes += ["/ThirdParty", "/BetterFontPicker/BetterFontPicker.framework",
                     "/ColorPicker/ColorPicker.framework",
                     "/SearchableComboListView/SearchableComboListView.framework",
                     "/last-xcode-version"]
    run(["rsync", "-a", "--delete", *[f"--exclude={p}" for p in excludes],
         str(repo) + "/", str(source) + "/"])
    if not native_ready:
        for command in ["cmake", "pkg-config", "autoconf", "automake", "cargo", "rustup"]:
            if shutil.which(command) is None:
                raise RuntimeError(f"Missing {command}; run make setup in {repo} first")
        print("Preparing native dependencies for the selected Xcode…", flush=True)
        environment = os.environ.copy()
        environment.update(CODESIGN_IDENTITY="-", CARGO_BUILD_JOBS="8")
        # Make resets PATH; Cargo still needs to find the selected rustc.
        environment["RUSTC"] = subprocess.check_output(["rustup", "which", "--toolchain", "stable", "rustc"], text=True).strip()
        cmake = shutil.which("cmake")
        if int(subprocess.check_output([cmake, "--version"], text=True).split()[2].split(".")[0]) >= 4:
            environment["CMAKE_POLICY_VERSION_MINIMUM"] = "3.5"
        # Keep the checked-in symbol catalog; regeneration requires the optional
        # SF Symbols design app and is unrelated to rebuilding compiled libraries.
        run(["/usr/bin/sandbox-exec", "-f", "deps.sb", "make", "-j8", "-o", "sfsymbolenum", "deps",
             f"BUILD_DIR={cache / 'products'}", f"CMAKE={cmake}"],
            cwd=source, environment=environment, log=cache / "dependencies.log")
        (source / "last-xcode-version").write_text(toolchain)
        stamp.write_text(signature)
    return source


def adapt_local_sdk(source, cache):
    # The repository can target a newer FoundationModels argument label than
    # the selected Xcode. Probe the real SDK and change only the build copy.
    probe = cache / "sdk-probe.swift"
    for label in ["samplingMode", "sampling"]:
        probe.write_text("import FoundationModels\n@available(macOS 26.0, *)\n"
                         f"func probe() {{ _ = GenerationOptions({label}: .greedy) }}\n")
        result = subprocess.run(["xcrun", "swiftc", "-typecheck", str(probe)],
                                capture_output=True, text=True)
        if result.returncode == 0:
            if label == "sampling":
                path = source / "sources/AITerm/AppleIntelligenceRunner.swift"
                path.write_text(path.read_text().replace("GenerationOptions(samplingMode:",
                                                       "GenerationOptions(sampling:"))
            return
    raise RuntimeError("Selected Xcode does not provide a supported FoundationModels SDK")


def sign_app(app):
    candidates = []
    for directory, folders, files in os.walk(app, followlinks=False):
        for name in files:
            path = Path(directory) / name
            if not path.is_symlink():
                with path.open("rb") as data:
                    if data.read(4) in MACHO_MAGICS:
                        candidates.append(path)
        for name in folders:
            path = Path(directory) / name
            if not path.is_symlink() and path.suffix in {".app", ".xpc", ".framework"}:
                candidates.append(path)
    # Sign nested code before enclosing bundles; never use --deep to sign.
    for path in sorted(candidates, key=lambda p: len(p.parts), reverse=True) + [app]:
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", str(path)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)


def verify_app(app):
    if app.is_symlink() or not app.is_dir():
        raise ValueError(f"Not an application bundle: {app}")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "com.googlecode.iterm2" or info.get("CFBundleExecutable") != "iTerm2":
        raise ValueError(f"Not an iTerm2 application: {app}")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)


def install_app(app, applications):
    verify_app(app)
    applications = applications.resolve()
    destination = applications / "iTerm2.app"
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        raise ValueError(f"Refusing to replace a non-directory or symlink: {destination}")
    staging = Path(tempfile.mkdtemp(prefix=".iterm2-install-", dir=applications))
    staged_app = staging / "iTerm2.app"
    backup = None
    try:
        subprocess.run(["ditto", str(app), str(staged_app)], check=True)
        verify_app(staged_app)
        if destination.exists():
            backup_directory = applications / ".iterm2-build-backups" / (
                datetime.now().strftime("%Y%m%d-%H%M%S-") + staging.name.rsplit("-", 1)[-1])
            backup_directory.mkdir(parents=True)
            backup = backup_directory / "iTerm2.app"
            os.replace(destination, backup)
        try:
            os.replace(staged_app, destination)
        except OSError:
            if backup is not None and backup.exists() and not destination.exists():
                os.replace(backup, destination)
            raise
        return destination, backup
    finally:
        shutil.rmtree(staging)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--no-install", action="store_true", help="Build without installing")
    parser.add_argument("--install-dir", type=Path, default=Path("/Applications"))
    parser.add_argument("--install-built", type=Path, help=argparse.SUPPRESS)
    arguments = parser.parse_args()
    if arguments.install_built:
        installed, backup = install_app(arguments.install_built, arguments.install_dir)
        print(f"Installed: {installed}")
        if backup:
            print(f"Previous version: {backup}")
        return
    if sys.platform != "darwin":
        raise RuntimeError("This script requires macOS and full Xcode")
    cache = REPOSITORY / "tmp/release-build"
    with build_lock(cache):
        print("Initializing missing submodules…", flush=True)
        initialize_missing_submodules(REPOSITORY, cache / "submodules.log")
        source = prepare_source(REPOSITORY, cache)
        adapt_local_sdk(source, cache)
        print("Building pinned file UI resources…", flush=True)
        tooling = source / "tools/file-workspace-ui"
        ui_stamp = cache / "ui-signature"
        signature = hashlib.sha256((tooling / "package-lock.json").read_bytes()).hexdigest()
        if not (tooling / "node_modules").is_dir() or not ui_stamp.exists() or ui_stamp.read_text() != signature:
            run(["npm", "ci", "--prefix", str(tooling)], log=cache / "npm.log")
            ui_stamp.write_text(signature)
        run(["npm", "run", "build", "--prefix", str(tooling)], log=cache / "ui.log")
        shutil.copy2(source / "plists/release-iTerm2.plist", source / "plists/iTerm2.plist")
        shutil.copy2(source / "xcstrings/Localizable.xcstrings", source / "sources/Localizable.xcstrings")
        print(f"Building Deployment ({os.uname().machine})… Full log: {cache / 'build.log'}", flush=True)
        run(["xcodebuild", "-scheme", "iTerm2", "-configuration", "Deployment", "-destination", "platform=macOS",
             "-skipPackagePluginValidation", "-disableAutomaticPackageResolution", "-skipPackageUpdates",
             "-onlyUsePackageVersionsFromResolvedFile", "CODE_SIGN_IDENTITY=", "CODE_SIGNING_REQUIRED=NO",
             "CODE_SIGNING_ALLOWED=NO", f"ARCHS={os.uname().machine}", "ONLY_ACTIVE_ARCH=YES",
             f"SYMROOT={cache / 'products'}", f"OBJROOT={cache / 'intermediates'}", "ENABLE_ADDRESS_SANITIZER=NO"],
            cwd=source, log=cache / "build.log")
        app = cache / "products/Deployment/iTerm2.app"
        print("Signing and verifying the local release…", flush=True)
        sign_app(app)
        verify_app(app)
        print(f"Release built: {app}", flush=True)
        if not arguments.no_install:
            if os.access(arguments.install_dir, os.W_OK):
                installed, backup = install_app(app, arguments.install_dir)
                print(f"Installed: {installed}")
                if backup:
                    print(f"Previous version: {backup}")
            else:
                run(["sudo", sys.executable, str(Path(__file__).resolve()), "--install-built", str(app),
                     "--install-dir", str(arguments.install_dir)])
            print("Restart iTerm2 if it is already running to use the installed release.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"release build: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            detail = error.stderr.decode(errors="replace") if isinstance(error.stderr, bytes) else error.stderr
            print(detail.strip(), file=sys.stderr)
        sys.exit(1)
