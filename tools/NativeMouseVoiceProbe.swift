import AppKit
import EnhancementCore

private final class FakeMouseAnchor: MouseVoiceAnchorChecking {
  var valid = true
  var inspected: (() -> Void)?
  func matches(at point: NSPoint) -> Bool { inspected?(); return valid }
}
private final class Fixture {
  let holdSeconds: TimeInterval
  init(holdSeconds: TimeInterval = 1) { self.holdSeconds = holdSeconds }
  var now: TimeInterval = 10
  var held = true, eligible = true, sessionReady = true, captureAvailable = true, hitBlocked = false, acceptsBegin = true
  var point = NSPoint(x: 10, y: 10)
  var captures = 0, starts = 0, stops = 0, cancels = 0
  var releasedAt: TimeInterval?
  var onCapture: (() -> Void)?
  let anchor = FakeMouseAnchor()
  lazy var trigger = MouseVoiceTrigger(holdSeconds:holdSeconds,
    canArm: { [unowned self] _ in self.eligible },
    canStart: { [unowned self] in self.eligible && self.sessionReady },
    begin: { [unowned self] _, _ in self.starts += 1; return self.acceptsBegin },
    stop: { [unowned self] time in self.stops += 1; self.releasedAt = time },
    cancel: { [unowned self] in self.cancels += 1 },
    capture: { [unowned self] _, _ in
      self.captures += 1; self.onCapture?()
      if self.hitBlocked { return .blocked }
      return self.captureAvailable ? .editor(self.anchor) : .unresolved
    }, clock: { [unowned self] in self.now }, leftPressed: { [unowned self] in self.held },
    location: { [unowned self] in self.point }, monitorEvents: false)
  func press() { trigger.press(at: now, point: point, processID: 42); trigger.capturePendingAnchor() }
  func deadline(_ time: TimeInterval = 11) { now = time; trigger.deadline() }
  func release(_ time: TimeInterval = 11.1) { held = false; trigger.release(at: time) }
}

@main enum NativeMouseVoiceProbe {
  static func main() throws {
    _ = NSApplication.shared
    var rows: [[String: Any]] = []
    func check(_ name: String, _ body: () -> Bool) { rows.append(["name": name, "passed": body()]) }
    for tenth in 1...30 {
      let delay=Double(tenth)/10
      check("configured_\(tenth)_tenths_start_at_threshold_and_release") {
        let f=Fixture(holdSeconds:delay); f.press(); f.deadline(10+delay-0.000001)
        guard f.starts==0 else { return false }
        f.deadline(10+delay); f.release(10+delay+0.01)
        return f.starts==1 && f.stops==1
      }
    }
    // Exercise the real run-loop timers, with no global events, AX, audio or
    // host focus changes. This catches a hardcoded one-second scheduler even
    // when the pure timing state machine has already been parameterized.
    for delay in [0.1,1.0,3.0] {
      check("real_timer_\(delay)_seconds") {
        var starts=0,stops=0,pressed=true,firedAt:TimeInterval?
        let anchor=FakeMouseAnchor(),point=NSPoint(x:10,y:10)
        let trigger=MouseVoiceTrigger(holdSeconds:delay,canArm:{_ in true},canStart:{true},begin:{time,_ in
          starts += 1; firedAt=time; return true
        },stop:{_ in stops += 1},cancel:{},capture:{_,_ in .editor(anchor)},leftPressed:{pressed},
          location:{point},monitorEvents:false,automaticTimers:true)
        let began=ProcessInfo.processInfo.systemUptime
        trigger.press(at:began,point:point,processID:42)
        let timeout=began+delay+0.6
        while starts==0 && ProcessInfo.processInfo.systemUptime<timeout {
          RunLoop.main.run(until:Date(timeIntervalSinceNow:0.005))
        }
        pressed=false; trigger.checkButtonState()
        guard let firedAt else { return false }
        return starts==1 && stops==1 && firedAt>=began+delay && firedAt<=began+delay+0.5
      }
    }
    check("first_click_binds_editor_before_its_input_session_activates") {
      let f = Fixture(holdSeconds: 0.3)
      f.sessionReady = false; f.anchor.valid = false
      f.press()
      f.trigger.applicationActivated(processID: 42)
      f.deadline(10.15)
      guard f.starts == 0, f.captures == 1 else { return false }
      f.sessionReady = true; f.anchor.valid = true
      f.deadline(10.3); f.release(10.4)
      return f.starts == 1 && f.stops == 1
    }
    check("global_event_copy_uses_foreground_editor_instead_of_observer_pid") {
      guard let top = NSScreen.screens.first?.frame.maxY,
            let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
              mouseCursorPosition: CGPoint(x: 10, y: top - 10), mouseButton: .left) else { return false }
      click.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(getpid()))
      click.setIntegerValueField(.mouseEventClickState, value: 1)
      guard let event = NSEvent(cgEvent: click) else { return false }
      var now = event.timestamp, starts = 0, stops = 0
      let point = NSPoint(x: 10, y: 10), anchor = FakeMouseAnchor()
      let trigger = MouseVoiceTrigger(holdSeconds: 0.3, canArm: { $0 == 42 }, canStart: { true },
        begin: { _, _ in starts += 1; return true }, stop: { _ in stops += 1 }, cancel: {},
        capture: { _, pid in pid == 42 ? .editor(anchor) : .blocked }, clock: { now },
        leftPressed: { true }, location: { point }, foregroundProcess: { 42 }, monitorEvents: false)
      trigger.handle(event)
      trigger.capturePendingAnchor()
      now += 0.3; trigger.deadline(); trigger.release(at: now)
      return starts == 1 && stops == 1
    }
    check("first_click_with_late_focus_works_in_common_runloop_mode") {
      let point = NSPoint(x: 10, y: 10), anchor = FakeMouseAnchor()
      var ready = false, pressed = true, starts = 0, stops = 0
      anchor.valid = false
      let trigger = MouseVoiceTrigger(holdSeconds: 0.3, canArm: { $0 == 42 }, canStart: { ready },
        begin: { _, _ in starts += 1; return true }, stop: { _ in stops += 1 }, cancel: {},
        capture: { _, pid in pid == 42 && ready ? .editor(anchor) : .unresolved }, leftPressed: { pressed },
        location: { point }, monitorEvents: false, automaticTimers: true)
      let trackingMode = RunLoop.Mode("MouseVoiceProbeTracking")
      CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: trackingMode.rawValue as CFString))
      let focus = Timer(timeInterval: 0.12, repeats: false) { _ in
        trigger.applicationActivated(processID: 42)
        ready = true; anchor.valid = true
      }
      RunLoop.main.add(focus, forMode: trackingMode)
      let began = ProcessInfo.processInfo.systemUptime
      trigger.press(at: began, point: point, processID: 42)
      while starts == 0 && ProcessInfo.processInfo.systemUptime < began + 0.65 {
        _ = RunLoop.main.run(mode: trackingMode, before: Date(timeIntervalSinceNow: 0.005))
      }
      pressed = false; trigger.checkButtonState()
      return starts == 1 && stops == 1
    }
    check("session_unready_at_deadline_does_not_start_later") {
      let f = Fixture(holdSeconds: 0.3)
      f.sessionReady = false; f.press(); f.deadline(10.3)
      f.sessionReady = true; f.deadline(10.4); f.release()
      return f.starts == 0 && f.stops == 0
    }
    check("activation_of_a_different_app_cancels_pending_press") {
      let f = Fixture(holdSeconds: 0.3)
      f.press(); f.trigger.applicationActivated(processID: 73)
      f.trigger.applicationActivated(processID: 42)
      f.deadline(10.3); f.release()
      return f.starts == 0 && f.stops == 0
    }
    check("second_down_before_release_cancels_the_previous_target") {
      let f = Fixture(holdSeconds: 0.3)
      f.press(); f.trigger.press(at: 10.15, point: f.point, processID: 42, singleClick: false)
      f.deadline(10.3); f.release()
      return f.starts == 0 && f.stops == 0
    }
    check("one_second_starts_once_and_release_stops_once") {
      let f = Fixture(); f.press(); f.deadline(10.999)
      guard f.starts == 0 else { return false }
      f.deadline(); f.deadline(11.01); f.release(); f.release(11.2)
      return f.starts == 1 && f.stops == 1 && f.releasedAt == 11.1 && f.cancels == 0
    }
    check("short_click_and_queued_deadline_never_begin") {
      let f = Fixture(); f.press(); f.release(10.8); f.deadline()
      return f.starts == 0 && f.stops == 0
    }
    check("physical_release_before_queued_up_blocks_begin") {
      let f = Fixture(); f.press(); f.held = false; f.deadline()
      return f.starts == 0
    }
    check("missing_global_up_stops_capture_via_physical_button_check") {
      let f = Fixture(); f.press(); f.deadline(); f.now = 11.2; f.held = false
      f.trigger.checkButtonState(); f.trigger.checkButtonState()
      return f.starts == 1 && f.stops == 1 && f.releasedAt == 11.2
    }
    check("missing_up_after_rejected_busy_press_rearms_next_fresh_press") {
      let f = Fixture(); f.eligible = false; f.press(); f.held = false; f.trigger.checkButtonState()
      f.eligible = true; f.held = true; f.now = 20; f.press(); f.deadline(21)
      return f.starts == 1
    }
    check("busy_hold_never_queues_even_if_previous_task_finishes") {
      let f = Fixture(); f.eligible = false; f.press(); f.eligible = true; f.deadline()
      return f.starts == 0 && f.captures == 0
    }
    check("late_accessibility_editor_is_recovered_on_same_press") {
      let f = Fixture(holdSeconds: 0.3)
      f.captureAvailable = false; f.press()
      f.captureAvailable = true; f.deadline(10.3); f.release(10.55)
      return f.captures == 2 && f.starts == 1 && f.stops == 1
    }
    check("shortest_hold_has_bounded_time_for_editor_to_appear") {
      let f = Fixture(holdSeconds: 0.1)
      f.captureAvailable = false; f.press(); f.deadline(10.1)
      guard f.starts == 0 else { return false }
      f.captureAvailable = true; f.deadline(10.14); f.release(10.2)
      return f.captures == 3 && f.starts == 1 && f.stops == 1
    }
    check("retry_never_accepts_an_editor_after_grace_expires") {
      let f = Fixture(holdSeconds: 0.1)
      f.captureAvailable = false; f.press(); f.deadline(10.1)
      f.captureAvailable = true; f.deadline(10.26); f.release(10.3)
      return f.captures == 2 && f.starts == 0
    }
    check("a_blocked_click_does_not_recover_as_an_editor") {
      let f = Fixture(); f.hitBlocked = true; f.press(); f.hitBlocked = false; f.deadline()
      return f.captures == 1 && f.starts == 0
    }
    check("release_before_deferred_hit_does_not_start") {
      let f = Fixture(holdSeconds: 0.1)
      f.captureAvailable = false; f.press(); f.deadline(10.1); f.release(10.12)
      f.captureAvailable = true; f.deadline(10.14)
      return f.starts == 0
    }
    check("changed_input_field_at_threshold_is_not_recorded") {
      let f = Fixture(); f.press(); f.anchor.valid = false; f.deadline()
      return f.starts == 0
    }
    check("focus_or_setting_disabled_at_threshold_is_not_recorded") {
      let f = Fixture(); f.press(); f.eligible = false; f.deadline()
      return f.starts == 0
    }
    check("drag_before_threshold_cancels_without_start") {
      let f = Fixture(); f.press(); f.point.x += 7; f.trigger.moved(to: f.point); f.deadline()
      return f.starts == 0 && f.cancels == 0
    }
    check("missed_drag_callback_is_detected_by_current_position") {
      let f = Fixture(); f.press(); f.point.y += 7; f.deadline()
      return f.starts == 0
    }
    check("small_pointer_jitter_still_allows_hold") {
      let f = Fixture(); f.press(); f.point.x += 3; f.point.y += 3; f.deadline(); f.release()
      return f.starts == 1 && f.stops == 1
    }
    check("drag_during_recording_cancels_and_up_does_not_finalize") {
      let f = Fixture(); f.press(); f.deadline(); f.point.x += 7; f.trigger.moved(to: f.point); f.release()
      return f.starts == 1 && f.cancels == 1 && f.stops == 0
    }
    check("interrupt_cancels_active_capture_exactly_once") {
      let f = Fixture(); f.press(); f.deadline(); f.trigger.interrupt(); f.trigger.interrupt(); f.release()
      return f.starts == 1 && f.cancels == 1 && f.stops == 0
    }
    check("interrupt_pending_hold_does_not_restart_until_new_press") {
      let f = Fixture(); f.press(); f.trigger.interrupt(); f.deadline()
      f.release(); f.held = true; f.now = 20; f.press(); f.deadline(21)
      return f.starts == 1
    }
    check("stalled_or_wake_delayed_callback_never_opens_microphone") {
      let f = Fixture(); f.press(); f.deadline(60)
      return f.starts == 0
    }
    check("double_click_and_modifier_click_do_not_capture") {
      let f = Fixture(); f.trigger.press(at: 10, point: f.point, processID: 42, singleClick: false); f.trigger.capturePendingAnchor(); f.deadline()
      f.release(); f.held = true
      f.trigger.press(at: 10, point: f.point, processID: 42, modified: true); f.trigger.capturePendingAnchor(); f.deadline()
      return f.starts == 0 && f.captures == 0
    }
    check("declined_begin_does_not_send_release_to_another_task") {
      let f = Fixture(); f.acceptsBegin = false; f.press(); f.deadline(); f.release()
      return f.starts == 1 && f.stops == 0 && f.cancels == 0
    }
    check("release_reentered_during_target_verification_blocks_start") {
      let f = Fixture(); f.press(); f.anchor.inspected = { [unowned f] in f.release(10.9) }; f.deadline()
      return f.starts == 0 && f.stops == 0
    }
    check("old_capture_reentry_cannot_cancel_a_new_press") {
      let f = Fixture()
      f.onCapture = { [unowned f] in
        f.onCapture = nil; f.release(10.1); f.held = true; f.now = 20
        f.trigger.press(at: 20, point: f.point, processID: 42)
      }
      f.press(); f.trigger.capturePendingAnchor(); f.deadline(21)
      return f.starts == 1
    }
    let ok = rows.allSatisfy { $0["passed"] as? Bool == true }
    let result: [String: Any] = ["status": ok ? "PASS" : "FAIL", "cases": rows,
      "kind": "production native mouse coordinator with injected clock/buttons/anchor/voice callbacks",
      "microphone_used": false, "cloud_calls": 0, "real_global_mouse_or_host_AX_tested": false]
    print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    exit(ok ? 0 : 1)
  }
}
