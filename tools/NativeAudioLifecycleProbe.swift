import Foundation
import EnhancementCore
import EnhancementIPC
import Darwin

private final class Counter {
  private let lock=NSLock(); private var count=0
  var value:Int { lock.lock(); defer { lock.unlock() }; return count }
  func add() { lock.lock(); count += 1; lock.unlock() }
}
private func pump(_ seconds:Double) { RunLoop.main.run(until:Date(timeIntervalSinceNow:seconds)) }
private func wait(_ seconds:Double = 1, _ predicate:()->Bool) -> Bool {
  let end=Date(timeIntervalSinceNow:seconds)
  while !predicate() && Date() < end { pump(0.005) }
  return predicate()
}
private final class FakeAudio:VoiceAudioCapture {
  let starts=Counter(), stops=Counter()
  private let lock=NSLock()
  private var completion:((Result<Void,Error>)->Void)?
  func start(uid:String?,pcm:@escaping(Data,Double)->Void,failure:@escaping(String)->Void,
             completion:@escaping(Result<Void,Error>)->Void) {
    lock.lock(); self.completion=completion; lock.unlock(); starts.add()
  }
  func finishStart(_ result:Result<Void,Error>) {
    lock.lock(); let callback=completion; lock.unlock(); callback?(result)
  }
  func stop(completion:@escaping(Bool)->Void)->TimeInterval {
    stops.add(); completion(true); return ProcessInfo.processInfo.systemUptime
  }
}

@main enum AudioLifecycleProbe {
  static func main() throws {
    if CommandLine.arguments.contains("--fatal-start") || CommandLine.arguments.contains("--fatal-stop") {
      let blocked=DispatchSemaphore(value:0)
      let start=CommandLine.arguments.contains("--fatal-start")
      let audio=AudioCapture(startupTimeout:0.04,teardownTimeout:0.04,
        startOperation:{ if start { blocked.wait() } },stopOperation:{ if !start { blocked.wait() } })
      audio.start(uid:nil,pcm:{ _,_ in },failure:{ _ in },completion:{ _ in
        if !start { audio.stop { _ in } }
      })
      withExtendedLifetime(audio) { pump(3) }
      exit(99) // The real production fatal boundary must have exited with EX_IOERR.
    }
    var checks:[[String:Any]]=[]
    func check(_ name:String,_ pass:Bool) { checks.append(["name":name,"passed":pass]) }
    let deadline=AudioOperationDeadline(), expired=Counter()
    let first=deadline.arm(seconds:0.03) { expired.add() }
    let second=deadline.arm(seconds:0.08) { expired.add() }
    check("superseded_deadline_cannot_complete_new_owner",!deadline.complete(first))
    check("completed_deadline_is_cancelled",deadline.complete(second))
    pump(0.1); check("cancelled_timers_never_fire",expired.value==0)

    do {
      let gate=DispatchSemaphore(value:0), entered=Counter(), callbacks=Counter(), fatal=Counter(), drains=Counter()
      let audio=AudioCapture(startupTimeout:0.06,teardownTimeout:0.06,
        startOperation:{ entered.add(); gate.wait() },fatalStall:{ fatal.add() })
      let now=ProcessInfo.processInfo.systemUptime
      audio.start(uid:nil,pcm:{ _,_ in },failure:{ _ in },completion:{ _ in callbacks.add() })
      check("hardware_start_never_blocks_caller",ProcessInfo.processInfo.systemUptime-now < 0.1)
      check("blocked_start_was_executed_on_control_lane",wait { entered.value==1 })
      check("startup_timeout_reports_failure_before_hardware_returns",wait { callbacks.value==1 })
      check("blocked_start_causes_bounded_helper_recovery",wait { fatal.value==1 })
      audio.stop { _ in drains.add() }
      gate.signal(); pump(0.1)
      check("late_start_cannot_publish_success",callbacks.value==1)
      check("expired_teardown_never_claims_safe_drain",drains.value==0)
      check("repeated_stop_does_not_repeat_fatal_recovery",fatal.value==1)
    }
    do {
      let gate=DispatchSemaphore(value:0), entered=Counter(), callbacks=Counter(), drains=Counter(), fatal=Counter()
      let audio=AudioCapture(startupTimeout:0.4,teardownTimeout:0.4,
        startOperation:{ entered.add(); gate.wait() },fatalStall:{ fatal.add() })
      audio.start(uid:nil,pcm:{ _,_ in },failure:{ _ in },completion:{ _ in callbacks.add() })
      _ = wait { entered.value==1 }
      let cutoff=audio.stop { ok in if ok { drains.add() } }
      let repeated=audio.stop { ok in if ok { drains.add() } }
      check("first_sample_cutoff_is_stable",cutoff==repeated)
      gate.signal()
      check("release_during_start_drains_all_waiters",wait { drains.value==2 })
      check("release_retires_start_completion",callbacks.value==0)
      check("successful_drain_cancels_recovery",fatal.value==0)
    }
    do {
      let gate=DispatchSemaphore(value:0), started=Counter(), fatal=Counter(), drains=Counter()
      let audio=AudioCapture(startupTimeout:0.2,teardownTimeout:0.06,
        startOperation:{},stopOperation:{ gate.wait() },fatalStall:{ fatal.add() })
      audio.start(uid:nil,pcm:{ _,_ in },failure:{ _ in },completion:{ _ in started.add() })
      check("normal_start_completes",wait { started.value==1 })
      audio.stop { _ in drains.add() }
      check("blocked_teardown_has_independent_deadline",wait { fatal.value==1 })
      gate.signal(); pump(0.05)
      check("late_teardown_does_not_release_owner_after_fatal",drains.value==0)
    }
    var settings=VoiceSettings(); settings.region = .beijing; settings.workspace="fixture"
    settings.credentialReference="fixture-only"; settings.binding=TriggerBinding(codes:[58])
    settings.connectSeconds=1
    do {
      let audio=FakeAudio(); var updates:[VoiceUpdate]=[], snapshots:[VoiceDiagnosticSnapshot]=[]
      let session=StreamingSession(identity:VoiceIdentity(generation:1),settings:settings,test:true,audio:audio) {
        updates.append($0); snapshots.append($1)
      }
      session.start(key:"fixture-key")
      check("session_accepts_async_capture_without_resuming_network",wait { audio.starts.value==1 })
      check("session_clock_runs_without_capture_completion",wait(1.5) { updates.contains{$0.phase == .failed} })
      check("startup_hang_fails_without_complete_text",updates.last?.complete == false && updates.last?.text == "")
      check("startup_hang_records_timeout",snapshots.last?.failure == .connectionTimeout)
      audio.finishStart(.success(())); pump(0.08)
      check("late_success_after_failure_cannot_resurrect_session",updates.filter{$0.phase == .failed}.count==1 && updates.last?.phase == .failed)
      withExtendedLifetime(session) {}
    }
    do {
      let audio=FakeAudio(); var updates:[VoiceUpdate]=[]
      let session=StreamingSession(identity:VoiceIdentity(generation:2),settings:settings,test:true,audio:audio) { value,_ in updates.append(value) }
      session.start(key:"fixture-key"); _ = wait { audio.starts.value==1 }
      session.release(at:ProcessInfo.processInfo.systemUptime,cause:.keyReleased)
      check("physical_release_is_processed_during_startup",wait { updates.contains{$0.phase == .cancelled} })
      audio.finishStart(.success(())); pump(0.08)
      check("released_press_never_restarts_or_inserts",updates.last?.phase == .cancelled && updates.allSatisfy{!$0.complete})
      check("cancelled_capture_emits_one_terminal_update",updates.filter{[.cancelled,.failed,.ready,.review].contains($0.phase)}.count==1)
      withExtendedLifetime(session) {}
    }
    do {
      let audio=FakeAudio(); var updates:[VoiceUpdate]=[]
      let session=StreamingSession(identity:VoiceIdentity(generation:3),settings:settings,test:true,audio:audio) { value,_ in updates.append(value) }
      session.start(key:"fixture-key"); _ = wait { audio.starts.value==1 }
      session.cancel()
      check("cancel_is_processed_during_startup",wait { updates.last?.phase == .cancelled })
      audio.finishStart(.failure(SettingsError.invalid("fixture late error"))); pump(0.04)
      check("late_start_error_does_not_duplicate_terminal",updates.filter{[.cancelled,.failed].contains($0.phase)}.count==1)
      withExtendedLifetime(session) {}
    }
    var owner=VoiceOwnerDeadline(startedAt:100,settings:settings)
    check("frontend_total_lifetime_is_bounded",owner.deadline < 500)
    owner.stop(at:105); let initial=owner.deadline
    for time in 106...200 { owner.stop(at:Double(time)) }
    check("repeated_stop_never_extends_frontend_wait",owner.deadline==initial)
    check("frontend_deadline_boundary",!owner.expired(at:initial-0.001) && owner.expired(at:initial))
    let failed=checks.filter{($0["passed"] as? Bool) != true}
    let data=try JSONSerialization.data(withJSONObject:["status":failed.isEmpty ? "PASS":"FAIL","checks":checks,"microphone_used":false,"cloud_calls":0],options:[.prettyPrinted,.sortedKeys])
    print(String(decoding:data,as:UTF8.self)); exit(failed.isEmpty ? 0:1)
  }
}
