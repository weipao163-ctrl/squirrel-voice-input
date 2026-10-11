import AppKit
import InputMethodKit
import ApplicationServices
import Carbon
import EnhancementCore

// Bind the same active IMK client used for normal typing. AX is supplementary
// evidence, not a prerequisite list of roles, applications or settable values.
final class EnhancementTarget {
  let client: IMKTextInput
  let generation: UInt64
  private let element: AXUIElement?
  private let window: AXUIElement?
  private let accessibilitySelection: NSRange?
  private let native: NativeVoiceTargetSnapshot
  private let windowFrame: NSRect?
  private let app: AXUIElement
  private let source: String
  private let processID: Int32
  private let bundleID: String
  private let ownedKeyCodes: Set<UInt16>
  private var observer: AXObserver?
  private var nativeMonitor: Any?
  private var nativeTimer: Timer?
  private var nativeWorkspaceObservers: [NSObjectProtocol] = []
  private lazy var monitoring = VoiceTargetMonitor(verify: { [weak self] in
    self?.verification() ?? .changed("target-released")
  }, invalidated: { [weak self] reason in
    self?.mismatchReason = reason; self?.revoke()
  })
  private(set) var valid = true
  private(set) var mismatchReason: String?
  var invalidated: (() -> Void)?

  enum CaptureFailure: Error {
    case unavailable, noFocusedElement(String,Int32), unsupportedRole, observerUnavailable, nativePositionUnavailable
    var message: String {
      switch self {
      case .unavailable: return "输入法、目标应用或安全状态尚未匹配；请重新聚焦目标文本框。"
      case .noFocusedElement(let attribute,let code): return "目标应用的\(attribute)读取失败（AX \(code)）；请聚焦可编辑文本框。"
      case .unsupportedRole: return "当前处于安全输入或控件已禁用，无法启动语音。"
      case .observerUnavailable: return "无法建立输入位置变化监听；请检查输入法焦点检测权限。"
      case .nativePositionUnavailable: return "当前键盘输入会话未提供可验证的位置；请点击可输入位置后重试。"
      }
    }
  }
  init(client: IMKTextInput, generation: UInt64, ownedKeyCodes: Set<UInt16> = []) throws {
    guard let front = NSWorkspace.shared.frontmostApplication, let bundleID = front.bundleIdentifier,
          VoiceTargetEligibility.currentlyEligible(expectedPID:front.processIdentifier,expectedBundle:bundleID,
            currentPID:front.processIdentifier,currentBundle:bundleID,clientBundle:client.bundleIdentifier(),
            trusted:AXIsProcessTrusted(),secureInput:IsSecureEventInputEnabled(),subrole:nil,enabled:nil),
          let source = SquirrelInstaller.currentInputSourceID(),
          source.hasPrefix("org.rime.inputmethod.SquirrelEnhanced.Development") else { throw CaptureFailure.unavailable }
    let app = AXUIElementCreateApplication(front.processIdentifier)
    self.client = client; self.generation = generation; self.app = app; self.source = source
    self.processID = front.processIdentifier; self.bundleID = bundleID; self.ownedKeyCodes = ownedKeyCodes
    // Outside the synchronous key callback, so the text host can service IPC.
    AXUIElementSetMessagingTimeout(app,0.1)
    func focused(_ key: String) throws -> AXUIElement? {
      var value: CFTypeRef?
      let status = AXUIElementCopyAttributeValue(app,key as CFString,&value)
      guard NativeVoiceTargetSnapshot.allowsMissingMetadata(status) else {
        throw CaptureFailure.noFocusedElement(key == kAXFocusedWindowAttribute ? "当前窗口" : "当前输入框",status.rawValue)
      }
      guard status == .success,let value,CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
      return unsafeBitCast(value,to:AXUIElement.self)
    }
    let element = try focused(kAXFocusedUIElementAttribute)
    let window = try focused(kAXFocusedWindowAttribute)
    if let element { AXUIElementSetMessagingTimeout(element,0.1) }
    if let window { AXUIElementSetMessagingTimeout(window,0.1) }
    guard Self.safe(element) else { throw CaptureFailure.unsupportedRole }
    let axRange = element.flatMap(Self.selectedRange)
    let frame = window.flatMap(NativeVoiceTargetSnapshot.accessibilityWindowFrame)
    guard let snapshot = NativeVoiceTargetSnapshot.capture(client:client,accessibilitySelection:axRange,
        hasAccessibilityIdentity:element != nil && window != nil,windowAt: {
          NativeVoiceTargetSnapshot.frontWindow(processID:front.processIdentifier,caret:$0,
            verifiedFrame:frame,windowLevel:client.windowLevel())
        }) else { throw CaptureFailure.nativePositionUnavailable }
    self.element = element; self.window = window; self.accessibilitySelection = axRange
    self.native = snapshot; self.windowFrame = frame
    try startNativeMonitoring()
  }
  func invalidate() { valid = false; monitoring.invalidate() }
  private func revoke() {
    guard valid else { return }
    valid = false; monitoring.invalidate(); invalidated?()
  }
  private static func safe(_ element: AXUIElement?) -> Bool {
    guard let element else { return true }
    func attribute(_ key: String) -> CFTypeRef? {
      var value: CFTypeRef?
      guard AXUIElementCopyAttributeValue(element,key as CFString,&value) == .success else { return nil }
      return value
    }
    return attribute(kAXSubroleAttribute) as? String != "AXSecureTextField" &&
      attribute(kAXRoleAttribute) as? String != "AXSecureTextField" &&
      attribute(kAXEnabledAttribute) as? Bool != false
  }
  private func startNativeMonitoring() throws {
    // A client proxy can be reused between fields. Clicks and ordinary key
    // presses revoke even if the caret later returns to its original position.
    // Scroll/AX/workspace hints verify actual ownership; idle redraws or an
    // unrelated background activation must not synthesize a physical release.
    nativeMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown,.scrollWheel,.keyDown]) { [weak self] event in
      guard let self else { return }
      if event.type == .keyDown && (event.isARepeat || self.ownedKeyCodes.contains(event.keyCode)) { return }
      if event.type == .scrollWheel { self.monitoring.scheduleInspection() }
      else { self.revoke() }
    }
    guard nativeMonitor != nil else { throw CaptureFailure.observerUnavailable }
    var extra:AXObserver?
    if AXObserverCreate(processID,{ _,_,notice,refcon in
      guard let refcon else { return }
      let target = Unmanaged<EnhancementTarget>.fromOpaque(refcon).takeUnretainedValue()
      if notice as String == kAXUIElementDestroyedNotification { target.revoke() }
      else { target.monitoring.scheduleInspection() }
    },&extra) == .success,let extra {
      let refcon=Unmanaged.passUnretained(self).toOpaque()
      for notice in [kAXFocusedUIElementChangedNotification,kAXFocusedWindowChangedNotification] {
        _ = AXObserverAddNotification(extra,app,notice as CFString,refcon)
      }
      if let element {
        for notice in [kAXValueChangedNotification,kAXSelectedTextChangedNotification] {
          _ = AXObserverAddNotification(extra,element,notice as CFString,refcon)
        }
        _ = AXObserverAddNotification(extra,element,kAXUIElementDestroyedNotification as CFString,refcon)
      }
      observer=extra
      CFRunLoopAddSource(CFRunLoopGetMain(),AXObserverGetRunLoopSource(extra),.commonModes)
    }
    let center=NSWorkspace.shared.notificationCenter
    for notice in [NSWorkspace.didActivateApplicationNotification,NSWorkspace.didDeactivateApplicationNotification,
        NSWorkspace.sessionDidResignActiveNotification,NSWorkspace.activeSpaceDidChangeNotification,
        NSWorkspace.willSleepNotification] {
      nativeWorkspaceObservers.append(center.addObserver(forName:notice,object:nil,queue:.main) { [weak self] _ in
        if notice == NSWorkspace.didActivateApplicationNotification || notice == NSWorkspace.didDeactivateApplicationNotification {
          self?.monitoring.scheduleInspection()
        } else { self?.revoke() }
      })
    }
    let timer=Timer(timeInterval:0.2,repeats:true) { [weak self] _ in
      guard let self,self.valid else { return }
      self.monitoring.inspect()
    }
    nativeTimer=timer
    RunLoop.main.add(timer,forMode:.common)
  }
  var verificationDescription: String { "原生键盘输入会话" }
  func previewAnchor() -> NSRect? { native.caret }
  func matches(client: IMKTextInput?, generation: UInt64) -> Bool {
    guard valid, self.generation == generation, let client, self.client === client else { return false }
    return monitoring.inspect()
  }
  func verifyForDelivery(client: IMKTextInput?, generation: UInt64, completion: @escaping (Bool) -> Void) {
    guard valid, self.generation == generation, let client, self.client === client else { completion(false); return }
    monitoring.verifyForDelivery { [weak self] verified in completion(verified && self?.valid == true) }
  }
  private func verification() -> VoiceTargetMonitor.Verification {
    mismatchReason = nil
    func changed(_ reason: String) -> VoiceTargetMonitor.Verification { mismatchReason = reason; return .changed(reason) }
    func unavailable(_ reason: String) -> VoiceTargetMonitor.Verification { mismatchReason = reason; return .unavailable(reason) }
    guard valid, let front = NSWorkspace.shared.frontmostApplication,
          VoiceTargetEligibility.currentlyEligible(expectedPID:processID,expectedBundle:bundleID,
            currentPID:front.processIdentifier,currentBundle:front.bundleIdentifier,clientBundle:client.bundleIdentifier(),
            trusted:AXIsProcessTrusted(),secureInput:IsSecureEventInputEnabled(),subrole:nil,enabled:nil),
          SquirrelInstaller.currentInputSourceID() == source else { return changed("input-session-or-security-changed") }
    func current(_ key: String) -> (AXUIElement?, AXError) {
      var value: CFTypeRef?
      let status = AXUIElementCopyAttributeValue(app,key as CFString,&value)
      guard status == .success,let value,CFGetTypeID(value) == AXUIElementGetTypeID() else { return (nil,status) }
      return (unsafeBitCast(value,to:AXUIElement.self),status)
    }
    let (focused,focusStatus) = current(kAXFocusedUIElementAttribute)
    if !NativeVoiceTargetSnapshot.allowsMissingMetadata(focusStatus) { return changed("ax-security-or-permission-changed") }
    if focusStatus == .cannotComplete { return unavailable("ax-input-temporarily-unavailable") }
    let (focusedWindow,windowStatus) = current(kAXFocusedWindowAttribute)
    if !NativeVoiceTargetSnapshot.allowsMissingMetadata(windowStatus) { return changed("ax-security-or-permission-changed") }
    if windowStatus == .cannotComplete { return unavailable("ax-window-temporarily-unavailable") }
    if let element {
      guard let focused else { return unavailable("ax-input-temporarily-unavailable") }
      guard CFEqual(focused,element) else { return changed("ax-input-identity-changed") }
      let selection = Self.selectedRange(element)
      if accessibilitySelection != nil && selection == nil { return unavailable("ax-selection-temporarily-unavailable") }
      guard selection == accessibilitySelection else { return changed("ax-selection-changed") }
    }
    if let window {
      guard let focusedWindow else { return unavailable("ax-window-temporarily-unavailable") }
      guard CFEqual(focusedWindow,window) else { return changed("ax-window-identity-changed") }
    }
    guard Self.safe(focused) else { return changed("ax-security-or-permission-changed") }
    let frame = focusedWindow.flatMap(NativeVoiceTargetSnapshot.accessibilityWindowFrame)
    if let windowFrame {
      guard let frame else { return unavailable("ax-window-frame-temporarily-unavailable") }
      guard frame == windowFrame else { return changed("ax-window-frame-changed") }
    }
    if let reason = native.mismatch(client:client,accessibilitySelection:accessibilitySelection,
      hasAccessibilityIdentity:element != nil && window != nil,windowAt: {
        NativeVoiceTargetSnapshot.frontWindow(processID:self.processID,caret:$0,
          verifiedFrame:self.windowFrame,windowLevel:client.windowLevel())
      }) {
      if reason == "native-position-unavailable" { return unavailable(reason) }
      return changed(reason)
    }
    return .verified
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
