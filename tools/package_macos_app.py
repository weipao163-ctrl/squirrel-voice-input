"""Package and verify a fresh extracted development app, without installing it."""
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
from macos_build_provenance import validate

ROOT=Path(__file__).resolve().parents[1]

def main():
    app=ROOT/'enhanced-squirrel/build/CLT/SquirrelEnhancedDev.app'
    provenance=validate(app)
    archive=ROOT/'dist/SquirrelEnhanced-MacDev-arm64-20261001.zip'
    archive.parent.mkdir(exist_ok=True)
    stage=Path(tempfile.mkdtemp(prefix='binary-unzip-',dir=ROOT/'enhanced-squirrel/build'))
    candidate=stage/archive.name
    subprocess.run(['/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',str(app),str(candidate)],check=True)
    subprocess.run(['/usr/bin/ditto','-x','-k',str(candidate),str(stage)],check=True)
    fresh=stage/app.name
    checks=[]
    for argv in [['codesign','--verify','--deep','--strict',str(fresh)],
      ['codesign','-d','--entitlements','-',str(fresh/'Contents/Resources/SquirrelVoiceHelper.app')],
      ['codesign','-d','--entitlements','-',str(fresh/'Contents/MacOS/SquirrelLetterProbe')],
      ['file',str(fresh/'Contents/MacOS/SquirrelEnhancedDev')]]:
        value=subprocess.run(argv,capture_output=True,text=True,timeout=60)
        checks.append({'argv':argv,'exit_code':value.returncode,'output':value.stdout+value.stderr})
    argv=[str(fresh/'Contents/MacOS/SquirrelLetterProbe'),str(fresh/'Contents/Frameworks/librime.1.dylib'),
          str(fresh/'Contents/Resources/LetterProbe'),str(stage/'probe-runtime'),'asdfghjkl','true']
    value=subprocess.run(argv,capture_output=True,text=True,timeout=60)
    probe=json.loads(value.stdout)
    info=plistlib.loads((fresh/'Contents/Info.plist').read_bytes())
    helper_info=plistlib.loads((fresh/'Contents/Resources/SquirrelVoiceHelper.app/Contents/Info.plist').read_bytes())
    forbidden=[str(p.relative_to(fresh)) for p in fresh.rglob('*') if p.is_file() and
               (p.name=='settings.json' or '.userdb' in p.name or p.suffix=='.log')]
    hashes={str(p.relative_to(fresh)):hashlib.sha256(p.read_bytes()).hexdigest() for p in
       [fresh/'Contents/MacOS/SquirrelEnhancedDev',fresh/'Contents/MacOS/SquirrelLetterProbe',
        fresh/'Contents/Resources/SquirrelVoiceHelper.app/Contents/MacOS/SquirrelVoiceHelper',fresh/'Contents/Frameworks/librime.1.dylib']}
    build=json.loads((ROOT/'evidence/macos-build.json').read_text())
    passed=all(x['exit_code']==0 for x in checks) and value.returncode==0 and probe['passed']==14 and probe['failed']==0
    passed &= 'com.apple.security.device.audio-input' in checks[1]['output'] and not forbidden
    passed &= info['SquirrelEnhancementTeamID']=='' and hashes==build['binary_sha256']
    passed &= bool(info.get('NSMicrophoneUsageDescription') and helper_info.get('NSMicrophoneUsageDescription'))
    passed &= helper_info.get('CFBundleIdentifier')=='org.rime.SquirrelEnhanced.Development.VoiceHelper'
    passed &= build['source_sha256']==provenance['source_sha256'] and hashes==provenance['binary_sha256']
    if passed:
        if archive.exists(): archive.rename(archive.with_name(archive.stem+'.previous-'+datetime.now().strftime('%H%M%S')+'.zip'))
        candidate.replace(archive)
    verified_archive=archive if passed else candidate
    report={'utc':datetime.now(timezone.utc).isoformat(),
      'layer':'fresh unzipped ad-hoc app signatures plus bundled real-Rime C API worker; NOT installed IMK/microphone/cloud',
      'archive':str(verified_archive),'archive_sha256':hashlib.sha256(verified_archive.read_bytes()).hexdigest(),
      'bytes':verified_archive.stat().st_size,'extracted':str(stage),'checks':checks,'probe_argv':argv,
      'probe_exit_code':value.returncode,'probe':probe,'probe_stderr':value.stderr,
      'binary_sha256':hashes,'microphone_usage_and_identity_valid':bool(info.get('NSMicrophoneUsageDescription') and helper_info.get('NSMicrophoneUsageDescription')),
      'forbidden_runtime_data':forbidden,'installed':False,'microphone_used':False,'cloud_calls':0,
      'status':'PASS' if passed else 'FAIL'}
    (ROOT/'evidence/macos-binary-smoke.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    if passed: archive.with_suffix('.zip.sha256').write_text(report['archive_sha256']+'  '+archive.name+'\n')
    print(report['status'],archive.name,report['bytes'],'bytes',probe['passed'],'native cases')
    return int(not passed)

if __name__=='__main__':raise SystemExit(main())
