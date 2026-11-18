#!/usr/bin/env python3
"""Real librime regression using synthetic data and independent processes.

Never opens an installed input method's user directory. Requires the validation
venv (ruamel.yaml) and a librime runtime with the Lua plugin.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from rime_api import Rime
from run_real_rime import Harness, fixture_files

ROOT = Path(__file__).resolve().parents[1]


def worker(args):
    work = args.work.resolve()
    assert (work / 'synthetic-learning-fixture').read_text() == 'no personal data\n'
    r = Rime(args.library, work / 'shared', work / 'user', args.plugin)
    h = Harness(r)
    if args.operation == 'seed':
        assert r.deploy_config_file(b'default.yaml', b'config_version')
        assert r.deploy_schema(str(work / 'user/letter_fixture.schema.yaml').encode())
    h.start()

    def menu():
        h.type('jingchang')
        _, state = h.key('space')
        return state['candidates']

    def select(text, mouse=False):
        candidates = menu()
        index = candidates.index(text)
        if mouse:
            assert r.select_candidate_on_current_page(h.sid, index)
            state = r.state(h.sid)
        else:
            _, state = h.key('asdfghjkl'[index])
        assert state['commit'] == text, state
        error = r.property(h.sid, '_letter_selection_learning_error')
        assert not error, error
        return index

    def usage():
        for _ in range(1500):
            h.type('nihao')
            h.key('space')
            _, state = h.key('space')
            assert state['commit'] == '你好', state

    result = {'operation': args.operation, 'version': r.get_version().decode()}
    op = args.operation
    if op == 'seed':
        r.set_option(h.sid, b'durable_learning_disabled', 1)
        for text, count in [('京畅', 33), ('经常', 25)]:
            for _ in range(count):
                select(text)
        usage()
    elif op in ('letter', 'mouse', 'crash'):
        result['selected_index'] = select('经常', op == 'mouse')
        assert result['selected_index'] > 0, result
    elif op == 'reverse':
        result['selected_index'] = select('京畅', True)
        assert result['selected_index'] > 0, result
    elif op == 'usage':
        usage()
    elif op == 'cancel':
        menu()
        assert r.highlight_candidate_on_current_page(h.sid, 1)
        r.clear_composition(h.sid)
    elif op in ('incognito_mode', 'disable_user_dict', 'durable_learning_disabled'):
        r.set_option(h.sid, op.encode(), 1)
        select('经常')
        r.set_option(h.sid, op.encode(), 0)
        usage()
    elif op != 'read':
        raise ValueError(op)
    result['candidates'] = menu()
    r.clear_composition(h.sid)
    result['learning_error'] = r.property(h.sid, '_letter_selection_learning_error')
    assert not result['learning_error'], result
    print(json.dumps(result, ensure_ascii=False), flush=True)
    if op == 'crash':
        # Do not destroy the session or finalize: test the explicit choice's
        # committed WAL, rather than relying on graceful process shutdown.
        os._exit(0)
    r.destroy_session(h.sid)
    r.finalize()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--library', required=True, type=Path)
    ap.add_argument('--plugin', type=Path, action='append', default=[])
    ap.add_argument('--report', type=Path, default=ROOT / 'evidence/learning-persistence.json')
    ap.add_argument('--work', type=Path, help=argparse.SUPPRESS)
    ap.add_argument('--operation', help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args.operation:
        worker(args)
        return
    from run_real_rime import install
    work = Path(tempfile.mkdtemp(prefix='rime-durable-learning-'))
    (work / 'synthetic-learning-fixture').write_text('no personal data\n')
    fixture_files(work / 'shared')
    dictionary = work / 'shared/letter_fixture.dict.yaml'
    with dictionary.open('a') as f:
        f.write('京畅\tjing chang\t100\n经常\tjing chang\t90\n')
    user = work / 'user'
    user.mkdir()
    shutil.copy2(work / 'shared/letter_fixture.schema.yaml', user)
    install(user, 'letter_fixture', True, keys='asdfghjkl')
    report = {'kind': 'real librime; synthetic userdb; independent processes',
              'macOS_UI_tested': False, 'work': str(work), 'tests': []}

    def run(op, first=None):
        command = [sys.executable, str(Path(__file__).resolve()), '--library', str(args.library),
                   '--work', str(work), '--operation', op]
        for plugin in args.plugin:
            command += ['--plugin', str(plugin)]
        proc = subprocess.run(command, capture_output=True, text=True, timeout=60)
        assert proc.returncode == 0, proc.stderr + proc.stdout
        value = json.loads(proc.stdout)
        if first:
            assert value['candidates'][0] == first, value
        report['tests'].append(value)
        return value

    try:
        run('seed', '京畅')
        backup = work / 'seed-user'
        shutil.copytree(user, backup)
        for method in ['letter', 'mouse', 'crash']:
            shutil.rmtree(user)
            shutil.copytree(backup, user)
            run(method, '经常')
            run('read', '经常')
            run('usage', '经常')
            run('read', '经常')
            run('reverse', '京畅')
            run('usage', '京畅')
            run('read', '京畅')
        for negative in ['cancel', 'incognito_mode', 'disable_user_dict', 'durable_learning_disabled']:
            shutil.rmtree(user)
            shutil.copytree(backup, user)
            run(negative)
            run('usage', '京畅')
            run('read', '京畅')
        report['status'] = 'PASS'
    except Exception as exc:
        report['status'] = 'FAIL'
        report['error'] = repr(exc)
        raise
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f"PASS {len(report['tests'])} independent-process learning checks")


if __name__ == '__main__':
    main()
