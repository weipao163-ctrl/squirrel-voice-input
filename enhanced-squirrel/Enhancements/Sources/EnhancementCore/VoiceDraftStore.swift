import Foundation

public struct VoiceDraftStore {
  public private(set) var identity:VoiceIdentity?
  public private(set) var text=""
  public private(set) var phase:VoicePhase = .cancelled
  public private(set) var complete=false
  private var sealed=true
  private var suppressed=false
  public init() {}
  public var canCopy:Bool { !text.isEmpty && [.ready,.review,.failed].contains(phase) }
  @discardableResult public mutating func begin(_ identity:VoiceIdentity) -> Bool {
    guard self.identity != identity else { return false }
    let replacing = !text.isEmpty
    self.identity=identity; text=""; complete=false; phase = .preparing
    sealed=false; suppressed=false; return replacing
  }
  @discardableResult public mutating func accept(_ identity:VoiceIdentity, phase:VoicePhase,
                                               text:String, complete:Bool) -> Bool {
    guard self.identity == identity, !sealed, text.utf8.count <= 128*1024 else { return false }
    self.phase=phase
    self.text = suppressed || phase == .cancelled ? "" : text
    self.complete = !self.text.isEmpty && complete && [.ready,.review].contains(phase)
    if [.ready,.review,.failed,.cancelled].contains(phase) { sealed=true }
    return true
  }
  public mutating func discard() {
    text=""; complete=false; suppressed=true // Current queued callbacks may not refill it.
  }
  public mutating func clear() {
    identity=nil; text=""; complete=false; phase = .cancelled; sealed=true; suppressed=true
  }
}
