"""Compile actual Helper/editor/panel sources and probe native insertion offline."""
from datetime import datetime,timezone
import argparse,hashlib,json,plistlib,subprocess,tempfile
from pathlib import Path
from macos_sdk import select_sdk
ROOT=Path(__file__).resolve().parents[1]

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--negative-background-window',action='store_true',help='Reintroduce the faulty visibility guard in an isolated copy; expect the production regression to fail')
    args=parser.parse_args()
    project=ROOT/'enhanced-squirrel'
    (project/'build').mkdir(exist_ok=True)
    (ROOT/'evidence').mkdir(exist_ok=True)
    bins=project/'build/swift-clt/arm64-apple-macosx/debug'
    sdk=select_sdk()
    work=Path(tempfile.mkdtemp(prefix='voice-editor-',dir=project/'build'))
    helper=sorted((project/'Enhancements/Sources/VoiceHelper').glob('*.swift'))
    helper=[p for p in helper if p.name!='Main.swift']
    if args.negative_background_window:
        original=project/'Enhancements/Sources/VoiceHelper/HelperService.swift'
        altered=work/'HelperService.swift'
        content=original.read_text()
        assert content.count('!self.settingsOwnFocus &&')==1
        altered.write_text(content.replace('!self.settingsOwnFocus &&','self.windowController?.window?.isVisible != true &&'))
        helper=[altered if p==original else p for p in helper]
    objects=[p for name in ['EnhancementCore','EnhancementIPC','EnhancementUI'] for p in sorted((bins/(name+'.build')).glob('*.swift.o'))]
    assert objects,'Build the Helper first with scripts/build-clt.sh'
    sources=helper+[ROOT/'tools/NativeVoiceEditorProbe.swift']
    app=work/'NativeVoiceEditorProbe.app'
    (app/'Contents/MacOS').mkdir(parents=True)
    executable=app/'Contents/MacOS/NativeVoiceEditorProbe'
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.rime.SquirrelEnhanced.EditorProbe','CFBundleName':'Native Voice Editor Probe','CFBundleExecutable':'NativeVoiceEditorProbe','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'13.0'}))
    cmd=['xcrun','swiftc','-swift-version','5','-sdk',sdk,'-I',str(bins/'Modules'),*map(str,sources),*map(str,objects),'-o',str(executable)]
    compile=subprocess.run(cmd,capture_output=True,text=True,timeout=180)
    name='macos-voice-editor-negative-background-window' if args.negative_background_window else 'macos-voice-editor'
    (ROOT/f'evidence/{name}.compile.txt').write_text(compile.stdout+compile.stderr)
    if compile.returncode:
        print(compile.stderr[-6000:]);return compile.returncode
    print('Focus this isolated probe window if macOS denies CLI activation: '+str(app),flush=True)
    run=subprocess.run([str(executable),str(work/'settings')],capture_output=True,text=True,timeout=40)
    (ROOT/f'evidence/{name}.console.txt').write_text(run.stdout+run.stderr)
    report=json.loads(run.stdout)
    report.update(utc=datetime.now(timezone.utc).isoformat(),compile_argv=cmd,compile_exit_code=compile.returncode,exit_code=run.returncode)
    source_files=[*sources,*sorted((project/'Enhancements/Sources/EnhancementCore').glob('*.swift')),
      *sorted((project/'Enhancements/Sources/EnhancementIPC').glob('*.swift')),*sorted((project/'Enhancements/Sources/EnhancementUI').glob('*.swift'))]
    report['source_sha256']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files}
    report['runner_sha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    if args.negative_background_window:
        failures=[c['name'] for c in report['checks'] if not c['passed']]
        report['original_suite_status']=report['status']
        report['mutation']='isolated reintroduction of isVisible-based production admission; production source unchanged'
        report['detected_expected_bug']='background_open_settings_allows_new_production_session' in failures and run.returncode==1
        report['status']='PASS' if report['detected_expected_bug'] else 'FAIL'
    (ROOT/f'evidence/{name}.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(report['status'],len(report['checks']),'native editor/overlay checks; no microphone or cloud')
    return int(report['status']!='PASS' or (not args.negative_background_window and run.returncode!=0))
if __name__=='__main__':raise SystemExit(main())
