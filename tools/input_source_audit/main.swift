import AppKit
import Carbon
import Foundation
import IOKit
import Darwin

let files = FileManager.default
let home = files.homeDirectoryForCurrentUser
let support = home.appendingPathComponent("Library/Application Support/SquirrelEnhancedDev/input-source-audit", isDirectory: true)
let installedApp = home.appendingPathComponent("Library/Input Methods/SquirrelEnhancedDev.app", isDirectory: true)
let configPath = support.appendingPathComponent("audit.json")

func property(_ source: TISInputSource, _ key: CFString) -> Any? {
  guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
  return Unmanaged<CFTypeRef>.fromOpaque(raw).takeUnretainedValue()
}
func enabledSources() -> [String] {
  let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
  return sources.compactMap {
    guard property($0, kTISPropertyInputSourceIsEnabled) as? Bool == true else { return nil }
    return auditIdentifier(property($0, kTISPropertyInputSourceID))
  }
}
func selectedSource() -> String? {
  guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
  return auditIdentifier(property(source, kTISPropertyInputSourceID))
}
func preferenceKey(_ domain: String, _ key: String) -> Any? {
  let path = home.appendingPathComponent("Library/Preferences/" + domain + ".plist")
  var metadata = stat()
  if lstat(path.path, &metadata) != 0 { return errno == ENOENT ? nil : NSNull() }
  guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= 4 * 1024 * 1024,
        let data = try? Data(contentsOf: path),
        let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let dictionary = value as? [String: Any] else { return NSNull() }
  return dictionary[key]
}
func persistedSources() -> AuditPersistence {
  // Disk evidence avoids a long-lived CFPreferences cache and never synchronizes
  // or writes preferences. Disk may lag a recent settings change; TIS is separate.
  let modern = preferenceKey("com.apple.inputsources", "AppleEnabledThirdPartyInputSources")
  // Missing modern key permits compatibility fallback; present empty/invalid does not.
  let legacy = modern == nil ? preferenceKey("com.apple.HIToolbox", "AppleEnabledInputSources") : nil
  return auditPersistence(modern: modern, legacy: legacy)
}
func securityMetadata() -> AuditSecurity {
  let secure = IsSecureEventInputEnabled()
  let session = CGSessionCopyCurrentDictionary() as? [String: Any]
  var owner: Int?
  if secure {
    let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/")
    if root != 0 {
      defer { IOObjectRelease(root) }
      let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
      owner = auditSecureOwner(session: session, consoleUsers: users, uid: Int(getuid()))
    } else { owner = auditSecureOwner(session: session, consoleUsers: nil, uid: Int(getuid())) }
  }
  let locked = session.map { $0["CGSSessionScreenIsLocked"] as? Bool == true || $0["kCGSSessionOnConsoleKey"] as? Bool == false }
  return .init(secureInput: secure, secureOwnerPID: owner, screenLocked: locked)
}
func running(_ identifier: String) -> [AuditProcess] {
  NSRunningApplication.runningApplications(withBundleIdentifier: identifier).map {
    AuditProcess(pid: $0.processIdentifier, bundlePath: $0.bundleURL?.standardizedFileURL.path)
  }.sorted { $0.pid < $1.pid }
}
func targetMetadata() -> AuditTarget {
  // Read the file again, instead of retaining a Bundle's cached version across updates.
  let infoPath = installedApp.appendingPathComponent("Contents/Info.plist")
  let data = try? Data(contentsOf: infoPath)
  let info = data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
  return .init(path: installedApp.path, exists: files.fileExists(atPath: installedApp.path),
    bundleID: auditIdentifier(info?["CFBundleIdentifier"]), version: auditIdentifier(info?["CFBundleShortVersionString"]),
    processes: running(auditBundleID), helperProcesses: running(auditHelperID),
    installationLock: files.fileExists(atPath: installedApp.path + ".install-lock"))
}
let reads = AuditReads(enabled: enabledSources, selected: selectedSource, persistence: persistedSources,
  security: securityMetadata, foreground: {
    let application = NSWorkspace.shared.frontmostApplication
    return .init(bundleID: auditIdentifier(application?.bundleIdentifier), pid: application?.processIdentifier)
  }, target: targetMetadata)

func configuration() -> AuditConfiguration? {
  guard let attributes = try? files.attributesOfItem(atPath: configPath.path),
        attributes[.type] as? FileAttributeType == .typeRegular,
        let size = attributes[.size] as? NSNumber, size.intValue <= 65536,
        let data = try? Data(contentsOf: configPath) else { return nil }
  return try? JSONDecoder().decode(AuditConfiguration.self, from: data)
}
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--snapshot"] {
  let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let data = try encoder.encode(reads.snapshot(sleeping: false))
  print(String(decoding: data, as: UTF8.self)); exit(0)
}
guard arguments == ["--run"] else { fputs("Usage: InputSourceAudit --run | --snapshot\n", stderr); exit(2) }
guard let config = configuration(), config.enabled, config.valid else { exit(0) }
umask(0o077)
let log: PrivateAuditLog
do { log = try PrivateAuditLog(directory: support) }
catch { fputs("InputSourceAudit: unsafe or unavailable private directory\n", stderr); exit(2) }
let lockFD = open(support.appendingPathComponent("run.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
guard lockFD >= 0 else { exit(2) }
guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); exit(0) }
// The kernel releases the lock on every exit, including SIGKILL.

final class Recorder: NSObject {
  let config: AuditConfiguration
  let log: PrivateAuditLog
  var changes = AuditChanges()
  var sleeping = false
  var count = 0
  var finished = false
  var tokens: [NSObjectProtocol] = []
  var timers: [DispatchSourceTimer] = []
  var signals: [DispatchSourceSignal] = []
  init(config: AuditConfiguration, log: PrivateAuditLog) { self.config = config; self.log = log }
  func status(_ phase: String, now: Double) throws {
    try log.status(.init(phase: phase, pid: getpid(), startedAt: config.startedAt,
      expiresAt: config.expiresAt, lastEventAt: now, eventsWritten: count))
  }
  func finish(_ phase: String) {
    guard !finished else { return }; finished = true
    let now = Date().timeIntervalSince1970
    do {
      try log.append(.init(timestamp: now, event: phase, reason: phase, anomalies: [], snapshot: nil)); count += 1
      try status(phase, now: now)
    } catch { fputs("InputSourceAudit: unable to write final metadata\n", stderr) }
    exit(0)
  }
  func sample(_ reason: String) {
    guard !finished else { return }
    let now = Date().timeIntervalSince1970
    switch auditRunAction(original: config, current: configuration(), now: now) {
    case .expired: finish("expired"); return
    case .stop: finish("stopped"); return
    case .sample: break
    }
    let snapshot = reads.snapshot(sleeping: sleeping)
    guard let event = changes.observe(snapshot, reason: reason, now: now) else { return }
    do { try log.append(event); count += 1; try status("running", now: now) }
    catch { fputs("InputSourceAudit: metadata write failed; stopping\n", stderr); exit(2) }
  }
  @objc func inputChanged(_ notification: Notification) {
    sample(notification.name.rawValue == kTISNotifySelectedKeyboardInputSourceChanged as String ? "selected_source_changed" : "enabled_sources_changed")
  }
  func begin() {
    let distributed = DistributedNotificationCenter.default()
    for name in [kTISNotifyEnabledKeyboardInputSourcesChanged as String, kTISNotifySelectedKeyboardInputSourceChanged as String] {
      distributed.addObserver(self, selector: #selector(inputChanged(_:)), name: .init(name), object: nil, suspensionBehavior: .deliverImmediately)
    }
    let center = NSWorkspace.shared.notificationCenter
    tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.sample("foreground_changed") })
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == auditBundleID || app.bundleIdentifier == auditHelperID else { return }
        self?.sample(name == NSWorkspace.didLaunchApplicationNotification ? "target_launched" : "target_terminated")
      })
    }
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
      tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.sleeping = name == NSWorkspace.willSleepNotification
        self?.sample(name == NSWorkspace.willSleepNotification ? "will_sleep" : "did_wake")
      })
    }
    for name in [NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification] {
      tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.sample("session_changed") })
    }
    let poll = DispatchSource.makeTimerSource(queue: .main)
    poll.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(2))
    poll.setEventHandler { [weak self] in self?.sample("periodic") }; poll.resume(); timers.append(poll)
    let expiry = DispatchSource.makeTimerSource(queue: .main)
    expiry.schedule(deadline: .now() + max(0, min(48 * 3600, config.expiresAt - Date().timeIntervalSince1970)))
    expiry.setEventHandler { [weak self] in self?.finish("expired") }; expiry.resume(); timers.append(expiry)
    for number in [SIGTERM, SIGINT] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { [weak self] in self?.finish("stopped") }; source.resume(); signals.append(source)
    }
    sample("started")
  }
}
let recorder = Recorder(config: config, log: log)
if Date().timeIntervalSince1970 >= config.expiresAt,
   let data = try? Data(contentsOf: support.appendingPathComponent("status.json")), data.count <= 65536,
   let prior = try? JSONDecoder().decode(AuditRuntimeStatus.self, from: data),
   prior.phase == "expired", prior.expiresAt == config.expiresAt { exit(0) }
recorder.begin()
RunLoop.main.run()
