import Foundation

// Per-controller stop ownership, not a physical-key state machine. A target
// revocation and a real release are distinct; only the key owner may rearm.
public struct VoiceStopRelay {
  private var identity:VoiceIdentity?
  public private(set) var released=false
  private var invalidationSent=false
  public init() {}
  public mutating func begin(_ identity:VoiceIdentity) {
    self.identity=identity; released=false; invalidationSent=false
  }
  public mutating func release(_ identity:VoiceIdentity, at uptime:TimeInterval) -> VoiceRelease? {
    guard self.identity == identity, !released, uptime.isFinite, uptime >= 0 else { return nil }
    released=true; return VoiceRelease(identity:identity,uptime:uptime)
  }
  public mutating func invalidate(_ identity:VoiceIdentity, at uptime:TimeInterval) -> VoiceRelease? {
    // A real release stops capture, NOT target observation. A later edit must
    // still revoke the helper's insertion eligibility without moving deadline.
    guard self.identity == identity, !invalidationSent,
          uptime.isFinite, uptime >= 0 else { return nil }
    invalidationSent=true; released=true
    return VoiceRelease(identity:identity,uptime:uptime,cause:.targetInvalidated)
  }
}
