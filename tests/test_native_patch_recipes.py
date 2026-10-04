"""Run shared native-planner GOLDEN YAML recipes on real librime.

This does NOT execute the Swift text planner, GUI, FilePairTransaction, or IMK.
Core XCTest consumes these same recipes, but requires a real Swift toolchain.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import traceback

ROOT = Path(__file__).resolve().parents[1]
from rime_api import Rime
from run_real_rime import Harness, fixture_files

RECIPES = ROOT / 'enhanced-squirrel/Enhancements/Tests/EnhancementCoreTests/Fixtures/native-patch-recipes.json'

def stage(library, shared, user, source, expected_processors, migrated, report, plugins=()):
    target = user / 'letter_fixture.custom.yaml'
    previous = target.stat().st_mtime if target.exists() else None
    target.write_text(source,encoding='utf-8',newline='')
    modified = target.stat().st_mtime
    adjusted = previous is not None and int(previous)==int(modified)
    if adjusted: os.utime(target,(modified,int(modified)-1))
    r = Rime(library,shared,user,plugins)
    h = None
    try:
        assert r.deploy_config_file(b'default.yaml',b'config_version')
        assert r.deploy_schema(str(user/'letter_fixture.schema.yaml').encode())
        actual = r.processors('letter_fixture')
        assert actual == expected_processors, {'actual':actual,'expected':expected_processors}
        h = Harness(r); h.start(); state = h.type('ni')
        legacy = r.property(h.sid,'_recipe_legacy_seen')
        if migrated:
            assert state['phase'] == 'editing' and not state['commit'] and not state['candidates'],state
            assert not legacy, 'removed fixture gate still executed'
            _, opened = h.key('space')
            assert opened['input']=='ni' and not opened['commit'] and opened['phase']=='selecting',opened
            assert opened['original_keys']=='abcdefghi' and opened['size']==9,opened
            _, second = h.key('Page_Down'); assert second['page']==1,second
            chosen = second['candidates'][1]
            _, selected = h.key('b'); assert selected['commit']==chosen and not selected['input'],selected
        else:
            assert state['phase'] != 'selecting',state
            _, selected = h.key('space')
            assert selected['commit'] and not selected['input'],selected
            if any('space_select_gate' in p for p in expected_processors): assert legacy, 'fixture legacy processor did not execute'
        report.append({'source_sha256':hashlib.sha256(source.encode()).hexdigest(),
                       'same_second_source_timestamp_adjusted':adjusted,
                       'source_mtime':target.stat().st_mtime,
                       'processors':r.processors('letter_fixture'),'phase_kind':'migrated golden recipe' if migrated else 'original recipe',
                       'legacy_fixture_seen':legacy,'steps':h.steps})
    finally:
        if h and h.sid: r.destroy_session(h.sid)
        r.finalize()

def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--library',required=True,type=Path)
    ap.add_argument('--plugin',type=Path,action='append',default=[])
    ap.add_argument('--report',type=Path,default=ROOT/'evidence/native-patch-recipes.json')
    args=ap.parse_args()
    work=Path(tempfile.mkdtemp(prefix='rime-native-patch-recipes-'))
    shared=work/'shared'; fixture_files(shared)
    recipes=json.loads(RECIPES.read_text(encoding='utf-8'))
    report={'utc':datetime.now(timezone.utc).isoformat(),'work':str(work),
            'kind':'real librime deployment of shared GOLDEN recipes, NOT Swift planner or macOS GUI',
            'Swift_planner_executed':False,'macOS_UI_tested':False,'tests':[],
            'fixture_sha256':hashlib.sha256(RECIPES.read_bytes()).hexdigest(),
            'legacy_gate_kind':'passthrough fixture with seen-property; NOT user legacy implementation'}
    for recipe in recipes:
        result={'name':recipe['name'],'stages':[]}
        try:
            user=work/recipe['name']; user.mkdir()
            shutil.copy2(shared/'letter_fixture.schema.yaml',user/'letter_fixture.schema.yaml')
            (user/'lua').mkdir()
            shutil.copy2(ROOT/'lua/letter_selection.lua',user/'lua/letter_selection.lua')
            (user/'lua/space_select_gate.lua').write_text('return {func=function(key,env) env.engine.context:set_property("_recipe_legacy_seen","yes"); return 2 end}\n',encoding='utf-8')
            stage(args.library,shared,user,recipe['source'],recipe['processorsBefore'],False,result['stages'],args.plugin)
            stage(args.library,shared,user,recipe['expected'],recipe['processorsAfter'],True,result['stages'],args.plugin)
            # Re-deploy original shared recipe. This proves engine restoration,
            # NOT that Swift's byte-preserving restoration code has executed.
            stage(args.library,shared,user,recipe['source'],recipe['processorsBefore'],False,result['stages'],args.plugin)
            assert (user/'letter_fixture.custom.yaml').read_bytes()==recipe['source'].encode()
            result['status']='PASS'
        except Exception:
            result['status']='FAIL'; result['traceback']=traceback.format_exc()
        report['tests'].append(result); print(recipe['name'],result['status'])
    user=work/'parser';user.mkdir()
    r=None
    try:
        r=Rime(args.library,shared,user,args.plugin)
        report['version']=r.get_version().decode()
        assert r.patch_keys('patch:\n') is None
        assert r.patch_keys('patch: {}\n')==[]
        assert r.patch_keys('unrelated_root: true\n') is None
        assert r.patch_keys('patch:\n  "engine\\/processors": []\n')==['engine/processors']
        try: r.patch_keys('patch: [unclosed')
        except AssertionError: pass
        else: raise AssertionError('invalid YAML accepted')
        parser={'name':'real_YAML_null_map_escaped_keys_and_invalid_document','status':'PASS'}
    except Exception:
        parser={'name':'real_YAML_null_map_escaped_keys_and_invalid_document','status':'FAIL','traceback':traceback.format_exc()}
    finally:
        if r:r.finalize()
    report['tests'].append(parser)
    report['passed']=sum(t['status']=='PASS' for t in report['tests'])
    report['failed']=sum(t['status']=='FAIL' for t in report['tests'])
    args.report.parent.mkdir(exist_ok=True,parents=True)
    args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('Shared recipes / real parser:',report['passed'],'passed,',report['failed'],'failed; Swift/Mac NOT TESTED')
    if report['failed']:
        for t in report['tests']:
            if t['status']=='FAIL': print(t['traceback'])
    return bool(report['failed'])

if __name__=='__main__':sys.exit(main())
