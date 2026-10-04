import Foundation

/// Caller serializes access. Connection identity is local routing, not peer authentication.
/// Pending menu intent survives a failed attempt; reopening still requires an explicit request.
public struct HelperLinkState: Sendable {
  public private(set) var connectionID: UUID?
  public private(set) var ready = false
  public private(set) var settingsPending = false
  public init() {}

  public mutating func reserve(_ id: UUID) -> Bool {
    guard connectionID == nil else { return false }
    connectionID = id; ready = false; return true
  }
  /// nil means stale/duplicate readiness; true means consume one pending menu request.
  public mutating func activate(_ id: UUID) -> Bool? {
    guard connectionID == id, !ready else { return nil }
    ready = true
    let show = settingsPending; settingsPending = false; return show
  }
  /// A ready connection can handle the menu immediately; otherwise retain one intent.
  public mutating func requestSettings() -> Bool {
    if ready { return true }
    settingsPending = true; return false
  }
  public func accepts(_ id: UUID) -> Bool { ready && connectionID == id }
  @discardableResult public mutating func end(_ id: UUID) -> Bool {
    guard connectionID == id else { return false }
    connectionID = nil; ready = false; return true
  }
  /// Only the current owning Process lifecycle may revoke a reserved connection.
  public mutating func ownerEnded() { connectionID = nil; ready = false }
}
