"""Production controller + real Rime with an isolated in-memory IMK host."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import plistlib
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--label', help='Separate evidence filename for a controlled performance comparison')
    parser.add_argument('--controller-source', type=Path, help='Preserved production controller for a baseline comparison')
    args = parser.parse_args()
    if args.label and (not args.label.replace('-', '').replace('_', '').isalnum()):
        parser.error('label must contain only letters, digits, hyphens or underscores')
    project = ROOT / 'enhanced-squirrel'
    build = project / 'build'
    work = Path(tempfile.mkdtemp(prefix='keyboard-input-', dir=build))
    sdk = json.loads((build / 'evidence/clt-build-complete.json').read_text())['sdk']
    bins = build / 'swift-clt/arm64-apple-macosx/debug'
    sources = sorted(p for p in (project / 'sources').glob('*.swift')
                     if p.name not in {'Main.swift', 'EnhancementBridge.swift'})
    if args.controller_source:
        controller = args.controller_source.resolve(strict=True)
        if controller.name != 'SquirrelInputController.swift':
            parser.error('controller-source must be a preserved SquirrelInputController.swift')
        sources = [controller if p.name == controller.name else p for p in sources]
    recovery = next(p for p in sources if p.name == 'SquirrelInputController.swift')
    recovery_defines = ['-D', 'CANDIDATE_RECOVERY_PROBE'] if 'var candidatePositionRecovery =' in recovery.read_text() else []
    sources.append(ROOT / 'tools/NativeKeyboardInputProbe.swift')
    objects = sorted(p for module in ['EnhancementCore', 'EnhancementIPC', 'EnhancementUI']
                     for p in (bins / (module + '.build')).glob('*.swift.o'))
    assert objects
    runtime = build / 'CLT/SquirrelEnhancedDev.app/Contents/Frameworks'
    app = work / 'KeyboardInputProbe.app'
    binary = app / 'Contents/MacOS/NativeKeyboardInputProbe'
    binary.parent.mkdir(parents=True)
    info = plistlib.loads((project / 'resources/Info.plist').read_bytes())
    info.update(CFBundleExecutable=binary.name, CFBundleIdentifier='org.rime.KeyboardInputProbe',
                CFBundleName='KeyboardInputProbe', InputMethodServerControllerClass='SquirrelInputController',
                CFBundleVersion='1', CFBundleShortVersionString='1', NSPrincipalClass='NSApplication')
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    bridge = work / 'KeyboardProbe-Bridging.h'
    bridge.write_text('#import "' + str(project / 'sources/Squirrel-Bridging-Header.h') + '"\n'
                      '#import <Foundation/Foundation.h>\n'
                      'id _Nonnull KeyboardProbeWrapClient(id _Nonnull client);\n'
                      'NSDictionary<NSString *, NSNumber *> * _Nonnull KeyboardProbeProcessMetrics(void);\n')
    proxy_object = work / 'KeyboardProbeClient.o'
    proxy_compile = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-isysroot', sdk,
                                    '-c', str(ROOT / 'tools/NativeKeyboardProbeClient.m'), '-o', str(proxy_object)],
                                   capture_output=True, text=True, timeout=30)
    if proxy_compile.returncode:
        print(proxy_compile.stderr); return proxy_compile.returncode
    command = ['xcrun', 'swiftc', '-swift-version', '5', '-enable-bare-slash-regex', *recovery_defines,
               '-sdk', sdk, '-I', str(bins / 'Modules'), '-F', str(project / 'Frameworks'),
               '-I', str(project / 'librime/src'), '-I', str(project / 'librime/include'),
               '-import-objc-header', str(bridge),
               *map(str, sources), *map(str, objects), str(proxy_object), str(runtime / 'librime.1.dylib'),
               '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', str(runtime),
               '-o', str(binary)]
    if not args.baseline:
        command.insert(2, '-O')
    name = args.label or ('macos-keyboard-input-baseline' if args.baseline else 'macos-keyboard-input')
    evidence = ROOT / 'evidence'
    evidence.mkdir(exist_ok=True)
    compile = subprocess.run(command, capture_output=True, text=True, timeout=120)
    (evidence / (name + '.compile.txt')).write_text(compile.stdout + compile.stderr)
    if compile.returncode:
        print(compile.stderr[-6000:]); return compile.returncode
    run = subprocess.run([str(binary), str(work / 'fixture'), str(project / 'resources/LetterProbe'),
                          str(ROOT / 'lua/letter_selection.lua'), str(runtime / 'rime-plugins/librime-lua.dylib')],
                         capture_output=True, text=True, timeout=60)
    (evidence / (name + '.console.txt')).write_text(run.stdout + run.stderr)
    marker = 'KEYBOARD_PROBE_REPORT='
    if marker not in run.stdout:
        print((run.stdout + run.stderr)[-5000:]); return run.returncode or 1
    report = json.loads(run.stdout.split(marker)[-1].strip())
    report.update(utc=datetime.now(timezone.utc).isoformat(), exit_code=run.returncode,
                  optimization='default' if args.baseline else '-O', compile_command=command,
                  work=str(work), source_sha256={str(p.relative_to(ROOT)) if p.is_relative_to(ROOT) else 'external-controller-baseline': hashlib.sha256(p.read_bytes()).hexdigest()
                                                for p in [*sources, ROOT / 'tools/NativeKeyboardProbeClient.m', Path(__file__)]})
    (evidence / (name + '.json')).write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({k: report[k] for k in ['status', 'checks', 'metrics']}, ensure_ascii=False, indent=2))
    return int(report['status'] != 'PASS')


if __name__ == '__main__':
    raise SystemExit(main())
