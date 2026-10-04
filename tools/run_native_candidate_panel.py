"""Exercise actual AppKit candidate rendering in a disposable local fixture."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--baseline', action='store_true')
    args = parser.parse_args()
    project = ROOT/'enhanced-squirrel'
    (project/'build').mkdir(exist_ok=True)
    (ROOT/'evidence').mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='candidate-panel-', dir=project/'build'))
    bins = project/'build/swift-clt/arm64-apple-macosx/debug'
    sources = [project/'Sources'/name for name in ['BridgingFunctions.swift', 'ReservedProperty.swift',
        'SquirrelConfig.swift', 'SquirrelTheme.swift', 'SquirrelView.swift', 'SquirrelPanel.swift']]
    sources.append(ROOT/'tools/NativeCandidatePanelProbe.swift')
    library = project/'build/CLT/SquirrelEnhancedDev.app/Contents/Frameworks/librime.1.dylib'
    objects = sorted((bins/'EnhancementCore.build').glob('*.swift.o'))
    assert objects
    argv = ['xcrun','swiftc','-swift-version','5','-enable-bare-slash-regex',
        '-sdk',subprocess.check_output(['xcrun','--sdk','macosx','--show-sdk-path'],text=True).strip(),
        '-I', str(bins/'Modules'), '-I', str(project/'librime/src'), '-I', str(project/'librime/include'),
        '-import-objc-header',str(project/'Sources/Squirrel-Bridging-Header.h'),
        *map(str,sources),*map(str,objects),str(library),'-Xlinker','-rpath','-Xlinker',str(library.parent),
        '-o',str(work/'NativeCandidatePanelProbe')]
    compilation = subprocess.run(argv,capture_output=True,text=True,timeout=90)
    name = 'macos-candidate-panel-baseline' if args.baseline else 'macos-candidate-panel'
    (ROOT/f'evidence/{name}.compile.txt').write_text(compilation.stdout+compilation.stderr)
    if compilation.returncode:
        print(compilation.stderr[-5000:]); return compilation.returncode
    runs = []
    # Each crash/repro is isolated: an empty format trap cannot mask stale hit regions.
    for scenario in (['--empty-only','--skip-empty'] if args.baseline else ['']):
        command = [str(work/'NativeCandidatePanelProbe'),str(work/(scenario or 'fixed'))]
        if scenario: command.append(scenario)
        result = subprocess.run(command,capture_output=True,text=True,timeout=30)
        runs.append({'scenario':scenario,'exit_code':result.returncode,'stdout':result.stdout,'stderr':result.stderr})
    if args.baseline:
        second = json.loads(runs[1]['stdout']) if runs[1]['stdout'] else {}
        failures = {c['name'] for c in second.get('checks', []) if not c['passed']}
        expected = {'reopened_config_drops_previous_cache', 'disappeared_up_arrow_cannot_intercept_click',
                    'disappeared_down_arrow_cannot_intercept_click'}
        reproduced = runs[0]['exit_code'] != 0 and 'NSRangeException' in runs[0]['stderr'] and runs[1]['exit_code'] == 1 and failures == expected
        report = {'status':'REPRODUCED' if reproduced else 'FAIL', 'runs':runs, 'confirmed_failures':sorted(failures)}
    else:
        if runs[0]['exit_code'] != 0 and not runs[0]['stdout']:
            print(runs[0]['stderr'][-5000:]); return runs[0]['exit_code'] or 1
        report = json.loads(runs[0]['stdout'])
        report['exit_code'] = runs[0]['exit_code']
    report.update(utc=datetime.now(timezone.utc).isoformat(),
        source_sha256={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [*sources,Path(__file__)]},
        compile_argv=argv)
    (ROOT/f'evidence/{name}.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(report['status'],len(report.get('checks', [])), 'native candidate checks; no microphone or cloud')
    return int(report['status'] not in {'PASS','REPRODUCED'})

if __name__ == '__main__': raise SystemExit(main())
