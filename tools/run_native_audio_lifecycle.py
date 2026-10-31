"""Production audio lifecycle with blocked synthetic drivers; no microphone/network."""
from datetime import datetime, timezone
import hashlib,json,subprocess
from pathlib import Path
from macos_sdk import select_sdk
ROOT=Path(__file__).resolve().parents[1]

def main():
    project=ROOT/'enhanced-squirrel'; build=project/'build'
    bins=build/'swift-clt/arm64-apple-macosx/debug'
    names=['VoiceSession.swift','AudioOperationDeadline.swift','AudioCapture.swift','PCMBufferConverter.swift','StreamingSession.swift']
    sources=[project/'Enhancements/Sources/VoiceHelper'/name for name in names]+[ROOT/'tools/NativeAudioLifecycleProbe.swift']
    objects=[p for module in ['EnhancementCore','EnhancementIPC'] for p in sorted((bins/(module+'.build')).glob('*.swift.o'))]
    binary=build/'NativeAudioLifecycleProbe'
    command=['xcrun','swiftc','-O','-swift-version','5','-sdk',select_sdk(),'-I',str(bins/'Modules'),*map(str,sources),*map(str,objects),'-o',str(binary)]
    subprocess.run(command,check=True)
    run=subprocess.run([str(binary)],capture_output=True,text=True,timeout=15)
    report=json.loads(run.stdout)
    for flag in ['--fatal-start','--fatal-stop']:
        fatal=subprocess.run([str(binary),flag],capture_output=True,text=True,timeout=5)
        report['checks'].append({'name':'real_helper_exit_'+flag[2:],'passed':fatal.returncode==74,'exit_code':fatal.returncode})
    report.update(utc=datetime.now(timezone.utc).isoformat(),compile_argv=command,exit_code=run.returncode,
        source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[project/'Enhancements/Sources/EnhancementCore/VoiceOwnerDeadline.swift',Path(__file__)]})
    report['status']='PASS' if run.returncode==0 and all(c['passed'] for c in report['checks']) else 'FAIL'
    (ROOT/'evidence/macos-audio-lifecycle.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'status':report['status'],'checks':len(report['checks']),'failures':[c for c in report['checks'] if not c['passed']]},ensure_ascii=False))
    return int(report['status']!='PASS')

if __name__=='__main__':raise SystemExit(main())
