"""Compile and execute the production mouse coordinator without input/audio."""
import hashlib
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report-dir', type=Path, default=ROOT / 'evidence/mouse-voice-20261117')
    args = parser.parse_args()
    project = ROOT / 'enhanced-squirrel'
    sdk = json.loads((project / 'build/evidence/clt-build-complete.json').read_text())['sdk']
    work = Path(tempfile.mkdtemp(prefix='mouse-voice-probe-', dir=project / 'build'))
    bins = project / 'build/swift-clt/arm64-apple-macosx/debug'
    sources = [project / 'sources/MouseVoiceTrigger.swift', ROOT / 'tools/NativeMouseVoiceProbe.swift']
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-sdk', sdk, '-I', str(bins / 'Modules'),
               *map(str, sources), *map(str, sorted((bins / 'EnhancementCore.build').glob('*.swift.o'))),
               '-o', str(work / 'MouseVoiceProbe')]
    build = subprocess.run(command, capture_output=True, text=True, timeout=120)
    evidence = args.report_dir.resolve()
    evidence.mkdir(exist_ok=True, parents=True)
    (evidence / 'native.compile.txt').write_text(build.stdout + build.stderr)
    if build.returncode:
        raise RuntimeError(build.stderr)
    result = subprocess.run([str(work / 'MouseVoiceProbe')], capture_output=True, text=True, timeout=30)
    report = json.loads(result.stdout)
    report['source_sha256'] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    (evidence / 'native.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(report['status'], len(report['cases']), 'native mouse checks; no microphone or cloud calls')
    if result.returncode:
        print([row['name'] for row in report['cases'] if not row['passed']])
    return result.returncode


if __name__ == '__main__':
    raise SystemExit(main())
