#!/usr/bin/env python3
"""Opt-in, temporary input-source metadata audit. Mutations require --apply."""
import argparse
import json
import math
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).resolve().parent
SUPPORT = Path.home() / 'Library/Application Support/SquirrelEnhancedDev/input-source-audit'
LABEL = 'org.rime.SquirrelEnhanced.InputSourceAudit'
AGENT = Path.home() / 'Library/LaunchAgents' / (LABEL + '.plist')
BINARY = SUPPORT / 'InputSourceAudit'
CONFIG = SUPPORT / 'audit.json'
STATUS = SUPPORT / 'status.json'


def read_json(path):
    try:
        if path.is_symlink() or path.stat().st_size > 65536:
            return {}
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def atomic(path, payload, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.parent.resolve() != path.parent or path.is_symlink():
        raise RuntimeError('Refusing symlinked audit paths')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            os.fchmod(stream.fileno(), mode)
            stream.write(payload)
        os.replace(temporary, path)
    finally:
        if temporary and temporary.exists():
            temporary.unlink()


def job():
    result = subprocess.run(['launchctl', 'print', f'gui/{os.getuid()}/{LABEL}'], capture_output=True, text=True)
    pid = re.search(r'^\s*pid = (\d+)\s*$', result.stdout, re.MULTILINE) if result.returncode == 0 else None
    return {'loaded': result.returncode == 0, 'pid': int(pid[1]) if pid else None}


def bootout():
    subprocess.run(['launchctl', 'bootout', f'gui/{os.getuid()}/{LABEL}'], capture_output=True)
    if job()['loaded']:
        raise RuntimeError('Audit job is still loaded; publication cancelled')


def disabled_config():
    value = read_json(CONFIG)
    return {'enabled': False, 'startedAt': timestamp(value.get('startedAt')) or 0,
            'expiresAt': timestamp(value.get('expiresAt')) or 0}


def timestamp(value):
    return value if type(value) in (int, float) and 0 < value < 1e12 and math.isfinite(value) else None


def runtime_metadata(value):
    clean = {}
    if value.get('phase') in ('running', 'stopped', 'expired'):
        clean['phase'] = value['phase']
    for key in ['startedAt', 'expiresAt', 'lastEventAt']:
        number = timestamp(value.get(key))
        if number is not None:
            clean[key] = number
    for key in ['pid', 'eventsWritten']:
        number = value.get(key)
        if type(number) is int and 0 <= number <= 2**31 - 1:
            clean[key] = number
    return clean


def status():
    config, runtime = read_json(CONFIG), read_json(STATUS)
    observed = job() if sys.platform == 'darwin' else {'loaded': False, 'pid': None}
    expiry = timestamp(config.get('expiresAt'))
    start = timestamp(config.get('startedAt'))
    enabled = config.get('enabled') is True
    expired = expiry is not None and time.time() >= expiry
    phase = 'expired' if expired else ('running' if enabled and observed['pid'] else ('stopped_unexpectedly' if enabled else 'stopped'))
    if enabled and (start is None or expiry is None or not 0 < expiry - start <= 48 * 3600):
        phase = 'invalid_configuration'
    elif enabled and start is not None and time.time() < start:
        phase = 'stopped_clock_changed'
    return {'installed': BINARY.is_file(), 'enabled': enabled, 'effective_status': phase,
            'expires_at': expiry, 'job': observed, 'runtime': runtime_metadata(runtime),
            'log_directory': str(SUPPORT), 'input_source_mutations': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['install', 'start', 'stop', 'status'])
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if args.command == 'status':
        print(json.dumps(status(), ensure_ascii=False, indent=2)); return 0
    if not args.apply:
        print(json.dumps({'dry_run': True, 'command': args.command, 'support': str(SUPPORT),
                          'duration_hours': 48, 'input_source_mutations': False}, ensure_ascii=False, indent=2))
        return 0
    if sys.platform != 'darwin':
        raise RuntimeError('Requires macOS')
    if SUPPORT.resolve() != SUPPORT:
        raise RuntimeError('Refusing symlinked audit directory')
    SUPPORT.mkdir(parents=True, exist_ok=True)
    os.chmod(SUPPORT, 0o700)
    if args.command == 'install':
        if job()['loaded']:
            raise RuntimeError('Stop the audit before replacing its helper')
        sdk = subprocess.check_output([sys.executable, str(ROOT / 'tools/macos_sdk.py')], text=True).strip()
        with tempfile.TemporaryDirectory(prefix='compile-', dir=SUPPORT) as directory:
            candidate = Path(directory) / 'InputSourceAudit'
            subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '5', '-sdk', sdk,
                            *(str(SOURCE / name) for name in ['AuditCore.swift', 'PrivateLog.swift', 'main.swift']),
                            '-o', str(candidate)], check=True)
            subprocess.run(['codesign', '--force', '--sign', '-', str(candidate)], check=True)
            subprocess.run(['codesign', '--verify', '--strict', str(candidate)], check=True)
            atomic(BINARY, candidate.read_bytes(), 0o700)
        if not CONFIG.exists():
            atomic(CONFIG, json.dumps(disabled_config()).encode())
        print('Audit helper installed; it has not been started.')
    elif args.command == 'start':
        if not BINARY.is_file() or BINARY.is_symlink():
            raise RuntimeError('Run install --apply first')
        bootout()
        now = time.time()
        config = {'enabled': True, 'startedAt': now, 'expiresAt': now + 48 * 3600}
        agent = {'Label': LABEL, 'ProgramArguments': [str(BINARY), '--run'], 'RunAtLoad': True,
                 'ProcessType': 'Background', 'LimitLoadToSessionType': 'Aqua'}
        try:
            atomic(CONFIG, json.dumps(config).encode())
            atomic(AGENT, plistlib.dumps(agent))
            subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(AGENT)], check=True)
        except BaseException:
            try:
                atomic(CONFIG, json.dumps({**config, 'enabled': False}).encode())
            finally:
                bootout()
            raise
        print('Read-only metadata audit started; expires after 48 hours. No automatic recovery is enabled.')
    else:
        atomic(CONFIG, json.dumps(disabled_config()).encode())
        bootout()
        if AGENT.is_symlink():
            raise RuntimeError('Refusing symlinked LaunchAgent')
        if AGENT.exists():
            AGENT.unlink()
        print('Audit stopped and LaunchAgent removed; existing diagnostic logs retained.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
