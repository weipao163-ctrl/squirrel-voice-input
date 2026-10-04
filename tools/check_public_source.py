#!/usr/bin/env python3
"""Check public source boundaries. Print paths and rule names, never secret values."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN_PARTS = {
    '.venv', 'venv', '__pycache__', '.build', 'build', 'dist', 'evidence',
    'download', 'Frameworks', 'xcuserdata', 'install-backups', 'cn_dicts',
    'en_dicts', 'upstream', 'tmp', 'test-work', 'vendor', 'data', 'packages',
    'repos', 'lib', 'bin',
}
FORBIDDEN_SUFFIXES = {
    '.pkg', '.dmg', '.zip', '.dylib', '.so', '.dll', '.exe', '.o', '.a',
    '.pyc', '.key', '.pem', '.p12', '.pfx', '.crt', '.cer', '.wav', '.pcm',
    '.mp3', '.m4a', '.db', '.log', '.bincode', '.bin',
}
PUBLIC_DICTIONARIES = {
    'tests/fixtures/letter_fixture.dict.yaml',
    'enhanced-squirrel/resources/LetterProbe/letter_fixture.dict.yaml',
    'enhanced-squirrel/resources/Quick5/quick5.dict.yaml',
    'enhanced-squirrel/resources/Quick5/quick5.supplement.dict.yaml',
}
PRIVATE_NAMES = {'settings.json', 'user.yaml', 'installation.yaml',
                 'custom_phrase.txt', '.DS_Store', 'SHA256SUMS.json',
                 'SQUIRREL_GOAL.md'}
RULES = {
    'private-key': re.compile(r'-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----'),
    'github-token': re.compile(r'(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})'),
    'service-key': re.compile(r'\bsk-[A-Za-z0-9_-]{20,}'),
    'aws-key': re.compile(r'\bAKIA[0-9A-Z]{16}\b'),
    'credential-literal': re.compile(r'''(?i)(?:api[_-]?key|access[_-]?token|password|secret)\s*[:=]\s*["']([A-Za-z0-9_+/=\-]{24,})["']'''),
    'personal-home-path': re.compile(r'(?:/Users/[A-Za-z0-9_.-]+/|[A-Za-z]:\\Users\\[A-Za-z0-9_.-]+\\)'),
}


def main():
    # A Git repository uses only tracked/staged files, so ignored local test
    # outputs cannot accidentally become an excuse to skip a committed secret.
    if (ROOT / '.git').exists():
        result = subprocess.run(['git', 'ls-files', '--stage', '-z'], cwd=ROOT,
                                capture_output=True, check=True)
        entries = {}
        for record in result.stdout.split(b'\0'):
            if not record: continue
            metadata, name = record.split(b'\t', 1)
            mode, digest, stage = metadata.decode().split()
            entries[name.decode()] = (mode, digest, stage)
        paths = [ROOT / n for n in entries]
        if not entries:
            print('FAIL: no staged/tracked source files'); return 1
        def read(path):
            mode, digest, stage = entries[path.relative_to(ROOT).as_posix()]
            return subprocess.run(['git', 'cat-file', 'blob', digest], cwd=ROOT,
                                  capture_output=True, check=True).stdout
    else:
        entries = None
        paths = [p for p in ROOT.rglob('*') if p.is_file() or p.is_symlink()]
        read = lambda path: path.read_bytes()
    failures = []
    for path in paths:
        rel = path.relative_to(ROOT)
        invalid_mode = entries is not None and (entries[rel.as_posix()][0] not in {'100644', '100755'} or entries[rel.as_posix()][2] != '0')
        if (invalid_mode or path.is_symlink() or FORBIDDEN_PARTS.intersection(rel.parts)
                or rel.as_posix().startswith('enhanced-squirrel/plum/package/')
                or any(p.startswith('._') or p.endswith('.userdb') for p in rel.parts)
                or path.suffix.lower() in FORBIDDEN_SUFFIXES
                or path.name in PRIVATE_NAMES
                or path.name.startswith('.env')
                or '.sqlite' in path.name or '.userdb.' in path.name
                or (path.name.endswith('.dict.yaml')
                    and rel.as_posix() not in PUBLIC_DICTIONARIES)):
            failures.append((str(rel), 'forbidden-path')); continue
        if entries is None and not path.is_file():
            failures.append((str(rel), 'missing-file')); continue
        data = read(path)
        if len(data) > 5 * 1024 * 1024:
            failures.append((str(rel), 'unexpected-large-file'))
        if data[:4] in {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\x7fELF'} or data[:2] == b'MZ':
            failures.append((str(rel), 'compiled-binary'))
        try:
            text = data.decode('utf-8-sig')
        except UnicodeDecodeError:
            if path.suffix.lower() != '.pdf':
                failures.append((str(rel), 'unexpected-binary-resource'))
            continue
        for name, pattern in RULES.items():
            if pattern.search(text): failures.append((str(rel), name))
    # Bundled dictionary sources must match the public upstream provenance.
    public = ROOT / 'enhanced-squirrel/resources/Quick5'
    try:
        upstream = json.loads(read(public/'UPSTREAM.json'))
        for name, digest in upstream['files_sha256'].items():
            if hashlib.sha256(read(public/name)).hexdigest() != digest:
                failures.append((str((public/name).relative_to(ROOT)), 'public-resource-source-mismatch'))
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError):
        failures.append(('enhanced-squirrel/resources/Quick5', 'missing-or-invalid-public-resource-provenance'))
    print(json.dumps({'status': 'FAIL' if failures else 'PASS',
                      'source_files_checked': len(paths),
                      'violations_paths_and_rules_only': failures}, ensure_ascii=False))
    return int(bool(failures))


if __name__ == '__main__':
    sys.exit(main())
