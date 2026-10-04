import Foundation

// A GUI test owns only its local editor snapshot, never a production target.
// The native caller claims this before insertText, so even a duplicate terminal
// update or an unknown native outcome cannot insert the same task twice.
public struct VoiceTestInsertion {
  public let identity:VoiceIdentity
  private let original:String
  private let range:NSRange
  private var valid=true
  private var attempted=false
  public init(identity:VoiceIdentity,text:String,selection:NSRange) {
    self.identity=identity; original=text; range=selection
    valid=selection.location != NSNotFound && selection.location >= 0 && selection.length >= 0 && selection.location <= (text as NSString).length &&
      selection.length <= (text as NSString).length-selection.location
  }
  public mutating func invalidate() { valid=false }
  public mutating func claim(identity:VoiceIdentity,phase:VoicePhase,complete:Bool,text:String,
                             current:String,selection:NSRange,focused:Bool,marked:Bool) -> NSRange? {
    guard self.identity == identity, phase == .ready, complete, valid, !attempted,
          focused, !marked, current == original, selection == range,
          !text.isEmpty, text.utf8.count <= 128*1024,
          !text.unicodeScalars.contains(where:{CharacterSet.controlCharacters.union(.newlines).contains($0)}) else { return nil }
    attempted=true; return range
  }
}
