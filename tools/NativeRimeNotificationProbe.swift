import Foundation

private final class Probe {
  let api=rime_get_api_stdbool().pointee
  var notices=0, deferredReads=0, ignoredReads=0, insideCall=false, readDuringCall=false
  func receive(session:RimeSessionId,type:UnsafePointer<CChar>?,value:UnsafePointer<CChar>?) {
    guard let type, String(cString:type) == "option", let value else { return }
    notices += 1
    let message=String(cString:value), state=message.first != "!"
    let name=state ? message : String(message.dropFirst())
    DispatchQueue.main.async {
      if self.insideCall { self.readDuringCall=true }
      if readyRimeOptionLabels(api:self.api,session:session,name:name,state:state) == nil { self.ignoredReads += 1 }
      else { self.deferredReads += 1 }
    }
  }
}
private func notification(context:UnsafeMutableRawPointer?,session:RimeSessionId,type:UnsafePointer<CChar>?,value:UnsafePointer<CChar>?) {
  guard let context else { return }
  Unmanaged<Probe>.fromOpaque(context).takeUnretainedValue().receive(session:session,type:type,value:value)
}
@main enum NativeRimeNotificationProbe {
  static func main() throws {
    let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
    let resource=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
    let files=FileManager.default
    let shared=root.appendingPathComponent("shared"),user=root.appendingPathComponent("user"),logs=root.appendingPathComponent("logs")
    for dir in [shared,user,logs] { try files.createDirectory(at:dir,withIntermediateDirectories:true) }
    for name in ["letter_fixture.schema.yaml","letter_fixture.dict.yaml"] {
      try files.copyItem(at:resource.appendingPathComponent(name),to:shared.appendingPathComponent(name))
      try files.copyItem(at:resource.appendingPathComponent(name),to:user.appendingPathComponent(name))
    }
    try "config_version: '1'\nschema_list:\n  - schema: letter_fixture\n".write(to:shared.appendingPathComponent("default.yaml"),atomically:true,encoding:.utf8)
    var traits=RimeTraits.rimeStructInit()
    traits.setCString(shared.path,to:\.shared_data_dir); traits.setCString(user.path,to:\.user_data_dir)
    traits.setCString(logs.path,to:\.log_dir); traits.setCString("rime.notification_probe",to:\.app_name)
    traits.min_log_level=2
    let probe=Probe(),api=probe.api
    api.setup(&traits); api.initialize(&traits); api.deployer_initialize(&traits)
    defer { api.set_notification_handler(nil,nil); api.finalize() }
    guard api.deploy_config_file("default.yaml","config_version"),
          api.deploy_schema(user.appendingPathComponent("letter_fixture.schema.yaml").path) else { fatalError("Fixture deployment failed") }
    api.set_notification_handler(notification,Unmanaged.passUnretained(probe).toOpaque())
    var checks:[[String:Any]]=[]
    func check(_ name:String,_ pass:Bool) { checks.append(["name":name,"passed":pass]) }
    check("missing_session_never_reads_labels",readyRimeOptionLabels(api:api,session:0,name:"ascii_mode",state:false) == nil)
    var validSessions=0, validLabels=0, staleSessions=0
    for _ in 0..<100 {
      probe.insideCall=true
      let session=api.create_session()
      if session != 0, api.select_schema(session,"letter_fixture") { validSessions += 1 }
      api.set_option(session,"ascii_mode",true); api.set_option(session,"ascii_mode",false)
      probe.insideCall=false
      RunLoop.main.run(until:Date(timeIntervalSinceNow:0.001))
      if let labels=readyRimeOptionLabels(api:api,session:session,name:"ascii_mode",state:false),labels.long == "Chinese",labels.short == "C" { validLabels += 1 }
      probe.insideCall=true
      _ = api.destroy_session(session)
      probe.insideCall=false
      if readyRimeOptionLabels(api:api,session:session,name:"ascii_mode",state:false) == nil { staleSessions += 1 }
    }
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.01))
    check("one_hundred_real_rime_sessions_create_without_crash",validSessions == 100)
    check("ready_sessions_preserve_native_long_and_abbreviated_labels",validLabels == 100)
    check("destroyed_sessions_never_read_labels",staleSessions == 100)
    check("real_option_notifications_exercised",probe.notices >= 200 && probe.deferredReads > 0)
    check("label_reads_happen_after_library_call_returns",!probe.readDuringCall)
    check("superseded_notifications_are_ignored",probe.ignoredReads > 0)
    let ax=NSRange(location:20,length:0),native=NSRange(location:3,length:0)
    let different=VoiceTargetSelection(native:native,accessibility:ax)
    check("imk_and_ax_coordinate_spaces_may_differ",different != nil)
    check("unchanged_independent_ranges_match",different?.matches(native:native,accessibility:ax) == true)
    check("ax_cursor_movement_revokes_target",different?.matches(native:native,accessibility:NSRange(location:21,length:0)) == false)
    check("native_cursor_movement_revokes_target",different?.matches(native:NSRange(location:4,length:0),accessibility:ax) == false)
    check("lost_ax_range_revokes_target",different?.matches(native:native,accessibility:nil) == false)
    let unsupported=NSRange(location:NSNotFound,length:0)
    let axOnly=VoiceTargetSelection(native:unsupported,accessibility:ax)
    check("unsupported_imk_range_uses_verified_ax_range",axOnly?.matches(native:unsupported,accessibility:ax) == true)
    check("changing_imk_capability_revokes_target",axOnly?.matches(native:native,accessibility:ax) == false)
    check("native_range_does_not_require_ax_range",VoiceTargetSelection(native:native,accessibility:nil) != nil)
    check("unknown_ax_offset_does_not_reject_native_keyboard_range",VoiceTargetSelection(native:native,accessibility:unsupported) != nil)
    check("ax_selection_is_frozen_in_its_own_coordinates",VoiceTargetSelection(native:native,accessibility:NSRange(location:20,length:2))?.matches(native:native,accessibility:NSRange(location:20,length:2)) == true)
    check("native_selection_uses_keyboard_replacement_semantics",VoiceTargetSelection(native:NSRange(location:3,length:2),accessibility:ax)?.matches(native:NSRange(location:3,length:2),accessibility:ax) == true)
    check("empty_matching_ranges_remain_compatible",VoiceTargetSelection(native:ax,accessibility:ax)?.matches(native:ax,accessibility:ax) == true)
    check("range_policy_preserves_unsupported_native_pair_for_session_verification",VoiceTargetSelection(native:NSRange(location:NSNotFound,length:NSNotFound),accessibility:nil) != nil)
    check("range_policy_preserves_optional_ax_capability_independently",VoiceTargetSelection(native:NSRange(location:NSNotFound,length:NSNotFound),accessibility:NSRange(location:NSNotFound,length:NSNotFound)) != nil)
    check("overflowing_selection_still_fails",VoiceTargetSelection(native:NSRange(location:Int.max-1,length:10),accessibility:ax) == nil)
    let replacement=VoiceTargetSelection(native:NSRange(location:3,length:2),accessibility:ax)
    check("replacement_selection_changes_revoke_target",replacement?.matches(native:NSRange(location:3,length:1),accessibility:ax) == false)
    let value:[String:Any]=["status":checks.allSatisfy{$0["passed"] as? Bool == true} ? "PASS" : "FAIL","checks":checks,
      "real_option_notifications":probe.notices,"deferred_label_reads":probe.deferredReads,"ignored_notifications":probe.ignoredReads,
      "real_rime_version":api.get_version().map{String(cString:$0)} ?? "unknown","microphone_used":false,"network_calls":0,"personal_dictionary_used":false,
      "scope":"actual production label readiness with real librime C API/disposable fixture and production independent-range policy; not installed IMK/AX notification compatibility"]
    print(String(decoding:try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    if value["status"] as? String != "PASS" { exit(1) }
  }
}
