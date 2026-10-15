import AppKit
import ApplicationServices
import Carbon

// Display geometry only. None of these anchors are exposed to voice target
// verification or used to authorize text delivery.
final class CandidatePositionRecovery {
  struct Context: Equatable {
    let pid: pid_t
    let bundle: String
    let screens: [NSRect]
    let top: CGFloat
  }
  final class Lease {
    var valid = true
    var observer: AXObserver?
    deinit {
      if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes) }
    }
  }
  struct Anchor {
    let rect: NSRect
    let window: NSRect
    let lease: Lease?
  }
  typealias Lookup = (Context, @escaping (Anchor?) -> Void) -> Void
  private let context: (String) -> Context?
  private let current: (Context) -> Bool
  private let lookup: Lookup
  private let clock: () -> TimeInterval
  private let observeSystemEvents: Bool
  private var epoch: UInt64 = 0
  private var busy = false
  private var lastAttempt: TimeInterval = -.infinity
  private var cache: (Context, Anchor, TimeInterval)?
  private var monitor: Any?
  private var notices: [(NotificationCenter, NSObjectProtocol)] = []
  private var invalidated: (() -> Void)?
  static let cacheLifetime: TimeInterval = 0.18
  static let retryInterval: TimeInterval = 0.18

  init(context: @escaping (String) -> Context? = CandidatePositionRecovery.frontContext,
       current: @escaping (Context) -> Bool = CandidatePositionRecovery.isCurrent,
       lookup: @escaping Lookup = CandidateAccessibilityCaret.lookup,
       observeSystemEvents: Bool = true,
       clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.context = context; self.current = current; self.lookup = lookup; self.clock = clock
    self.observeSystemEvents = observeSystemEvents
  }
  deinit { stopMonitoring() }

  func startMonitoring(invalidated: @escaping () -> Void) {
    guard self.invalidated == nil else { return }
    self.invalidated = invalidated
    guard observeSystemEvents else { return } // Deterministic in-memory host fixtures.
    monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] _ in
      self?.targetChanged()
    }
    let workspace = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                 NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
      notices.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.targetChanged() }))
    }
    let center = NotificationCenter.default
    notices.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.targetChanged() }))
  }
  static func movesTarget(_ event: NSEvent) -> Bool {
    event.modifierFlags.intersection([.command, .control]).isEmpty == false ||
      [UInt16(48), 53, 115, 116, 117, 119, 121, 123, 124, 125, 126].contains(event.keyCode)
  }
  private func targetChanged() {
    invalidate()
    invalidated?()
  }
  private func stopMonitoring() {
    if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
    notices.forEach { $0.0.removeObserver($0.1) }; notices.removeAll()
    invalidated = nil
  }
  func invalidate(stop: Bool = false) {
    epoch &+= 1; cache?.1.lease?.valid = false; cache = nil
    // A superseded worker still occupies its one slot until it completes.
    // Do not queue an unbounded number of AX jobs after repeated focus changes.
    if stop { stopMonitoring() }
  }
  func cached(bundle: String) -> NSRect? {
    guard let (context, anchor, time) = cache,
          bundle == context.bundle, clock() - time <= Self.cacheLifetime,
          anchor.lease?.valid == true, current(context) else { return nil }
    return anchor.rect
  }
  func recover(bundle: String, completion: @escaping (NSRect) -> Void) {
    guard !busy, clock() - lastAttempt >= Self.retryInterval, let context = context(bundle) else { return }
    busy = true; lastAttempt = clock()
    let epoch = epoch
    CandidatePositionStatistics.shared.increment("ax_attempts")
    lookup(context) { [weak self] anchor in
      // Lookup contract: completion is on the main queue, even on failure.
      guard let self else { return }
      self.busy = false
      guard self.epoch == epoch, self.current(context) else {
        CandidatePositionStatistics.shared.increment("ax_stale_results"); return
      }
      guard let anchor, let rect = KeyboardInputPosition.normalizedCaret(anchor.rect),
            anchor.lease?.observer == nil || anchor.lease?.valid == true,
            anchor.window.intersects(rect.insetBy(dx: -1, dy: -1)) else {
        CandidatePositionStatistics.shared.increment("ax_unavailable"); return
      }
      self.cache = (context, Anchor(rect: rect, window: anchor.window, lease: anchor.lease), self.clock())
      CandidatePositionStatistics.shared.increment("ax_hits")
      completion(rect)
    }
  }
  static func frontContext(bundle: String) -> Context? {
    guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
          let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundle,
          let first = NSScreen.screens.first else { return nil }
    return Context(pid: front.processIdentifier, bundle: bundle, screens: NSScreen.screens.map(\.frame), top: first.frame.maxY)
  }
  static func isCurrent(_ context: Context) -> Bool {
    guard !IsSecureEventInputEnabled(), let front = NSWorkspace.shared.frontmostApplication else { return false }
    return AXIsProcessTrusted() && front.processIdentifier == context.pid && front.bundleIdentifier == context.bundle &&
      NSScreen.screens.map(\.frame) == context.screens
  }
}

// At most one AX lookup in this input-method process. Slow or unavailable
// applications never create a per-key background queue or block the key path.
enum CandidateAccessibilityCaret {
  private static let queue = DispatchQueue(label: "org.rime.candidate-geometry", qos: .userInitiated)
  private static var busy = false // main queue only
  static func lookup(_ context: CandidatePositionRecovery.Context, completion: @escaping (CandidatePositionRecovery.Anchor?) -> Void) {
    guard !busy else { DispatchQueue.main.async { completion(nil) }; return }
    busy = true
    queue.async {
      let result = capture(context)
      DispatchQueue.main.async {
        busy = false
        if let observer = result?.lease?.observer {
          CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        completion(result)
      }
    }
  }
  private static func capture(_ context: CandidatePositionRecovery.Context) -> CandidatePositionRecovery.Anchor? {
    let deadline = ProcessInfo.processInfo.systemUptime + 0.20
    func remaining() -> Bool { ProcessInfo.processInfo.systemUptime < deadline }
    func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
      guard remaining() else { return nil }
      // Timeouts are per AX object, not inherited from the application object.
      AXUIElementSetMessagingTimeout(element, 0.035)
      var value: CFTypeRef?
      return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    func element(_ object: AXUIElement, _ key: String) -> AXUIElement? {
      guard let value = attribute(object, key), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
      return unsafeBitCast(value, to: AXUIElement.self)
    }
    func range(_ field: AXUIElement) -> CFRange? {
      guard let value = attribute(field, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
      let ax = unsafeBitCast(value, to: AXValue.self)
      var range = CFRange()
      guard AXValueGetType(ax) == .cfRange, AXValueGetValue(ax, .cfRange, &range),
            range.location >= 0, range.length >= 0, range.location != NSNotFound,
            range.length <= Int.max - range.location else { return nil }
      return range
    }
    func frame(_ window: AXUIElement) -> NSRect? {
      guard let p = attribute(window, kAXPositionAttribute), let s = attribute(window, kAXSizeAttribute),
            CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
      var point = CGPoint.zero, size = CGSize.zero
      let position = unsafeBitCast(p, to: AXValue.self), dimensions = unsafeBitCast(s, to: AXValue.self)
      guard AXValueGetType(position) == .cgPoint, AXValueGetType(dimensions) == .cgSize,
            AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(dimensions, .cgSize, &size),
            [point.x, point.y, size.width, size.height].allSatisfy({ $0.isFinite }), size.width > 0, size.height > 0 else { return nil }
      return NSRect(x: point.x, y: context.top - point.y - size.height, width: size.width, height: size.height)
    }
    let app = AXUIElementCreateApplication(context.pid)
    guard let field = element(app, kAXFocusedUIElementAttribute), let window = element(app, kAXFocusedWindowAttribute),
          attribute(field, kAXSubroleAttribute) as? String != "AXSecureTextField",
          attribute(field, kAXRoleAttribute) as? String != "AXSecureTextField",
          attribute(field, kAXEnabledAttribute) as? Bool != false,
          let selection = range(field), let windowFrame = frame(window), remaining() else { return nil }
    var insertion = CFRange(location: selection.location, length: 0)
    guard let parameter = AXValueCreate(.cfRange, &insertion) else { return nil }
    var value: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(field, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
          let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    let bounds = unsafeBitCast(value, to: AXValue.self)
    var rect = CGRect.zero
    guard AXValueGetType(bounds) == .cgRect, AXValueGetValue(bounds, .cgRect, &rect),
          [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height].allSatisfy({ $0.isFinite }), rect.size.height != 0 else { return nil }
    rect = rect.standardized
    rect.origin.y = context.top - rect.maxY
    guard windowFrame.intersects(rect.insetBy(dx: -1, dy: -1)),
          context.screens.contains(where: { $0.intersects(rect.insetBy(dx: -1, dy: -1)) }), remaining(),
          let sameField = element(app, kAXFocusedUIElementAttribute), CFEqual(field, sameField),
          let sameWindow = element(app, kAXFocusedWindowAttribute), CFEqual(window, sameWindow),
          let sameRange = range(field), sameRange.location == selection.location, sameRange.length == selection.length,
          let sameFrame = frame(window), sameFrame == windowFrame, remaining() else { return nil }
    // Cache only with an active, independently scoped AX focus/window lease.
    // Hosts without notifications can still provide a fresh one-shot anchor.
    let lease = CandidatePositionRecovery.Lease()
    var observer: AXObserver?
    if AXObserverCreate(context.pid, { _, _, _, refcon in
      guard let refcon else { return }
      Unmanaged<CandidatePositionRecovery.Lease>.fromOpaque(refcon).takeUnretainedValue().valid = false
    }, &observer) == .success, let observer {
      let refcon = Unmanaged.passUnretained(lease).toOpaque()
      let registrations = [(app, kAXFocusedUIElementChangedNotification), (app, kAXFocusedWindowChangedNotification),
                           (window, kAXMovedNotification), (window, kAXResizedNotification),
                           (field, kAXSelectedTextChangedNotification), (field, kAXUIElementDestroyedNotification)]
      var complete = true
      for (object, name) in registrations {
        AXUIElementSetMessagingTimeout(object, 0.015)
        if !remaining() || AXObserverAddNotification(observer, object, name as CFString, refcon) != .success { complete = false; break }
      }
      if complete { lease.observer = observer } else { lease.valid = false }
    } else { lease.valid = false }
    return .init(rect: rect, window: windowFrame, lease: lease)
  }
}

// Fixed-size, in-memory diagnostics: no input text, key sequence, coordinates,
// AX values or credentials. Never emit logs in the typing path.
final class CandidatePositionStatistics {
  static let shared = CandidatePositionStatistics()
  private var counts: [String: UInt64] = [:]
  private var durations: [Double] = []
  private var durationIndex = 0
  private(set) var source = "none"
  func increment(_ key: String) { counts[key, default: 0] &+= 1 }
  func native(_ query: KeyboardInputPosition.Query, elapsed: TimeInterval) {
    increment("native_" + query.source.rawValue)
    let ms = elapsed * 1000
    if durations.count < 64 { durations.append(ms) } else { durations[durationIndex] = ms }
    durationIndex = (durationIndex + 1) % 64
  }
  func displayed(_ value: String) { source = value; increment("display_" + value) }
  func report() -> [String: Any] {
    let sorted = durations.sorted()
    return ["counts": counts, "position_source": source, "sample_count": sorted.count,
            "native_query_p95_ms": sorted.isEmpty ? 0 : sorted[(sorted.count - 1) * 95 / 100],
            "contains_text_or_coordinates": false]
  }
}
