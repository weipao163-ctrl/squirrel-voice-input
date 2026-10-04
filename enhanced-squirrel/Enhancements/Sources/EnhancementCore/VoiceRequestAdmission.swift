import Foundation

public enum VoiceAdmissionDecision: Equatable, Sendable {
  case start, duplicate, stoppedBeforeBegin, unavailable, invalidClock, capacityLimited
}

// Helper's main-queue production admission. No microphone/network operation.
// Do not rely on XPC delivery/main-queue dispatch ordering: a close arriving
// before begin must prohibit capture, not merely be discarded as an unknown ID.
public struct VoiceRequestAdmission: Sendable {
  public static let maximumRecords = 512
  private struct Record: Sendable {
    var identity:VoiceIdentity
    var attempted:Bool
    var active:Bool
    var receivedAt:TimeInterval
  }
  private var records:[Record] = []
  private var revokedBefore:TimeInterval?
  public var recordCount:Int { records.count }
  public init() {}
  private mutating func prune(at now:TimeInterval) {
    // Keep longer than the accepted 360-second origin horizon + clock skew.
    // Active records do not expire. No capacity eviction of closed identities.
    records.removeAll { !$0.active && now-$0.receivedAt > 360.5 }
  }
  public mutating func revokePending(at now:TimeInterval) {
    guard now.isFinite, now >= 0 else { return }
    revokedBefore=max(revokedBefore ?? now,now)
  }
  public mutating func admit(_ identity:VoiceIdentity, pressUptime:TimeInterval?,
                            receivedAt now:TimeInterval, canStart:Bool) -> VoiceAdmissionDecision {
    guard let origin=pressUptime,
          VoiceDiagnosticTimeline.validClock(origin,receivedAt:now) else { return .invalidClock }
    prune(at:now)
    if let index=records.firstIndex(where:{$0.identity == identity}) {
      if records[index].attempted { return .duplicate }
      records[index].attempted=true; return .stoppedBeforeBegin
    }
    if let cutoff=revokedBefore, origin <= cutoff { return .stoppedBeforeBegin }
    guard records.count < Self.maximumRecords else { return .capacityLimited }
    let allowed=canStart && !records.contains(where:{$0.active})
    records.append(Record(identity:identity,attempted:true,active:allowed,receivedAt:now))
    return allowed ? .start : .unavailable
  }
  // Return true only for an accepted active production identity. Unknown stop
  // still leaves a tombstone, but never terminates a different running session.
  @discardableResult public mutating func close(_ identity:VoiceIdentity, receivedAt now:TimeInterval) -> Bool {
    guard now.isFinite, now >= 0 else { return false }
    prune(at:now)
    if let index=records.firstIndex(where:{$0.identity == identity}) {
      let owned=records[index].active
      records[index].active=false; records[index].receivedAt=max(records[index].receivedAt,now)
      return owned
    }
    if records.count < Self.maximumRecords {
      records.append(Record(identity:identity,attempted:false,active:false,receivedAt:now))
    } else {
      // Fail closed under overflow; do not evict a stop then revive its delayed
      // begin. A genuine pre-stop press cannot exceed receipt clock + skew.
      revokePending(at:now+0.25)
    }
    return false
  }
}
