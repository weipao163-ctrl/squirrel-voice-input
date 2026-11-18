"""Build a reversible Chrome focus-regression compatibility launcher, no execution."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FEATURE = 'RWHVMacHasFocusReturnsFalseForNonKeyWindow'


def main():
    work = ROOT / 'enhanced-squirrel/build/chrome-ime-compatibility'
    app = work / 'Chrome 输入法兼容启动.app'
    macos = app / 'Contents/MacOS'
    resources = app / 'Contents/Resources'
    macos.mkdir(parents=True, exist_ok=True)
    resources.mkdir(exist_ok=True)
    sdk = subprocess.check_output(['python3', str(ROOT / 'tools/macos_sdk.py')], text=True).strip()
    binary = macos / 'ChromeIMECompatibility'
    subprocess.run(['xcrun', 'swiftc', '-O', '-sdk', sdk, '-target', 'arm64-apple-macos13.0',
                    str(ROOT / 'tools/ChromeIMECompatibility.swift'), '-o', str(binary)], check=True)
    info = {'CFBundleIdentifier': 'local.squirrel.ChromeIMECompatibility', 'CFBundleExecutable': binary.name,
            'CFBundleName': 'Chrome 输入法兼容启动', 'CFBundleDisplayName': 'Chrome 输入法兼容启动',
            'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1', 'LSUIElement': True,
            'LSMinimumSystemVersion': '13.0'}
    original = Path('/Applications/Google Chrome.app/Contents/Resources/app.icns')
    if original.exists():
        shutil.copy2(original, resources / 'Chrome.icns')
        info['CFBundleIconFile'] = 'Chrome.icns'
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
    # Draft only; enabling this login item is a separate maintenance action.
    agent = {'Label': 'local.squirrel.ChromeIMECompatibility',
             'ProgramArguments': ['/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
                                  '--disable-features=' + FEATURE, '--no-startup-window'],
             'RunAtLoad': True, 'ProcessType': 'Interactive', 'LimitLoadToSessionType': 'Aqua'}
    (work / 'local.squirrel.ChromeIMECompatibility.plist').write_bytes(plistlib.dumps(agent))
    print(json.dumps({'status': 'PASS', 'launcher': str(app), 'login_agent_draft': str(work / 'local.squirrel.ChromeIMECompatibility.plist'),
                      'source_sha256': hashlib.sha256((ROOT / 'tools/ChromeIMECompatibility.swift').read_bytes()).hexdigest(),
                      'chrome_restarted': False, 'login_agent_enabled': False}, ensure_ascii=False))


if __name__ == '__main__':
    main()
