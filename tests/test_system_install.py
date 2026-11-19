"""Run the production Bash migration in a temporary filesystem with OS doubles.

No actual root, input-source registration, process termination or system writes.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'enhanced-squirrel/scripts'
IDENTIFIER = 'org.rime.inputmethod.SquirrelEnhanced.Development'


class SystemInstallTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='squirrel-system-install-')
        self.root = Path(self.tmp.name).resolve()
        self.home = self.root / 'home'
        self.home.mkdir()
        self.system = self.root / 'Library'
        self.scripts = self.root / 'scripts'
        self.scripts.mkdir()
        self.calls = self.root / 'calls'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.app = self.scripts / 'SquirrelEnhancedDev.app'
        self.target = self.system / 'Input Methods/SquirrelEnhancedDev.app'
        self.user = self.home / 'Library/Input Methods/SquirrelEnhancedDev.app'
        self.fixture_app(self.app, 'new')
        self.fixture_app(self.user, 'user-old')
        self.personal = self.home / 'Library/Application Support/SquirrelEnhancedDev'
        self.personal.mkdir(parents=True)
        (self.personal / 'settings.json').write_text('DO NOT CHANGE')
        self.executable('id', '#!/bin/bash\nif [[ $# == 1 ]]; then echo 0; else echo '+str(os.getuid())+'; fi\n')
        self.executable('pgrep', '#!/bin/bash\n[[ ${BUSY:-0} == 1 ]]\n')
        self.executable('sleep', '#!/bin/bash\nexit 0\n')
        self.executable('codesign', '#!/bin/bash\nexit 0\n')
        self.executable('chown', '#!/bin/bash\nprintf "ownership\\n" >> "$CALLS"\n')
        self.executable('open', '#!/bin/bash\nprintf "open:%s\\n" "$2" >> "$CALLS"\n')
        self.executable('session', '#!/bin/bash\nshift\nexport REGISTRATION_SCOPE=user\n"$@"\n')
        self.executable('stat', '#!/bin/bash\nif [[ $3 == "$FIXTURE_HOME" ]]; then echo '+str(os.getuid())+'; else echo 0; fi\n')
        self.executable('find', '#!/bin/bash\nif [[ ${UNSAFE_SYSTEM_TREE:-0} == 1 && "$1" == "$SYSTEM_TARGET" && $(cat "$1/version") == new ]]; then echo "$1/unsafe"; fi\n')
        self.executable('sudo', '#!/bin/bash\nshift 3\n"$@"\n')
        self.executable('registrar', '#!/bin/bash\nprintf "registry:%s\\n" "$*" >> "$CALLS"\n')
        substitutions = {
            '/Library/Input Methods': str(self.system / 'Input Methods'),
            '/Library/Application Support/SquirrelEnhancedDev': str(self.system / 'Application Support/SquirrelEnhancedDev'),
            '/usr/bin/codesign': str(self.bin / 'codesign'),
            '/usr/sbin/chown': str(self.bin / 'chown'),
            '/usr/bin/pgrep': str(self.bin / 'pgrep'),
            '/bin/sleep': str(self.bin / 'sleep'),
            '/usr/bin/open': str(self.bin / 'open'),
            '/usr/bin/stat': str(self.bin / 'stat'),
            '/usr/bin/find': str(self.bin / 'find'),
            '/bin/launchctl asuser': str(self.bin / 'session'),
            '/usr/bin/sudo': str(self.bin / 'sudo'),
            '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister': str(self.bin / 'registrar'),
        }
        for name in ['pkg-system-install.sh', 'app-install-transaction.sh']:
            source = (SCRIPTS / name).read_text()
            source = source.replace('\n    codesign --verify', '\n    '+str(self.bin / 'codesign')+' --verify')
            source = source.replace('\n  codesign --verify', '\n  '+str(self.bin / 'codesign')+' --verify')
            for before, after in substitutions.items():
                source = source.replace(before, after)
            (self.scripts / name).write_text(source)
        # User paths use the injected real temporary home and remain unchanged.
        p = self.scripts / 'pkg-system-install.sh'
        s = p.read_text().replace('$account_home'+str(self.system), '$account_home/Library')
        p.write_text(s)

    def tearDown(self):
        self.tmp.cleanup()

    def executable(self, name, text):
        p = self.bin / name
        p.write_text(text)
        p.chmod(0o755)

    def fixture_app(self, app, version):
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Resources/SquirrelVoiceHelper.app').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': IDENTIFIER}))
        (app / 'version').write_text(version)
        executable = app / 'Contents/MacOS/SquirrelEnhancedDev'
        executable.write_text('''#!/bin/bash
printf 'cli:%s:%s\n' "$0" "$*" >> "$CALLS"
if [[ $1 == --register-input-source ]]; then
  app="${0%/Contents/MacOS/SquirrelEnhancedDev}"
  version="$(cat "$app/version")"
  printf 'registration:%s:%s\n' "${REGISTRATION_SCOPE:-system}" "$version" >> "$CALLS"
  if [[ "$version" == new && "${REGISTRATION_SCOPE:-system}" == system && ${FAIL_SYSTEM_REGISTER:-0} == 1 ]]; then exit 1; fi
  if [[ "$version" == new && "${REGISTRATION_SCOPE:-system}" == user && ${FAIL_USER_REGISTER:-0} == 1 ]]; then exit 1; fi
fi
if [[ $1 == --enable-input-source ]]; then printf 'enable-scope:%s\n' "${REGISTRATION_SCOPE:-system}" >> "$CALLS"; fi
if [[ $1 == --quit && ${CANCEL:-0} == 1 ]]; then exit 1; fi
if [[ $1 == --register-input-source && $0 == "$SYSTEM_TARGET/"* && ${FAIL_REGISTER:-0} == 1 ]]; then exit 1; fi
if [[ $1 == --register-input-source && $0 == "$SYSTEM_TARGET/"* && ${REJECT_USER_COPY:-0} == 1 && -d "$USER_TARGET" ]]; then exit 1; fi
if [[ $1 == --exchange-installed-bundle ]]; then
  mv "$2" "$3.test-swap" && mv "$3" "$2" && mv "$3.test-swap" "$3"
  exit $?
fi
exit 0
''')
        executable.chmod(0o755)

    def run_install(self, **options):
        env = dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'],
                   CALLS=str(self.calls), SYSTEM_TARGET=str(self.target), USER_TARGET=str(self.user),
                   FIXTURE_HOME=str(self.home), **options)
        return subprocess.run(['/bin/bash', str(self.scripts / 'pkg-system-install.sh'),
                               str(self.app), 'fixture', str(os.getuid()), str(self.home)],
                              env=env, capture_output=True, text=True, timeout=20)

    def test_migration_retires_user_copy_preserves_data_and_registers_system(self):
        r = self.run_install()
        self.assertEqual(r.returncode, 0, r.stdout+r.stderr)
        self.assertEqual((self.target / 'version').read_text(), 'new')
        self.assertFalse(self.user.exists())
        backups = list((self.personal / 'install-backups').glob('*.app-backup'))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / 'version').read_text(), 'user-old')
        self.assertEqual((self.personal / 'settings.json').read_text(), 'DO NOT CHANGE')
        calls = self.calls.read_text()
        self.assertIn('ownership', calls)
        self.assertIn(str(self.target)+'/Contents/MacOS/SquirrelEnhancedDev:--enable-input-source', calls)
        self.assertFalse(self.target.stat().st_mode & 0o022)

    def test_cancelled_quit_does_not_install_or_retire_user_copy(self):
        r = self.run_install(CANCEL='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.target.exists())
        self.assertEqual((self.user / 'version').read_text(), 'user-old')

    def test_registers_system_cache_then_user_before_user_enablement_once(self):
        r = self.run_install()
        self.assertEqual(r.returncode, 0, r.stdout+r.stderr)
        calls = self.calls.read_text()
        self.assertEqual(calls.count('registration:system:new'), 1)
        self.assertEqual(calls.count('registration:user:new'), 1)
        self.assertLess(calls.index('registration:system:new'), calls.index('registration:user:new'))
        self.assertLess(calls.index('registration:user:new'), calls.index('enable-scope:user'))
        self.assertNotIn('enable-scope:system', calls)

    def test_system_registration_failure_restores_old_system_registration(self):
        self.fixture_app(self.target, 'system-old')
        r = self.run_install(FAIL_SYSTEM_REGISTER='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.target / 'version').read_text(), 'system-old')
        calls = self.calls.read_text()
        self.assertNotIn('registration:user:new', calls)
        self.assertIn('registration:system:system-old', calls)
        self.assertIn('registration:user:system-old', calls)
        self.assertEqual((self.personal / 'settings.json').read_text(), 'DO NOT CHANGE')

    def test_user_registration_failure_rolls_back_both_registration_scopes(self):
        self.fixture_app(self.target, 'system-old')
        r = self.run_install(FAIL_USER_REGISTER='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.target / 'version').read_text(), 'system-old')
        calls = self.calls.read_text()
        self.assertIn('registration:system:new', calls)
        self.assertIn('registration:user:new', calls)
        self.assertIn('registration:system:system-old', calls)
        self.assertIn('registration:user:system-old', calls)

    def test_identical_system_reinstall_still_refreshes_both_scopes(self):
        self.fixture_app(self.target, 'new')
        r = self.run_install()
        self.assertEqual(r.returncode, 0, r.stdout+r.stderr)
        calls = self.calls.read_text()
        self.assertEqual(calls.count('registration:system:new'), 1)
        self.assertEqual(calls.count('registration:user:new'), 1)

    def test_never_runs_retired_user_app_registration_as_system(self):
        r = self.run_install(FAIL_SYSTEM_REGISTER='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(self.user.exists())
        calls = self.calls.read_text()
        self.assertNotIn('registration:system:user-old', calls)
        self.assertIn('registration:user:user-old', calls)

    def test_unsafe_system_tree_is_not_executed_as_root(self):
        self.fixture_app(self.target, 'system-old')
        r = self.run_install(UNSAFE_SYSTEM_TREE='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.target / 'version').read_text(), 'system-old')
        calls = self.calls.read_text()
        self.assertNotIn('registration:system:new', calls)
        self.assertIn('registration:system:system-old', calls)

    def test_busy_process_aborts_before_any_system_install(self):
        r = self.run_install(BUSY='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.target.exists())
        self.assertTrue(self.user.exists())

    def test_registration_failure_rolls_back_existing_system_app(self):
        self.fixture_app(self.target, 'system-old')
        r = self.run_install(FAIL_REGISTER='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.target / 'version').read_text(), 'system-old')
        self.assertFalse(self.user.exists())
        self.assertEqual(len(list((self.personal / 'install-backups').glob('*.app-backup'))), 1)
        self.assertEqual((self.personal / 'settings.json').read_text(), 'DO NOT CHANGE')

    def test_user_copy_is_retired_before_system_registration(self):
        r = self.run_install(REJECT_USER_COPY='1')
        self.assertEqual(r.returncode, 0, r.stdout+r.stderr)
        self.assertFalse(self.user.exists())

    def test_first_migration_registration_failure_restores_user_app(self):
        r = self.run_install(FAIL_REGISTER='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.target.exists())
        self.assertEqual((self.user / 'version').read_text(), 'user-old')

    def test_symlink_system_destination_is_rejected(self):
        self.target.parent.mkdir(parents=True)
        self.target.symlink_to(self.user)
        r = self.run_install()
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual((self.user / 'version').read_text(), 'user-old')


if __name__ == '__main__':
    unittest.main()
