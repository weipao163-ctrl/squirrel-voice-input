import Foundation

// Freeze native and optional AX coordinate spaces independently. Selected text
// follows normal keyboard replacement semantics, only while both ranges stay
// unchanged. This type performs no text/AX/IME writes or geometry queries.
struct VoiceTargetSelection {
  let native: NSRange
  let accessibility: NSRange?
  static func valid(_ range: NSRange) -> Bool {
    guard range.location >= 0,range.length >= 0,range.length != NSNotFound else { return false }
    if range.location == NSNotFound { return range.length == 0 }
    return range.length <= Int.max-range.location
  }
  init?(native: NSRange,accessibility: NSRange?) {
    func supportedOrUnknown(_ range: NSRange) -> Bool {
      Self.valid(range) || (range.location == NSNotFound && range.length == NSNotFound)
    }
    if let accessibility { guard supportedOrUnknown(accessibility) else { return nil } }
    guard supportedOrUnknown(native) else { return nil }
    self.native = native; self.accessibility = accessibility
  }
  func matches(native: NSRange,accessibility: NSRange?) -> Bool {
    native == self.native && accessibility == self.accessibility
  }
}
