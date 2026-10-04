import AppKit
import InputMethodKit
import ApplicationServices

// Some embedded web views implement IMK text input but expose no AX focused
// element. Use the same current-selection rectangle as the keyboard candidate
// panel, without inventing an absolute document offset or reading its text.
struct NativeVoiceTargetSnapshot {
  struct Window: Equatable {
    let number: CGWindowID
    let frame: NSRect
  }
  let selection: NSRange
  let caret: NSRect
  let window: Window
  private let finderRename: Bool

  static func allowsFallback(_ error: AXError) -> Bool {
    error == .noValue || error == .attributeUnsupported
  }
  static func allowsWindowFallback(bundleID: String, error: AXError) -> Bool {
    bundleID == "com.apple.finder" && allowsFallback(error)
  }
  static func capture(client: IMKTextInput, finderRename: Bool = false, windowAt: (NSRect) -> Window?) -> Self? {
    let range = client.selectedRange()
    // NSNotFound is retained as an unsupported offset. A known empty selection
    // and a verifiable on-screen caret are still required; unknown length fails.
    guard range.location >= 0 else { return nil }
    if finderRename {
      // Finder's inline filename editor selects the basename on entry. The
      // user's rename operation explicitly owns that selection. This exception
      // never applies to other apps, unknown replacement offsets, or marked
      // text. A known empty selection keeps the existing offset-less IMK path.
      guard client.bundleIdentifier() == "com.apple.finder",
            range.length != NSNotFound,range.length >= 0,range.length <= 1024,
            (range.length == 0 || range.location != NSNotFound),
            client.markedRange().location == NSNotFound else { return nil }
    } else if range.length != 0 { return nil }
    var rect = NSRect.zero
    // The index is relative to the inline session, not the document. With no
    // marked text, index 0 asks for the current selection (IMKInputSession.h).
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
    if finderRename && range.location != NSNotFound && !validCaret(rect) {
      var actual=NSRange(location:NSNotFound,length:0)
      rect=client.firstRect(forCharacterRange:NSRange(location:range.location,length:0),actualRange:&actual)
    }
    guard validCaret(rect), let window = windowAt(rect) else { return nil }
    return Self(selection: range, caret: rect, window: window, finderRename:finderRename)
  }
  func matches(client: IMKTextInput, windowAt: (NSRect) -> Window?) -> Bool {
    guard let current = Self.capture(client: client, finderRename:finderRename, windowAt: windowAt) else { return false }
    return selection == current.selection && caret == current.caret && window == current.window
  }
  static func validCaret(_ rect: NSRect) -> Bool {
    [rect.minX, rect.minY, rect.width, rect.height].allSatisfy { $0.isFinite } &&
      rect.size.width >= 0 && rect.size.height > 0 &&
      NSScreen.screens.contains { $0.frame.intersects(rect.insetBy(dx: -1, dy: -1)) }
  }
  static func frontWindow(processID: Int32, caret: NSRect, includeFinderDesktop: Bool = false) -> Window? {
    guard let top = NSScreen.screens.first?.frame.maxY,
          let windows = CGWindowListCopyWindowInfo(includeFinderDesktop ? [.optionOnScreenOnly] : [.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
    for info in windows {
      guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
            let layer=info[kCGWindowLayer as String] as? NSNumber,
            layer.int32Value == 0 || (includeFinderDesktop && layer.int32Value == CGWindowLevelForKey(.desktopIconWindow)),
            let number=info[kCGWindowNumber as String] as? NSNumber,
            let bounds=info[kCGWindowBounds as String] as? NSDictionary,
            let frame=CGRect(dictionaryRepresentation:bounds) else { continue }
      let converted=NSRect(x:frame.minX,y:top-frame.maxY,width:frame.width,height:frame.height)
      if converted.insetBy(dx:-2,dy:-2).contains(NSPoint(x:caret.midX,y:caret.midY)) {
        return Window(number:number.uint32Value,frame:converted)
      }
      if !includeFinderDesktop { return nil } // Preserve the usual top-window rule.
    }
    return nil
  }
}
