"""Bind a completed CLT build to its inputs and binaries; reject stale artifacts."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'enhanced-squirrel'
STATE = PROJECT / 'build/evidence'

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def input_hashes():
    sources = [*sorted((PROJECT/'sources').glob('*.swift')),
               *sorted((PROJECT/'Enhancements/Sources').rglob('*.swift')),
               PROJECT/'Enhancements/Package.swift', PROJECT/'Enhancements/Native/LetterProbe.cpp',
               *[PROJECT/'scripts'/n for n in ['build-clt.sh','local-signing.sh','build-enhanced.sh','helper.entitlements','letter-probe.entitlements']],
               *[PROJECT/'resources'/n for n in ['Localizable.xcstrings','InfoPlist.xcstrings','Squirrel.entitlements','Info.plist','letter_selection.lua','EnhancedDefaultSquirrel.yaml']],
               *sorted(p for p in (PROJECT/'resources/Quick5').glob('*') if p.is_file()),
               Path(__file__).resolve(), ROOT/'tools/record_macos_build.py']
    return {str(p.relative_to(ROOT)):digest(p) for p in sources}

def binary_hashes(app):
    names = ['Contents/MacOS/SquirrelEnhancedDev', 'Contents/MacOS/SquirrelLetterProbe',
             'Contents/Resources/SquirrelVoiceHelper.app/Contents/MacOS/SquirrelVoiceHelper',
             'Contents/Frameworks/librime.1.dylib']
    return {name:digest(app/name) for name in names}

def validate(app):
    start = json.loads((STATE/'clt-build-start.json').read_text())
    completed = json.loads((STATE/'clt-build-complete.json').read_text())
    assert completed['status']=='PASS' and start['attempt_id']==completed['attempt_id'], 'Latest build did not complete'
    assert completed['source_sha256']==start['source_sha256']==input_hashes(), 'Build inputs changed or provenance is stale'
    assert completed['binary_sha256']==binary_hashes(app), 'Built binaries changed'
    for name,expected in completed['plist_sha256'].items():
        assert digest(app/name)==expected, 'Built metadata changed'
    return completed

def main():
    STATE.mkdir(parents=True,exist_ok=True)
    if sys.argv[1]=='start':
        value={'attempt_id':str(uuid.uuid4()), 'utc':datetime.now(timezone.utc).isoformat(),
               'sdk':sys.argv[2], 'source_sha256':input_hashes()}
        (STATE/'clt-build-start.json').write_text(json.dumps(value,indent=2)+'\n')
    elif sys.argv[1]=='complete':
        app=Path(sys.argv[2])
        value=json.loads((STATE/'clt-build-start.json').read_text())
        assert value['source_sha256']==input_hashes(), 'Source changed during compilation'
        value.update(status='PASS',utc_completed=datetime.now(timezone.utc).isoformat(),
                     binary_sha256=binary_hashes(app),
                     plist_sha256={n:digest(app/n) for n in ['Contents/Info.plist','Contents/Resources/SquirrelVoiceHelper.app/Contents/Info.plist']})
        (STATE/'clt-build-complete.json').write_text(json.dumps(value,indent=2)+'\n')
    else:
        raise ValueError('Expected start or complete')

if __name__=='__main__':main()
