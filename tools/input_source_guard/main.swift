import AppKit
import Carbon
import Foundation
import Darwin

let bundleID = "org.rime.inputmethod.SquirrelEnhanced.Development"
let allowedModes = Set([bundleID + ".Hans", bundleID + ".Hant"])
let files = FileManager.default
let home = files.homeDirectoryForCurrentUser
let support = home.appendingPathComponent("Library/Application Support/SquirrelEnhancedDev/input-source-guard", isDirectory: true)
let app = home.appendingPathComponent("Library/Input Methods/SquirrelEnhancedDev.app", isDirectory: true)
let configURL = support.appendingPathComponent("guard.json")
let stateURL = support.appendingPathComponent("state.json")
let statusOnly = CommandLine.arguments.dropFirst().elementsEqual(["--status"])
guard CommandLine.arguments.count == 1 || statusOnly else { fputs("Usage: InputSourceGuard [--status]\n", stderr); exit(2) }

struct Configuration: Codable { let enabled: Bool; let modes: [String] }
func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
  guard let data = try? Data(contentsOf: url), data.count <= 65536 else { return nil }
  return try? JSONDecoder().decode(type, from: data)
}
func write<T: Encodable>(_ value: T, _ url: URL) throws {
  let data = try JSONEncoder().encode(value)
  try data.write(to: url, options: .atomic)
  try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
func property(_ source: TISInputSource, _ key: CFString) -> Any? {
  guard let value = TISGetInputSourceProperty(source, key) else { return nil }
  return Unmanaged<CFTypeRef>.fromOpaque(value).takeUnretainedValue()
}
func identifier(_ source: TISInputSource) -> String? { property(source, kTISPropertyInputSourceID) as? String }
func enabledIDs() -> Set<String> {
  let list = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
  return Set(list.compactMap { s in
    guard property(s, kTISPropertyInputSourceIsEnabled) as? Bool == true else { return nil }
    return identifier(s)
  })
}
func stored() -> (domain: String, records: [[String: Any]], valid: Bool) {
  let modern = CFPreferencesCopyAppValue("AppleEnabledThirdPartyInputSources" as CFString, "com.apple.inputsources" as CFString)
  let legacy = CFPreferencesCopyAppValue("AppleEnabledInputSources" as CFString, "com.apple.HIToolbox" as CFString)
  return persistedSourceRecords(modern: modern, legacy: legacy)
}
func storedIDs(_ rows: [[String: Any]]) -> Set<String> {
  return Set(rows.compactMap { row -> String? in
    guard row["Bundle ID"] as? String == bundleID else { return nil }
    if row["InputSourceKind"] as? String == "Keyboard Input Method" { return bundleID }
    return row["Input Mode"] as? String
  })
}
func locked() -> Bool {
  guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return true }
  return session["CGSSessionScreenIsLocked"] as? Bool == true || session["kCGSSessionOnConsoleKey"] as? Bool == false
}
func appIdentityValid() -> Bool {
  guard app.standardizedFileURL == app.resolvingSymlinksInPath().standardizedFileURL,
        let bundle = Bundle(url: app), bundle.bundleIdentifier == bundleID else { return false }
  return files.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/SquirrelEnhancedDev").path)
}
func preferred() -> String? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.standardizedFileURL.path }
func logEvent(_ name: String, _ detail: [String: Any] = [:]) {
  // No input text, app titles, URLs, audio, configuration values or credentials.
  var event = detail; event["event"] = name; event["timestamp"] = ISO8601DateFormatter().string(from: Date())
  guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
  data.append(0x0a)
  let target = support.appendingPathComponent("events.jsonl")
  if let size = (try? files.attributesOfItem(atPath: target.path)[.size]) as? NSNumber, size.intValue > 256 * 1024 {
    let previous = support.appendingPathComponent("events.previous.jsonl")
    try? files.removeItem(at: previous)
    try? files.moveItem(at: target, to: previous)
  }
  if !files.fileExists(atPath: target.path) { files.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
  if let handle = try? FileHandle(forWritingTo: target) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data) }
}
func signatureValid() -> Bool {
  let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
  task.arguments = ["--verify", "--deep", "--strict", app.path]
  task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
  do { try task.run() } catch { return false }
  let deadline = Date(timeIntervalSinceNow: 15)
  while task.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
  if task.isRunning { task.terminate(); return false }
  return task.terminationStatus == 0
}

let config = read(Configuration.self, configURL)
let configValid = config.map { !$0.modes.isEmpty && Set($0.modes).isSubset(of: allowedModes) && $0.modes.count == Set($0.modes).count } ?? false
let protectionEnabled = configValid && config?.enabled == true
if !statusOnly && !protectionEnabled { exit(0) }
let desired = Set(configValid ? config!.modes : [])
let actualEnabled = enabledIDs() // Always before any all-installed query.
let persistence = stored()
let persisted = storedIDs(persistence.records)
let validApp = appIdentityValid()
let preferredPath = preferred()
let required = desired.union([bundleID])
let healthy = validApp && persistence.valid && required.isSubset(of: actualEnabled) && required.isSubset(of: persisted) && preferredPath == app.path
let secureInput = IsSecureEventInputEnabled()
let screenLocked = locked()
let settingsFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences"
let installLock = files.fileExists(atPath: app.path + ".install-lock")
let deferred = secureInput || screenLocked || settingsFront || installLock || !persistence.valid
if statusOnly {
  let state = read(GuardState.self, stateURL)
  let stateReport: [String: Any] = ["missing_since": state?.missingSince as Any? ?? NSNull(), "last_attempt": state?.lastAttempt as Any? ?? NSNull()]
  let report: [String: Any] = ["protection_enabled": protectionEnabled, "config_valid": configValid,
    "registration_healthy": healthy, "app_identity_valid": validApp, "preferred_app_path": preferredPath ?? "missing",
    "desired_modes": desired.sorted(), "enabled_source_ids": actualEnabled.filter { $0.hasPrefix(bundleID) }.sorted(),
    "persisted_source_ids": persisted.sorted(), "persistence_domain": persistence.domain,
    "persistence_valid": persistence.valid, "secure_input": secureInput, "screen_locked": screenLocked,
    "system_settings_frontmost": settingsFront, "installation_lock": installLock,
    "state": stateReport]
  let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
  print(String(decoding: data, as: UTF8.self)); exit(0)
}
// Missing/disabled config is a hard opt-out. Do not create directories or state.
guard protectionEnabled else { exit(0) }
guard support.standardizedFileURL == support.resolvingSymlinksInPath().standardizedFileURL else { exit(2) }
// Serialize manual invocations with launchd; never remove another process lock.
let runLock = support.appendingPathComponent("run.lock")
let lockFD = open(runLock.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
guard lockFD >= 0 else { exit(2) }
guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); exit(0) }
defer { _ = flock(lockFD, LOCK_UN); close(lockFD) }
let old = read(GuardState.self, stateURL) ?? GuardState()
let plan = guardPlan(.init(enabled: protectionEnabled, appPresent: validApp, healthy: healthy, deferred: deferred, now: Date().timeIntervalSince1970), old)
if plan.state.missingSince != old.missingSince || plan.state.lastAttempt != old.lastAttempt { try write(plan.state, stateURL) }
guard plan.action == .repair else { exit(0) }
// Recheck opt-out, installation transaction and security immediately before any
// registry mutation. No recovery is allowed to override these boundaries.
guard appIdentityValid(), signatureValid() else { logEvent("repair_validation_failed"); exit(1) }
// Signature verification can take time. Check the complete boundary again only
// after it returns; an opt-out or a newly locked screen must win the race.
guard let latest = read(Configuration.self, configURL), latest.enabled,
      !latest.modes.isEmpty, Set(latest.modes).isSubset(of: allowedModes), Set(latest.modes) == desired,
      !files.fileExists(atPath: app.path + ".install-lock"), !IsSecureEventInputEnabled(), !locked(),
      NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.systempreferences",
      appIdentityValid() else { logEvent("repair_deferred"); exit(0) }
let latestEnabled = enabledIDs()
let latestStored = stored()
let latestPersisted = storedIDs(latestStored.records)
let latestPreferred = preferred()
guard latestStored.valid else { logEvent("repair_deferred"); exit(0) }
if required.isSubset(of: latestEnabled) && required.isSubset(of: latestPersisted) && latestPreferred == app.path {
  // Another process already restored the source during signature verification.
  // Cancel this attempt without touching the registries or logging a recovery.
  try write(GuardState(missingSince: nil, lastAttempt: old.lastAttempt), stateURL)
  exit(0)
}
logEvent("repair_attempt", ["missing_enabled_ids": required.subtracting(latestEnabled).sorted(), "missing_persisted_ids": required.subtracting(latestPersisted).sorted(), "preferred_path_matches": latestPreferred == app.path])
var steps: [String: Int32] = [:]
var result = LSRegisterURL(app as CFURL, true); steps["launch_services"] = result
if result == noErr { result = TISRegisterInputSource(app as CFURL); steps["tis_register"] = result }
if result == noErr {
  let list = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
  let own = Dictionary(list.compactMap { s -> (String, TISInputSource)? in identifier(s).map { ($0,s) } }, uniquingKeysWith: { a,_ in a })
  for id in [bundleID] + desired.sorted() {
    guard let source = own[id] else { result = OSStatus(paramErr); steps[id] = result; break }
    result = TISEnableInputSource(source); steps[id] = result
    if result != noErr { break }
  }
}
RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
let finalStored = stored()
let verified = result == noErr && finalStored.valid && required.isSubset(of: storedIDs(finalStored.records)) && required.isSubset(of: enabledIDs()) && preferred() == app.path
logEvent(verified ? "repair_verified" : "repair_failed", ["steps": steps, "persistence_domain": finalStored.domain, "verified": verified])
exit(verified ? 0 : 1)
