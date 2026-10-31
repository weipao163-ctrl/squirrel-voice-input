import Foundation

let auditBundleID = "org.rime.inputmethod.SquirrelEnhanced.Development"
let auditHelperID = "org.rime.SquirrelEnhanced.Development.VoiceHelper"

struct AuditConfiguration: Codable {
  let enabled: Bool
  let startedAt: Double
  let expiresAt: Double
  var valid: Bool {
    startedAt.isFinite && expiresAt.isFinite && startedAt > 0 &&
      expiresAt > startedAt && expiresAt - startedAt <= 48 * 3600
  }
}
enum AuditRunAction { case sample, expired, stop }
func auditRunAction(original: AuditConfiguration, current: AuditConfiguration?, now: Double) -> AuditRunAction {
  guard original.valid, original.enabled, now.isFinite, now >= original.startedAt else { return .stop }
  if now >= original.expiresAt { return .expired }
  guard let current, current.valid, current.enabled,
        current.startedAt == original.startedAt, current.expiresAt == original.expiresAt else { return .stop }
  return .sample
}

// Closed metadata types: arbitrary preference dictionaries never reach disk.
struct AuditPersistedSource: Codable, Equatable {
  let bundleID: String?
  let inputMode: String?
  let kind: String?
  let keyboardLayoutID: Int?
}
struct AuditPersistence: Codable, Equatable {
  let domain: String
  let observation: String
  let valid: Bool
  let sources: [AuditPersistedSource]
}
func auditIdentifier(_ raw: Any?) -> String? {
  guard let value = raw as? String, !value.isEmpty, value.utf8.count <= 256,
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
  return value
}
func auditPersistence(modern: Any?, legacy: Any?) -> AuditPersistence {
  let domain = modern == nil ? "com.apple.HIToolbox" : "com.apple.inputsources"
  guard let rows = (modern ?? legacy) as? [[String: Any]], rows.count <= 512 else {
    return .init(domain: domain, observation: "disk", valid: false, sources: [])
  }
  let sources = rows.map { row in
    AuditPersistedSource(bundleID: auditIdentifier(row["Bundle ID"]),
      inputMode: auditIdentifier(row["Input Mode"]), kind: auditIdentifier(row["InputSourceKind"]),
      keyboardLayoutID: row["KeyboardLayout ID"] as? Int)
  }
  return .init(domain: domain, observation: "disk", valid: true, sources: sources)
}
func auditSecureOwner(session: [String: Any]?, consoleUsers: Any?, uid: Int) -> Int? {
  func pid(_ row: [String: Any]) -> Int? {
    for key in ["kCGSSessionSecureInputPID", "CGSSessionSecureInputPID"] {
      if let value = row[key] as? Int, value > 0 && value <= Int(Int32.max) { return value }
    }
    return nil
  }
  if let session, let result = pid(session) { return result }
  guard let rows = consoleUsers as? [[String: Any]] else { return nil }
  return rows.first(where: {
    $0["kCGSSessionUserIDKey"] as? Int == uid && $0["kCGSSessionOnConsoleKey"] as? Bool == true
  }).flatMap(pid)
}
struct AuditSecurity: Codable, Equatable {
  let secureInput: Bool
  let secureOwnerPID: Int?
  let screenLocked: Bool?
}
struct AuditForeground: Codable, Equatable { let bundleID: String?; let pid: Int32? }
struct AuditProcess: Codable, Equatable { let pid: Int32; let bundlePath: String? }
struct AuditTarget: Codable, Equatable {
  let path: String
  let exists: Bool
  let bundleID: String?
  let version: String?
  let processes: [AuditProcess]
  let helperProcesses: [AuditProcess]
  let installationLock: Bool
}
struct AuditSnapshot: Codable, Equatable {
  let enabledSourceIDs: [String]
  let selectedSourceID: String?
  let persistence: AuditPersistence
  let security: AuditSecurity
  let foreground: AuditForeground
  let target: AuditTarget
  let sleeping: Bool
  var anomalies: [String] {
    var result: [String] = []
    if !persistence.valid { result.append("persistence_unreadable") }
    if selectedSourceID == nil { result.append("selected_source_unavailable") }
    if !target.exists { result.append("installed_app_missing") }
    else if target.bundleID != auditBundleID { result.append("installed_app_identity_mismatch") }
    if !enabledSourceIDs.contains(where: { $0 == auditBundleID || $0.hasPrefix(auditBundleID + ".") }) {
      result.append("target_not_in_enabled_sources")
    }
    return result
  }
}
struct AuditReads {
  let enabled: () -> [String]
  let selected: () -> String?
  let persistence: () -> AuditPersistence
  let security: () -> AuditSecurity
  let foreground: () -> AuditForeground
  let target: () -> AuditTarget
  func snapshot(sleeping: Bool) -> AuditSnapshot {
    // Keep this order explicit. Never query all-installed sources.
    let sources = enabled()
    return .init(enabledSourceIDs: Array(Set(sources)).sorted(), selectedSourceID: selected(),
      persistence: persistence(), security: security(), foreground: foreground(), target: target(), sleeping: sleeping)
  }
}
struct AuditEvent: Codable {
  let timestamp: Double
  let event: String
  let reason: String
  let anomalies: [String]
  let snapshot: AuditSnapshot?
}
struct AuditChanges {
  private(set) var previous: AuditSnapshot?
  mutating func observe(_ snapshot: AuditSnapshot, reason: String, now: Double) -> AuditEvent? {
    guard previous != snapshot else { return nil }
    let event = previous == nil ? "baseline" : "state_changed"
    previous = snapshot
    return .init(timestamp: now, event: event, reason: reason, anomalies: snapshot.anomalies, snapshot: snapshot)
  }
}
struct AuditRuntimeStatus: Codable {
  let phase: String
  let pid: Int32
  let startedAt: Double
  let expiresAt: Double
  let lastEventAt: Double
  let eventsWritten: Int
}
