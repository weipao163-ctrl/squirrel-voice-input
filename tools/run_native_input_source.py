"""Test the production installer with injected APIs; optional read-only TIS snapshots."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--diagnose', action='store_true', help='Also collect independent-process read-only TIS snapshot orders')
    args = parser.parse_args()
    evidence = ROOT / 'evidence'
    evidence.mkdir(exist_ok=True)
    work_root = ROOT / 'test-work'
    work_root.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='input-source-', dir=work_root))
    production = ROOT / 'enhanced-squirrel/sources/InputSource.swift'
    probe = ROOT / 'tools/NativeInputSourceProbe.swift'
    binary = work / 'InputSourceProbe'
    command = ['xcrun', 'swiftc', '-swift-version', '5', str(production), str(probe),
               '-framework', 'InputMethodKit', '-framework', 'Carbon', '-o', str(binary)]
    build = subprocess.run(command, capture_output=True, text=True, timeout=120)
    (evidence / 'input-source-probe.compile.txt').write_text(build.stdout + build.stderr)
    if build.returncode:
        print(build.stderr); return build.returncode
    run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
    (evidence / 'input-source-probe.console.txt').write_text(run.stdout + run.stderr)
    marker = 'INPUT_SOURCE_PROBE_REPORT='
    if marker not in run.stdout:
        print(run.stdout + run.stderr); return run.returncode or 1
    report = json.loads(run.stdout.split(marker)[-1])
    report.update(utc=datetime.now(timezone.utc).isoformat(), exit_code=run.returncode,
                  production_source=str(production), binary=str(binary),
                  source_sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in [production, probe, Path(__file__)]},
                  real_registration_attempted=False, real_enable_attempted=False)
    if args.diagnose:
        report['read_only_diagnostics'] = {}
        for label, arguments in [('enabled-first', ['--snapshot-order', 'enabled-first']),
                                 ('installed-first', ['--snapshot-order', 'installed-first']),
                                 ('status', ['--status'])]:
            result = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=30)
            if result.returncode:
                raise RuntimeError(result.stderr)
            report['read_only_diagnostics'][label] = json.loads(result.stdout)
        report['snapshot_limit'] = 'Independent processes; concurrent changes elsewhere can affect comparisons.'
    (evidence / 'input-source-probe.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return run.returncode or int(report['status'] != 'PASS')


if __name__ == '__main__':
    raise SystemExit(main())
