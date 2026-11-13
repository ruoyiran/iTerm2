#!/usr/bin/env python3
"""Record a pinned source import and locale subset; builds never require Orca."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import re
import subprocess

PIN = '729f757b592244176420a86114c1ea23911eeeba'
TOOLING = Path(__file__).resolve().parent
REPO = TOOLING.parent.parent
RESOURCES = REPO / 'sources/FileWorkspace/Resources'
VENDOR = RESOURCES / 'src/orca'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write(path, data):
    path.write_text(data)
    subprocess.run(['git', '-C', str(REPO), 'add', str(path)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', required=True, type=Path)
    args = parser.parse_args()
    def original(path):
        return subprocess.check_output(['git', '-C', str(args.upstream), 'show', PIN + ':' + path])
    records, patches = [], []
    for path in sorted(VENDOR.rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(VENDOR).as_posix()
        before, after = original(relative), path.read_bytes()
        records.append({'path': relative, 'upstreamSHA256': digest(before), 'sha256': digest(after)})
        if before != after:
            patches.extend(difflib.unified_diff(before.decode().splitlines(True), after.decode().splitlines(True), fromfile='a/' + relative, tofile='b/' + relative))
    keys = set()
    for path in (RESOURCES / 'src').rglob('*'):
        if path.suffix in ('.ts', '.tsx', '.mjs'):
            keys.update(re.findall(r'''['"]([^'"\n]+)['"]''', path.read_text()))
    catalogs, locale_sources = {}, []
    for locale in ['en', 'zh', 'zh-Hant', 'ja', 'ko', 'es', 'fr', 'pt', 'ru', 'tr', 'de']:
        relative = 'src/renderer/src/i18n/locales/' + locale + '.json'
        raw = original(relative)
        def flatten(value, prefix=''):
            result = {}
            for key, entry in value.items():
                name = prefix + key
                if isinstance(entry, dict):
                    result.update(flatten(entry, name + '.'))
                elif isinstance(entry, str):
                    result[name] = entry
            return result
        full = flatten(json.loads(raw))
        catalogs[locale] = {key: value for key, value in full.items() if key in keys or re.sub(r'_(zero|one|two|few|many|other)$', '', key) in keys}
        locale_sources.append({'path': relative, 'upstreamSHA256': digest(raw), 'keys': sorted(catalogs[locale])})
    locale_path = RESOURCES / 'src/portable/orca-locales.json'
    write(locale_path, json.dumps(catalogs, ensure_ascii=False, indent=2) + '\n')
    record = {'repository': 'https://github.com/stablyai/orca', 'commit': PIN, 'license': 'MIT', 'files': records, 'locales': locale_sources, 'localeSubsetSHA256': digest(locale_path.read_bytes())}
    write(RESOURCES / 'licenses/Orca-SOURCE-PROVENANCE.json', json.dumps(record, indent=2) + '\n')
    write(TOOLING / 'patches/orca-local.patch.json', json.dumps({'format': 'unified-diff', 'patch': ''.join(patches)}, ensure_ascii=False, indent=2) + '\n')
    print(f'Recorded {len(records)} source files and {len(catalogs)} scoped locale catalogs.')


if __name__ == '__main__':
    main()
