import AppKit
import ApplicationServices
import Carbon
import EnhancementCore

protocol MouseVoiceAnchorChecking: AnyObject {
  func matches(at point: NSPoint) -> Bool
}

// Mouse gestures need stronger hit evidence than an explicit keyboard hotkey:
// a stale IMK client must never make a held button or read-only label record.
final class MouseVoiceAnchor: MouseVoiceAnchorChecking {
  private let element: AXUIElement
  private let processID: Int32
  private let bundle: String
  private init(element: AXUIElement, processID: Int32, bundle: String) {
    self.element = element; self.processID = processID; self.bundle = bundle
  }
  static func capture(at point: NSPoint) -> MouseVoiceAnchor? {
    guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
          let front = NSWorkspace.shared.frontmostApplication,
          let bundle = front.bundleIdentifier, !MouseVoicePolicy.excludes(bundle: bundle),
          let top = NSScreen.screens.first?.frame.maxY,
          point.x.isFinite, point.y.isFinite else { return nil }
    let app = AXUIElementCreateApplication(front.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 0.08)
    func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
      var value: CFTypeRef?
      return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    guard let raw = attribute(app, kAXFocusedUIElementAttribute),
          CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
    let focused = unsafeBitCast(raw, to: AXUIElement.self)
    AXUIElementSetMessagingTimeout(focused, 0.08)
    let role = attribute(focused, kAXRoleAttribute) as? String
    guard ["AXTextField", "AXTextArea", "AXComboBox"].contains(role ?? ""),
          attribute(focused, kAXSubroleAttribute) as? String != "AXSecureTextField",
          attribute(focused, kAXEnabledAttribute) as? Bool != false else { return nil }
    var writable = DarwinBoolean(false)
    let canSetValue = AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &writable) == .success && writable.boolValue
    guard MouseVoicePolicy.allowsFocusedElement(role: role,
      subrole: attribute(focused, kAXSubroleAttribute) as? String,
      enabled: attribute(focused, kAXEnabledAttribute) as? Bool,
      writable: canSetValue || attribute(focused, "AXEditable") as? Bool == true) else { return nil }
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(top - point.y), &hit) == .success,
          var current = hit else { return nil }
    // Text can be a child of the editable element; embedded buttons are not
    // recording targets, even when the text field remains keyboard-focused.
    for _ in 0..<8 {
      AXUIElementSetMessagingTimeout(current, 0.08)
      if CFEqual(current, focused) {
        return MouseVoiceAnchor(element: focused, processID: front.processIdentifier, bundle: bundle)
      }
      let hitRole = attribute(current, kAXRoleAttribute) as? String
      guard !["AXButton", "AXPopUpButton", "AXMenuItem", "AXLink", "AXScrollBar"].contains(hitRole ?? ""),
            let parent = attribute(current, kAXParentAttribute),
            CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
      current = unsafeBitCast(parent, to: AXUIElement.self)
    }
    return nil
  }
  func matches(at point: NSPoint) -> Bool {
    guard let current = Self.capture(at: point) else { return false }
    return processID == current.processID && bundle == current.bundle && CFEqual(element, current.element)
  }
}

// Passive observation only: never swallow/synthesize a mouse event or change
// focus. One instance belongs to the currently active input controller.
final class MouseVoiceTrigger {
  private var cycle: MouseHoldCycle
  let holdSeconds: TimeInterval
  private var epoch = UUID()
  private var anchor: MouseVoiceAnchorChecking?
  private var origin = NSPoint.zero
  private var recognizeAt: TimeInterval = 0
  private var timer: Timer?
  private var buttonTimer: Timer?
  private var monitor: Any?
  private var observers: [NSObjectProtocol] = []
  private var sourceObserver: NSObjectProtocol?
  private let canStart: () -> Bool
  private let begin: (TimeInterval) -> Bool
  private let stop: (TimeInterval) -> Void
  private let cancel: () -> Void
  private let capture: (NSPoint) -> MouseVoiceAnchorChecking?
  private let clock: () -> TimeInterval
  private let leftPressed: () -> Bool
  private let location: () -> NSPoint
  private let monitorEvents: Bool
  private let automaticTimers: Bool
  var available: Bool { !monitorEvents || monitor != nil }

  init(holdSeconds: TimeInterval = MouseHoldTiming.defaultSeconds,
       canStart: @escaping () -> Bool, begin: @escaping (TimeInterval) -> Bool,
       stop: @escaping (TimeInterval) -> Void, cancel: @escaping () -> Void,
       capture: @escaping (NSPoint) -> MouseVoiceAnchorChecking? = { MouseVoiceAnchor.capture(at: $0) },
       clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
       leftPressed: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 },
       location: @escaping () -> NSPoint = { NSEvent.mouseLocation }, monitorEvents: Bool = true,
       automaticTimers: Bool? = nil) {
    self.holdSeconds = holdSeconds; self.cycle = MouseHoldCycle(holdSeconds: holdSeconds)
    self.canStart = canStart; self.begin = begin; self.stop = stop; self.cancel = cancel
    self.capture = capture; self.clock = clock; self.leftPressed = leftPressed
    self.location = location; self.monitorEvents = monitorEvents
    self.automaticTimers = automaticTimers ?? monitorEvents
    guard monitorEvents else { return }
    monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown, .flagsChanged]) { [weak self] event in
      self?.handle(event)
    }
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification,
        NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.interrupt() })
    }
    sourceObserver = DistributedNotificationCenter.default().addObserver(
      forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
    ) { [weak self] _ in self?.interrupt() }
  }
  private func eventPoint(_ event: NSEvent) -> NSPoint {
    guard let point = event.cgEvent?.location, let top = NSScreen.screens.first?.frame.maxY else { return location() }
    return NSPoint(x: point.x, y: top - point.y)
  }
  private func handle(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      press(at: event.timestamp, point: eventPoint(event), singleClick: event.clickCount == 1,
            modified: !event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty)
    case .leftMouseUp: release(at: event.timestamp)
    case .leftMouseDragged: moved(to: eventPoint(event))
    default: interrupt()
    }
  }
  func press(at now: TimeInterval, point: NSPoint, singleClick: Bool = true, modified: Bool = false) {
    let armed = cycle.press(at: now, x: point.x, y: point.y, eligible: canStart(), singleClick: singleClick, modified: modified)
    if automaticTimers, cycle.held, buttonTimer == nil {
      // Global AppKit monitors exclude events delivered to this process. Check
      // the physical release only WHILE held, so an up over our own panel or a
      // missing event still ends capture and rearms the next genuine press.
      let watcher = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.checkButtonState() }
      buttonTimer = watcher; RunLoop.main.add(watcher, forMode: .common)
    }
    guard armed else { return }
    epoch = UUID(); let token = epoch; origin = point; recognizeAt = now + holdSeconds
    guard automaticTimers else { return }
    // Let the application's ordinary click place the caret before AX queries.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
      guard let self, self.epoch == token else { return }; self.capturePendingAnchor()
    }
    scheduleDeadline(token)
  }
  private func scheduleDeadline(_ token: UUID) {
    let timer = Timer(timeInterval: max(0.001, recognizeAt - clock()), repeats: false) { [weak self] _ in
      guard let self, self.epoch == token else { return }; self.deadline()
    }
    self.timer = timer; RunLoop.main.add(timer, forMode: .common)
  }
  func capturePendingAnchor() {
    guard cycle.pending, leftPressed(), canStart() else { interrupt(); return }
    let token = epoch
    let result = capture(origin)
    guard epoch == token else { return }
    guard cycle.pending, leftPressed(), canStart(), let result else { interrupt(); return }
    anchor = result
  }
  func moved(to point: NSPoint) {
    if cycle.moved(x: point.x, y: point.y) == .cancel { cancel() }
    if !cycle.pending { timer?.invalidate(); timer = nil; anchor = nil }
  }
  func checkButtonState() {
    guard cycle.held else { buttonTimer?.invalidate(); buttonTimer = nil; return }
    if !leftPressed() { release(at: clock()) }
    else { moved(to: location()) }
  }
  func deadline() {
    timer?.invalidate(); timer = nil
    let token = epoch, point = location()
    moved(to: point)
    guard cycle.pending else { return }
    let eligible = canStart() && leftPressed() && anchor?.matches(at: point) == true
    guard epoch == token else { return }
    if cycle.deadline(at: clock(), leftPressed: leftPressed(), eligible: eligible && canStart()) == .start {
      anchor = nil
      if !begin(clock()) { _ = cycle.interrupt() }
    } else if cycle.pending, automaticTimers {
      scheduleDeadline(token) // An early timer cannot silently lose the hold.
    }
  }
  func release(at now: TimeInterval) {
    epoch = UUID(); timer?.invalidate(); timer = nil; anchor = nil
    buttonTimer?.invalidate(); buttonTimer = nil
    if cycle.release() == .stop { stop(now) }
  }
  func interrupt() {
    epoch = UUID(); timer?.invalidate(); timer = nil; anchor = nil
    if cycle.interrupt() == .cancel { cancel() }
  }
  deinit {
    timer?.invalidate()
    buttonTimer?.invalidate()
    if let monitor { NSEvent.removeMonitor(monitor) }
    for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
  }
}
