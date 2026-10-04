"""Source-matched shared file transaction evidence, not macOS installation."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def current_app_install_evidence():
    report = json.loads((ROOT/'evidence/app-install-transaction.json').read_text(encoding='utf-8'))
    expected = set(re.findall(r'^    def (test_\w+)\(', (ROOT/'tests/test_app_install_transaction.py').read_text(encoding='utf-8'), re.M))
    assert report['status'] == 'PASS' and report['tests_run'] == len(expected) == 9
    assert {t['name'] for t in report['tests']} == expected and all(t['status'] == 'PASS' for t in report['tests'])
    assert report['macOS_installed_or_tested'] is False and report['real_TIS_or_codesign_executed'] is False
    assert report['live_home_or_input_method_modified'] is False and report['network_or_microphone_used'] is False
    for name, digest in report['source_sha256'].items():
        assert hashlib.sha256((ROOT/name).read_bytes()).hexdigest() == digest, 'Installer evidence stale: '+name
    return report
