import AppKit
import InputMethodKit

// The text client and window inventory are controlled fixtures. Snapshotting
// and comparisons use the production implementation; no real text is read.
final class FixtureTextClient: NSObject, IMKTextInput {
  var range = NSRange(location:320,length:0)
  var rect = NSRect.zero
  var indices: [Int] = []
  var identifier = "org.rime.target.fixture"
  var marked = NSRange(location:NSNotFound,length:0)
  var firstRectOverride: NSRect?
  var clientID: String? = "fixture-client"
  var volatileClientID = false
  var clientIDQueries = 0
  var level: CGWindowLevel = 0
  var textReads = 0
  var textWrites = 0
  func insertText(_ string: Any!, replacementRange: NSRange) { textWrites += 1 }
  func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) { textWrites += 1 }
  func selectedRange() -> NSRange { range }
  func markedRange() -> NSRange { marked }
  func attributedSubstring(from range: NSRange) -> NSAttributedString! { textReads += 1; return nil }
  func length() -> Int { NSNotFound }
  func characterIndex(for point: NSPoint, tracking: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { NSNotFound }
  func attributes(forCharacterIndex index: Int, lineHeightRectangle: UnsafeMutablePointer<NSRect>!) -> [AnyHashable:Any]! {
    indices.append(index)
    lineHeightRectangle.pointee = index == 0 ? rect : .zero
    return [:]
  }
  func validAttributesForMarkedText() -> [Any]! { [] }
  func overrideKeyboard(withKeyboardNamed name: String!) {}
  func selectMode(_ mode: String!) {}
  func supportsUnicode() -> Bool { true }
  func bundleIdentifier() -> String! { identifier }
  func windowLevel() -> CGWindowLevel { level }
  func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
  func uniqueClientIdentifierString() -> String! {
    clientIDQueries += 1
    return volatileClientID ? "changing-client-\(clientIDQueries)" : clientID
  }
  func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { textReads += 1; return nil }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { firstRectOverride ?? rect }
}

@main enum NativeVoiceTargetProbe {
  static func main() throws {
    _ = NSApplication.shared
    guard let screen = NSScreen.screens.first else { fatalError("No screen") }
    let client = FixtureTextClient()
    client.rect = NSRect(x:screen.frame.midX,y:screen.frame.midY,width:1,height:20)
    let originalRect = client.rect
    var window: NativeVoiceTargetSnapshot.Window? = .init(number:17,frame:screen.frame)
    func capture(_ ax: NSRange? = nil, identity: Bool = false) -> NativeVoiceTargetSnapshot? {
      .capture(client:client,accessibilitySelection:ax,hasAccessibilityIdentity:identity,windowAt:{ _ in window })
    }
    var checks: [[String:Any]] = []
    func check(_ name: String,_ pass: Bool) { checks.append(["name":name,"passed":pass]) }
    for error in [AXError.success,.noValue,.attributeUnsupported,.notImplemented,.cannotComplete] {
      check("optional_ax_metadata_\(error.rawValue)_does_not_replace_native_verification",NativeVoiceTargetSnapshot.allowsMissingMetadata(error))
    }
    for error in [AXError.apiDisabled,.invalidUIElement,.invalidUIElementObserver,.illegalArgument,.failure] {
      check("ax_denied_or_invalid_\(error.rawValue)_fails_closed",!NativeVoiceTargetSnapshot.allowsMissingMetadata(error))
    }
    let utility = NativeVoiceTargetSnapshot.WindowCandidate(processID:42,layer:0,
      window:.init(number:16,frame:NSRect(x:screen.frame.minX,y:screen.frame.minY,width:20,height:20)))
    let editor = NativeVoiceTargetSnapshot.WindowCandidate(processID:42,layer:0,window:window!)
    func owned(_ list: [NativeVoiceTargetSnapshot.WindowCandidate],_ frame: NSRect? = screen.frame,
               caret: NSRect? = originalRect, level: CGWindowLevel = 0) -> NativeVoiceTargetSnapshot.Window? {
      NativeVoiceTargetSnapshot.ownedWindow(processID:42,caret:caret,candidates:list,verifiedFrame:frame,windowLevel:level)
    }
    check("verified_ax_window_skips_unrelated_utility_window",owned([utility,editor]) == editor.window)
    check("caret_cannot_select_covered_ordinary_window",owned([utility,editor],nil) == nil)
    check("native_popover_outside_ax_parent_uses_first_owned_native_window",owned([editor],utility.window.frame) == editor.window)
    check("popover_does_not_skip_a_covering_native_window",owned([utility,editor],utility.window.frame) == nil)
    check("ax_window_that_contains_caret_still_requires_matching_cg_frame",owned([editor],screen.frame.insetBy(dx:5,dy:5)) == nil)
    check("another_process_cannot_own_keyboard_window",owned([.init(processID:43,layer:0,window:editor.window)]) == nil)
    check("unrelated_overlay_cannot_own_keyboard_window",owned([.init(processID:42,layer:1,window:editor.window)]) == nil)
    check("native_window_level_identifies_panel_editor",owned([.init(processID:42,layer:3,window:editor.window)],nil,level:3) == editor.window)
    check("native_window_level_still_requires_correct_caret",owned([.init(processID:42,layer:3,window:utility.window)],nil,level:3) == nil)
    check("missing_cg_window_fails",owned([]) == nil)
    check("verified_window_can_bind_without_placement",owned([editor],caret:nil) == editor.window)
    check("missing_caret_and_ax_window_fails",owned([editor],nil,caret:nil) == nil)
    let desktop = NativeVoiceTargetSnapshot.WindowCandidate(processID:42,layer:CGWindowLevelForKey(.desktopIconWindow),window:editor.window)
    check("desktop_editor_uses_owned_layer_without_bundle_exception",owned([utility,desktop],nil) == desktop.window)
    check("foreign_desktop_owner_is_rejected",owned([.init(processID:43,layer:desktop.layer,window:editor.window)],nil) == nil)
    let snapshot = capture()
    check("native_position_captures_without_ax",snapshot != nil)
    check("inline_index_zero_is_shared_with_keyboard_at_absolute_offset_320",client.indices == [0] && snapshot?.caret == originalRect)
    check("candidate_and_voice_use_identical_geometry",KeyboardInputPosition.caret(client:client) == snapshot?.caret)
    check("unchanged_native_target_matches",snapshot?.matches(client:client,windowAt:{ _ in window }) == true)
    for identifier in ["com.apple.finder","com.kingsoft.wpsoffice.mac","com.tencent.xinWeChat","com.apple.TextEdit",
                       "com.google.Chrome","com.openai.codex","example.custom-editor","example.future-app"] {
      client.identifier = identifier
      check("native_client_supported_without_bundle_list_\(identifier)",capture() != nil)
    }
    client.range = NSRange(location:321,length:0)
    check("cursor_move_revokes_target",snapshot?.matches(client:client,windowAt:{ _ in window }) == false)
    client.range = NSRange(location:320,length:10)
    let selected = capture()
    check("keyboard_owned_selection_captures_for_any_client",selected?.selection == client.range)
    check("unchanged_selection_remains_eligible",selected?.matches(client:client,windowAt:{ _ in window }) == true)
    client.range = NSRange(location:321,length:10)
    check("moved_selection_revokes_replacement",selected?.matches(client:client,windowAt:{ _ in window }) == false)
    client.range = NSRange(location:320,length:9)
    check("selection_length_change_revokes_replacement",selected?.matches(client:client,windowAt:{ _ in window }) == false)
    client.range = NSRange(location:320,length:0)
    check("collapsed_selection_revokes_replacement",selected?.matches(client:client,windowAt:{ _ in window }) == false)
    client.marked = NSRange(location:320,length:2)
    check("native_marked_text_is_never_replaced",capture() == nil)
    client.marked = NSRange(location:NSNotFound,length:NSNotFound)
    check("unsupported_native_marked_range_is_not_an_active_composition",capture() != nil)
    client.marked = NSRange(location:0,length:0)
    check("zero_length_marked_range_is_idle",capture() != nil)
    client.marked = NSRange(location:NSNotFound,length:0)
    for range in [NSRange(location:NSNotFound,length:10),NSRange(location:0,length:NSNotFound),
                  NSRange(location:-1,length:0),NSRange(location:0,length:-1),NSRange(location:Int.max-1,length:10)] {
      client.range = range
      check("invalid_or_unowned_selection_\(range.location)_\(range.length)_rejects",capture() == nil)
    }
    client.range = NSRange(location:NSNotFound,length:NSNotFound)
    check("missing_range_api_uses_native_client_id_and_caret",capture() != nil)
    client.clientID = nil
    check("missing_range_and_client_id_fail_without_independent_ax_range",capture() == nil)
    client.clientID = "fixture-client"
    check("independent_known_ax_selection_can_complete_native_evidence",capture(NSRange(location:30,length:0)) != nil)
    check("unsupported_ax_range_does_not_block_native_client_id_and_caret",capture(NSRange(location:NSNotFound,length:NSNotFound)) != nil)
    client.clientID = nil
    check("two_unknown_ranges_without_native_id_cannot_verify",capture(NSRange(location:NSNotFound,length:NSNotFound)) == nil)
    check("known_ax_range_can_verify_unknown_native_range_without_id",capture(NSRange(location:30,length:0)) != nil)
    client.clientID = "fixture-client"
    client.range = NSRange(location:NSNotFound,length:0)
    let offsetless = capture()
    check("unsupported_offset_is_not_invented_as_zero",offsetless?.selection.location == NSNotFound)
    check("unchanged_offsetless_target_matches",offsetless?.matches(client:client,windowAt:{ _ in window }) == true)
    client.range = NSRange(location:320,length:0)
    check("changing_range_capability_revokes",offsetless?.matches(client:client,windowAt:{ _ in window }) == false)
    client.rect.origin.x += 2
    check("caret_move_revokes",snapshot?.matches(client:client,windowAt:{ _ in window }) == false)
    client.rect = originalRect
    client.clientID = "other-input-field"
    check("optional_client_identifier_does_not_override_verified_keyboard_geometry",snapshot?.matches(client:client,windowAt:{ _ in window }) == true)
    client.volatileClientID = true
    check("volatile_identifier_does_not_reject_known_keyboard_target",capture() != nil)
    check("volatile_identifier_does_not_revoke_known_keyboard_target",snapshot?.matches(client:client,windowAt:{ _ in window }) == true)
    client.volatileClientID = false
    client.clientID = "fixture-client"; client.level = 3
    check("native_window_level_change_revokes",snapshot?.matches(client:client,windowAt:{ _ in window }) == false)
    client.level = 0
    window = .init(number:18,frame:screen.frame)
    check("same_range_and_caret_in_another_window_revokes",snapshot?.matches(client:client,windowAt:{ _ in window }) == false)
    window = .init(number:17,frame:screen.frame.offsetBy(dx:1,dy:0))
    check("window_move_revokes",snapshot?.matches(client:client,windowAt:{ _ in window }) == false)
    window = nil
    check("missing_native_window_cannot_start",capture() == nil)
    check("destroyed_window_revokes",snapshot?.matches(client:client,windowAt:{ _ in window }) == false)
    window = .init(number:17,frame:screen.frame)
    client.rect = .zero
    check("missing_caret_without_independent_identity_fails",capture() == nil)
    let noPlacement = capture(identity:true)
    check("verified_field_window_and_native_id_allow_optional_placement",noPlacement != nil && noPlacement?.caret == nil)
    check("no_placement_target_revalidates",noPlacement?.matches(client:client,hasAccessibilityIdentity:true,windowAt:{ _ in window }) == true)
    client.clientID = "other-field"
    check("required_native_identity_change_revokes_no_placement_target",noPlacement?.matches(client:client,hasAccessibilityIdentity:true,windowAt:{ _ in window }) == false)
    client.clientID = "fixture-client";client.volatileClientID = true
    check("volatile_identifier_cannot_supply_missing_placement_evidence",capture(identity:true) == nil)
    client.volatileClientID = false
    check("losing_independent_identity_revokes_no_placement_target",noPlacement?.matches(client:client,windowAt:{ _ in window }) == false)
    client.clientID = nil
    check("missing_native_id_and_caret_fails_even_with_ax_identity",capture(identity:true) == nil)
    client.clientID = "fixture-client"; client.range = NSRange(location:NSNotFound,length:0)
    check("unknown_offset_and_missing_caret_fail_without_ax_range",capture(identity:true) == nil)
    check("known_ax_offset_allows_optional_caret",capture(NSRange(location:10,length:0),identity:true) != nil)
    client.range = NSRange(location:320,length:0)
    client.firstRectOverride = originalRect
    check("native_first_rect_works_for_every_editor",capture()?.caret == originalRect)
    check("keyboard_candidate_uses_the_same_first_rect_fallback",KeyboardInputPosition.caret(client:client) == originalRect)
    client.range = NSRange(location:NSNotFound,length:0)
    check("first_rect_does_not_invent_unknown_offset",capture() == nil)
    client.range = NSRange(location:320,length:0);client.firstRectOverride = nil
    for rect in [NSRect(x:0,y:0,width:1,height:-20),NSRect(x:CGFloat.nan,y:0,width:1,height:20),NSRect(x:0,y:0,width:-1,height:20),
                 originalRect.offsetBy(dx:100000,dy:0),NSRect(x:0,y:0,width:1,height:0)] {
      client.rect = rect
      check("invalid_geometry_is_not_used_as_caret_\(checks.count)",KeyboardInputPosition.caret(client:client) == nil)
    }
    client.rect = originalRect;client.clientID = nil
    check("native_geometry_does_not_require_optional_client_identifier",capture() != nil)
    check("position_capture_never_reads_document_text",client.textReads == 0)
    check("position_capture_never_probes_by_inserting_or_marking",client.textWrites == 0)
    let report: [String:Any] = ["status":checks.allSatisfy { $0["passed"] as? Bool == true } ? "PASS" : "FAIL",
      "checks":checks,"microphone_used":false,"cloud_calls":0,"document_text_read":false,
      "scope":"Production shared keyboard geometry, native input target capabilities and owned-window binding with controlled text clients; not live app or audio acceptance"]
    print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    if report["status"] as? String != "PASS" { exit(1) }
  }
}
