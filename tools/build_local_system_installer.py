"""Build a private local update package; NEVER publish this artifact.

Keep installed SharedSupport and, by default, the authorized Helper byte-for-byte.
--update-helper includes new Helper behavior/UI when the change requires it.
The public package builder deliberately rejects those personal dictionaries.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from datetime import datetime

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.run([str(x) for x in args], check=True, capture_output=True, text=True)


def hashes(root, allow_internal_links=False):
    assert root.is_dir() and not root.is_symlink()
    result = {}
    for p in root.rglob('*'):
        if p.is_symlink():
            assert allow_internal_links and p.resolve().is_relative_to(root.resolve()), 'Refusing external linked resources'
            result[str(p.relative_to(root))] = 'symlink:' + str(p.readlink())
            continue
        if p.is_file():
            result[str(p.relative_to(root))] = hashlib.sha256(p.read_bytes()).hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--public-app', type=Path, required=True)
    parser.add_argument('--report', type=Path, default=ROOT / 'evidence/local-preserved-update.json')
    parser.add_argument('--update-helper', action='store_true')
    args = parser.parse_args()
    public = args.public_app.resolve()
    assert public.is_relative_to(ROOT / 'enhanced-squirrel/build')
    system = Path('/Library/Input Methods/SquirrelEnhancedDev.app')
    installed = system if system.exists() else Path.home() / 'Library/Input Methods/SquirrelEnhancedDev.app'
    assert not installed.is_symlink() and installed.resolve() == installed
    if installed == system:
        assert installed.stat().st_uid == 0 and not installed.stat().st_mode & 0o022
    run('codesign', '--verify', '--deep', '--strict', installed)
    run('codesign', '--verify', '--deep', '--strict', public)
    old = plistlib.loads((installed / 'Contents/Info.plist').read_bytes())
    new = plistlib.loads((public / 'Contents/Info.plist').read_bytes())
    assert old['CFBundleIdentifier'] == new['CFBundleIdentifier']
    assert old['SquirrelEnhancementCertificateSHA1'] == new['SquirrelEnhancementCertificateSHA1']
    app_version = new['CFBundleShortVersionString']
    version = '0.1.' + datetime.now().strftime('%Y%m%d') + '.' + app_version.rsplit('.', 1)[1]
    work = Path(tempfile.mkdtemp(prefix=f'.local-preserved-update-{app_version}-', suffix='.noindex',
                                 dir=ROOT / 'enhanced-squirrel/build'))
    scripts = work / 'scripts'
    scripts.mkdir()
    app = scripts / 'SquirrelEnhancedDev.app'
    run('/usr/bin/ditto', public, app)
    preserved = {}
    preserved_paths = ['Contents/SharedSupport']
    if not args.update_helper:
        preserved_paths.append('Contents/Resources/SquirrelVoiceHelper.app')
    for relative in preserved_paths:
        preserved[relative] = hashes(installed / relative)
        shutil.rmtree(app / relative)
        run('/usr/bin/ditto', installed / relative, app / relative)
        assert hashes(app / relative) == preserved[relative]
    project = ROOT / 'enhanced-squirrel'
    # Sign only the changed parent. The Helper is either byte-preserved or the
    # new already-signed public Helper; no Keychain data is accessed.
    signing = 'root="$1"; source "$root/scripts/local-signing.sh"; prepare_local_signing; sign_local_code "$2" "$root/resources/Squirrel.entitlements"'
    run('/bin/bash', '-c', signing, 'local-migration', project, app)
    run('codesign', '--verify', '--deep', '--strict', app)
    for relative, expected in preserved.items():
        assert hashes(app / relative) == expected
    for name, target in [('pkg-postinstall.sh', 'postinstall'),
                         ('pkg-system-install.sh', 'pkg-system-install.sh'),
                         ('app-install-transaction.sh', 'app-install-transaction.sh')]:
        shutil.copy2(project / 'scripts' / name, scripts / target)
        (scripts / target).chmod(0o755)
        run('/bin/bash', '-n', scripts / target)
    output = work / f'SquirrelVoiceInput-{version}-local-system-arm64.pkg'
    run('/usr/bin/pkgbuild', '--nopayload', '--scripts', scripts,
        '--identifier', 'org.rime.SquirrelEnhanced.Development.LocalSystemMigration',
        '--version', version, '--install-location', '/', output)
    expanded = work / 'expanded'
    run('/usr/sbin/pkgutil', '--expand-full', output, expanded)
    fresh = next(p for p in expanded.rglob('SquirrelEnhancedDev.app') if p.is_dir())
    assert hashes(app, True) == hashes(fresh, True)
    run('codesign', '--verify', '--deep', '--strict', fresh)
    report = {'status': 'PASS', 'package': str(output),
              'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
              'private_local_only': True, 'installed': False,
              'main_version': new['CFBundleShortVersionString'],
              'helper_updated': args.update_helper,
              'helper_version': plistlib.loads((app / 'Contents/Resources/SquirrelVoiceHelper.app/Contents/Info.plist').read_bytes())['CFBundleShortVersionString'],
              'preserved_files': {k: len(v) for k, v in preserved.items()},
              'keychain_read': False, 'settings_changed': False}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
