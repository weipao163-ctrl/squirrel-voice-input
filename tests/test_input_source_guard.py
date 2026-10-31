#!/usr/bin/env python3
"""Compile/run pure policy tests; never register, enable or select real sources."""
from pathlib import Path
import json
import importlib.util
import sys
from unittest import mock
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'tools/input_source_guard'

SWIFT = r'''
import Foundation
var count = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
  precondition(condition(), name); count += 1
}
func observation(_ now: Double = 1000, enabled: Bool = true, present: Bool = true, healthy: Bool = false, deferred: Bool = false) -> GuardObservation {
  .init(enabled: enabled, appPresent: present, healthy: healthy, deferred: deferred, now: now)
}
let empty = GuardState()
let first = guardPlan(observation(), empty)
check(first.action == .pending && first.state.missingSince == 1000, "first missing never repairs")
check(guardPlan(observation(1009), first.state).action == .pending, "transient loss grace period")
let second = guardPlan(observation(1010), first.state)
check(second.action == .repair && second.state.lastAttempt == 1010 && second.state.missingSince == nil, "stable loss repairs once")
check(guardPlan(observation(1200), second.state).action == .cooldown, "repeated failure rate limited")
check(guardPlan(observation(1310), second.state).action == .pending, "cooldown expiry still requires stable loss")
for next in [observation(1011,enabled:false),observation(1011,present:false),observation(1011,healthy:true),observation(1011,deferred:true)] {
  check(guardPlan(next, first.state).state.missingSince == nil, "disabled, uninstalled, recovered or secure resets loss")
}
check(guardPlan(observation(enabled:false,healthy:true), empty).action == .disabled, "opt-out precedence")
check(guardPlan(observation(present:false,deferred:true), empty).action == .unavailable, "never recreate uninstalled app")
check(guardPlan(observation(deferred:true), empty).action == .deferred, "secure, locked, setup or installation defers")
let resumed = guardPlan(observation(1030), guardPlan(observation(1020,deferred:true), first.state).state)
check(resumed.action == .pending && resumed.state.missingSince == 1030, "leaving security context requires new grace")
check(guardPlan(observation(2000), first.state).action == .pending && guardPlan(observation(2000), first.state).state.missingSince == 2000, "long sleep resets continuity")
check(guardPlan(observation(900), first.state).state.missingSince == 900, "backwards wall clock resets grace")
check(guardPlan(observation(900), second.state).action == .cooldown, "backwards wall clock never bypasses cooldown")
let legacy = [["Bundle ID":"legacy"]]
let modern = [["Bundle ID":"modern"]]
check(persistedSourceRecords(modern: modern,legacy:legacy).records[0]["Bundle ID"] as? String == "modern", "modern authority")
check(persistedSourceRecords(modern: [[String:Any]](),legacy:legacy).records.isEmpty, "modern empty means disabled")
check(persistedSourceRecords(modern: nil,legacy:legacy).domain == "com.apple.HIToolbox", "legacy compatibility")
check(!persistedSourceRecords(modern: "invalid",legacy:legacy).valid, "invalid modern never falls back")
check(!persistedSourceRecords(modern: nil,legacy: nil).valid, "missing preferences fail closed")
print("PASS \(count) input-source guard policy checks")
'''


class GuardTests(unittest.TestCase):
    def test_native_policy(self):
        with tempfile.TemporaryDirectory(prefix='guard-policy-') as directory:
            directory = Path(directory)
            main = directory / 'main.swift'
            main.write_text(SWIFT)
            binary = directory / 'policy'
            subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(SOURCE / 'GuardPolicy.swift'), str(main), '-o', str(binary)], check=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn('PASS 21 ', result.stdout)
            print(result.stdout.strip())

    def test_management_defaults_to_dry_run(self):
        for operation in ['install', 'enable', 'disable']:
            result = subprocess.run(['python3', str(SOURCE / 'manage.py'), operation], check=True, capture_output=True, text=True)
            report = json.loads(result.stdout)
            self.assertTrue(report['dry_run'])
            self.assertEqual(report['command'], operation)
            self.assertEqual(report['modes'], ['Hans'])

    def test_agent_publication_failure_disables_protection(self):
        spec = importlib.util.spec_from_file_location('guard_manager_fixture', SOURCE / 'manage.py')
        manager = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(manager)
        with tempfile.TemporaryDirectory(prefix='guard-manager-fixture-') as directory:
            root = Path(directory).resolve()
            support = root / 'support'
            support.mkdir()
            binary = support / 'InputSourceGuard'
            binary.write_bytes(b'fixture; never executed')
            config = support / 'guard.json'
            agent = root / 'LaunchAgents/fixture.plist'
            real_atomic = manager.atomic
            def fail_agent(path, content, mode=0o600):
                if path == agent:
                    raise OSError('injected agent write failure')
                return real_atomic(path, content, mode)
            with mock.patch.multiple(manager, SUPPORT=support, BINARY=binary, CONFIG=config, AGENT=agent), \
                 mock.patch.object(manager, 'atomic', side_effect=fail_agent), \
                 mock.patch.object(manager, 'stop') as stop, \
                 mock.patch.object(sys, 'argv', ['manage.py','enable','--apply']), \
                 mock.patch.object(sys, 'platform', 'darwin'):
                with self.assertRaisesRegex(OSError, 'injected'):
                    manager.main()
                self.assertFalse(json.loads(config.read_text())['enabled'])
                self.assertEqual(stop.call_count, 2)
                self.assertFalse(agent.exists())


if __name__ == '__main__':
    unittest.main()
