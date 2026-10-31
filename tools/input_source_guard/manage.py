#!/usr/bin/env python3
"""Explicit opt-in management. No command changes the system without --apply."""
import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SUPPORT = Path.home() / 'Library/Application Support/SquirrelEnhancedDev/input-source-guard'
LABEL = 'org.rime.SquirrelEnhanced.InputSourceGuard'
AGENT = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
BINARY = SUPPORT / 'InputSourceGuard'
CONFIG = SUPPORT / 'guard.json'
BASE = 'org.rime.inputmethod.SquirrelEnhanced.Development'


def atomic(path, content, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as f:
        temporary = Path(f.name)
        f.write(content)
    os.chmod(temporary, mode)
    os.replace(temporary, path)


def backup(path):
    if path.exists():
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        target = SUPPORT / 'backups' / (stamp + '-' + path.name)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)


def stop():
    # Nonzero is normal when not loaded. The disabled config remains authoritative.
    target = f'gui/{os.getuid()}/{LABEL}'
    subprocess.run(['launchctl', 'bootout', target], capture_output=True)
    if subprocess.run(['launchctl', 'print', target], capture_output=True).returncode == 0:
        raise RuntimeError('LaunchAgent is still loaded; config/agent publication cancelled')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['install', 'enable', 'disable', 'status'])
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--mode', action='append', choices=['Hans', 'Hant'])
    args = parser.parse_args()
    if args.command == 'status':
        if BINARY.exists():
            return subprocess.run([str(BINARY), '--status']).returncode
        print(json.dumps({'installed': False, 'protection_enabled': False})); return 0
    if not args.apply:
        print(json.dumps({'dry_run': True, 'command': args.command, 'support': str(SUPPORT),
                          'agent': str(AGENT), 'modes': args.mode or ['Hans']}, ensure_ascii=False, indent=2))
        return 0
    if sys.platform != 'darwin':
        raise RuntimeError('Requires macOS')
    if SUPPORT.exists() and SUPPORT.resolve() != SUPPORT:
        raise RuntimeError('Refusing a symlinked support path')
    SUPPORT.mkdir(parents=True, exist_ok=True)
    os.chmod(SUPPORT, 0o700)
    if args.command == 'install':
        sdk = subprocess.check_output([sys.executable, str(ROOT / 'tools/macos_sdk.py')], text=True).strip()
        with tempfile.TemporaryDirectory(prefix='build-', dir=SUPPORT) as directory:
            output = Path(directory) / 'InputSourceGuard'
            source = Path(__file__).resolve().parent
            subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '5', '-sdk', sdk,
                            str(source / 'GuardPolicy.swift'), str(source / 'main.swift'), '-o', str(output)], check=True)
            subprocess.run(['codesign', '--force', '--sign', '-', str(output)], check=True)
            subprocess.run(['codesign', '--verify', '--strict', str(output)], check=True)
            backup(BINARY)
            atomic(BINARY, output.read_bytes(), 0o700)
        if not CONFIG.exists():
            atomic(CONFIG, json.dumps({'enabled': False, 'modes': [BASE + '.Hans']}).encode())
        print('Installed helper; protection remains at its prior setting. Use enable --apply to opt in.')
    elif args.command == 'enable':
        if not BINARY.is_file():
            raise RuntimeError('Run install --apply first')
        modes = sorted(set(args.mode or ['Hans']))
        backup(CONFIG); backup(AGENT)
        # Stop the previous registration before publishing the new configuration.
        stop()
        payload = {'Label': LABEL, 'ProgramArguments': [str(BINARY)], 'RunAtLoad': True,
                   'StartInterval': 30, 'ProcessType': 'Background', 'LimitLoadToSessionType': 'Aqua'}
        try:
            atomic(CONFIG, json.dumps({'enabled': True, 'modes': [BASE + '.' + m for m in modes]}).encode())
            atomic(AGENT, plistlib.dumps(payload))
            subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(AGENT)], check=True)
        except BaseException:
            try:
                atomic(CONFIG, json.dumps({'enabled': False, 'modes': [BASE + '.' + m for m in modes]}).encode())
            finally:
                stop()
            raise
        print('Enabled input-source protection. No input source was selected.')
    else:
        modes = [BASE + '.Hans']
        if CONFIG.exists():
            try:
                modes = json.loads(CONFIG.read_text())['modes']
            except (ValueError, KeyError):
                pass
        backup(CONFIG); backup(AGENT)
        atomic(CONFIG, json.dumps({'enabled': False, 'modes': modes}).encode())
        stop()
        if AGENT.exists():
            AGENT.unlink()  # A timestamped backup is retained above.
        print('Protection disabled and LaunchAgent removed. Input methods and user data unchanged.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
