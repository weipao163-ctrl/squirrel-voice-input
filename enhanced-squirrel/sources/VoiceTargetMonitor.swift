import Foundation

// AX notifications are hints to inspect the keyboard target, not proof that it
// changed. A busy host gets a bounded retry; insertion always needs a fresh
// successful inspection. User actions and confirmed changes revoke immediately.
final class VoiceTargetMonitor {
  enum Verification {
    case verified, unavailable(String), changed(String)
  }
  private let verify: () -> Verification
  private let invalidated: (String) -> Void
  private let clock: () -> TimeInterval
  private let retryLimit: TimeInterval
  private var unavailableSince: TimeInterval?
  private var inspectionQueued = false
  private(set) var valid = true
  private(set) var reason: String?
  init(retryLimit: TimeInterval = 0.8,
       clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
       verify: @escaping () -> Verification, invalidated: @escaping (String) -> Void) {
    self.retryLimit = retryLimit; self.clock = clock
    self.verify = verify; self.invalidated = invalidated
  }
  func invalidate() { valid = false }
  private func revoke(_ reason: String) {
    guard valid else { return }
    valid = false; self.reason = reason; invalidated(reason)
  }
  @discardableResult func inspect() -> Bool {
    guard valid else { return false }
    let result = verify()
    // A synchronous host query can reenter an IMK lifecycle callback.
    guard valid else { return false }
    switch result {
    case .verified:
      unavailableSince = nil; reason = nil; return true
    case .changed(let reason): revoke(reason)
    case .unavailable(let reason):
      let now = clock()
      self.reason = reason
      if unavailableSince == nil { unavailableSince = now }
      if !now.isFinite || now < unavailableSince! || now - unavailableSince! >= retryLimit { revoke(reason) }
    }
    return false
  }
  func scheduleInspection() {
    guard valid, !inspectionQueued else { return }
    inspectionQueued = true
    // Let the host complete the update that emitted the notification first.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
      guard let self else { return }
      self.inspectionQueued = false; self.inspect()
    }
  }
  func verifyForDelivery(_ completion: @escaping (Bool) -> Void) {
    verifyForDelivery(deadline: clock() + retryLimit, completion: completion)
  }
  private func verifyForDelivery(deadline: TimeInterval, completion: @escaping (Bool) -> Void) {
    if inspect() { completion(true); return }
    guard valid else { completion(false); return }
    guard clock() < deadline else { revoke(reason ?? "target-verification-timeout"); completion(false); return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
      guard let self else { completion(false); return }
      self.verifyForDelivery(deadline: deadline, completion: completion)
    }
  }
}
