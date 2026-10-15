import AppKit
import InputMethodKit

// One geometry query for both the ordinary candidate panel and voice. IMK's
// attributes index is relative to the inline session, not the document offset.
enum KeyboardInputPosition {
  enum Source: String { case attributes, firstRect, unavailable }
  struct Query { let rect: NSRect?; let source: Source }
  static func caret(client: IMKTextInput) -> NSRect? {
    query(client: client).rect
  }
  static func query(client: IMKTextInput) -> Query {
    var rect = NSRect.zero
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
    if let rect = normalizedCaret(rect) { return Query(rect: rect, source: .attributes) }
    let selection = client.selectedRange()
    if selection.location != NSNotFound, selection.location >= 0 {
      var actual = NSRange(location: NSNotFound, length: 0)
      rect = client.firstRect(forCharacterRange: NSRange(location: selection.location, length: 0), actualRange: &actual)
      if let rect = normalizedCaret(rect) { return Query(rect: rect, source: .firstRect) }
    }
    return Query(rect: nil, source: .unavailable)
  }
  static func validCaret(_ rect: NSRect) -> Bool {
    normalizedCaret(rect) != nil
  }
  static func normalizedCaret(_ rect: NSRect) -> NSRect? {
    // NSTextInputClient explicitly allows directed rectangles (for example
    // right-to-left text). Validate raw components before standardizing; never
    // invent a height or treat the zero rectangle as a valid insertion point.
    guard [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy({ $0.isFinite }),
          rect.size.height != 0 else { return nil }
    let rect = rect.standardized
    guard NSScreen.screens.contains(where: { $0.frame.intersects(rect.insetBy(dx: -1, dy: -1)) }) else { return nil }
    return rect
  }
}
