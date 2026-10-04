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
  func insertText(_ string: Any!, replacementRange: NSRange) {}
  func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) {}
  func selectedRange() -> NSRange { range }
  func markedRange() -> NSRange { marked }
  func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
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
  func windowLevel() -> CGWindowLevel { 0 }
  func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
  func uniqueClientIdentifierString() -> String! { "fixture-client" }
  func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { nil }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect { firstRectOverride ?? rect }
}

@main enum NativeVoiceTargetProbe {
  static func main() throws {
    _ = NSApplication.shared
    guard let screen = NSScreen.screens.first else { fatalError("No screen") }
    let client=FixtureTextClient()
    client.rect=NSRect(x:screen.frame.midX,y:screen.frame.midY,width:1,height:20)
    let originalRect=client.rect
    var window:NativeVoiceTargetSnapshot.Window? = .init(number:17,frame:screen.frame)
    func capture() -> NativeVoiceTargetSnapshot? { .capture(client:client,windowAt:{ _ in window }) }
    var checks:[[String:Any]]=[]
    func check(_ name:String,_ pass:Bool) { checks.append(["name":name,"passed":pass]) }
    check("wechat_ax_no_value_allows_native_verification",NativeVoiceTargetSnapshot.allowsFallback(.noValue))
    check("unsupported_ax_attribute_allows_native_verification",NativeVoiceTargetSnapshot.allowsFallback(.attributeUnsupported))
    check("ax_timeout_never_bypasses_verification",!NativeVoiceTargetSnapshot.allowsFallback(.cannotComplete))
    check("ax_api_disabled_never_bypasses_verification",!NativeVoiceTargetSnapshot.allowsFallback(.apiDisabled))
    check("stale_ax_element_never_bypasses_verification",!NativeVoiceTargetSnapshot.allowsFallback(.invalidUIElement))
    check("working_ax_keeps_existing_strict_path",!NativeVoiceTargetSnapshot.allowsFallback(.success))
    check("finder_missing_ax_window_uses_verified_native_window",NativeVoiceTargetSnapshot.allowsWindowFallback(bundleID:"com.apple.finder",error:.noValue))
    check("finder_unsupported_ax_window_uses_verified_native_window",NativeVoiceTargetSnapshot.allowsWindowFallback(bundleID:"com.apple.finder",error:.attributeUnsupported))
    check("other_apps_keep_required_ax_window",!NativeVoiceTargetSnapshot.allowsWindowFallback(bundleID:"org.rime.target.fixture",error:.noValue))
    check("finder_ax_window_timeout_cannot_bypass_verification",!NativeVoiceTargetSnapshot.allowsWindowFallback(bundleID:"com.apple.finder",error:.cannotComplete))
    check("finder_ax_window_denied_cannot_bypass_verification",!NativeVoiceTargetSnapshot.allowsWindowFallback(bundleID:"com.apple.finder",error:.apiDisabled))
    check("finder_stale_ax_window_cannot_bypass_verification",!NativeVoiceTargetSnapshot.allowsWindowFallback(bundleID:"com.apple.finder",error:.invalidUIElement))
    check("finder_working_ax_window_keeps_existing_strict_path",!NativeVoiceTargetSnapshot.allowsWindowFallback(bundleID:"com.apple.finder",error:.success))
    let snapshot=capture()
    check("native_empty_selection_captures_without_ax",snapshot != nil)
    check("current_caret_uses_inline_index_zero_at_document_offset_320",client.indices == [0] && snapshot?.caret == originalRect)
    check("unchanged_native_position_matches",snapshot?.matches(client:client,windowAt:{ _ in window }) == true)
    client.range=NSRange(location:321,length:0)
    check("native_cursor_movement_revokes_target",snapshot?.matches(client:client,windowAt:{ _ in window }) == false)
    client.range=NSRange(location:320,length:2)
    check("selected_text_never_becomes_native_target",capture() == nil)
    client.range=NSRange(location:NSNotFound,length:NSNotFound)
    check("unknown_selection_length_never_becomes_native_target",capture() == nil)
    client.range=NSRange(location:NSNotFound,length:0)
    let unsupported=capture()
    check("unsupported_document_offset_is_retained_without_inventing_zero",unsupported?.selection.location == NSNotFound && unsupported?.caret == originalRect)
    client.range=NSRange(location:320,length:0)
    check("changing_native_range_capability_revokes_target",unsupported?.matches(client:client,windowAt:{ _ in window }) == false)
    client.rect.origin.x += 2
    check("moving_caret_geometry_revokes_target",snapshot?.matches(client:client,windowAt:{ _ in window }) == false)
    client.rect=originalRect
    window = .init(number:18,frame:screen.frame)
    check("same_range_and_caret_in_other_window_revokes_target",snapshot?.matches(client:client,windowAt:{ _ in window }) == false)
    window = .init(number:17,frame:screen.frame.offsetBy(dx:1,dy:0))
    check("window_move_revokes_target",snapshot?.matches(client:client,windowAt:{ _ in window }) == false)
    window=nil
    check("missing_native_window_cannot_start",capture() == nil)
    check("destroyed_native_window_revokes_target",snapshot?.matches(client:client,windowAt:{ _ in window }) == false)
    window = .init(number:17,frame:screen.frame)
    client.rect = .zero
    check("missing_native_caret_cannot_start",capture() == nil)
    client.rect = NSRect(x:CGFloat.nan,y:0,width:1,height:20)
    check("nonfinite_native_caret_cannot_start",capture() == nil)
    client.rect = originalRect; client.rect.size.width = -1
    check("negative_native_caret_width_cannot_start",capture() == nil)
    client.rect = originalRect.offsetBy(dx:100000,dy:0)
    check("offscreen_native_caret_cannot_start",capture() == nil)
    client.rect=originalRect; client.identifier="com.apple.finder"
    client.range=NSRange(location:0,length:10)
    check("finder_selection_requires_explicit_rename_scope",capture() == nil)
    func renameCapture() -> NativeVoiceTargetSnapshot? { .capture(client:client,finderRename:true,windowAt:{ _ in window }) }
    let rename=renameCapture()
    check("finder_basename_selection_is_owned_by_rename_target",rename?.selection == client.range)
    check("unchanged_finder_selection_remains_eligible",rename?.matches(client:client,windowAt:{ _ in window }) == true)
    client.range=NSRange(location:1,length:10)
    check("moved_finder_selection_revokes_replacement",rename?.matches(client:client,windowAt:{ _ in window }) == false)
    client.range=NSRange(location:0,length:9)
    check("changed_finder_selection_length_revokes_replacement",rename?.matches(client:client,windowAt:{ _ in window }) == false)
    client.range=NSRange(location:0,length:0)
    check("collapsed_finder_selection_revokes_original_replacement",rename?.matches(client:client,windowAt:{ _ in window }) == false)
    client.range=NSRange(location:NSNotFound,length:0)
    let finderEmpty=renameCapture()
    check("finder_known_empty_selection_keeps_offset_less_native_compatibility",finderEmpty?.selection.location == NSNotFound && finderEmpty?.selection.length == 0)
    check("finder_offset_less_empty_selection_remains_eligible",finderEmpty?.matches(client:client,windowAt:{ _ in window }) == true)
    client.range=NSRange(location:NSNotFound,length:10)
    check("finder_unknown_offset_cannot_replace_filename",renameCapture() == nil)
    client.range=NSRange(location:0,length:NSNotFound)
    check("finder_unknown_selection_length_cannot_replace_filename",renameCapture() == nil)
    client.range=NSRange(location:0,length:1025)
    check("finder_selection_size_is_bounded",renameCapture() == nil)
    client.range=NSRange(location:0,length:10);client.identifier="org.rime.target.fixture"
    check("rename_scope_never_allows_other_app_selection",renameCapture() == nil)
    client.identifier="com.apple.finder";client.marked=NSRange(location:0,length:2)
    check("existing_finder_marked_text_is_not_replaced",renameCapture() == nil)
    client.marked=NSRange(location:NSNotFound,length:0);client.rect = .zero;client.firstRectOverride=originalRect
    check("finder_can_use_native_first_rect_without_inline_composition",renameCapture()?.caret == originalRect)
    client.range=NSRange(location:0,length:0);client.identifier="org.rime.target.fixture"
    check("other_apps_do_not_gain_unverified_first_rect_fallback",capture() == nil)
    let report:[String:Any] = ["status":checks.allSatisfy{$0["passed"] as? Bool == true} ? "PASS" : "FAIL",
      "checks":checks,"microphone_used":false,"cloud_calls":0,"document_text_read":false,
      "scope":"Production IMK current-selection snapshot and AX fallback policy with controlled text client/window fixtures; not a WeChat page or live focus-event acceptance"]
    print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    if report["status"] as? String != "PASS" { exit(1) }
  }
}
