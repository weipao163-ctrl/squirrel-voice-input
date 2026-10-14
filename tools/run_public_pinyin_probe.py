"""Compare public bundled pinyin in fresh Rime data; no live data or cloud access."""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests'))
from rime_api import Rime, Config

PHRASES = [
    ('shurufa', '输入法'), ('yuyinshuru', '语音输入'),
    ('rengongzhineng', '人工智能'), ('kuajingdianshang', '跨境电商'),
    ('dianzishangwu', '电子商务'), ('shouhoufuwu', '售后服务'),
    ('kefufuwu', '客服服务'), ('tuihuotuikuan', '退货退款'),
    ('wuliuxinxi', '物流信息'), ('dingdanguanli', '订单管理'),
    ('kucunguanli', '库存管理'), ('lianxifangshi', '联系方式'),
    ('shoujihao', '手机号'), ('yanzhengma', '验证码'),
    ('dianziyouxiang', '电子邮箱'), ('zhanghaomima', '账号密码'),
    ('yonghuming', '用户名'), ('jisuanzhengchang', '计算正常'),
    ('hulianwang', '互联网'), ('shujuku', '数据库'),
    ('liulanqi', '浏览器'), ('yunfuwu', '云服务'),
    ('caigoudingdan', '采购订单'), ('zizhukaimu', '自主开模'),
    ('gaoqingshipin', '高清视频'), ('zaixiankefu', '在线客服'),
    ('bangongruanjian', '办公软件'), ('gengxinbanben', '更新版本'),
    ('zhongguo', '中国'), ('ceshi', '测试'),
    ('tishici', '提示词'), ('zhinengti', '智能体'), ('gongzuoliu', '工作流'),
    ('shurufapeizhi', '输入法配置'), ('kuaididanhao', '快递单号'),
    ('shuxuguan', '鼠须管'), ('anzhuangbao', '安装包'),
    ('pingmugongxiang', '屏幕共享'), ('ruanjiangengxin', '软件更新'),
    ('xuexijilu', '学习记录'),
]


def worker(args):
    os.chdir(args.shared)
    library = args.library
    plugin = library.parent / 'rime-plugins/librime-lua.dylib'
    r = Rime(library, args.shared, args.user, [plugin])
    started = time.perf_counter()
    assert r.start_maintenance(True)
    r.join_maintenance_thread()
    deployment = time.perf_counter() - started
    sid = r.create_session()
    assert sid and r.select_schema(sid, b'luna_pinyin')
    r.set_option(sid, b'ascii_mode', False)
    r.set_option(sid, b'zh_hans', True)
    r.set_option(sid, b'zh_hant', False)
    rows = []
    for code, expected in PHRASES:
        r.clear_composition(sid)
        for ch in code:
            assert r.process_key(sid, ord(ch), 0)
        candidates = r.state(sid)['candidates']
        rows.append({'code': code, 'expected_public_phrase': expected,
                     'rank_in_first_page': candidates.index(expected) + 1 if expected in candidates else None,
                     'candidates': candidates})
    checks = []
    def check(name, ok):
        checks.append({'name': name, 'status': 'PASS' if ok else 'FAIL'})
    if args.enhanced:
        config = Config()
        assert r.schema_open(b'luna_pinyin', ctypes.byref(config))
        try:
            check('bundled_dictionary_is_active', r.config_get_cstring(ctypes.byref(config), b'translator/dictionary') == b'squirrel_public_pinyin')
            check('learning_identity_preserved', r.config_get_cstring(ctypes.byref(config), b'translator/user_dict') == b'luna_pinyin')
        finally:
            r.config_close(ctypes.byref(config))
        for traditional, expected in [(False, '输入法'), (True, '輸入法')]:
            r.clear_composition(sid)
            r.set_option(sid, b'zh_hans', not traditional)
            r.set_option(sid, b'zh_hant', traditional)
            for ch in 'shurufa': assert r.process_key(sid, ord(ch), 0)
            check('traditional_conversion' if traditional else 'simplified_conversion', expected in r.state(sid)['candidates'])
        r.set_option(sid, b'zh_hans', True); r.set_option(sid, b'zh_hant', False)
        # Run the same production Lua processor against the real large dictionary.
        r.destroy_session(sid)
        shutil.copyfile(ROOT / 'lua/letter_selection.lua', args.user / 'lua/letter_selection.lua')
        (args.user / 'luna_pinyin.custom.yaml').write_text('''patch:
  engine/processors/@before 0: lua_processor@*letter_selection
  menu/page_size: 9
  letter_selection/keys: asdfghjkl
  letter_selection/hide_candidates: true
''')
        assert r.deploy_schema(str(args.shared / 'luna_pinyin.schema.yaml').encode())
        sid = r.create_session(); assert r.select_schema(sid, b'luna_pinyin')
        r.set_option(sid, b'ascii_mode', False); r.set_option(sid, b'zh_hans', True)
        r.set_option(sid, b'zh_hant', False)
        for ch in 'nihao': assert r.process_key(sid, ord(ch), 0)
        state = r.state(sid)
        check('pinyin_hidden_until_space', state['phase'] == 'editing' and not state['candidates'] and not state['commit'])
        assert r.process_key(sid, 32, 0)
        state = r.state(sid)
        check('space_opens_letter_candidates', state['phase'] == 'selecting' and bool(state['candidates']))
        first = state['candidates'][0]
        assert r.process_key(sid, ord('a'), 0)
        check('letter_selects_actual_large_dictionary_candidate', r.state(sid)['commit'] == first)
        for digit in '0123456789':
            for showing in [False, True]:
                r.clear_composition(sid)
                for ch in 'nihao': assert r.process_key(sid, ord(ch), 0)
                if showing: assert r.process_key(sid, 32, 0)
                assert r.process_key(sid, ord(digit), 0)
                state = r.state(sid)
                check('digit_' + digit + ('_selecting' if showing else '_editing'),
                      state['input'] == 'nihao' + digit and not state['commit'] and state['phase'] != 'selecting')
        for text in ['lovewin2k', 'abc123def456', 'win0x64', 'nihao2k']:
            r.clear_composition(sid)
            for ch in text: assert r.process_key(sid, ord(ch), 0)
            assert r.process_key(sid, 0xff0d, 0)
            check('literal_' + text, r.state(sid)['commit'] == text)
    r.destroy_session(sid); r.finalize()
    print(json.dumps({'status': 'FAIL' if any(x['status'] != 'PASS' for x in checks) else 'PASS',
                      'quality_sample': rows, 'exact_phrase_first_page': sum(x['rank_in_first_page'] is not None for x in rows),
                      'sample_size': len(rows), 'fresh_deployment_seconds': round(deployment, 3), 'checks': checks}, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shared', type=Path, required=True)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--worker', action='store_true')
    parser.add_argument('--user', type=Path)
    parser.add_argument('--enhanced', action='store_true')
    args = parser.parse_args()
    if args.worker: return worker(args)
    (ROOT / 'test-work').mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='public-pinyin-', dir=ROOT / 'test-work'))
    results = {}
    for name, shared in [('baseline', args.baseline), ('enhanced', args.shared)]:
        if shared is None: continue
        user = work / name; (user / 'lua').mkdir(parents=True)
        argv = [sys.executable, str(Path(__file__).resolve()), '--worker', '--shared', str(shared.resolve()),
                '--library', str(args.library.resolve()), '--user', str(user)]
        if name == 'enhanced': argv.append('--enhanced')
        value = subprocess.run(argv, capture_output=True, text=True, timeout=180)
        (work / (name + '.stderr.txt')).write_text(value.stderr)
        if value.returncode: raise RuntimeError(name + ' failed; inspect ' + str(work / (name + '.stderr.txt')))
        results[name] = json.loads(value.stdout)
    manifest = ROOT / 'enhanced-squirrel/resources/PublicPinyin/UPSTREAM.json'
    report = {'status': 'PASS' if all(x['status'] == 'PASS' for x in results.values()) else 'FAIL',
              'layer': 'real librime; new isolated data directories and public query sample',
              'personal_data_read': False, 'microphone_used': False, 'cloud_calls': 0,
              'provenance_sha256': hashlib.sha256(manifest.read_bytes()).hexdigest(), 'results': results}
    (ROOT / 'evidence/public-pinyin-probe.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    for name, result in results.items():
        print(name, result['status'], 'first-page exact public phrases', result['exact_phrase_first_page'], '/', result['sample_size'],
              'checks', len(result['checks']), 'deployment seconds', result['fresh_deployment_seconds'])
    return int(report['status'] != 'PASS')


if __name__ == '__main__': sys.exit(main())
