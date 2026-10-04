import AppKit
import EnhancementCore
import EnhancementIPC
import EnhancementUI
import AVFoundation
private final class FakeConnectionProbe:ConnectionProbeTask {
  var cancelled=false
  func cancel() { cancelled=true }
}
private final class FakeVoiceSession:VoiceSession {
  let identity:VoiceIdentity
  let update:(VoiceUpdate,VoiceDiagnosticSnapshot)->Void
  var starts=0, cancellations=0, leases=0
  var startedKey:String?
  var releases:[VoiceStopCause]=[]
  init(identity:VoiceIdentity,update:@escaping(VoiceUpdate,VoiceDiagnosticSnapshot)->Void) {
    self.identity=identity; self.update=update
  }
  func start(key:String) { starts += 1; startedKey=key }
  func release(at:TimeInterval,cause:VoiceStopCause) { releases.append(cause) }
  func cancel() { cancellations += 1; finish(.cancelled) }
  func renewLease() { leases += 1 }
  func clearDiagnostics() {}
  func finish(_ phase:VoicePhase) {
    let now=ProcessInfo.processInfo.systemUptime
    var timeline=VoiceDiagnosticTimeline(identity:identity,revision:nil,mode:.production,
      origin:.helperStart,referenceUptime:now)
    timeline.record(phase == .ready ? .taskFinished : .cancelled,at:now)
    update(VoiceUpdate(identity:identity,phase:phase,text:"",complete:phase == .ready),timeline.snapshot(phase:phase))
  }
}

// Linked with the actual Helper sources (except its @main). All updates here
// are explicit fixtures; neither StreamingSession.start nor AudioCapture.start
// is invoked. This proves native editor/presentation wiring, not cloud ASR.
@main enum NativeVoiceEditorProbe {
  static func main() throws {
    let app=NSApplication.shared; app.setActivationPolicy(.regular); app.finishLaunching()
    let base=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
    let model=HelperModel(baseDirectory:base)
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:240),styleMask:[.titled,.closable],backing:.buffered,defer:false)
    window.title="语音测试框原生离线验证（无采音）"
    let editor=VoiceTestEditor.TestTextView(frame:NSRect(x:10,y:10,width:560,height:200))
    editor.model=model; editor.delegate=editor; editor.isRichText=false; editor.allowsUndo=true
    window.contentView?.addSubview(editor); model.testEditorController.attach(editor)
    window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps:true); window.makeFirstResponder(editor)
    // macOS can deny foreground activation to command-line launches. Wait for
    // the operator/CUA to focus this isolated probe window instead of weakening
    // the actual editor's key-window guard to manufacture a passing insertion.
    let focusDeadline=Date(timeIntervalSinceNow:25)
    while !window.isKeyWindow && Date()<focusDeadline {
      if let event=app.nextEvent(matching:.any,until:Date(timeIntervalSinceNow:0.1),inMode:.default,dequeue:true) { app.sendEvent(event) }
      app.updateWindows()
    }
    var checks:[[String:Any]]=[]
    func check(_ name:String,_ value:Bool) { checks.append(["name":name,"passed":value]) }
    var permissionState:AVAuthorizationStatus = .notDetermined
    var requestCount=0
    var completion:((Bool)->Void)?
    let permissionModel=HelperModel(baseDirectory:base.appendingPathComponent("permission-fixture"),
      microphonePermission:MicrophonePermissionClient(authorization:{permissionState},request:{ callback in
        requestCount += 1; completion=callback
      }))
    check("opening_settings_never_requests_permission",requestCount == 0 && permissionModel.microphoneAuthorization == .notDetermined)
    permissionModel.requestMicrophone(); permissionModel.requestMicrophone()
    check("permission_request_is_explicit_and_not_reentrant",requestCount == 1 && permissionModel.requestingMicrophone)
    permissionState = .denied; completion?(false)
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.05))
    check("denial_is_reported_and_pending_cleared",permissionModel.microphoneAuthorization == .denied && !permissionModel.requestingMicrophone)
    permissionModel.requestMicrophone()
    check("denied_permission_does_not_reprompt",requestCount == 1)
    permissionState = .authorized; permissionModel.refreshMicrophoneAuthorization()
    check("return_from_settings_refreshes_authorization",permissionModel.microphoneAuthorization == .authorized)
    permissionModel.requestMicrophone()
    check("authorized_permission_does_not_reprompt",requestCount == 1)
    permissionState = .restricted; permissionModel.refreshMicrophoneAuthorization()
    check("restricted_permission_is_not_marked_ready",permissionModel.microphoneStatus.contains("限制"))
    var probeTasks:[FakeConnectionProbe]=[]
    var probeResults:[(ConnectionProbeResult)->Void]=[]
    let connectionModel=HelperModel(baseDirectory:base.appendingPathComponent("connection-fixture"),automaticConnectionCheck:false,
      probeFactory:{ _,_,completion in
        let task=FakeConnectionProbe(); probeTasks.append(task); probeResults.append(completion); return task
      })
    connectionModel.draft.voice.region = .beijing; connectionModel.draft.voice.workspace="ws-fixture"
    connectionModel.checkConnectionAutomatically()
    check("incomplete_credentials_do_not_connect",probeTasks.isEmpty)
    connectionModel.newKey="fixture-a"; connectionModel.checkConnectionAutomatically()
    connectionModel.checkConnectionAutomatically()
    check("automatic_connection_is_deduplicated",probeTasks.count == 1 && connectionModel.checkingConnection)
    connectionModel.newKey="fixture-b"; connectionModel.checkConnectionAutomatically()
    check("changing_token_cancels_old_probe",probeTasks.count == 2 && probeTasks[0].cancelled)
    probeResults[0](.webSocketOpened)
    check("stale_success_cannot_validate_new_token",connectionModel.checkingConnection && connectionModel.connectionError == nil)
    probeResults[1](.failed(httpStatus:401))
    check("invalid_key_sets_error_alert",connectionModel.connectionError?.contains("401") == true && !connectionModel.checkingConnection)
    connectionModel.newKey="fixture-c"; connectionModel.checkConnectionAutomatically(); probeResults[2](.webSocketOpened)
    check("successful_authentication_clears_error",connectionModel.connectionError == nil && connectionModel.connectionStatus.contains("鉴权") && !connectionModel.checkingConnection)
    connectionModel.newKey="unsafe\nfixture"; connectionModel.checkConnectionAutomatically()
    check("invalid_header_is_local_error_without_token_echo",probeTasks.count == 3 && connectionModel.connectionError != nil && !connectionModel.connectionStatus.contains("unsafe"))
    let keyReadBase=base.appendingPathComponent("key-read-fixture")
    var keySettings=Settings(); keySettings.voice.credentialReference=UUID().uuidString
    _ = try SettingsStore(url:keyReadBase.appendingPathComponent("settings.json")).save(keySettings)
    let readGate=DispatchSemaphore(value:0)
    var pendingProbeCount=0
    let pendingKeyModel=HelperModel(baseDirectory:keyReadBase,automaticConnectionCheck:false,
      credentialLoader:{ _ in
        guard readGate.wait(timeout:.now()+3) == .success else { throw SettingsError.invalid("fixture timeout") }
        return "fixture-stale-key"
      },probeFactory:{ _,_,_ in pendingProbeCount += 1; return FakeConnectionProbe() })
    check("keychain_read_does_not_block_settings_construction",pendingKeyModel.connectionStatus.contains("正在读取"))
    pendingKeyModel.newKey="editable-fixture"; pendingKeyModel.revert()
    check("settings_remain_editable_while_key_read_waits",pendingKeyModel.newKey.isEmpty)
    pendingKeyModel.deleteKey(); readGate.signal()
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.1))
    pendingKeyModel.testConnection()
    check("deleted_key_cannot_be_revived_by_late_read",pendingProbeCount == 0 && pendingKeyModel.draft.voice.credentialReference == nil)
    let loadedBase=base.appendingPathComponent("loaded-key-fixture")
    keySettings.voice.region = .beijing; keySettings.voice.workspace="ws-fixture"
    _ = try SettingsStore(url:loadedBase.appendingPathComponent("settings.json")).save(keySettings)
    var loadedProbeCount=0
    let loadedKeyModel=HelperModel(baseDirectory:loadedBase,credentialLoader:{ _ in "fixture-loaded-key" },
      probeFactory:{ _,key,_ in loadedProbeCount += key == "fixture-loaded-key" ? 1 : 100; return FakeConnectionProbe() })
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.2))
    check("loaded_key_triggers_automatic_connection_check",loadedProbeCount == 1 && loadedKeyModel.checkingConnection)
    loadedKeyModel.stopAll(cancel:true)
    let delayedBase=base.appendingPathComponent("delayed-key-fixture")
    _ = try SettingsStore(url:delayedBase.appendingPathComponent("settings.json")).save(keySettings)
    let delayedGate=DispatchSemaphore(value:0)
    var delayedProbeCount=0
    let delayedKeyModel=HelperModel(baseDirectory:delayedBase,credentialReadTimeout:0.03,
      credentialLoader:{ _ in
        guard delayedGate.wait(timeout:.now()+1) == .success else { throw SettingsError.invalid("fixture timeout") }
        return "fixture-late-key"
      },probeFactory:{ _,_,_ in delayedProbeCount += 1; return FakeConnectionProbe() })
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.06))
    check("key_read_deadline_reports_actionable_error",delayedKeyModel.connectionError?.contains("超时") == true && delayedProbeCount == 0)
    delayedGate.signal(); RunLoop.main.run(until:Date(timeIntervalSinceNow:0.1))
    check("late_key_permission_can_recover_after_deadline",delayedProbeCount == 1 && delayedKeyModel.connectionError == nil)
    delayedKeyModel.stopAll(cancel:true)
    let replacementBase=base.appendingPathComponent("replacement-key-fixture")
    _ = try SettingsStore(url:replacementBase.appendingPathComponent("settings.json")).save(keySettings)
    let replacementGate=DispatchSemaphore(value:0)
    let replacementKeyModel=HelperModel(baseDirectory:replacementBase,automaticConnectionCheck:false,credentialReadTimeout:0.03,
      credentialLoader:{ _ in
        guard replacementGate.wait(timeout:.now()+1) == .success else { throw SettingsError.invalid("fixture timeout") }
        return "fixture-old-key"
      })
    replacementKeyModel.newKey="fixture-replacement-key"
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.06))
    check("pending_key_read_does_not_interrupt_replacement_entry",replacementKeyModel.connectionError == nil)
    replacementGate.signal()
    // Exercise the actual Helper admission with a real, still-visible settings
    // window. Only microphone/network work is replaced by the session fixture.
    let productionBase=base.appendingPathComponent("production-fixture")
    var productionSettings=keySettings
    productionSettings.voice.enabled=true; productionSettings.voice.binding=TriggerBinding(codes:[58])
    productionSettings.voice.deviceUID="fixture-saved-usb"
    productionSettings.voice.model = .message; productionSettings.voice.nativePolish=true
    let persisted=try SettingsStore(url:productionBase.appendingPathComponent("settings.json")).save(productionSettings)
    var sessions:[FakeVoiceSession]=[]
    var snapshots:[VoiceSettings]=[]
    var modes:[Bool]=[]
    let productionModel=HelperModel(baseDirectory:productionBase,automaticConnectionCheck:false,
      credentialLoader:{ _ in "fixture-production-key" },sessionFactory:{ identity,settings,test,_,_,update in
        snapshots.append(settings); modes.append(test)
        let session=FakeVoiceSession(identity:identity,update:update); sessions.append(session); return session
      })
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.1))
    productionModel.showSettings(); RunLoop.main.run(until:Date(timeIntervalSinceNow:0.15))
    let settingsWindow=NSApp.windows.first{$0.title == "鼠须管增强输入设置（开发隔离版）"}
    check("production_fixture_settings_window_is_visible_and_key",settingsWindow?.isVisible == true && settingsWindow?.isKeyWindow == true && app.isActive)
    func beginProduction(_ id:VoiceIdentity,revision:UInt64? = nil,origin:TimeInterval? = nil) throws {
      productionModel.begin(try Wire.encode(VoiceRequest(identity:id,revision:revision ?? persisted.revision,
        pressUptime:origin ?? ProcessInfo.processInfo.systemUptime)))
      RunLoop.main.run(until:Date(timeIntervalSinceNow:0.03))
    }
    try beginProduction(VoiceIdentity(generation:1))
    check("foreground_settings_rejects_external_production_request",sessions.isEmpty && productionModel.status.contains("焦点"))
    window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.05))
    check("background_settings_remains_open",settingsWindow?.isVisible == true && settingsWindow?.isKeyWindow == false)
    productionModel.draft.voice.deviceUID="fixture-unsaved-built-in"
    productionModel.draft.voice.model = .streaming; productionModel.draft.voice.nativePolish=false
    check("unsaved_microphone_choice_is_clearly_reported",productionModel.productionMicrophoneStatus.contains("尚未保存"))
    let productionID=VoiceIdentity(generation:2)
    try beginProduction(productionID)
    check("background_open_settings_allows_new_production_session",sessions.count == 1 && sessions.first?.starts == 1)
    check("production_freezes_saved_microphone_and_settings",snapshots.first == persisted.voice && modes.first == false)
    check("production_uses_saved_message_model_despite_unsaved_streaming",snapshots.first?.model == .message)
    check("production_uses_saved_native_polish_despite_unsaved_switch",snapshots.first?.nativePolish == true)
    let productionRequest=try JSONSerialization.jsonObject(with:QwenProtocol.run(task:productionID.task,settings:snapshots.first ?? VoiceSettings())) as! [String:Any]
    let productionPayload=productionRequest["payload"] as! [String:Any]
    check("saved_model_reaches_recognition_request",productionPayload["model"] as? String == VoiceModel.message.rawValue)
    check("saved_polish_reaches_recognition_request",(productionPayload["parameters"] as? [String:Any])?["disfluency_removal_enabled"] as? Bool == true)
    try beginProduction(productionID)
    check("duplicate_begin_does_not_restart_production",sessions.count == 1 && sessions.first?.starts == 1)
    NotificationCenter.default.post(name:NSApplication.didResignActiveNotification,object:app)
    NotificationCenter.default.post(name:NSWindow.didResignKeyNotification,object:settingsWindow)
    check("settings_focus_loss_does_not_cancel_other_app_voice",sessions.first?.cancellations == 0)
    productionModel.lease(try Wire.encode(productionID)); RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))
    check("production_lease_survives_settings_focus_loss",sessions.first?.leases == 1)
    try beginProduction(VoiceIdentity(generation:3))
    check("busy_production_session_rejects_second_press",sessions.count == 1)
    productionModel.release(try Wire.encode(VoiceRelease(identity:productionID,uptime:ProcessInfo.processInfo.systemUptime,cause:.keyReleased)))
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))
    check("physical_release_reaches_current_production_owner",sessions.first?.releases == [.keyReleased])
    productionModel.revert()
    check("closing_background_settings_does_not_cancel_production",productionModel.confirmClosing() && sessions.first?.cancellations == 0)
    settingsWindow?.close()
    check("background_window_close_notification_preserves_production",sessions.first?.cancellations == 0)
    sessions.first?.finish(.ready)
    let nextID=VoiceIdentity(generation:4)
    try beginProduction(nextID)
    check("next_production_press_starts_after_terminal_result",sessions.count == 2)
    productionModel.showSettings(); RunLoop.main.run(until:Date(timeIntervalSinceNow:0.03))
    check("opening_settings_explicitly_cancels_existing_production",sessions.last?.cancellations == 1)
    window.makeKeyAndOrderFront(nil); RunLoop.main.run(until:Date(timeIntervalSinceNow:0.03))
    try beginProduction(VoiceIdentity(generation:5),origin:ProcessInfo.processInfo.systemUptime-1)
    check("delayed_press_from_before_settings_open_cannot_start",sessions.count == 2 && productionModel.status.contains("失效"))
    try beginProduction(VoiceIdentity(generation:6),revision:persisted.revision+1)
    check("stale_configuration_request_cannot_start",sessions.count == 2 && productionModel.status.contains("同步"))
    productionModel.deploymentReply(try Wire.encode("focus-status:required")); RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))
    check("actual_frontend_missing_permission_is_visible",productionModel.focusPermissionStatus.contains("辅助功能") && productionModel.focusPermissionStatus.contains("测试无需"))
    productionModel.deploymentReply(try Wire.encode("focus-status:allowed")); RunLoop.main.run(until:Date(timeIntervalSinceNow:0.02))
    check("actual_frontend_granted_permission_is_visible",productionModel.focusPermissionStatus.contains("已允许"))
    productionModel.showSettings(); RunLoop.main.run(until:Date(timeIntervalSinceNow:0.03))
    productionModel.draft.voice.deviceUID="fixture-unsaved-built-in"
    productionModel.draft.voice.model = .message; productionModel.draft.voice.nativePolish=false
    productionModel.testHold(cloud:true,action:.start(UUID()))
    check("settings_test_still_uses_draft_microphone",sessions.count == 3 && snapshots.last == productionModel.draft.voice && modes.last == true)
    check("settings_test_uses_unsaved_message_and_polish_off",snapshots.last?.model == .message && snapshots.last?.nativePolish == false)
    productionModel.draft.voice.model = .streaming; productionModel.draft.voice.nativePolish=true
    check("active_settings_test_keeps_frozen_model_and_polish",snapshots.last?.model == .message && snapshots.last?.nativePolish == false)
    check("model_selection_keeps_saved_key_reference",snapshots.last?.credentialReference == persisted.voice.credentialReference)
    let testRequest=try JSONSerialization.jsonObject(with:QwenProtocol.run(task:sessions.last!.identity.task,settings:snapshots.last!)) as! [String:Any]
    check("test_request_keeps_message_partials_and_polish_off",((testRequest["payload"] as? [String:Any])?["parameters"] as? [String:Any])?["disfluency_removal_enabled"] as? Bool == false)
    NotificationCenter.default.post(name:NSApplication.didResignActiveNotification,object:app)
    check("leaving_settings_still_cancels_its_own_test",sessions.count == 3 && sessions.last?.cancellations == 1)
    productionModel.stopAll(cancel:true); settingsWindow?.orderOut(nil)
    window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
    productionModel.revert()
    try beginProduction(VoiceIdentity(generation:7))
    check("explicit_helper_quit_still_cancels_production",sessions.count == 4 && productionModel.confirmClosing(stoppingProduction:true) && sessions.last?.cancellations == 1)
    let doubaoBase=base.appendingPathComponent("doubao-provider-fixture")
    var providerSettings=productionSettings
    providerSettings.voice.model = .doubao
    providerSettings.voice.doubao.credentialReference=UUID().uuidString
    providerSettings.voice.doubao.resource = .bigConcurrent
    providerSettings.voice.doubao.nativePolish=true
    let providerSaved=try SettingsStore(url:doubaoBase.appendingPathComponent("settings.json")).save(providerSettings)
    var providerSessions:[FakeVoiceSession]=[], providerSnapshots:[VoiceSettings]=[]
    let qwenReference=providerSaved.voice.credentialReference
    let providerModel=HelperModel(baseDirectory:doubaoBase,automaticConnectionCheck:false,
      credentialLoader:{ ref in ref == qwenReference ? "fixture-qwen-only" : "fixture-doubao-only" },
      sessionFactory:{ identity,settings,_,_,_,update in
        providerSnapshots.append(settings)
        let session=FakeVoiceSession(identity:identity,update:update); providerSessions.append(session); return session
      })
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.1))
    check("doubao_loading_keeps_both_provider_references",providerModel.draft.voice.credentialReference == qwenReference && providerModel.draft.voice.doubao.credentialReference == providerSaved.voice.doubao.credentialReference)
    providerModel.draft.voice.model = .streaming; providerModel.newKey="fixture-unsaved-qwen"
    window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
    let providerID=VoiceIdentity(generation:20)
    providerModel.begin(try Wire.encode(VoiceRequest(identity:providerID,revision:providerSaved.revision,pressUptime:ProcessInfo.processInfo.systemUptime)))
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.03))
    check("doubao_production_uses_saved_provider_despite_unsaved_qwen",providerSnapshots.first?.model == .doubao && providerSessions.count == 1)
    check("doubao_production_uses_only_saved_doubao_secret",providerSessions.first?.startedKey == "fixture-doubao-only")
    check("doubao_production_freezes_resource_and_native_polish",providerSnapshots.first?.doubao.resource == .bigConcurrent && providerSnapshots.first?.doubao.nativePolish == true)
    providerModel.draft.voice.doubao.nativePolish=false; providerModel.draft.voice.doubao.resource = .seedDuration
    check("doubao_active_request_is_not_changed_by_form_edits",providerSnapshots.first == providerSaved.voice)
    providerSessions.first?.finish(.ready)
    providerModel.draft.voice.model = .doubao; providerModel.newDoubaoKey="fixture-unsaved-doubao"
    providerModel.testHold(cloud:true,action:.start(UUID()))
    check("doubao_settings_test_uses_only_entered_doubao_secret",providerSessions.count == 2 && providerSessions.last?.startedKey == "fixture-unsaved-doubao")
    check("doubao_settings_test_uses_draft_resource_and_polish",providerSnapshots.last?.doubao.resource == .seedDuration && providerSnapshots.last?.doubao.nativePolish == false)
    providerModel.stopAll(cancel:true)
    providerModel.draft.voice.model = .message; providerModel.newKey=""; providerModel.testHold(cloud:true,action:.start(UUID()))
    check("qwen_test_after_doubao_uses_its_own_saved_secret",providerSessions.count == 3 && providerSessions.last?.startedKey == "fixture-qwen-only" && providerSnapshots.last?.model == .message)
    providerModel.stopAll(cancel:true)
    providerModel.revert()
    check("revert_clears_both_unsaved_secrets_and_preserves_saved_provider",providerModel.newKey.isEmpty && providerModel.newDoubaoKey.isEmpty && providerModel.draft == providerSaved)
    var providerProbes:[FakeConnectionProbe]=[], probeHeaders:[[String:String]]=[]
    let providerCheck=HelperModel(baseDirectory:base.appendingPathComponent("doubao-connection-fixture"),automaticConnectionCheck:false,
      probeFactory:{ settings,key,_ in
        probeHeaders.append(try settings.connectionHeaders(key:key,task:UUID()))
        let task=FakeConnectionProbe(); providerProbes.append(task); return task
      })
    providerCheck.draft.voice.model = .doubao; providerCheck.newKey="fixture-qwen-never-fallback"
    providerCheck.checkConnectionAutomatically()
    check("missing_doubao_secret_never_falls_back_to_qwen",providerProbes.isEmpty)
    providerCheck.newDoubaoKey="fixture-doubao-api"; providerCheck.checkConnectionAutomatically()
    check("doubao_automatic_auth_probe_uses_documented_api_headers",providerProbes.count == 1 && probeHeaders.first?["X-Api-Key"] == "fixture-doubao-api" && probeHeaders.first?["Authorization"] == nil)
    providerCheck.draft.voice.doubao.resource = .seedConcurrent; providerCheck.checkConnectionAutomatically()
    check("changing_doubao_resource_cancels_and_rechecks_probe",providerProbes.count == 2 && providerProbes[0].cancelled && probeHeaders.last?["X-Api-Resource-Id"] == "volc.seedasr.sauc.concurrent")
    providerCheck.draft.voice.doubao.authentication = .appAccessToken; providerCheck.draft.voice.doubao.appID="12345"
    providerCheck.checkConnectionAutomatically()
    check("legacy_doubao_mode_rechecks_with_app_and_access_headers",providerProbes.count == 3 && providerProbes[1].cancelled && probeHeaders.last?["X-Api-App-Key"] == "12345" && probeHeaders.last?["X-Api-Access-Key"] == "fixture-doubao-api" && probeHeaders.last?["X-Api-Key"] == nil)
    providerCheck.stopAll(cancel:true)
    model.testEditorController.restoreFocusIfNeeded()
    let preview=EnhancementPreview(title:"离线浮窗布局测试",dismissInterval:0.05)
    let previewID=VoiceIdentity(generation:0)
    preview.begin(previewID,showPreview:true)
    let panel=NSApp.windows.first { $0.title == "离线浮窗布局测试" }
    check("preview_is_compact_borderless_nonactivating",panel?.frame.width == 340 && (panel?.frame.height ?? 999) < 140 && panel?.styleMask.contains(.titled) == false && panel?.canBecomeKey == false)
    check("preview_uses_native_rounded_material",(panel?.contentView as? NSVisualEffectView)?.material == .popover && panel?.contentView?.layer?.cornerRadius == 16)
    preview.update(VoiceUpdate(identity:previewID,phase:.recording,text:String(repeating:"这是长段落识别预览。",count:200),complete:false,level:0.5,duration:8))
    func descendants(_ view:NSView) -> [NSView] { [view]+view.subviews.flatMap(descendants) }
    let previewScroll=panel?.contentView.flatMap { descendants($0).compactMap{$0 as? NSScrollView}.first }
    let document=previewScroll?.documentView as? NSTextView
    check("long_preview_is_bounded_and_full_text_scrolls",(panel?.frame.height ?? 999) <= 238 && panel?.frame.width == 340 &&
      (document?.frame.height ?? 0) > (previewScroll?.contentView.bounds.height ?? 999) && document?.string.count == 2000)
    check("preview_never_changes_key_window",window.isKeyWindow && window.firstResponder === editor)
    if let panel,let screen=NSScreen.screens.first(where:{$0.frame.intersects(panel.frame)}) {
      check("default_overlay_is_centered_above_dock",abs(panel.frame.midX-screen.visibleFrame.midX)<1 && panel.frame.minY >= screen.visibleFrame.minY+19 && panel.frame.maxY < screen.visibleFrame.midY)
    } else { check("default_overlay_is_centered_above_dock",false) }
    check("legacy_overlay_defaults_to_ten_percent_transparency",abs((panel?.alphaValue ?? 0)-0.9)<0.001)
    if let screen=NSScreen.main {
      let caret=NSRect(x:screen.visibleFrame.midX,y:screen.visibleFrame.midY,width:1,height:20)
      preview.begin(VoiceIdentity(generation:200),showPreview:true,transparency:0.45,atCaret:true,anchor:caret)
      check("configured_transparency_is_applied_to_native_panel",abs((panel?.alphaValue ?? 0)-0.55)<0.001)
      check("caret_mode_places_overlay_below_current_caret",panel?.frame.minX == caret.minX && abs((panel?.frame.maxY ?? 0)-(caret.minY-8))<1)
      preview.begin(VoiceIdentity(generation:201),showPreview:true,transparency:0,atCaret:false,anchor:caret)
      check("unchecked_caret_mode_ignores_caret_location",abs((panel?.frame.midX ?? 0)-screen.visibleFrame.midX)<1 && panel?.alphaValue == 1)
      preview.begin(VoiceIdentity(generation:202),showPreview:true,atCaret:true,anchor:nil)
      check("missing_caret_falls_back_to_dock_position",abs((panel?.frame.midX ?? 0)-screen.visibleFrame.midX)<1 && (panel?.frame.minY ?? -1)>=screen.visibleFrame.minY+19)
    } else {
      for name in ["configured_transparency_is_applied_to_native_panel","caret_mode_places_overlay_below_current_caret","unchecked_caret_mode_ignores_caret_location","missing_caret_falls_back_to_dock_position"] { check(name,false) }
    }
    let secondary=NSRect(x:-1920,y:0,width:1920,height:1080), visible=NSRect(x:-1920,y:80,width:1920,height:975)
    let lowCaret=NSRect(x:-10,y:85,width:1,height:20)
    let edge=EnhancementPreview.placement(size:NSSize(width:340,height:200),screen:secondary,visible:visible,caret:lowCaret)
    check("secondary_display_caret_moves_above_and_clamps_edges",edge.minY == 113 && edge.maxX == visible.maxX && visible.contains(edge))
    let dock=EnhancementPreview.placement(size:NSSize(width:340,height:112),screen:secondary,visible:visible,caret:nil)
    check("secondary_display_dock_position_respects_negative_coordinates",dock.midX == -960 && dock.minY == 100 && visible.contains(dock))
    preview.clear()
    check("clearing_preview_hides_window",panel?.isVisible == false)
    let terminalPreviewID=VoiceIdentity(generation:101)
    preview.begin(terminalPreviewID,showPreview:true)
    preview.update(VoiceUpdate(identity:terminalPreviewID,phase:.failed,text:"",complete:false,message:"测试失败"))
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.1))
    check("terminal_error_preview_hides_automatically",panel?.isVisible == false)
    preview.notice("就绪提示")
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.1))
    check("readiness_notice_hides_automatically",panel?.isVisible == false)
    let recoverID=VoiceIdentity(generation:103)
    preview.begin(recoverID,showPreview:true)
    preview.update(VoiceUpdate(identity:recoverID,phase:.review,text:"可恢复的离线草稿",complete:true))
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.1))
    check("hidden_terminal_draft_remains_recoverable",panel?.isVisible == false && preview.hasRecoverableDraft)
    preview.showDraft()
    let copyButton=panel?.contentView.flatMap { descendants($0).compactMap{$0 as? NSButton}.first{$0.title == "复制草稿"} }
    let discardButton=panel?.contentView.flatMap { descendants($0).compactMap{$0 as? NSButton}.first{$0.title == "丢弃"} }
    check("restoring_draft_shows_text_and_copy_control",panel?.isVisible == true && document?.string == "可恢复的离线草稿" && copyButton?.isEnabled == true)
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.1))
    check("explicitly_restored_draft_stays_open",panel?.isVisible == true)
    check("draft_recovery_does_not_steal_input_focus",window.isKeyWindow && window.firstResponder === editor)
    discardButton?.performClick(nil)
    check("discard_removes_recovery_and_hides_panel",!preview.hasRecoverableDraft && panel?.isVisible == false)
    preview.showDraft()
    check("discarded_draft_cannot_reappear",panel?.isVisible == false)
    let cancelledID=VoiceIdentity(generation:104)
    preview.begin(cancelledID,showPreview:true)
    preview.update(VoiceUpdate(identity:cancelledID,phase:.recording,text:"取消草稿",complete:false))
    preview.update(VoiceUpdate(identity:cancelledID,phase:.cancelled,text:"取消草稿",complete:false))
    check("cancelled_preview_clears_draft_and_hides_panel",!preview.hasRecoverableDraft && panel?.isVisible == false)
    preview.notice("旧提示"); preview.begin(VoiceIdentity(generation:102),showPreview:true)
    RunLoop.main.run(until:Date(timeIntervalSinceNow:0.1))
    check("old_dismiss_timer_cannot_hide_new_recording",panel?.isVisible == true)
    preview.clear()
    func prepare(_ source:String,_ range:NSRange) -> VoiceIdentity {
      window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
      editor.string=source; editor.setSelectedRange(range)
      let id=VoiceIdentity(generation:UInt64(checks.count+1))
      model.beginTestPresentation(identity:id,intoTestEditor:true); return id
    }
    func render(_ id:VoiceIdentity,_ phase:VoicePhase,_ text:String,_ complete:Bool) {
      model.renderTestVoiceUpdate(VoiceUpdate(identity:id,phase:phase,text:text,complete:complete,level:0.4,duration:1))
    }
    check("real_window_and_editor_have_focus",model.testEditorController.isFocused)
    if !model.testEditorController.isFocused { fputs("Focus diagnostic: active=\(app.isActive), key=\(window.isKeyWindow), editor=\(window.firstResponder === editor), hidden=\(editor.isHiddenOrHasHiddenAncestor)\n",stderr) }
    model.draft.voice.previewTransparency=0.6;model.draft.voice.previewAtCaret=true
    let anchorID=prepare("光标测试",NSRange(location:2,length:0))
    let testPanel=NSApp.windows.first{$0.title == "语音输入测试 · 实时预览"}
    let editorAnchor=model.testEditorController.anchor()
    check("test_editor_supplies_current_caret_bounds",editorAnchor != nil && (editorAnchor?.height ?? 999)<editor.bounds.height)
    check("helper_test_overlay_uses_draft_transparency",abs((testPanel?.alphaValue ?? 0)-0.4)<0.001)
    model.draft.voice.previewTransparency=0;model.draft.voice.previewAtCaret=false
    render(anchorID,.recording,"布局测试",false)
    check("active_test_overlay_keeps_frozen_presentation",abs((testPanel?.alphaValue ?? 0)-0.4)<0.001 && testPanel?.frame.minX == editorAnchor?.minX)
    let id=prepare("甲😀乙",NSRange(location:1,length:2))
    check("overlay_does_not_steal_editor_focus",window.firstResponder === editor && window.isKeyWindow)
    render(id,.recording,"临时结果",false)
    check("partial_is_preview_only",editor.string == "甲😀乙")
    render(id,.ready,"中文",true)
    check("final_replaces_utf16_selection_once",editor.string == "甲中文乙")
    check("successful_input_hides_test_overlay_immediately",NSApp.windows.first{$0.title == "语音输入测试 · 实时预览"}?.isVisible == false)
    render(id,.ready,"中文",true)
    check("duplicate_final_does_not_insert_again",editor.string == "甲中文乙")
    let next=prepare(editor.string,NSRange(location:4,length:0))
    render(next,.ready,"下一段",true)
    check("next_session_inserts_at_current_cursor",editor.string == "甲中文乙下一段")
    let moved=prepare("原文",NSRange(location:2,length:0)); editor.setSelectedRange(NSRange(location:0,length:0))
    render(moved,.ready,"迟到",true)
    check("cursor_change_rejects_late_final",editor.string == "原文")
    let edited=prepare("原文",NSRange(location:2,length:0)); editor.insertText("手动",replacementRange:NSRange(location:2,length:0))
    render(edited,.ready,"迟到",true)
    check("manual_edit_is_preserved",editor.string == "原文手动")
    let lost=prepare("原文",NSRange(location:2,length:0)); window.makeFirstResponder(nil)
    render(lost,.ready,"迟到",true)
    check("focus_loss_rejects_late_final",editor.string == "原文")
    let unsafe=prepare("原文",NSRange(location:2,length:0)); render(unsafe,.ready,"结果\n",true)
    check("control_characters_never_insert",editor.string == "原文")
    let incomplete=prepare("原文",NSRange(location:2,length:0)); render(incomplete,.ready,"结果",false)
    check("incomplete_final_never_inserts",editor.string == "原文")
    render(incomplete,.failed,"草稿",false)
    check("failed_task_keeps_editor_text",editor.string == "原文")
    let old=prepare("原文",NSRange(location:2,length:0)); _=prepare("原文",NSRange(location:2,length:0))
    render(old,.ready,"旧结果",true)
    check("foreign_session_cannot_write_editor",editor.string == "原文")
    check("missing_api_key_is_not_ready",model.editorVoiceReadiness?.contains("API Key") == true)
    model.stopAll(cancel:true); model.testEditorController.detach(editor); window.orderOut(nil)
    let result:[String:Any]=["checks":checks,"status":checks.allSatisfy{$0["passed"] as? Bool == true} ? "PASS" : "FAIL",
      "microphone_used":false,"cloud_calls":0,"input_source_changed":false,
      "layer":"real AppKit editor/overlay and actual Helper production admission/window lifecycle; injected session boundary and permission fixtures; not actual TCC, physical hotkeys, microphone or cloud"]
    let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
    print(String(decoding:data,as:UTF8.self))
    if result["status"] as? String != "PASS" { exit(1) }
  }
}
