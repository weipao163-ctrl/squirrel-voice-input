import AppKit
import InputMethodKit
import ApplicationServices
import Carbon
import EnhancementCore

// All evidence is local and bounded: identity/ranges/change notifications, no document text.
final class EnhancementTarget {
  let client: IMKTextInput
  let generation: UInt64
  private let selection:VoiceTargetSelection?
  private let element: AXUIElement?
  private let window: AXUIElement?
  private let native: NativeVoiceTargetSnapshot?
  private let app: AXUIElement
  private let source: String
  private let processID:Int32
  private let bundleID:String
  private var observer: AXObserver?
  private var nativeMonitor: Any?
  private var nativeTimer: Timer?
  private var nativeWorkspaceObservers: [NSObjectProtocol] = []
  private(set) var valid = true
  var invalidated: (() -> Void)?

  enum CaptureFailure:Error {
    case unavailable, noFocusedElement(String,Int32), unsupportedRole, selectionUnavailable, selectedText, readonly, observerUnavailable, notificationUnavailable(String), nativePositionUnavailable
    var message:String {
      switch self {
      case .unavailable: return "输入法、目标应用或安全状态尚未匹配；请重新聚焦目标文本框。"
      case .noFocusedElement(let attribute,let code): return "目标应用的\(attribute)读取失败（AX \(code)）；请聚焦可编辑文本框。"
      case .unsupportedRole: return "当前焦点不是普通文本输入框，或属于安全输入框；无法启动语音。"
      case .selectionUnavailable: return "目标应用没有提供可验证的辅助功能光标范围；无法安全自动输入。"
      case .selectedText: return "请先取消已有文字选区，把光标放到要输入的位置，再按住热键。"
      case .readonly: return "当前输入框没有提供可验证的编辑能力；请聚焦可编辑文本框。"
      case .observerUnavailable: return "无法建立目标输入框的变化监听；请重新聚焦文本框再试。"
      case .notificationUnavailable(let notice): return "当前输入框不支持必要的位置变化监听（\(notice)）；无法保证语音输入原位置。"
      case .nativePositionUnavailable: return "当前应用未提供辅助功能输入框，原生输入会话也未提供可验证的选区或光标位置；请点击输入位置后重试。"
      }
    }
  }
  init(client: IMKTextInput, generation: UInt64) throws {
    guard !IsSecureEventInputEnabled(), AXIsProcessTrusted(),
          let front = NSWorkspace.shared.frontmostApplication, let bundleID=front.bundleIdentifier,
          !bundleID.isEmpty, bundleID == client.bundleIdentifier(),
          let source = SquirrelInstaller.currentInputSourceID(),
          source.hasPrefix("org.rime.inputmethod.SquirrelEnhanced.Development") else { throw CaptureFailure.unavailable }
    let app = AXUIElementCreateApplication(front.processIdentifier)
    self.client = client; self.generation = generation; self.app = app; self.source = source
    self.processID=front.processIdentifier; self.bundleID=bundleID
    // Called outside the synchronous IMK key callback. The host must first be
    // free to service accessibility IPC; 50 ms was too short for busy editors.
    AXUIElementSetMessagingTimeout(app, 0.3)
    func object(_ parent: AXUIElement, _ key: String) -> CFTypeRef? {
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(parent, key as CFString, &value) == .success else { return nil }
      return value
    }
    var focus:CFTypeRef?
    let focusError=AXUIElementCopyAttributeValue(app,kAXFocusedUIElementAttribute as CFString,&focus)
    if focusError != .success {
      // Unsupported AX metadata is a host capability gap, not a permission
      // failure. Never turn a timeout/denial/stale AX object into this fallback.
      guard NativeVoiceTargetSnapshot.allowsFallback(focusError) else {
        throw CaptureFailure.noFocusedElement("当前输入框",focusError.rawValue)
      }
      let range = client.selectedRange()
      let finderRename=bundleID == "com.apple.finder"
      if !finderRename && range.length != 0 && range.length != NSNotFound { throw CaptureFailure.selectedText }
      guard let snapshot = NativeVoiceTargetSnapshot.capture(client:client,finderRename:finderRename,windowAt: {
        NativeVoiceTargetSnapshot.frontWindow(processID:front.processIdentifier,caret:$0,includeFinderDesktop:finderRename)
      }) else { throw CaptureFailure.nativePositionUnavailable }
      self.selection=nil; self.element=nil; self.window=nil; self.native=snapshot
      try startNativeMonitoring()
      return
    }
    guard let focus,CFGetTypeID(focus) == AXUIElementGetTypeID() else {
      throw CaptureFailure.noFocusedElement("当前输入框",focusError.rawValue)
    }
    let element = unsafeBitCast(focus, to: AXUIElement.self)
    AXUIElementSetMessagingTimeout(element,0.3)
    var windowValue:CFTypeRef?
    let windowError=AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&windowValue)
    if NativeVoiceTargetSnapshot.allowsWindowFallback(bundleID:bundleID,error:windowError) {
      // Finder's inline rename editor can expose an AX focused element without
      // an AX focused window (including desktop icons). Its IMK selection,
      // caret and owned CG window still identify the real keyboard target.
      guard object(element,kAXSubroleAttribute) as? String != "AXSecureTextField" else { throw CaptureFailure.unsupportedRole }
      guard let snapshot=NativeVoiceTargetSnapshot.capture(client:client,finderRename:true,windowAt: {
        NativeVoiceTargetSnapshot.frontWindow(processID:front.processIdentifier,caret:$0,includeFinderDesktop:true)
      }) else { throw CaptureFailure.nativePositionUnavailable }
      self.selection=nil; self.element=element; self.window=nil; self.native=snapshot
      try startNativeMonitoring()
      return
    }
    guard windowError == .success,let focusWindow=windowValue,CFGetTypeID(focusWindow) == AXUIElementGetTypeID() else {
      throw CaptureFailure.noFocusedElement("当前窗口",windowError.rawValue)
    }
    let window = unsafeBitCast(focusWindow, to: AXUIElement.self)
    AXUIElementSetMessagingTimeout(element,0.3); AXUIElementSetMessagingTimeout(window,0.3)
    // AX roles secure/terminal-like editors are not auto-insertion targets.
    guard let role = object(element,kAXRoleAttribute) as? String,
          [kAXTextFieldRole, kAXTextAreaRole].contains(role),
          object(element,kAXSubroleAttribute) as? String != "AXSecureTextField" else { throw CaptureFailure.unsupportedRole }
    let nativeRange=client.selectedRange()
    guard let axRange=Self.selectedRange(element),axRange.location != NSNotFound else { throw CaptureFailure.selectionUnavailable }
    if bundleID == "com.apple.finder",role == kAXTextFieldRole,
       object(element,kAXSubroleAttribute) as? String != "AXSearchField",
       nativeRange.length > 0,nativeRange == axRange {
      // The same filename selection also needs to work when Finder DOES
      // supply its AX window. Keep the ordinary AX edit/change requirements.
      var writable:DarwinBoolean=false
      guard AXUIElementIsAttributeSettable(element,kAXValueAttribute as CFString,&writable) == .success,
            writable.boolValue else { throw CaptureFailure.readonly }
      guard let snapshot=NativeVoiceTargetSnapshot.capture(client:client,finderRename:true,windowAt: {
        NativeVoiceTargetSnapshot.frontWindow(processID:front.processIdentifier,caret:$0,includeFinderDesktop:true)
      }) else { throw CaptureFailure.nativePositionUnavailable }
      self.selection=nil; self.element=element; self.window=window; self.native=snapshot
      try startNativeMonitoring(requireAXChanges:true)
      return
    }
    guard nativeRange.length == 0,axRange.length == 0 else { throw CaptureFailure.selectedText }
    guard let selection=VoiceTargetSelection(native:nativeRange,accessibility:axRange) else { throw CaptureFailure.selectionUnavailable }
    var settable: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(element,kAXValueAttribute as CFString,&settable) == .success,
          settable.boolValue else { throw CaptureFailure.readonly }
    self.selection = selection; self.native=nil
    self.element = element; self.window = window
    var observer: AXObserver?
    let status = AXObserverCreate(front.processIdentifier, { _, _, _, refcon in
      guard let refcon else { return }
      let target = Unmanaged<EnhancementTarget>.fromOpaque(refcon).takeUnretainedValue()
      target.valid = false; target.invalidated?()
    }, &observer)
    guard status == .success, let observer else { throw CaptureFailure.observerUnavailable }
    self.observer = observer
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    // Value/selection/focus changes are mandatory. Element destruction is an
    // optional extra: unsupported destruction notices cannot block an otherwise
    // observable editor; final identity/range checks still reject a lost object.
    for (owner, notice) in [(app,kAXFocusedUIElementChangedNotification),
        (app,kAXFocusedWindowChangedNotification), (element,kAXValueChangedNotification),
        (element,kAXSelectedTextChangedNotification)] {
      guard AXObserverAddNotification(observer,owner,notice as CFString,refcon) == .success else { throw CaptureFailure.notificationUnavailable(notice) }
    }
    _ = AXObserverAddNotification(observer,element,kAXUIElementDestroyedNotification as CFString,refcon)
    CFRunLoopAddSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),.commonModes)
  }
  func invalidate() { valid = false }
  private func revoke() {
    guard valid else { return }
    valid=false; invalidated?()
  }
  private func startNativeMonitoring(requireAXChanges:Bool = false) throws {
    // A client proxy can be reused between fields. Revoke on any click, scroll,
    // ordinary key press, activation, session/space or screen change, even if
    // it subsequently returns to the same coordinates and range.
    nativeMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown,.scrollWheel,.keyDown]) { [weak self] event in
      if event.type != .keyDown || !event.isARepeat { self?.revoke() }
    }
    guard nativeMonitor != nil else { throw CaptureFailure.observerUnavailable }
    var extra:AXObserver?
    if AXObserverCreate(processID,{ _,_,_,refcon in
      guard let refcon else { return }
      Unmanaged<EnhancementTarget>.fromOpaque(refcon).takeUnretainedValue().revoke()
    },&extra) == .success,let extra {
      let refcon=Unmanaged.passUnretained(self).toOpaque()
      for notice in [kAXFocusedUIElementChangedNotification,kAXFocusedWindowChangedNotification] {
        let status=AXObserverAddNotification(extra,app,notice as CFString,refcon)
        if requireAXChanges,status != .success { throw CaptureFailure.notificationUnavailable(notice) }
      }
      if let element {
        for notice in [kAXValueChangedNotification,kAXSelectedTextChangedNotification] {
          let status=AXObserverAddNotification(extra,element,notice as CFString,refcon)
          if requireAXChanges,status != .success { throw CaptureFailure.notificationUnavailable(notice) }
        }
        _ = AXObserverAddNotification(extra,element,kAXUIElementDestroyedNotification as CFString,refcon)
      }
      observer=extra
      CFRunLoopAddSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(extra),.commonModes)
    } else if requireAXChanges { throw CaptureFailure.observerUnavailable }
    let center=NSWorkspace.shared.notificationCenter
    for notice in [NSWorkspace.didActivateApplicationNotification,NSWorkspace.didDeactivateApplicationNotification,
        NSWorkspace.sessionDidResignActiveNotification,NSWorkspace.activeSpaceDidChangeNotification,
        NSWorkspace.willSleepNotification] {
      nativeWorkspaceObservers.append(center.addObserver(forName:notice,object:nil,queue:.main) { [weak self] _ in self?.revoke() })
    }
    let timer=Timer(timeInterval:0.2,repeats:true) { [weak self] _ in
      guard let self,self.valid else { return }
      if !self.matches(client:self.client,generation:self.generation) { self.revoke() }
    }
    nativeTimer=timer
    RunLoop.main.add(timer,forMode:.common)
  }
  var verificationDescription: String {
    native == nil ? "辅助功能输入框" : (bundleID == "com.apple.finder" ? "Finder 改名原生输入会话" : "原生输入会话（网页兼容）")
  }
  func previewAnchor() -> NSRect? {
    if let native { return native.caret }
    guard let selection,let element else { return nil }
    // Placement is optional evidence. A host without caret bounds can still
    // use the verified insertion target and the default Dock position.
    var range=CFRange(location:selection.accessibility.location,length:0)
    if let argument=AXValueCreate(.cfRange,&range) {
      var value:CFTypeRef?
      if AXUIElementCopyParameterizedAttributeValue(element,kAXBoundsForRangeParameterizedAttribute as CFString,
          argument,&value) == .success,let value,CFGetTypeID(value) == AXValueGetTypeID() {
        var rect=CGRect.zero
        if AXValueGetValue(unsafeBitCast(value,to:AXValue.self),.cgRect,&rect),
           let primary=NSScreen.screens.first {
          // Accessibility uses a top-left origin on the primary display;
          // AppKit uses bottom-left, also for secondary display coordinates.
          let converted=NSRect(x:rect.minX,y:primary.frame.maxY-rect.maxY,width:rect.width,height:rect.height)
          if Self.validAnchor(converted) { return converted }
        }
      }
    }
    var rect=NSRect.zero
    client.attributes(forCharacterIndex:0,lineHeightRectangle:&rect)
    return Self.validAnchor(rect) ? rect : nil
  }
  private static func validAnchor(_ rect:NSRect) -> Bool {
    [rect.minX,rect.minY,rect.width,rect.height].allSatisfy({$0.isFinite}) && rect.width >= 0 && rect.height > 0 &&
      NSScreen.screens.contains { $0.frame.intersects(rect.insetBy(dx:-1,dy:-1)) }
  }
  func matches(client: IMKTextInput?, generation: UInt64) -> Bool {
    guard valid, self.generation == generation, let client,
          self.client === client, let front=NSWorkspace.shared.frontmostApplication,
          front.processIdentifier == processID, front.bundleIdentifier == bundleID,
          client.bundleIdentifier() == bundleID, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
          SquirrelInstaller.currentInputSourceID() == source else { return false }
    if let native {
      if let element {
        // Preserve any available AX field identity even when only its window
        // metadata is absent. A proxy at the same coordinates cannot replace it.
        var focused:CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,kAXFocusedUIElementAttribute as CFString,&focused) == .success,
              let focused,CFGetTypeID(focused) == AXUIElementGetTypeID(),CFEqual(focused,element) else { return false }
        var subrole:CFTypeRef?
        if AXUIElementCopyAttributeValue(element,kAXSubroleAttribute as CFString,&subrole) == .success,
           subrole as? String == "AXSecureTextField" { return false }
        if let window {
          var focusedWindow:CFTypeRef?
          var writable:DarwinBoolean=false
          guard AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&focusedWindow) == .success,
                let focusedWindow,CFGetTypeID(focusedWindow) == AXUIElementGetTypeID(),CFEqual(focusedWindow,window),
                AXUIElementIsAttributeSettable(element,kAXValueAttribute as CFString,&writable) == .success,
                writable.boolValue,Self.selectedRange(element) == native.selection else { return false }
        }
      }
      return native.matches(client:client,windowAt: {
        NativeVoiceTargetSnapshot.frontWindow(processID:self.processID,caret:$0,includeFinderDesktop:self.bundleID == "com.apple.finder")
      })
    }
    guard let selection,let element,let window,
          selection.matches(native:client.selectedRange(),accessibility:Self.selectedRange(element)) else { return false }
    func attribute(_ key:String) -> CFTypeRef? {
      var value:CFTypeRef?
      guard AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success else { return nil }
      return value
    }
    var writable:DarwinBoolean=false
    guard AXUIElementIsAttributeSettable(element,kAXValueAttribute as CFString,&writable) == .success,
          VoiceTargetEligibility.currentlyEligible(expectedPID:processID,expectedBundle:bundleID,
            currentPID:front.processIdentifier,currentBundle:front.bundleIdentifier,clientBundle:client.bundleIdentifier(),
            trusted:AXIsProcessTrusted(),secureInput:IsSecureEventInputEnabled(),
            role:attribute(kAXRoleAttribute) as? String,subrole:attribute(kAXSubroleAttribute) as? String,
            writable:writable.boolValue) else { return false }
    func equal(_ key:String, _ original:AXUIElement) -> Bool {
      var value:CFTypeRef?
      guard AXUIElementCopyAttributeValue(app,key as CFString,&value) == .success, let value else { return false }
      return CFEqual(value, original)
    }
    return equal(kAXFocusedUIElementAttribute,element) && equal(kAXFocusedWindowAttribute,window)
  }
  private static func selectedRange(_ element:AXUIElement) -> NSRange? {
    var value:CFTypeRef?
    guard AXUIElementCopyAttributeValue(element,kAXSelectedTextRangeAttribute as CFString,&value) == .success,
          let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var range = CFRange()
    guard AXValueGetValue(unsafeBitCast(value,to:AXValue.self),.cfRange,&range),
          range.location >= 0, range.length >= 0 else { return nil }
    return NSRange(location:range.location,length:range.length)
  }
  deinit {
    nativeTimer?.invalidate()
    if let nativeMonitor { NSEvent.removeMonitor(nativeMonitor) }
    for token in nativeWorkspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(observer),.commonModes) }
  }
}
