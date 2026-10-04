"""Refuse to package stale macOS evidence after changing executed source."""
import hashlib
import json
from pathlib import Path
import re
from app_install_evidence import current_app_install_evidence

ROOT=Path(__file__).resolve().parents[1]

def matched(report,field):
    values=report[field]
    assert values, 'Missing source hashes'
    for name,digest in values.items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest()==digest,'Stale evidence: '+name

def current_macos_evidence():
    reports={name:json.loads((ROOT/'evidence'/name).read_text()) for name in
             ['macos-core.json','macos-audio.json','macos-native-letter-probe.json','macos-build.json','macos-voice-editor.json','macos-ipc-trust.json','macos-installer.json','checks.json']}
    core=reports['macos-core.json']
    names=set(re.findall(r'  func (test\w+)\(', (ROOT/'enhanced-squirrel/Enhancements/Tests/EnhancementCoreTests/CoreTests.swift').read_text()))
    assert core['status']=='PASS' and set(core['passed_tests'])==names and core['written_tests']==len(names)
    assert core['all_test_bodies_preserved']
    matched(core,'production_source_sha256')
    for name in ['macos-audio.json','macos-native-letter-probe.json','macos-build.json','macos-voice-editor.json']:
        assert reports[name]['status']=='PASS',name
        matched(reports[name],'source_sha256')
    assert len(reports['macos-voice-editor.json']['checks'])==105 and all(c['passed'] for c in reports['macos-voice-editor.json']['checks'])
    candidates=json.loads((ROOT/'evidence/macos-candidate-panel.json').read_text())
    assert candidates['status']=='PASS' and len(candidates['checks'])==7 and all(c['passed'] for c in candidates['checks'])
    matched(candidates,'source_sha256')
    targets=json.loads((ROOT/'evidence/macos-native-voice-target.json').read_text())
    assert targets['status']=='PASS' and len(targets['checks'])==45 and all(c['passed'] for c in targets['checks'])
    matched(targets,'source_sha256')
    notifications=json.loads((ROOT/'evidence/macos-rime-notification.json').read_text())
    assert notifications['status']=='PASS' and len(notifications['checks'])==19 and all(c['passed'] for c in notifications['checks'])
    matched(notifications,'source_sha256')
    assert len(reports['macos-audio.json']['cases'])==24
    probe=reports['macos-native-letter-probe.json']
    assert len(probe['cases'])==6 and probe['passed']==83
    assert all(c['status']=='PASS' for c in probe['negative_controls'])
    checks=reports['checks.json']
    assert all(c['exit_code']==0 for c in checks['commands'])
    matched(checks,'implementation_sha256')
    current_app_install_evidence()
    binary=json.loads((ROOT/'evidence/macos-binary-smoke.json').read_text())
    assert binary['status']=='PASS' and binary['probe']['passed']==14
    assert binary['binary_sha256']==reports['macos-build.json']['binary_sha256']
    ipc=reports['macos-ipc-trust.json']
    assert ipc['status']=='PASS' and len(ipc['cases'])==12 and all(c['passed'] for c in ipc['cases'])
    assert ipc['configuration_checks']==11 and ipc['bootstrap_checks']==11
    matched(ipc,'source_sha256')
    installer=reports['macos-installer.json']
    assert installer['status']=='PASS' and installer['probe']['passed']==14 and not installer['full_goal_complete']
    clean=installer['clean_default_rime_probe']
    assert clean['status']=='PASS' and clean['enabled_schemas']==6
    assert clean['all_enabled_schema_sources_and_selection_verified'] and clean['quick5_real_candidates']
    assert clean['all_enabled_schemas_have_real_candidates']
    matched(installer,'source_sha256')
    assert installer['binary_sha256']==reports['macos-build.json']['binary_sha256']
    assert hashlib.sha256(Path(installer['package']).read_bytes()).hexdigest()==installer['sha256']
    return reports
