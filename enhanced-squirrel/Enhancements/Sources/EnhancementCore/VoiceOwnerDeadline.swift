import Foundation

// Last-resort frontend bound, independent of Helper queues and callbacks.
// Repeated stop/lease/status events never move an existing deadline later.
public struct VoiceOwnerDeadline {
  public private(set) var deadline: TimeInterval
  private let finishAllowance: TimeInterval
  public init(startedAt:TimeInterval, settings:VoiceSettings) {
    finishAllowance = Double(settings.finalizeSeconds) + 10
    deadline = startedAt + Double(settings.maximumSeconds + settings.connectSeconds + settings.taskStartSeconds) + finishAllowance
  }
  public mutating func stop(at uptime:TimeInterval) {
    guard uptime.isFinite else { return }
    deadline = min(deadline, uptime + finishAllowance)
  }
  public func expired(at uptime:TimeInterval) -> Bool { uptime >= deadline }
}
