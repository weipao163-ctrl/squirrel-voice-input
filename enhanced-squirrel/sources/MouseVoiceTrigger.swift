import AppKit
import ApplicationServices
import Carbon
import EnhancementCore

protocol MouseVoiceAnchorChecking: AnyObject {
  func matches(at point: NSPoint) -> Bool
}

enum MouseVoiceHit<Element> {
  case editor(Element)
  case unresolved
  case blocked
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
  static func capture(at point: NSPoint, in processID: Int32) -> MouseVoiceHit<MouseVoiceAnchorChecking> {
    guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
          let application = NSRunningApplication(processIdentifier: processID),
          let bundle = application.bundleIdentifier, !MouseVoicePolicy.excludes(bundle: bundle) else { return .blocked }
    let app = AXUIElementCreateApplication(processID)
    AXUIElementSetMessagingTimeout(app, 0.08)
    switch editableHit(in: app, at: point) {
    case .editor(let element): return .editor(MouseVoiceAnchor(element: element, processID: processID, bundle: bundle))
    case .unresolved: return .unresolved
    case .blocked: return .blocked
    }
  }
  private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
  }
  private static func editableHit(in app: AXUIElement, at point: NSPoint) -> MouseVoiceHit<AXUIElement> {
    guard let top = NSScreen.screens.first?.frame.maxY, point.x.isFinite, point.y.isFinite else { return .blocked }
    var hit: AXUIElement?
    guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(top - point.y), &hit) == .success,
          var current = hit else { return .unresolved }
    // Text can be a child of the editor. Never treat an embedded button,
    // link or secure field as part of an editable hit.
    for _ in 0..<8 {
      AXUIElementSetMessagingTimeout(current, 0.08)
      guard let role = attribute(current, kAXRoleAttribute) as? String else { return .unresolved }
      guard !["AXButton", "AXPopUpButton", "AXMenuItem", "AXLink", "AXScrollBar", "AXSecureTextField"].contains(role) else { return .blocked }
      if ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) {
        let subrole = attribute(current, kAXSubroleAttribute) as? String
        let enabled = attribute(current, kAXEnabledAttribute) as? Bool
        var writable = DarwinBoolean(false)
        let canSetValue = AXUIElementIsAttributeSettable(current, kAXValueAttribute as CFString, &writable) == .success && writable.boolValue
        return MouseVoicePolicy.allowsFocusedElement(role: role, subrole: subrole, enabled: enabled,
          writable: canSetValue || attribute(current, "AXEditable") as? Bool == true) ? .editor(current) : .blocked
      }
      guard let parent = attribute(current, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return .unresolved }
      current = unsafeBitCast(parent, to: AXUIElement.self)
    }
    return .unresolved
  }
  func matches(at point: NSPoint) -> Bool {
    guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
          let front = NSWorkspace.shared.frontmostApplication,
          front.processIdentifier == processID, front.bundleIdentifier == bundle else { return false }
    let app = AXUIElementCreateApplication(processID)
    AXUIElementSetMessagingTimeout(app, 0.08)
    guard let raw = Self.attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID(),
          CFEqual(element, raw), case .editor(let hit) = Self.editableHit(in: app, at: point),
          CFEqual(element, hit) else { return false }
    return true
  }
}

// Passive observation only: never swallow/synthesize a mouse event or change
// focus. One listener survives handoff between input sessions.
final class MouseVoiceTrigger {
  private static let hitRetryInterval: TimeInterval = 0.04
  private static let hitGrace: TimeInterval = 0.15
  private var cycle: MouseHoldCycle
  let holdSeconds: TimeInterval
  private var epoch = UUID()
  private var anchor: MouseVoiceAnchorChecking?
  private var origin = NSPoint.zero
  private var targetPID: Int32?
  private var recognizeAt: TimeInterval = 0
  private var timer: Timer?
  private var anchorTimer: Timer?
  private var buttonTimer: Timer?
  private var monitor: Any?
  private var observers: [NSObjectProtocol] = []
  private var sourceObserver: NSObjectProtocol?
  private let canArm: (Int32) -> Bool
  private let canStart: () -> Bool
  private let begin: (TimeInterval, MouseVoiceAnchorChecking) -> Bool
  private let stop: (TimeInterval) -> Void
  private let cancel: () -> Void
  private let capture: (NSPoint, Int32) -> MouseVoiceHit<MouseVoiceAnchorChecking>
  private let record: (String) -> Void
  private let clock: () -> TimeInterval
  private let leftPressed: () -> Bool
  private let location: () -> NSPoint
  private let foregroundProcess: () -> Int32?
  private let monitorEvents: Bool
  private let automaticTimers: Bool
  var available: Bool { !monitorEvents || monitor != nil }

  init(holdSeconds: TimeInterval = MouseHoldTiming.defaultSeconds,
       canArm: @escaping (Int32) -> Bool, canStart: @escaping () -> Bool,
       begin: @escaping (TimeInterval, MouseVoiceAnchorChecking) -> Bool,
       stop: @escaping (TimeInterval) -> Void, cancel: @escaping () -> Void,
       capture: @escaping (NSPoint, Int32) -> MouseVoiceHit<MouseVoiceAnchorChecking> = { MouseVoiceAnchor.capture(at: $0, in: $1) },
       record: @escaping (String) -> Void = { _ in },
       clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
       leftPressed: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 },
       location: @escaping () -> NSPoint = { NSEvent.mouseLocation },
       foregroundProcess: @escaping () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
       monitorEvents: Bool = true,
       automaticTimers: Bool? = nil) {
    self.holdSeconds = holdSeconds; self.cycle = MouseHoldCycle(holdSeconds: holdSeconds)
    self.canArm = canArm; self.canStart = canStart; self.begin = begin; self.stop = stop; self.cancel = cancel
    self.capture = capture; self.record = record; self.clock = clock; self.leftPressed = leftPressed
    self.location = location; self.foregroundProcess = foregroundProcess; self.monitorEvents = monitorEvents
    self.automaticTimers = automaticTimers ?? monitorEvents
    guard monitorEvents else { return }
    monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown, .flagsChanged]) { [weak self] event in
      self?.handle(event)
    }
    let center = NSWorkspace.shared.notificationCenter
    observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
      let application = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      self?.applicationActivated(processID: application?.processIdentifier)
    })
    for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.activeSpaceDidChangeNotification] {
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
  func handle(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      // The global monitor's event copy can name the observer as its target.
      // Bind to the foreground process and cancel if that application changes.
      guard let processID = foregroundProcess() else { return }
      press(at: event.timestamp, point: eventPoint(event), processID: processID, singleClick: event.clickCount == 1,
            modified: !event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty)
    case .leftMouseUp: release(at: event.timestamp)
    case .leftMouseDragged: moved(to: eventPoint(event))
    default: interrupt()
    }
  }
  func press(at now: TimeInterval, point: NSPoint, processID: Int32, singleClick: Bool = true, modified: Bool = false) {
    // A newer down invalidates a prior mouse cycle even if its up was missed.
    guard !cycle.held else { interrupt(); return }
    let eligible = singleClick && !modified && canArm(processID)
    let armed = cycle.press(at: now, x: point.x, y: point.y, eligible: eligible, singleClick: singleClick, modified: modified)
    if automaticTimers, cycle.held, buttonTimer == nil {
      // Global AppKit monitors exclude events delivered to this process. Check
      // the physical release only WHILE held, so an up over our own panel or a
      // missing event still ends capture and rearms the next genuine press.
      let watcher = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.checkButtonState() }
      buttonTimer = watcher; RunLoop.main.add(watcher, forMode: .common)
    }
    guard armed else { return }
    record("armed")
    epoch = UUID(); let token = epoch; origin = point; targetPID = processID; recognizeAt = now + holdSeconds
    guard automaticTimers else { return }
    // Bind the editor under the down event before the threshold. Its keyboard
    // focus and IMK session may finish activating later during the same hold.
    let captureTimer = Timer(timeInterval: 0.03, repeats: false) { [weak self] _ in
      guard let self, self.epoch == token else { return }; self.capturePendingAnchor()
    }
    anchorTimer = captureTimer; RunLoop.main.add(captureTimer, forMode: .common)
    scheduleDeadline(token, at: recognizeAt)
  }
  private func scheduleDeadline(_ token: UUID, at uptime: TimeInterval) {
    let timer = Timer(timeInterval: max(0.001, uptime - clock()), repeats: false) { [weak self] _ in
      guard let self, self.epoch == token else { return }; self.deadline()
    }
    self.timer = timer; RunLoop.main.add(timer, forMode: .common)
  }
  func capturePendingAnchor() {
    anchorTimer?.invalidate(); anchorTimer = nil
    guard cycle.pending, anchor == nil, leftPressed(), let targetPID,
          !monitorEvents || foregroundProcess() == targetPID else { return }
    let token = epoch
    let result = capture(origin, targetPID)
    guard epoch == token, cycle.pending, leftPressed() else { return }
    switch result {
    case .editor(let editor): anchor = editor
    case .unresolved: break // The clicked editor can appear only after the host processes the down event.
    case .blocked: record("hit_blocked"); interrupt()
    }
  }
  func applicationActivated(processID: Int32?) {
    guard cycle.pending || cycle.recording else { return }
    if processID == nil || processID != targetPID { interrupt() }
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
    if clock() < recognizeAt {
      if automaticTimers { scheduleDeadline(token, at: recognizeAt) }
      return
    }
    guard clock() <= recognizeAt + MouseHoldCycle.maximumDelay, leftPressed() else { interrupt(); return }
    if anchor == nil {
      // Retry the original down coordinates and process, not the focused
      // element alone. Never replace an editor already pinned by the first hit.
      let limit = recognizeAt + Self.hitGrace
      if clock() <= limit { capturePendingAnchor() }
      guard epoch == token, cycle.pending else { return }
      if anchor == nil {
        if clock() < limit, leftPressed() {
          if automaticTimers { scheduleDeadline(token, at: min(limit, clock() + Self.hitRetryInterval)) }
        } else { record("hit_unavailable"); interrupt() }
        return
      }
      guard clock() <= limit else { record("hit_unavailable"); interrupt(); return }
      record("hit_recovered")
    }
    moved(to: location())
    guard cycle.pending, let anchor else { return }
    let matches = anchor.matches(at: location())
    guard epoch == token, cycle.pending else { return }
    let eligible = matches && canStart()
    guard epoch == token, cycle.pending else { return }
    if cycle.deadline(at: clock(), leftPressed: leftPressed(), eligible: eligible) == .start {
      if begin(clock(), anchor) { record("reserved") }
      else if epoch == token { _ = cycle.interrupt() }
    } else {
      record(matches ? "session_unavailable" : "focus_changed")
    }
    if epoch == token { self.anchor = nil }
  }
  private func clearPending() {
    epoch = UUID(); timer?.invalidate(); timer = nil
    anchorTimer?.invalidate(); anchorTimer = nil
    anchor = nil; targetPID = nil
  }
  func release(at now: TimeInterval) {
    clearPending()
    buttonTimer?.invalidate(); buttonTimer = nil
    if cycle.release() == .stop { stop(now) }
  }
  func interrupt() {
    clearPending()
    if cycle.interrupt() == .cancel { cancel() }
  }
  deinit {
    anchorTimer?.invalidate()
    timer?.invalidate()
    buttonTimer?.invalidate()
    if let monitor { NSEvent.removeMonitor(monitor) }
    for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
  }
}
