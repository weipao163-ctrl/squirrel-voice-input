"""Real shared Bash file transaction; native signing/TIS are explicit doubles.
Never invokes install --apply against the real home or a real macOS app.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT/'enhanced-squirrel/scripts/app-install-transaction.sh'
DRIVER = ROOT/'enhanced-squirrel/scripts/install-dev.sh'
UNINSTALL = ROOT/'enhanced-squirrel/scripts/uninstall-dev.sh'
SOURCES = [SCRIPT, DRIVER, UNINSTALL, ROOT/'enhanced-squirrel/sources/InputSource.swift',
           ROOT/'enhanced-squirrel/sources/Main.swift', Path(__file__).resolve()]


def bash_path(path):
    path = Path(path).resolve()
    if os.name == 'nt':
        return '/' + path.drive[0].lower() + path.as_posix()[2:]
    return str(path)


def snapshot(path):
    return {str(p.relative_to(path)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in path.rglob('*') if p.is_file()}


class TransactionTests(unittest.TestCase):
    bash = None
    observations = []

    def setUp(self):
        self.temp_root = Path(tempfile.gettempdir()).resolve()
        self.base = Path(tempfile.mkdtemp(prefix='squirrel-app-install-')).resolve()
        assert self.base.is_relative_to(self.temp_root) and self.base != self.temp_root
        self.source = self.base/'源构建 with spaces/SquirrelEnhancedDev.app'
        self.home = self.base/'isolated-home'
        self.target = self.home/'Library/Input Methods/SquirrelEnhancedDev.app'
        self.backups = self.home/'Library/Application Support/SquirrelEnhancedDev/install-backups'
        self.calls = self.base/'register-calls.txt'
        self.commands = self.base/'commands.txt'
        self.app(self.source, 'new')
        self.environment = os.environ.copy()
        self.environment.update(HOME=bash_path(self.home), REGISTRATION_LOG=bash_path(self.calls),
                                COMMAND_LOG=bash_path(self.commands))

    def tearDown(self):
        # Resolved absolute target checked before recursive native Python cleanup.
        assert self.base.is_relative_to(self.temp_root) and self.base != self.temp_root
        shutil.rmtree(self.base)

    def app(self, path, version):
        (path/'Contents/MacOS').mkdir(parents=True)
        (path/'Contents/version.txt').write_text(version, encoding='utf-8')
        executable = path/'Contents/MacOS/SquirrelEnhancedDev'
        executable.write_text('''#!/bin/bash
[[ "$1" == --register-input-source ]] || exit 99
printf 'register\\n' >> "$REGISTRATION_LOG"
if [[ "${CHANGE_TARGET:-0}" == 1 ]]; then
  printf 'later user edit' > "$(dirname "$0")/../version.txt"
fi
exit "${REGISTER_STATUS:-0}"
''', encoding='utf-8')
        executable.chmod(0o755)

    def run_transaction(self, expected, **options):
        env = {**self.environment, **{k: str(v) for k, v in options.items()}}
        command = '''export PATH="/usr/bin:/bin:$PATH"
codesign() {
  printf 'codesign\\n' >> "$COMMAND_LOG"
  for last in "$@"; do :; done
  if [[ "${FAIL_SIGNATURE:-0}" == 1 && "$last" == *.new.* ]]; then return 17; fi
  return 0
}
ditto() {
  cp -a "$1" "$2" || return
  if [[ "${FAIL_COPY:-0}" == 1 ]]; then return 19; fi
}
source "$1"
if [[ "${COLLIDE_STAGE:-0}" == 1 ]]; then mkdir -p "$3.new.$$"; printf KEEP > "$3.new.$$/marker"; fi
install_development_app "$2" "$3" "$4"
'''
        argv = [self.bash, '--noprofile', '--norc', '-c', command, 'fixture',
                bash_path(SCRIPT), bash_path(self.source), bash_path(self.target), bash_path(self.backups)]
        run = subprocess.run(argv, env=env, capture_output=True, encoding='utf-8', errors='strict', timeout=30)
        self.observations.append({'test': self.id().split('.')[-1], 'exit_code': run.returncode,
                                  'stdout': run.stdout, 'stderr': run.stderr,
                                  'native_codesign_and_registration_are_doubles': True})
        self.assertEqual(run.returncode, expected, run.stdout + run.stderr)
        self.assertFalse(Path(str(self.target) + '.install-lock').exists())
        return run

    def old_app(self):
        self.app(self.target, 'old')
        return snapshot(self.target)

    def test_first_install_and_identical_repeat_do_not_reregister(self):
        self.run_transaction(0)
        self.assertEqual(snapshot(self.target), snapshot(self.source))
        self.assertEqual(self.calls.read_text(), 'register\n')
        self.assertEqual(list(self.backups.iterdir()), [])
        self.run_transaction(0)
        self.assertEqual(self.calls.read_text(), 'register\n')
        self.assertEqual(list(self.backups.iterdir()), [])

    def test_update_preserves_exact_old_bundle_once(self):
        old = self.old_app(); self.run_transaction(0)
        self.assertEqual(snapshot(self.target), snapshot(self.source))
        backups = list(self.backups.glob('app-*.app')); self.assertEqual(len(backups), 1)
        self.assertEqual(snapshot(backups[0]), old)

    def test_failed_registration_restores_old_bundle_and_preserves_failed_new(self):
        old = self.old_app(); self.run_transaction(23, REGISTER_STATUS=23)
        self.assertEqual(snapshot(self.target), old)
        failed = list(self.backups.glob('failed-*.app')); self.assertEqual(len(failed), 1)
        self.assertEqual(snapshot(failed[0]), snapshot(self.source))
        self.assertEqual(list(self.backups.glob('app-*.app')), [])

    def test_failed_first_registration_leaves_no_installed_app_and_keeps_new(self):
        self.run_transaction(23, REGISTER_STATUS=23)
        self.assertFalse(self.target.exists())
        failed = list(self.backups.glob('failed-*.app')); self.assertEqual(len(failed), 1)
        self.assertEqual(snapshot(failed[0]), snapshot(self.source))

    def test_signature_and_partial_copy_failure_preserve_existing_target(self):
        old = self.old_app()
        self.run_transaction(17, FAIL_SIGNATURE=1)
        self.assertEqual(snapshot(self.target), old); self.assertFalse(self.calls.exists())
        self.run_transaction(19, FAIL_COPY=1)
        self.assertEqual(snapshot(self.target), old); self.assertFalse(self.calls.exists())
        self.assertEqual(len(list(self.backups.glob('staged-*.app'))), 2)

    def test_later_target_edit_is_not_overwritten_by_old_backup(self):
        old = self.old_app(); self.run_transaction(23, REGISTER_STATUS=23, CHANGE_TARGET=1)
        self.assertEqual((self.target/'Contents/version.txt').read_text(), 'later user edit')
        backups = list(self.backups.glob('app-*.app')); self.assertEqual(len(backups), 1)
        self.assertEqual(snapshot(backups[0]), old)
        self.assertEqual(list(self.backups.glob('failed-*.app')), [])

    def test_stage_collision_preserves_foreign_stage_and_existing_app(self):
        old = self.old_app(); self.run_transaction(2, COLLIDE_STAGE=1)
        self.assertEqual(snapshot(self.target), old); self.assertFalse(self.calls.exists())
        stages = list(self.target.parent.glob('SquirrelEnhancedDev.app.new.*'))
        self.assertEqual(len(stages), 1); self.assertEqual((stages[0]/'marker').read_bytes(), b'KEEP')

    def test_existing_lock_is_not_stolen_and_preserves_target(self):
        old = self.old_app(); lock = Path(str(self.target) + '.install-lock'); lock.mkdir()
        marker = lock/'transaction.txt'; marker.write_bytes(b'UNKNOWN OWNER')
        command = 'export PATH="/usr/bin:/bin:$PATH"; source "$1"; install_development_app "$2" "$3" "$4"'
        run = subprocess.run([self.bash, '--noprofile', '--norc', '-c', command, 'fixture',
                              bash_path(SCRIPT), bash_path(self.source), bash_path(self.target), bash_path(self.backups)],
                             env=self.environment, capture_output=True, encoding='utf-8', timeout=30)
        self.observations.append({'test': self.id().split('.')[-1], 'exit_code': run.returncode,
                                  'stdout': run.stdout, 'stderr': run.stderr})
        self.assertEqual(run.returncode, 2); self.assertEqual(marker.read_bytes(), b'UNKNOWN OWNER')
        self.assertEqual(snapshot(self.target), old); self.assertFalse(self.calls.exists())

    def test_real_driver_dry_run_does_not_write_or_install(self):
        before = snapshot(self.base)
        for driver in [DRIVER, UNINSTALL]:
            run = subprocess.run([self.bash, '--noprofile', '--norc', bash_path(driver), bash_path(self.source)],
                                 env=self.environment, capture_output=True, encoding='utf-8', timeout=30)
            self.observations.append({'test': self.id().split('.')[-1], 'driver': driver.name, 'exit_code': run.returncode,
                                      'stdout': run.stdout, 'stderr': run.stderr, 'native_commands_called': False})
            self.assertEqual(run.returncode, 0); self.assertEqual(snapshot(self.base), before)
        self.assertFalse(self.home.exists()); self.assertFalse(self.calls.exists())


class Results(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs); self.rows = []

    def addSuccess(self, test):
        super().addSuccess(test); self.rows.append({'name': test.id().split('.')[-1], 'status': 'PASS'})

    def addFailure(self, test, error):
        super().addFailure(test, error); self.rows.append({'name': test.id().split('.')[-1], 'status': 'FAIL'})

    def addError(self, test, error):
        super().addError(test, error); self.rows.append({'name': test.id().split('.')[-1], 'status': 'ERROR'})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bash', default=shutil.which('bash') or 'C:/Program Files/Git/bin/bash.exe')
    parser.add_argument('--report', type=Path, default=ROOT/'evidence/app-install-transaction.json')
    args = parser.parse_args(); TransactionTests.bash = args.bash
    version = subprocess.run([args.bash, '--version'], capture_output=True, encoding='utf-8', check=True).stdout.splitlines()[0]
    result = unittest.TextTestRunner(verbosity=2, resultclass=Results).run(unittest.defaultTestLoader.loadTestsFromTestCase(TransactionTests))
    report = {'utc': datetime.now(timezone.utc).isoformat(), 'layer': 'real production shared Bash file transaction; codesign/ditto/TIS fixture doubles, NOT macOS installation',
              'bash_version': version, 'status': 'PASS' if result.wasSuccessful() else 'FAIL',
              'tests_run': result.testsRun, 'tests': result.rows, 'observations': TransactionTests.observations,
              'source_sha256': {str(p.relative_to(ROOT)).replace('\\', '/'): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES},
              'macOS_installed_or_tested': False, 'real_TIS_or_codesign_executed': False,
              'live_home_or_input_method_modified': False, 'network_or_microphone_used': False}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({k: report[k] for k in ['status', 'tests_run', 'macOS_installed_or_tested']}, indent=2))
    return int(not result.wasSuccessful())


if __name__ == '__main__':
    raise SystemExit(main())
