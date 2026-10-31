#!/usr/bin/env python3
"""Pure metadata/log fixtures plus mocked management. Never run the live sampler."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'tools/input_source_audit'

SWIFT = r'''
import Foundation
import Darwin
var count = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
  precondition(condition(), name); count += 1
}
let modern: [[String: Any]] = [["Bundle ID": auditBundleID, "Input Mode": auditBundleID + ".Hans",
  "InputSourceKind": "Input Mode", "KeyboardLayout ID": 1, "KeyboardLayout Name": "PRIVATE_CONTENT",
  "unrelated_secret": "PRIVATE_CONTENT"]]
let old = [["Bundle ID": "old.source"]]
let persisted = auditPersistence(modern: modern, legacy: old)
check(persisted.domain == "com.apple.inputsources" && persisted.valid, "modern domain")
check(persisted.observation == "disk", "persistent evidence labelled as disk")
let encoded = String(decoding: try JSONEncoder().encode(persisted), as: UTF8.self)
check(!encoded.contains("PRIVATE_CONTENT") && !encoded.contains("unrelated_secret"), "strict preference whitelist")
check(auditPersistence(modern: [[String: Any]](), legacy: old).sources.isEmpty, "empty modern authoritative")
check(!auditPersistence(modern: "invalid", legacy: old).valid, "invalid modern no legacy fallback")
check(auditPersistence(modern: nil, legacy: old).sources.first?.bundleID == "old.source", "legacy only when modern absent")
check(!auditPersistence(modern: nil, legacy: nil).valid, "unavailable persistence visible")
check(auditIdentifier("text\ncontent") == nil && auditIdentifier(String(repeating: "x", count: 257)) == nil, "metadata length/control bound")
let console: [[String: Any]] = [["kCGSSessionUserIDKey": 502, "kCGSSessionOnConsoleKey": true, "kCGSSessionSecureInputPID": 11],
  ["kCGSSessionUserIDKey": 501, "kCGSSessionOnConsoleKey": true, "kCGSSessionSecureInputPID": 22, "name": "PRIVATE_CONTENT"]]
check(auditSecureOwner(session: nil, consoleUsers: console, uid: 501) == 22, "current console user only")
check(auditSecureOwner(session: nil, consoleUsers: console, uid: 503) == nil, "unknown owner not guessed")
check(auditSecureOwner(session: ["kCGSSessionSecureInputPID": -1], consoleUsers: nil, uid: 501) == nil, "invalid pid omitted")
var order: [String] = []
let reads = AuditReads(enabled: { order.append("enabled"); return [auditBundleID, auditBundleID] },
  selected: { order.append("selected"); return auditBundleID + ".Hans" },
  persistence: { order.append("persistence"); return persisted },
  security: { order.append("security"); return .init(secureInput: false, secureOwnerPID: nil, screenLocked: false) },
  foreground: { order.append("foreground"); return .init(bundleID: "fixture.editor", pid: 42) },
  target: { order.append("target"); return .init(path: "/fixture/installed.app", exists: true, bundleID: auditBundleID,
    version: "fixture", processes: [.init(pid: 43, bundlePath: "/fixture/installed.app")], helperProcesses: [], installationLock: false) })
let first = reads.snapshot(sleeping: false)
check(order == ["enabled", "selected", "persistence", "security", "foreground", "target"], "enabled-only read always first")
check(first.enabledSourceIDs == [auditBundleID], "enabled IDs deterministic")
var changes = AuditChanges()
check(changes.observe(first, reason: "started", now: 1)?.event == "baseline", "baseline once")
check(changes.observe(first, reason: "periodic", now: 31) == nil, "unchanged poll silent")
let sleeping = reads.snapshot(sleeping: true)
check(changes.observe(sleeping, reason: "will_sleep", now: 35)?.event == "state_changed", "sleep transition recorded")
check(changes.observe(sleeping, reason: "periodic", now: 65) == nil, "unchanged sleep silent")
check(changes.observe(first, reason: "did_wake", now: 70) != nil, "wake transition recorded")
let absent = AuditSnapshot(enabledSourceIDs: [], selectedSourceID: nil,
  persistence: auditPersistence(modern: "invalid", legacy: old), security: first.security,
  foreground: first.foreground, target: first.target, sleeping: false)
check(changes.observe(absent, reason: "enabled_sources_changed", now: 80)?.anomalies ==
  ["persistence_unreadable", "selected_source_unavailable", "target_not_in_enabled_sources"], "anomalies are metadata codes")
check(changes.observe(absent, reason: "periodic", now: 110) == nil, "unchanged anomaly not spammed")
let config = AuditConfiguration(enabled: true, startedAt: 1000, expiresAt: 1000 + 48 * 3600)
check(config.valid, "48h valid")
check(!AuditConfiguration(enabled: true, startedAt: 1000, expiresAt: 1001 + 48 * 3600).valid, "no more than 48h")
check(auditRunAction(original: config, current: config, now: config.expiresAt - 1) == .sample, "sample until deadline")
check(auditRunAction(original: config, current: config, now: config.expiresAt) == .expired, "exact deadline expires")
check(auditRunAction(original: config, current: config, now: 999) == .stop, "clock before start fails closed across relaunch")
check(auditRunAction(original: config, current: nil, now: 1100) == .stop, "missing config stops")
check(auditRunAction(original: config, current: .init(enabled: false, startedAt: 1000, expiresAt: config.expiresAt), now: 1100) == .stop, "opt out stops")
check(auditRunAction(original: config, current: .init(enabled: true, startedAt: 1001, expiresAt: config.expiresAt), now: 1100) == .stop, "replaced session cannot extend old run")
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let directory = root.appendingPathComponent("private")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
let logger = try PrivateAuditLog(directory: directory, limit: 512)
for index in 0..<30 {
  try logger.append(.init(timestamp: Double(index), event: "fixture", reason: String(repeating: "x", count: 80), anomalies: [], snapshot: nil))
}
let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
check(paths.count == 3, "at most three logs")
for path in paths {
  let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
  check((attributes[.size] as! NSNumber).intValue <= 512, "hard size bound")
  check((attributes[.posixPermissions] as! NSNumber).intValue == 0o600, "logs private")
}
try logger.status(.init(phase: "expired", pid: 1, startedAt: 1000, expiresAt: 173800, lastEventAt: 173800, eventsWritten: 30))
let statusAttributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("status.json").path)
check((statusAttributes[.posixPermissions] as! NSNumber).intValue == 0o600, "status private")
let unsafe = root.appendingPathComponent("unsafe")
try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
let marker = root.appendingPathComponent("marker")
try Data("KEEP".utf8).write(to: marker)
try FileManager.default.createSymbolicLink(at: unsafe.appendingPathComponent("events.jsonl"), withDestinationURL: marker)
do {
  try PrivateAuditLog(directory: unsafe).append(.init(timestamp: 1, event: "fixture", reason: "test", anomalies: [], snapshot: nil))
  fatalError("symlink accepted")
} catch AuditIOError.unsafePath { count += 1 }
let markerContent = try String(contentsOf: marker, encoding: .utf8)
check(markerContent == "KEEP", "symlink target unchanged")
let oversized = root.appendingPathComponent("oversized")
try FileManager.default.createDirectory(at: oversized, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
let huge = oversized.appendingPathComponent("events.jsonl")
try Data(repeating: 0x78, count: 513).write(to: huge)
do {
  try PrivateAuditLog(directory: oversized, limit: 512).append(.init(timestamp: 1, event: "fixture", reason: "test", anomalies: [], snapshot: nil))
  fatalError("oversized existing file accepted")
} catch AuditIOError.oversizedExistingFile { count += 1 }
let retained = try Data(contentsOf: huge)
check(retained.count == 513, "oversized evidence preserved and not rotated")
print("PASS \(count) audit fixture checks; no live sampler executed")
'''


class AuditTests(unittest.TestCase):
    def test_pure_native_metadata_and_private_log(self):
        with tempfile.TemporaryDirectory(prefix='squirrel-audit-fixture-') as directory:
            root = Path(directory)
            main = root / 'main.swift'
            main.write_text(SWIFT)
            binary = root / 'fixture'
            subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', str(SOURCE/'AuditCore.swift'),
                            str(SOURCE/'PrivateLog.swift'), str(main), '-o', str(binary)], check=True)
            result = subprocess.run([str(binary), str(root)], check=True, capture_output=True, text=True)
            self.assertIn('no live sampler executed', result.stdout)
            print(result.stdout.strip())

    def manager(self):
        spec = importlib.util.spec_from_file_location('audit_manager_fixture', SOURCE/'manage.py')
        manager = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(manager)
        return manager

    def test_management_dry_run_never_invokes_system_commands(self):
        manager = self.manager()
        for command in ['install', 'start', 'stop']:
            with mock.patch.object(sys, 'argv', ['manage.py', command]), mock.patch.object(manager.subprocess, 'run', side_effect=AssertionError('system command')):
                self.assertEqual(manager.main(), 0)

    def test_start_and_stop_only_publish_own_agent(self):
        manager = self.manager()
        with tempfile.TemporaryDirectory(prefix='audit-manager-fixture-') as directory:
            root = Path(directory).resolve(); support = root/'support'; support.mkdir()
            binary = support/'InputSourceAudit'; binary.write_bytes(b'fixture; never executed')
            config = support/'audit.json'; agent = root/'LaunchAgents/audit.plist'
            with mock.patch.multiple(manager, SUPPORT=support, BINARY=binary, CONFIG=config, AGENT=agent), \
                 mock.patch.object(manager, 'bootout') as stop, mock.patch.object(manager.subprocess, 'run') as run, \
                 mock.patch.object(sys, 'platform', 'darwin'), mock.patch.object(sys, 'argv', ['manage.py', 'start', '--apply']):
                self.assertEqual(manager.main(), 0)
                value = json.loads(config.read_text())
                self.assertEqual(value['expiresAt'] - value['startedAt'], 48 * 3600)
                payload = plistlib.loads(agent.read_bytes())
                self.assertTrue(payload['RunAtLoad'])
                self.assertNotIn('KeepAlive', payload); self.assertNotIn('StartInterval', payload)
                self.assertEqual(payload['ProgramArguments'], [str(binary), '--run'])
                self.assertEqual(run.call_args.args[0][:2], ['launchctl', 'bootstrap'])
                self.assertEqual(os.stat(config).st_mode & 0o777, 0o600)
                log = support/'events.jsonl'; log.write_bytes(b'KEEP')
                with mock.patch.object(sys, 'argv', ['manage.py', 'stop', '--apply']):
                    self.assertEqual(manager.main(), 0)
                self.assertFalse(json.loads(config.read_text())['enabled'])
                self.assertFalse(agent.exists()); self.assertEqual(log.read_bytes(), b'KEEP')
                self.assertEqual(stop.call_count, 2)

    def test_publication_or_bootstrap_failure_disables_audit(self):
        for failure in ['publication', 'bootstrap']:
            manager = self.manager()
            with tempfile.TemporaryDirectory(prefix='audit-publication-fixture-') as directory:
                root = Path(directory).resolve(); support = root/'support'; support.mkdir()
                binary = support/'InputSourceAudit'; binary.write_bytes(b'fixture; never executed')
                config = support/'audit.json'; agent = root/'LaunchAgents/audit.plist'
                real_atomic = manager.atomic
                def atomic(path, data, mode=0o600):
                    if failure == 'publication' and path == agent:
                        raise OSError('injected publication failure')
                    real_atomic(path, data, mode)
                with mock.patch.multiple(manager, SUPPORT=support, BINARY=binary, CONFIG=config, AGENT=agent), \
                     mock.patch.object(manager, 'atomic', side_effect=atomic), mock.patch.object(manager, 'bootout') as stop, \
                     mock.patch.object(manager.subprocess, 'run', side_effect=OSError('injected bootstrap failure')), \
                     mock.patch.object(sys, 'platform', 'darwin'), mock.patch.object(sys, 'argv', ['manage.py', 'start', '--apply']):
                    with self.assertRaisesRegex(OSError, 'injected'):
                        manager.main()
                    self.assertFalse(json.loads(config.read_text())['enabled'])
                    self.assertEqual(stop.call_count, 2)

    def test_sampler_has_only_read_apis(self):
        code = '\n'.join(path.read_text() for path in SOURCE.glob('*.swift'))
        forbidden = ['LSRegisterURL', 'TISRegisterInputSource', 'TISEnableInputSource', 'TISDisableInputSource',
                     'TISSelectInputSource', 'CFPreferencesSetAppValue', 'CFPreferencesSetValue', 'CFPreferencesAppSynchronize',
                     'AXUIElementCreateApplication', 'CGEventTapCreate', 'CGEventPost', 'SecItemCopyMatching',
                     'SecItemAdd', 'AVAudioEngine', 'AVCaptureDevice', 'Process']
        for name in forbidden:
            self.assertNotRegex(code, r'\b' + name + r'\s*\(')
        self.assertEqual(re.findall(r'TISCreateInputSourceList\(([^)]*)\)', code), ['nil, false'])

    def test_status_does_not_echo_unknown_or_malformed_fields(self):
        manager = self.manager()
        value = manager.runtime_metadata({'phase': 'PRIVATE_CONTENT', 'pid': 'PRIVATE_CONTENT',
            'startedAt': 'PRIVATE_CONTENT', 'expiresAt': float('inf'), 'lastEventAt': 10**500,
            'eventsWritten': {'secret': 'PRIVATE_CONTENT'}, 'text': 'PRIVATE_CONTENT'})
        self.assertEqual(value, {})
        clean = manager.runtime_metadata({'phase': 'expired', 'pid': 42, 'startedAt': 1000,
            'expiresAt': 173800, 'lastEventAt': 173800, 'eventsWritten': 2, 'text': 'PRIVATE_CONTENT'})
        self.assertNotIn('PRIVATE_CONTENT', json.dumps(clean))
        self.assertEqual(clean['phase'], 'expired')


if __name__ == '__main__':
    unittest.main()
