import Foundation

// Pure policy: a missing source must survive two observations. A successful
// check or a security/setup context resets that observation, and repair attempts
// are rate limited even if registration repeatedly returns a misleading noErr.
struct GuardState: Codable {
  var missingSince: Double?
  var lastAttempt: Double?
}
struct GuardObservation {
  var enabled: Bool
  var appPresent: Bool
  var healthy: Bool
  var deferred: Bool
  var now: Double
}
enum GuardAction: String { case disabled, unavailable, healthy, deferred, pending, cooldown, repair }
struct GuardPlan {
  var action: GuardAction
  var state: GuardState
}
func guardPlan(_ observation: GuardObservation, _ old: GuardState) -> GuardPlan {
  var state = old
  if !observation.enabled { state.missingSince = nil; return .init(action: .disabled, state: state) }
  if !observation.appPresent { state.missingSince = nil; return .init(action: .unavailable, state: state) }
  if observation.healthy { state.missingSince = nil; return .init(action: .healthy, state: state) }
  if observation.deferred { state.missingSince = nil; return .init(action: .deferred, state: state) }
  if let attempted = state.lastAttempt, observation.now - attempted < 300 {
    return .init(action: .cooldown, state: state)
  }
  if let since = state.missingSince, observation.now - since > 120 { state.missingSince = nil }
  guard let since = state.missingSince, observation.now >= since, observation.now - since >= 10 else {
    if state.missingSince == nil || observation.now < state.missingSince! { state.missingSince = observation.now }
    return .init(action: .pending, state: state)
  }
  state.lastAttempt = observation.now
  state.missingSince = nil
  return .init(action: .repair, state: state)
}

func persistedSourceRecords(modern: Any?, legacy: Any?) -> (domain: String, records: [[String: Any]], valid: Bool) {
  // An existing empty modern list is authoritative. Never resurrect a legacy
  // entry from an older OS after the user removed it in the current settings.
  if let modern {
    guard let rows = modern as? [[String: Any]] else { return ("com.apple.inputsources", [], false) }
    return ("com.apple.inputsources", rows, true)
  }
  guard let rows = legacy as? [[String: Any]] else { return ("com.apple.HIToolbox", [], false) }
  return ("com.apple.HIToolbox", rows, true)
}
