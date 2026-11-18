import Foundation

public enum MouseHoldAction: Equatable { case none, start, stop, cancel }

public enum MouseHoldTiming {
  public static let defaultSeconds: TimeInterval = 1
  public static let range: ClosedRange<TimeInterval> = 0.1...3
  public static func valid(_ value: TimeInterval) -> Bool { value.isFinite && range.contains(value) }
}

// Own only a fresh, stationary left-button press. Rejected/busy/cancelled holds
// cannot queue or re-arm until a real release and a new press.
public struct MouseHoldCycle {
  public let holdSeconds: TimeInterval
  public static let maximumDelay: TimeInterval = 0.5
  public static let movementTolerance: Double = 6
  public private(set) var held = false
  public private(set) var pending = false
  public private(set) var recording = false
  private var began: TimeInterval = 0
  private var x: Double = 0, y: Double = 0
  public init(holdSeconds: TimeInterval = MouseHoldTiming.defaultSeconds) { self.holdSeconds = holdSeconds }
  public mutating func press(at now: TimeInterval, x: Double, y: Double,
                             eligible: Bool, singleClick: Bool, modified: Bool) -> Bool {
    guard !held else { return false }
    held = true
    guard eligible, singleClick, !modified, MouseHoldTiming.valid(holdSeconds),
          now.isFinite, now >= 0, (now + holdSeconds).isFinite, now + holdSeconds > now,
          x.isFinite, y.isFinite else { return false }
    pending = true; began = now; self.x = x; self.y = y
    return true
  }
  public mutating func moved(x: Double, y: Double) -> MouseHoldAction {
    guard held else { return .none }
    guard x.isFinite, y.isFinite,
          hypot(x - self.x, y - self.y) <= Self.movementTolerance else { return interrupt() }
    return .none
  }
  public mutating func deadline(at now: TimeInterval, leftPressed: Bool, eligible: Bool) -> MouseHoldAction {
    guard pending, held else { return .none }
    guard now.isFinite, now >= began, leftPressed, eligible,
          now <= began + holdSeconds + Self.maximumDelay else { return interrupt() }
    // Absolute deadlines preserve the exact 0.1-second boundary at large uptimes.
    guard now >= began + holdSeconds else { return .none }
    pending = false; recording = true
    return .start
  }
  public mutating func release() -> MouseHoldAction {
    let action: MouseHoldAction = recording ? .stop : .none
    held = false; pending = false; recording = false
    return action
  }
  public mutating func interrupt() -> MouseHoldAction {
    let action: MouseHoldAction = recording ? .cancel : .none
    pending = false; recording = false
    return action
  }
}

public enum MouseVoicePolicy {
  // Bundle identities, not localized application names. The exclusion applies
  // only to mouse activation; keyboard voice uses its existing policy.
  public static func excludes(bundle: String?) -> Bool {
    guard let bundle, !bundle.isEmpty else { return true }
    let value = bundle.lowercased()
    return ["com.tencent.xinwechat", "com.tencent.wechat"].contains {
      value == $0 || value.hasPrefix($0 + ".")
    }
  }
  public static func allowsFocusedElement(role: String?, subrole: String?, enabled: Bool?, writable: Bool) -> Bool {
    ["AXTextField", "AXTextArea", "AXComboBox"].contains(role ?? "") &&
      subrole != "AXSecureTextField" && enabled != false && writable
  }
}
