import AppKit
import InputMethodKit
import ApplicationServices

// The active keyboard text client is authoritative. AX supplies optional
// identity/range/window evidence, never an application or editable-role list.
struct NativeVoiceTargetSnapshot {
  struct Window: Equatable {
    let number: CGWindowID
    let frame: NSRect
  }
  struct WindowCandidate {
    let processID: Int32
    let layer: Int32
    let window: Window
  }
  private let ranges: VoiceTargetSelection
  var selection: NSRange { ranges.native }
  let caret: NSRect?
  let window: Window
  let clientIdentifier: String?
  let windowLevel: CGWindowLevel

  static func allowsMissingMetadata(_ error: AXError) -> Bool {
    // A busy AX server does not revoke a working IMK text client. Permission
    // denial and invalid object identities still fail closed.
    error == .success || error == .noValue || error == .attributeUnsupported || error == .notImplemented || error == .cannotComplete
  }
  static func validSelection(_ range: NSRange) -> Bool {
    VoiceTargetSelection.valid(range)
  }
  static func capture(client: IMKTextInput, accessibilitySelection: NSRange? = nil,
      hasAccessibilityIdentity: Bool = false, windowAt: (NSRect?) -> Window?) -> Self? {
    let range = client.selectedRange(), marked = client.markedRange()
    guard (marked.length == 0 && marked.location >= 0) ||
      (marked.location == NSNotFound && marked.length == NSNotFound) else { return nil }
    // Freeze each supported/unsupported coordinate space, without inventing
    // offsets. Missing range APIs need independent native session evidence.
    guard let ranges = VoiceTargetSelection(native:range,accessibility:accessibilitySelection) else { return nil }
    let caret = KeyboardInputPosition.caret(client: client)
    let hasKnownSelection = validSelection(range) || accessibilitySelection.map(validSelection) == true
    // Some native hosts return a new identifier on every query (including
    // TextEdit). It must not override a working keyboard caret/range/window.
    // Only use it as supplementary evidence when a range or caret is absent,
    // and require two consecutive queries to identify the same session.
    var identifier: String?
    if !hasKnownSelection || caret == nil {
      let first: String? = client.uniqueClientIdentifierString()
      let second: String? = client.uniqueClientIdentifierString()
      if let first, !first.isEmpty, first == second { identifier = first }
    }
    if !hasKnownSelection { guard caret != nil,identifier != nil else { return nil } }
    // Placement is optional when field/window identity, a native session ID and
    // a known selection provide independent evidence of the keyboard target.
    if caret == nil {
      guard hasAccessibilityIdentity, identifier != nil,
            (range.location != NSNotFound || (accessibilitySelection?.location != nil && accessibilitySelection?.location != NSNotFound)),
            hasKnownSelection else { return nil }
    }
    guard let window = windowAt(caret) else { return nil }
    return Self(ranges: ranges, caret: caret, window: window, clientIdentifier: identifier, windowLevel: client.windowLevel())
  }
  func mismatch(client: IMKTextInput, accessibilitySelection: NSRange? = nil,
      hasAccessibilityIdentity: Bool = false, windowAt: (NSRect?) -> Window?) -> String? {
    guard let current = Self.capture(client:client,accessibilitySelection:accessibilitySelection,
      hasAccessibilityIdentity:hasAccessibilityIdentity,windowAt:windowAt) else { return "native-position-unavailable" }
    if !ranges.matches(native:current.selection,accessibility:accessibilitySelection) { return "native-selection-changed" }
    if caret != current.caret { return "native-caret-changed" }
    if window != current.window { return "native-window-changed" }
    if clientIdentifier != current.clientIdentifier { return "native-client-identifier-changed" }
    if windowLevel != current.windowLevel { return "native-window-level-changed" }
    return nil
  }
  func matches(client: IMKTextInput, accessibilitySelection: NSRange? = nil,
      hasAccessibilityIdentity: Bool = false, windowAt: (NSRect?) -> Window?) -> Bool {
    mismatch(client:client,accessibilitySelection:accessibilitySelection,
      hasAccessibilityIdentity:hasAccessibilityIdentity,windowAt:windowAt) == nil
  }
  static func accessibilityWindowFrame(_ window: AXUIElement) -> NSRect? {
    func attribute(_ key: String) -> AXValue? {
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(window,key as CFString,&value) == .success,
            let value,CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
      return unsafeBitCast(value,to:AXValue.self)
    }
    var position=CGPoint.zero, size=CGSize.zero
    guard let point=attribute(kAXPositionAttribute),let dimensions=attribute(kAXSizeAttribute),
          AXValueGetValue(point,.cgPoint,&position),AXValueGetValue(dimensions,.cgSize,&size),
          let top=NSScreen.screens.first?.frame.maxY,
          [position.x,position.y,size.width,size.height].allSatisfy({$0.isFinite}),
          size.width > 0,size.height > 0 else { return nil }
    return NSRect(x:position.x,y:top-position.y-size.height,width:size.width,height:size.height)
  }
  static func ownedWindow(processID: Int32, caret: NSRect?, candidates: [WindowCandidate],
      verifiedFrame: NSRect? = nil, windowLevel: CGWindowLevel = 0) -> Window? {
    let desktopLevel = CGWindowLevelForKey(.desktopIconWindow)
    let expectedFrame: NSRect?
    if let verifiedFrame, let caret,
       !verifiedFrame.insetBy(dx:-2,dy:-2).contains(NSPoint(x:caret.midX,y:caret.midY)) {
      expectedFrame = nil // Native popover outside its AX parent window.
    } else { expectedFrame = verifiedFrame }
    var firstOrdinaryWindow = true
    for candidate in candidates {
      guard candidate.processID == processID,
            candidate.layer == 0 || candidate.layer == windowLevel || candidate.layer == desktopLevel else { continue }
      let frame = candidate.window.frame
      if let expectedFrame {
        guard abs(frame.minX-expectedFrame.minX) <= 2, abs(frame.minY-expectedFrame.minY) <= 2,
              abs(frame.width-expectedFrame.width) <= 2, abs(frame.height-expectedFrame.height) <= 2 else { continue }
      } else if candidate.layer != desktopLevel {
        // Do not choose a covered, stale document window using caret alone.
        guard firstOrdinaryWindow else { continue }
        firstOrdinaryWindow = false
      }
      if let caret {
        if frame.insetBy(dx:-2,dy:-2).contains(NSPoint(x:caret.midX,y:caret.midY)) { return candidate.window }
      } else if expectedFrame != nil { return candidate.window }
    }
    return nil
  }
  static func frontWindow(processID: Int32, caret: NSRect?, verifiedFrame: NSRect? = nil,
      windowLevel: CGWindowLevel = 0) -> Window? {
    guard let top = NSScreen.screens.first?.frame.maxY,
          let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String:Any]] else { return nil }
    let candidates = windows.compactMap { info -> WindowCandidate? in
      guard let owner = info[kCGWindowOwnerPID as String] as? NSNumber,
            let layer = info[kCGWindowLayer as String] as? NSNumber,
            let number = info[kCGWindowNumber as String] as? NSNumber,
            let bounds = info[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation:bounds) else { return nil }
      let converted = NSRect(x:frame.minX,y:top-frame.maxY,width:frame.width,height:frame.height)
      return WindowCandidate(processID:owner.int32Value,layer:layer.int32Value,
        window:Window(number:number.uint32Value,frame:converted))
    }
    return ownedWindow(processID:processID,caret:caret,candidates:candidates,
      verifiedFrame:verifiedFrame,windowLevel:windowLevel)
  }
}
