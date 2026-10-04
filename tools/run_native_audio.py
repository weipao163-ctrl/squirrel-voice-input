"""Execute production PCMBufferConverter with synthetic signals, without a mic."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, default=Path(subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip()))
    args = parser.parse_args()
    project = ROOT / 'enhanced-squirrel'
    (project/'build').mkdir(exist_ok=True)
    (ROOT/'evidence').mkdir(exist_ok=True)
    scratch = project / 'build/swift-clt'
    command = ['swift','build','--package-path',str(project/'Enhancements'),'--build-system','native',
               '--sdk',str(args.sdk),'--scratch-path',str(scratch),'-j','4','--product','SquirrelVoiceHelper']
    subprocess.run(command,check=True)
    bins = Path(subprocess.check_output(command[:-4]+['--show-bin-path'],text=True).strip())
    sources = [project/'Enhancements/Sources/VoiceHelper/PCMBufferConverter.swift', ROOT/'tools/NativeAudioProbe.swift']
    executable = project/'build/NativeAudioProbe'
    build = ['xcrun','swiftc','-swift-version','5','-sdk',str(args.sdk),'-I',str(bins/'Modules'),
             *map(str,(bins/'EnhancementCore.build').glob('*.swift.o')),*map(str,sources),'-o',str(executable)]
    subprocess.run(build,check=True)
    run = subprocess.run([str(executable)],capture_output=True,text=True,timeout=60)
    (ROOT/'evidence/macos-audio.console.txt').write_text(run.stdout+run.stderr)
    report = json.loads(run.stdout)
    report.update(utc=datetime.now(timezone.utc).isoformat(),exit_code=run.returncode,build_argv=build,
                  source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in [*sources,*sorted((project/'Enhancements/Sources/EnhancementCore').glob('*.swift'))]})
    if run.returncode: report['status']='FAIL'
    (ROOT/'evidence/macos-audio.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(report['status'],len(report['cases']),'native synthetic cases; no microphone')
    return int(report['status'] != 'PASS')

if __name__ == '__main__': raise SystemExit(main())
