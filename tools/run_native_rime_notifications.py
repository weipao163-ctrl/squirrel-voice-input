"""Actual librime/production label and range policy; never use personal dictionaries."""
from datetime import datetime,timezone
import hashlib,json,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def main():
    project=ROOT/'enhanced-squirrel'
    work=Path(tempfile.mkdtemp(prefix='notification-',dir=project/'build'))
    output=work/'NativeRimeNotificationProbe'
    sources=[project/'Sources/BridgingFunctions.swift',ROOT/'tools/NativeRimeNotificationProbe.swift']
    library=Path('/Library/Input Methods/Squirrel.app/Contents/Frameworks/librime.1.dylib')
    command=['xcrun','swiftc','-swift-version','5','-I',str(project/'librime/src'),'-I',str(project/'librime/include'),
      '-import-objc-header',str(project/'Sources/Squirrel-Bridging-Header.h'),*map(str,sources),str(library),
      '-Xlinker','-rpath','-Xlinker',str(library.parent),'-o',str(output)]
    compile=subprocess.run(command,capture_output=True,text=True,timeout=60)
    (ROOT/'evidence/macos-rime-notification.compile.txt').write_text(compile.stdout+compile.stderr)
    if compile.returncode:
        print(compile.stderr[-4000:]);return compile.returncode
    run=subprocess.run([str(output),str(work/'fixture'),str(project/'resources/LetterProbe')],capture_output=True,text=True,timeout=30)
    (ROOT/'evidence/macos-rime-notification.console.txt').write_text(run.stdout+run.stderr)
    if not run.stdout or run.returncode:
        print(run.stdout+run.stderr[-3000:]);return run.returncode or 1
    report=json.loads(run.stdout)
    report.update(utc=datetime.now(timezone.utc).isoformat(),source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [*sources,Path(__file__)]},
      library_sha256=hashlib.sha256(library.read_bytes()).hexdigest(),exit_code=run.returncode)
    (ROOT/'evidence/macos-rime-notification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(report['status'],len(report['checks']),'checks;',report['real_option_notifications'],'real option notifications')
    return int(report['status']!='PASS')
if __name__=='__main__':raise SystemExit(main())
