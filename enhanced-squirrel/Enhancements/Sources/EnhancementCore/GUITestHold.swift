import Foundation

public enum GUITestHoldInput: Hashable, Sendable { case mouse, space }
public enum GUITestHoldAction: Equatable, Sendable {
  case none, start(UUID), release(UUID), cancel(UUID)
}

// The real settings control uses this gesture state; it is never a production
// trigger or a click-to-toggle recorder. One source owns each physical gesture.
public struct GUITestHoldCycle: Sendable {
  public private(set) var held: Set<GUITestHoldInput> = []
  public private(set) var activeID: UUID?
  private var activeInput: GUITestHoldInput?
  public var needsReleaseObservation: Bool { !held.isEmpty }
  public init() {}
  public mutating func press(_ input: GUITestHoldInput, repeated: Bool = false) -> GUITestHoldAction {
    let fresh = held.insert(input).inserted
    guard fresh, !repeated, held.count == 1, activeID == nil else { return .none }
    let id = UUID(); activeID = id; activeInput = input
    return .start(id)
  }
  public mutating func release(_ input: GUITestHoldInput) -> GUITestHoldAction {
    held.remove(input)
    guard activeInput == input, let id = activeID else { return .none }
    activeInput = nil; activeID = nil
    return .release(id)
  }
  public mutating func cancel() -> GUITestHoldAction {
    guard let id = activeID else { return .none }
    activeInput = nil; activeID = nil
    // Retain held sources: repeats cannot start a task after cancellation.
    return .cancel(id)
  }
}

// Both GUI controls share this owner in HelperModel. A rejected control's up,
// cancellation or late audio callback must never stop a different GUI test.
public struct GUITestHoldOwner: Sendable {
  public private(set) var id: UUID?
  public init() {}
  public mutating func begin(_ value: UUID) -> Bool {
    guard id == nil else { return false }; id = value; return true
  }
  public func owns(_ value: UUID) -> Bool { id == value }
  public mutating func finish(_ value: UUID) -> Bool {
    guard owns(value) else { return false }; id = nil; return true
  }
  public mutating func cancelAll() { id = nil }
}
