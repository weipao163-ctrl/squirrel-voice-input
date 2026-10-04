"""Production native target snapshot compatibility, offline controlled clients."""
from datetime import datetime,timezone
import hashlib,json,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def main():
    project=ROOT/'enhanced-squirrel'
    (project/'build').mkdir(exist_ok=True)
    (ROOT/'evidence').mkdir(exist_ok=True)
    work=Path(tempfile.mkdtemp(prefix='voice-target-',dir=project/'build'))
    sources=[project/'Sources/NativeVoiceTargetSnapshot.swift',ROOT/'tools/NativeVoiceTargetProbe.swift']
    output=work/'NativeVoiceTargetProbe'
    sdk=subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()
    compile=subprocess.run(['xcrun','swiftc','-swift-version','5','-sdk',sdk,*map(str,sources),'-o',str(output)],capture_output=True,text=True,timeout=60)
    (ROOT/'evidence/macos-native-voice-target.compile.txt').write_text(compile.stdout+compile.stderr)
    if compile.returncode:
        print(compile.stderr[-6000:]);return compile.returncode
    run=subprocess.run([str(output)],capture_output=True,text=True,timeout=30)
    (ROOT/'evidence/macos-native-voice-target.console.txt').write_text(run.stdout+run.stderr)
    if not run.stdout:
        print(run.stderr[-3000:]);return run.returncode or 1
    report=json.loads(run.stdout)
    integration=[project/'Sources/EnhancementTarget.swift',project/'Sources/SquirrelInputController.swift']
    report.update(utc=datetime.now(timezone.utc).isoformat(),exit_code=run.returncode,
      source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [*sources,*integration,Path(__file__)]})
    (ROOT/'evidence/macos-native-voice-target.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(report['status'],len(report['checks']),'native target checks; no microphone or cloud')
    return int(report['status']!='PASS' or run.returncode!=0)
if __name__=='__main__':raise SystemExit(main())
