import Foundation

public enum KeyCycleAction: Equatable { case none, start, stop }

public enum VoiceKeyboardEventKind: Equatable { case keyDown, keyUp, modifierChange }

// Called by the native coordinator after the owned-cycle routing. This does not
// synthesize a release or consume an event: the original input path still runs.
public enum VoiceKeyInterruptionPolicy {
  public static func shouldInvalidate(code: UInt16, kind: VoiceKeyboardEventKind,
                                      liveVoice: Bool, ownedCycle: Set<UInt16>,
                                      binding: TriggerBinding?, finalizing: Bool) -> Bool {
    guard liveVoice, !ownedCycle.contains(code) else { return false }
    // A new configured trigger during finalization is a rejected busy cycle,
    // not ordinary editing. It must not discard the previous task's eligibility.
    if finalizing && binding?.codes.contains(code) == true { return false }
    // Any unowned modifier change is keyboard activity too (including Caps
    // Lock or an extra side's release). Hardware-side trigger releases were
    // routed first and are explicitly excluded above. Never infer a release
    // from aggregate modifier flags or consume the unrelated event here.
    return kind == .keyDown || kind == .modifierChange
  }
}

public struct PhysicalKeys {
  public private(set) var held: Set<UInt16> = []
  public private(set) var owner: TriggerBinding?
  private var latched = false
  private var awaitingIdle = false
  public init() {}
  public mutating func event(code: UInt16, down: Bool, repeated: Bool,
                             binding: TriggerBinding?, canStart: Bool) -> KeyCycleAction {
    // IMK doesn't promise an ordinary typing keyUp for every keyDown. Only
    // supported hotkeys belong to this cycle; normal typing is independently
    // handled by VoiceKeyInterruptionPolicy and the original input pipeline.
    guard TriggerBinding.supportedCodes.contains(code) else { return .none }
    let freshPress = down && !held.contains(code)
    if down { held.insert(code) } else { held.remove(code) }
    if awaitingIdle {
      if held.isEmpty { awaitingIdle = false }; return .none
    }
    if let owner {
      if !down && owner.codes.contains(code) {
        self.owner = nil
        if let frozen, held.isDisjoint(with: frozen.codes) { latched = false; self.frozen = nil }
        return .stop
      }
      return .none
    }
    if latched {
      // Retain the frozen binding after cancellation/settings changes until ALL released.
      if let frozen, held.isDisjoint(with: frozen.codes) { latched = false; self.frozen = nil }
      return .none
    }
    guard freshPress, !repeated, let binding,
          binding.codes.contains(code), held == binding.codes else { return .none }
    guard canStart else { rejectBusyCycle(binding:binding); return .none }
    owner = binding; frozen = binding; latched = true
    return .start
  }
  private var frozen: TriggerBinding?
  public mutating func cancel() { owner = nil }
  public mutating func rejectBusyCycle(binding: TriggerBinding) {
    guard !held.isDisjoint(with:binding.codes) else { return }
    owner = nil; frozen = binding; latched = true
  }
  public mutating func lostLifecycle() { held = []; owner = nil; latched = true }
  public mutating func verifiedAllReleased() { held = []; owner = nil; frozen = nil; latched = false; awaitingIdle = false }
  public mutating func reconcileAfterActivation(pressed:Set<UInt16>) {
    held = pressed.intersection(TriggerBinding.supportedCodes); owner = nil
    if let frozen {
      if held.isDisjoint(with:frozen.codes) { self.frozen = nil; latched = false }
    } else {
      // An idle lifecycle loss has no owned cycle to wait for. Re-arm after
      // activation; awaitingIdle below still requires real external releases.
      latched = false
    }
    // A modifier pressed in another app is not an owned trigger. Wait for a
    // real release before arming, without consuming its original event path.
    awaitingIdle = !held.isEmpty
  }
  public var ownsRelease: Set<UInt16> { frozen?.codes ?? [] }
}

public struct LetterRepeatGuard {
  private var owned: Set<UInt16> = []
  public init() {}
  public func consumeRepeat(code: UInt16, isRepeat: Bool) -> Bool { isRepeat && owned.contains(code) }
  public func owns(code: UInt16) -> Bool { owned.contains(code) }
  public var ownedCodes:Set<UInt16> { owned }
  public mutating func accepted(code: UInt16) { owned.insert(code) }
  public mutating func released(code: UInt16) { owned.remove(code) }
  public mutating func reset() { owned = [] }
}
