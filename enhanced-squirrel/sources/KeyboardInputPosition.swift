import AppKit
import InputMethodKit

// One geometry query for both the ordinary candidate panel and voice. IMK's
// attributes index is relative to the inline session, not the document offset.
enum KeyboardInputPosition {
  static func caret(client: IMKTextInput) -> NSRect? {
    var rect = NSRect.zero
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
    if validCaret(rect) { return rect }
    let selection = client.selectedRange()
    if selection.location != NSNotFound, selection.location >= 0 {
      var actual = NSRange(location: NSNotFound, length: 0)
      rect = client.firstRect(forCharacterRange: NSRange(location: selection.location, length: 0), actualRange: &actual)
      if validCaret(rect) { return rect }
    }
    return nil
  }
  static func validCaret(_ rect: NSRect) -> Bool {
    [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0.isFinite } &&
      rect.size.width >= 0 && rect.size.height > 0 &&
      NSScreen.screens.contains { $0.frame.intersects(rect.insetBy(dx: -1, dy: -1)) }
  }
}
