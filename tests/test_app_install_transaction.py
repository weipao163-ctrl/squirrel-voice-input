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
        self.environment.update(REGISTRATION_LOG=bash_path(self.calls), COMMAND_LOG=bash_path(self.commands),
                                FIXTURE_SOURCE=bash_path(self.source), FIXTURE_BACKUPS=bash_path(self.backups))

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
version="$(cat "$(dirname "$0")/../version.txt")"
printf 'register:%s:%s\\n' "$version" "$0" >> "$COMMAND_LOG"
if [[ "${CHANGE_TARGET:-0}" == 1 ]]; then
  printf 'later user edit' > "$(dirname "$0")/../version.txt"
fi
if [[ "$version" == new && -n "${REGISTER_NEW_STATUS:-}" ]]; then exit "$REGISTER_NEW_STATUS"; fi
exit "${REGISTER_STATUS:-0}"
''', encoding='utf-8')
        executable.chmod(0o755)

    def helper(self, app, marker='helper'):
        helper = app/'Contents/Resources/SquirrelVoiceHelper.app'
        helper.mkdir(parents=True)
        (helper/'marker.txt').write_text(marker)
        return helper

    def assert_copy_unregistered(self, app):
        calls = self.commands.read_text().splitlines()
        helper_call = 'unregister:' + str(app/'Contents/Resources/SquirrelVoiceHelper.app')
        app_call = 'unregister:' + str(app)
        self.assertIn(helper_call, calls)
        self.assertIn(app_call, calls)
        self.assertLess(calls.index(helper_call), calls.index(app_call))
        self.assertNotIn('unregister:' + str(self.target), calls)
        return calls.index(app_call)

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
mv() {
  if [[ "${FAIL_RECOVERY_MOVE_KIND:-}" == staged && "$2" == "$FIXTURE_BACKUPS/staged-"* ]]; then return 29; fi
  if [[ "${FAIL_RECOVERY_MOVE_KIND:-}" == failed && "$2" == "$FIXTURE_BACKUPS/failed-"* ]]; then return 29; fi
  command mv "$@"
}
source "$1"
run_input_method_registrar() {
  [[ "$1" == -u ]] || return 99
  printf 'unregister:%s\\n' "$2" >> "$COMMAND_LOG"
  local error='' status=1
  if [[ "$2" == "$FIXTURE_SOURCE" || "$2" == "$FIXTURE_SOURCE/"* ]]; then
    error="${REGISTRAR_ERROR:-}"; status="${REGISTRAR_STATUS:-1}"
  elif [[ "$2" == "$FIXTURE_BACKUPS/failed-"* || "$2" == "$FIXTURE_BACKUPS/staged-"* ]]; then
    error="${RECOVERY_REGISTRAR_ERROR:-}"; status="${RECOVERY_REGISTRAR_STATUS:-1}"
  elif [[ "$2" == "$FIXTURE_BACKUPS/app-"* ]]; then
    error="${BACKUP_REGISTRAR_ERROR:-}"; status="${BACKUP_REGISTRAR_STATUS:-1}"
  fi
  if [[ -n "$error" ]]; then
    printf 'failed to scan %s: %s\\n from spotlight\\n' "$2" "$error" >&2
    if [[ "${REGISTRAR_EXTRA_ERROR:-0}" == 1 ]]; then printf 'additional unknown failure\\n' >&2; fi
    return "$status"
  fi
  return 0
}
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

    def test_identical_reinstall_repairs_registration_without_new_backup(self):
        self.run_transaction(0)
        self.assertEqual(snapshot(self.target), snapshot(self.source))
        self.assertEqual(self.calls.read_text(), 'register\n')
        self.assertEqual(list(self.backups.iterdir()), [])
        self.run_transaction(0)
        self.assertEqual(self.calls.read_text(), 'register\nregister\n')
        self.assertEqual(list(self.backups.iterdir()), [])

    def test_update_preserves_exact_old_bundle_once(self):
        old = self.old_app(); self.run_transaction(0)
        self.assertEqual(snapshot(self.target), snapshot(self.source))
        backups = list(self.backups.glob('app-*.app-backup')); self.assertEqual(len(backups), 1)
        self.assertEqual(snapshot(backups[0]), old)
        self.assertEqual(list(self.backups.glob('*.app')), [])
        calls = self.commands.read_text()
        self.assertIn('unregister:' + str(backups[0]), calls)
        self.assertIn('unregister:' + str(self.source), calls)
        self.assertNotIn('unregister:' + str(self.target) + '\n', calls)

    def test_unregistered_source_and_helper_do_not_rollback(self):
        old = self.old_app()
        helper = self.source/'Contents/Resources/SquirrelVoiceHelper.app'
        helper.mkdir(parents=True)
        (helper/'marker.txt').write_text('helper source')
        self.run_transaction(0, REGISTRAR_ERROR=-10814)
        self.assertEqual(snapshot(self.target), snapshot(self.source))
        backups = list(self.backups.glob('app-*.app-backup'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(snapshot(backups[0]), old)
        self.assertEqual(list(self.backups.glob('failed-*.app-backup')), [])
        self.assertEqual(self.calls.read_text(), 'register\n')
        calls = self.commands.read_text()
        self.assertIn('unregister:' + str(helper), calls)
        self.assertIn('unregister:' + str(self.source) + '\n', calls)

    def test_unknown_unregistration_error_rolls_back(self):
        old = self.old_app()
        self.run_transaction(1, REGISTRAR_ERROR=-10810)
        self.assertEqual(snapshot(self.target), old)
        failed = list(self.backups.glob('failed-*.app-backup'))
        self.assertEqual(len(failed), 1)
        self.assertEqual(snapshot(failed[0]), snapshot(self.source))
        self.assertEqual(self.calls.read_text(), 'register\n')  # restored old bundle only

    def test_application_not_found_with_additional_error_is_not_ignored(self):
        old = self.old_app()
        self.run_transaction(1, REGISTRAR_ERROR=-10814, REGISTRAR_EXTRA_ERROR=1)
        self.assertEqual(snapshot(self.target), old)
        self.assertEqual(len(list(self.backups.glob('failed-*.app-backup'))), 1)
        self.assertEqual(self.calls.read_text(), 'register\n')

    def test_failed_registration_restores_old_bundle_and_preserves_failed_new(self):
        old = self.old_app(); self.helper(self.source)
        self.run_transaction(23, REGISTER_NEW_STATUS=23)
        self.assertEqual(snapshot(self.target), old)
        failed = list(self.backups.glob('failed-*.app-backup')); self.assertEqual(len(failed), 1)
        self.assertEqual(snapshot(failed[0]), snapshot(self.source))
        self.assertEqual(list(self.backups.glob('app-*.app-backup')), [])
        self.assertEqual(self.calls.read_text(), 'register\nregister\n')
        cleanup_index = self.assert_copy_unregistered(failed[0])
        calls = self.commands.read_text().splitlines()
        self.assertLess(cleanup_index, calls.index('register:old:' + str(self.target/'Contents/MacOS/SquirrelEnhancedDev')))

    def test_failed_first_registration_leaves_no_installed_app_and_keeps_new(self):
        self.helper(self.source)
        self.run_transaction(23, REGISTER_STATUS=23)
        self.assertFalse(self.target.exists())
        failed = list(self.backups.glob('failed-*.app-backup')); self.assertEqual(len(failed), 1)
        self.assertEqual(snapshot(failed[0]), snapshot(self.source))
        self.assert_copy_unregistered(failed[0])

    def test_failed_copy_cleanup_error_attempts_both_and_preserves_original_status(self):
        old = self.old_app(); self.helper(self.source)
        run = self.run_transaction(23, REGISTER_NEW_STATUS=23,
                                   RECOVERY_REGISTRAR_ERROR=-10810, RECOVERY_REGISTRAR_STATUS=31)
        self.assertEqual(snapshot(self.target), old)
        failed = next(self.backups.glob('failed-*.app-backup'))
        self.assertEqual(snapshot(failed), snapshot(self.source))
        cleanup_index = self.assert_copy_unregistered(failed)
        self.assertIn('failed to scan ' + str(failed) + ': -10810', run.stderr)
        self.assertIn('失败新包已保留，但系统注册清理失败', run.stderr)
        calls = self.commands.read_text().splitlines()
        self.assertLess(cleanup_index, calls.index('register:old:' + str(self.target/'Contents/MacOS/SquirrelEnhancedDev')))

    def test_never_registered_failed_copy_is_idempotent(self):
        old = self.old_app(); self.helper(self.source)
        run = self.run_transaction(23, REGISTER_NEW_STATUS=23, RECOVERY_REGISTRAR_ERROR=-10814)
        self.assertEqual(snapshot(self.target), old)
        self.assert_copy_unregistered(next(self.backups.glob('failed-*.app-backup')))
        self.assertNotIn('系统注册清理失败', run.stderr)

    def test_failed_new_move_does_not_unregister_or_overwrite_target(self):
        old = self.old_app(); self.helper(self.source)
        run = self.run_transaction(23, REGISTER_NEW_STATUS=23, FAIL_RECOVERY_MOVE_KIND='failed')
        self.assertEqual(snapshot(self.target), snapshot(self.source))
        self.assertEqual(snapshot(next(self.backups.glob('app-*.app-backup'))), old)
        self.assertEqual(list(self.backups.glob('failed-*.app-backup')), [])
        self.assertEqual(self.calls.read_text(), 'register\n')
        self.assertNotIn('unregister:' + str(self.target) + '\n', self.commands.read_text())
        self.assertNotIn('unregister:' + str(self.target/'Contents/Resources/SquirrelVoiceHelper.app'), self.commands.read_text())
        self.assertIn('新包保留在目标位置；移动失败', run.stderr)

    def test_signature_and_partial_copy_failure_preserve_existing_target(self):
        self.helper(self.source)
        old = self.old_app()
        self.run_transaction(17, FAIL_SIGNATURE=1)
        self.assertEqual(snapshot(self.target), old); self.assertFalse(self.calls.exists())
        self.run_transaction(19, FAIL_COPY=1)
        self.assertEqual(snapshot(self.target), old); self.assertFalse(self.calls.exists())
        staged = list(self.backups.glob('staged-*.app-backup'))
        self.assertEqual(len(staged), 2)
        for copy in staged:
            self.assertEqual(snapshot(copy), snapshot(self.source))
            self.assert_copy_unregistered(copy)

    def test_staging_cleanup_error_preserves_existing_target_and_original_status(self):
        old = self.old_app(); self.helper(self.source)
        run = self.run_transaction(17, FAIL_SIGNATURE=1,
                                   RECOVERY_REGISTRAR_ERROR=-10810, RECOVERY_REGISTRAR_STATUS=31)
        self.assertEqual(snapshot(self.target), old)
        self.assertFalse(self.calls.exists())
        staged = next(self.backups.glob('staged-*.app-backup'))
        self.assertEqual(snapshot(staged), snapshot(self.source))
        self.assert_copy_unregistered(staged)
        self.assertIn('failed to scan ' + str(staged) + ': -10810', run.stderr)
        self.assertIn('未完成 staging 已保留，但系统注册清理失败', run.stderr)

    def test_staging_cleanup_precedes_old_bundle_registration_after_backup_error(self):
        self.helper(self.source); self.old_app(); self.helper(self.target)
        old = snapshot(self.target)
        self.run_transaction(37, BACKUP_REGISTRAR_ERROR=-10810, BACKUP_REGISTRAR_STATUS=37)
        self.assertEqual(snapshot(self.target), old)
        staged = next(self.backups.glob('staged-*.app-backup'))
        cleanup_index = self.assert_copy_unregistered(staged)
        calls = self.commands.read_text().splitlines()
        self.assertLess(cleanup_index, calls.index('register:old:' + str(self.target/'Contents/MacOS/SquirrelEnhancedDev')))
        self.assertEqual(self.calls.read_text(), 'register\n')

    def test_staging_move_error_keeps_and_unregisters_owned_original_stage(self):
        old = self.old_app(); self.helper(self.source)
        run = self.run_transaction(17, FAIL_SIGNATURE=1, FAIL_RECOVERY_MOVE_KIND='staged')
        self.assertEqual(snapshot(self.target), old)
        self.assertFalse(self.calls.exists())
        stages = list(self.target.parent.glob('SquirrelEnhancedDev.app.new.*'))
        self.assertEqual(len(stages), 1)
        self.assertEqual(snapshot(stages[0]), snapshot(self.source))
        self.assert_copy_unregistered(stages[0])
        self.assertEqual(list(self.backups.glob('staged-*.app-backup')), [])
        self.assertIn('未完成 staging 保留在：' + str(stages[0]), run.stderr)

    def test_later_target_edit_is_not_overwritten_by_old_backup(self):
        old = self.old_app(); self.run_transaction(23, REGISTER_STATUS=23, CHANGE_TARGET=1)
        self.assertEqual((self.target/'Contents/version.txt').read_text(), 'later user edit')
        backups = list(self.backups.glob('app-*.app-backup')); self.assertEqual(len(backups), 1)
        self.assertEqual(snapshot(backups[0]), old)
        self.assertEqual(list(self.backups.glob('failed-*.app-backup')), [])
        self.assertNotIn('unregister:' + str(self.target) + '\n', self.commands.read_text())

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
