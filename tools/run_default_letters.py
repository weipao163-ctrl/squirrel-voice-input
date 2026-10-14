"""Verify fresh bundled letters and user overrides in isolated real Rime workers."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
from rime_api import Rime, Config


def worker(args):
    user = args.user
    user.mkdir()
    custom = user / 'luna_pinyin.custom.yaml'
    original = b'patch:\n  menu/page_size: 5\n  translator/user_dict: custom_fixture\n'
    if args.case == 'user-custom':
        custom.write_bytes(original)
    os.chdir(args.app / 'Contents/SharedSupport')
    library = args.app / 'Contents/Frameworks/librime.1.dylib'
    r = Rime(library, args.app / 'Contents/SharedSupport', user,
             [library.parent / 'rime-plugins/librime-lua.dylib'])
    assert r.start_maintenance(True)
    r.join_maintenance_thread()
    sid = r.create_session()
    assert sid and r.select_schema(sid, b'luna_pinyin')
    r.set_option(sid, b'ascii_mode', False)
    checks = []
    def check(name, value):
        checks.append({'name': name, 'passed': bool(value)})
    def type_pinyin():
        for ch in 'nihao':
            assert r.process_key(sid, ord(ch), 0)
    if args.case == 'fresh':
        check('default_processor_loaded_without_user_patch', r.processors('luna_pinyin')[0] == 'lua_processor@*letter_selection')
        type_pinyin()
        state = r.state(sid)
        check('first_composition_is_hidden_and_uncommitted', state['phase'] == 'editing' and not state['candidates'] and not state['commit'])
        assert r.process_key(sid, 32, 0)
        state = r.state(sid)
        check('first_space_shows_letters_without_committing', state['phase'] == 'selecting' and len(state['candidates']) > 0 and not state['commit'])
        check('default_keys_and_page_size', state['keys'] == 'asdfghjkl' and state['size'] == 9)
        first = state['candidates'][0]
        assert r.process_key(sid, ord('a'), 0)
        check('letter_selects_real_first_candidate', r.state(sid)['commit'] == first)
        r.set_option(sid, b'letter_selection_disabled', True)
        type_pinyin()
        assert r.process_key(sid, 32, 0)
        check('explicit_runtime_opt_out_restores_space_commit', bool(r.state(sid)['commit']))
        check('no_user_patch_or_user_lua_generated', not custom.exists() and not (user / 'lua/letter_selection.lua').exists())
    else:
        check('user_custom_takes_precedence_over_bundled_default', 'lua_processor@*letter_selection' not in r.processors('luna_pinyin'))
        config = Config()
        assert r.schema_open(b'luna_pinyin', ctypes.byref(config))
        check('user_page_size_preserved', r.config_get_cstring(ctypes.byref(config), b'menu/page_size') == b'5')
        check('user_learning_dictionary_preserved', r.config_get_cstring(ctypes.byref(config), b'translator/user_dict') == b'custom_fixture')
        r.config_close(ctypes.byref(config))
        type_pinyin()
        assert r.process_key(sid, 32, 0)
        check('unmodified_user_schema_keeps_normal_space', bool(r.state(sid)['commit']))
        check('user_source_bytes_unchanged', custom.read_bytes() == original)
    r.destroy_session(sid)
    r.finalize()
    print(json.dumps({'case': args.case, 'checks': checks,
                      'status': 'PASS' if all(c['passed'] for c in checks) else 'FAIL'}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--case', choices=['fresh', 'user-custom'])
    parser.add_argument('--user', type=Path)
    args = parser.parse_args()
    args.app = args.app.resolve(strict=True)
    if args.worker:
        return worker(args)
    (ROOT / 'test-work').mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='default-letters-', dir=ROOT / 'test-work'))
    results = []
    for case in ['fresh', 'user-custom']:
        run = subprocess.run([sys.executable, str(Path(__file__).resolve()), '--worker',
            '--app', str(args.app), '--case', case, '--user', str(work / case)],
            capture_output=True, text=True, timeout=180)
        (work / (case + '.stderr.txt')).write_text(run.stderr)
        assert run.returncode == 0, 'Real Rime worker failed; inspect isolated evidence'
        results.append(json.loads(run.stdout))
    report = {'status': 'PASS' if all(r['status'] == 'PASS' for r in results) else 'FAIL',
              'checks': sum(len(r['checks']) for r in results), 'results': results,
              'layer': 'real bundled Rime in new data directories; no GUI deployment button',
              'personal_data_read': False, 'microphone_used': False, 'cloud_calls': 0,
              'source_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    (ROOT / 'evidence/default-letters.json').write_text(json.dumps(report, indent=2) + '\n')
    print(report['status'], report['checks'], 'real fresh/default and user-override checks')
    return int(report['status'] != 'PASS')


if __name__ == '__main__':
    sys.exit(main())
