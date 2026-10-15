import AppKit
import InputMethodKit
import EnhancementCore
import EnhancementIPC
import Carbon

// These clients are local objects with no connection to a real text field.
// Exercise BOTH security states deterministically without toggling macOS secure
// input. This symbol exists only in the test executable, never in the app build.
private enum KeyboardProbeSecurity { static var secure = false }
func IsSecureEventInputEnabled() -> Bool { KeyboardProbeSecurity.secure }

// Compile the real controller, panel and Rime calls against an in-memory IMK
// client. Only transport/startup paths are stubbed: no live app, Keychain or mic.
protocol EnhancementInput: AnyObject {
  func voiceReceived(_ value: VoiceUpdate)
  func enhancementConfigurationChanged(_ value: Settings)
  func enhancementDeploy(action: String, schema: String)
  func enhancementInvalidated()
}
final class EnhancementBridge {
  static let shared = EnhancementBridge()
  var settings = Settings()
  weak var input: EnhancementInput?
  var connected: Bool { false }
  var helper: HelperCommands? { nil }
  @discardableResult func launchIfNeeded() -> Bool { false }
  func openSettings() {}
  func reply(_ value: String) {}
}
enum SquirrelApp {
  static var userDir = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("user")
  static var logDir = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("logs")
  static let appDir = Bundle.main.bundleURL
  static func prepareUserDirectory() throws {}
}

final class KeyboardProbeClient: NSObject, IMKTextInput {
  var committed = "", marked = "", fallback = ""
  var geometryQueries = 0, rangeQueries = 0
  var bundleQueries = 0
  var queryDelay: TimeInterval = 0
  var bundleQueryDelay: TimeInterval = 0
  var bundle = "org.rime.KeyboardProbeClient"
  var onGeometry: (() -> Void)?
  var geometryAvailable = true
  var fallbackRect: NSRect = .zero
  lazy var proxy: Any = KeyboardProbeWrapClient(self)
  private func text(_ value: Any?) -> String {
    (value as? NSAttributedString)?.string ?? (value as? String ?? "")
  }
  func insertText(_ string: Any!, replacementRange: NSRange) { committed += text(string); marked = "" }
  func setMarkedText(_ string: Any!, selectionRange: NSRange, replacementRange: NSRange) { marked = text(string) }
  func selectedRange() -> NSRange { rangeQueries += 1; return NSRange(location: 0, length: 0) }
  func markedRange() -> NSRange { NSRange(location: 0, length: marked.utf16.count) }
  func attributedSubstring(from range: NSRange) -> NSAttributedString! { nil }
  func length() -> Int { committed.utf16.count }
  func characterIndex(for point: NSPoint, tracking: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>!) -> Int { 0 }
  func attributes(forCharacterIndex index: Int, lineHeightRectangle: UnsafeMutablePointer<NSRect>!) -> [AnyHashable: Any]! {
    geometryQueries += 1
    if queryDelay > 0 { Thread.sleep(forTimeInterval: queryDelay) }
    onGeometry?()
    let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1000, height: 1000)
    lineHeightRectangle?.pointee = geometryAvailable ? NSRect(x: screen.midX, y: screen.midY, width: 1, height: 18) : .zero
    return [:]
  }
  func validAttributesForMarkedText() -> [Any]! { [] }
  func overrideKeyboard(withKeyboardNamed name: String!) {}
  func selectMode(_ modeIdentifier: String!) {}
  func supportsUnicode() -> Bool { true }
  func bundleIdentifier() -> String! {
    bundleQueries += 1
    if bundleQueryDelay > 0 { Thread.sleep(forTimeInterval: bundleQueryDelay) }
    return bundle
  }
  func windowLevel() -> CGWindowLevel { 0 }
  func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
  func uniqueClientIdentifierString() -> String! { "keyboard-probe-client" }
  func string(from range: NSRange, actualRange: NSRangePointer!) -> String! { nil }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer!) -> NSRect {
    actualRange?.pointee = range
    return fallbackRect
  }
}

@main enum NativeKeyboardInputProbe {
  static func main() throws {
    let secureInputAtStart = Carbon.IsSecureEventInputEnabled()
    let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let resource = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let files = FileManager.default, api = rime_get_api_stdbool().pointee
    guard dlopen(CommandLine.arguments[4], RTLD_NOW | RTLD_GLOBAL) != nil else { fatalError("Lua plugin load failed") }
    let shared = root.appendingPathComponent("shared"), user = SquirrelApp.userDir
    for dir in [shared, user, SquirrelApp.logDir] { try files.createDirectory(at: dir, withIntermediateDirectories: true) }
    for name in ["letter_fixture.schema.yaml", "letter_fixture.dict.yaml"] {
      try files.copyItem(at: resource.appendingPathComponent(name), to: shared.appendingPathComponent(name))
      try files.copyItem(at: resource.appendingPathComponent(name), to: user.appendingPathComponent(name))
    }
    try files.createDirectory(at: user.appendingPathComponent("lua"), withIntermediateDirectories: true)
    try files.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[3]), to: user.appendingPathComponent("lua/letter_selection.lua"))
    try "config_version: '1'\nschema_list:\n  - schema: letter_fixture\n".write(to: shared.appendingPathComponent("default.yaml"), atomically: true, encoding: .utf8)
    try "patch:\n  engine/processors/@before 0: lua_processor@*letter_selection\n  menu/page_size: 9\n  letter_selection/keys: asdfghjkl\n".write(to: user.appendingPathComponent("letter_fixture.custom.yaml"), atomically: true, encoding: .utf8)
    try "config_version: '1'\nstyle:\n  inline_preedit: true\n  inline_candidate: false\nshow_notifications_when: never\n".write(to: shared.appendingPathComponent("squirrel.yaml"), atomically: true, encoding: .utf8)
    var traits = RimeTraits.rimeStructInit()
    traits.setCString(shared.path, to: \.shared_data_dir); traits.setCString(user.path, to: \.user_data_dir)
    traits.setCString(SquirrelApp.logDir.path, to: \.log_dir); traits.setCString("rime.keyboard_probe", to: \.app_name)
    traits.min_log_level = 2
    let modules = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: 4)
    for (index, name) in ["default", "lua", "deployer"].enumerated() { modules[index] = UnsafePointer(strdup(name)) }
    modules[3] = nil; traits.modules = modules
    api.setup(&traits); api.initialize(&traits); api.deployer_initialize(&traits)
    guard api.deploy_config_file("default.yaml", "config_version"), api.deploy_config_file("squirrel.yaml", "config_version"),
          api.deploy_schema(user.appendingPathComponent("letter_fixture.schema.yaml").path) else { fatalError("Fixture deployment failed") }
    defer { api.finalize() }
    let app = NSApplication.shared, delegate = SquirrelApplicationDelegate()
    app.delegate = delegate; app.setActivationPolicy(.accessory)
    delegate.panel = SquirrelPanel(position: .zero); delegate.loadSettings()
    EnhancementBridge.shared.settings.letters["letter_fixture"] = LetterProfile()
    EnhancementBridge.shared.settings.letters["letter_fixture"]?.enabled = true
    let server = IMKServer(name: "KeyboardProbe-" + UUID().uuidString,
      bundleIdentifier: Bundle.main.bundleIdentifier)
    var checks: [[String: Any]] = [], metrics: [String: Any] = [:]
    func check(_ name: String, _ pass: Bool) { checks.append(["name": name, "passed": pass]) }
    func visibleFallback() -> Bool {
      guard let panel = delegate.panel, let screen = NSScreen.main else { return false }
      let usable = screen.visibleFrame
      return panel.isVisible && usable.contains(panel.frame) &&
        abs(panel.frame.midX - usable.midX) < 1 &&
        panel.frame.minY >= usable.minY + 8 && panel.frame.minY <= usable.minY + 64
    }
    func pump(_ duration: TimeInterval = 0.08) {
      // CLI fixtures need the autorelease boundary provided by an app event loop.
      autoreleasepool { RunLoop.main.run(until: Date(timeIntervalSinceNow: duration)) }
    }
    func event(_ text: String, code: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
      NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
        characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }
    func send(_ controller: SquirrelInputController, _ client: KeyboardProbeClient, _ text: String, code: UInt16 = 0) -> Bool {
      let accepted = controller.handle(event(text, code: code), client: client.proxy)
      if !accepted { client.fallback += text }
      return accepted
    }
    do {
      let client = KeyboardProbeClient()
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      client.queryDelay = 0.04
      let start = ProcessInfo.processInfo.systemUptime
      for c in "nihao" { _ = send(controller, client, String(c)) }
      let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
      metrics["hidden_candidates_five_keys_ms"] = elapsed
      metrics["hidden_candidates_geometry_queries"] = client.geometryQueries
      check("first_five_letters_are_pinyin", client.fallback.isEmpty && !client.marked.isEmpty && client.committed.isEmpty)
      check("hidden_candidates_never_query_host_geometry", client.geometryQueries == 0)
      let before = client.geometryQueries, opened = ProcessInfo.processInfo.systemUptime
      _ = send(controller, client, " ", code: 49)
      metrics["space_handler_ms"] = (ProcessInfo.processInfo.systemUptime - opened) * 1000
      check("visible_panel_geometry_is_outside_key_handler", client.geometryQueries == before)
      pump()
      check("visible_panel_eventually_queries_caret", client.geometryQueries > before)
      _ = send(controller, client, "a")
      check("normal_letter_selection_still_commits", !client.committed.isEmpty && client.fallback.isEmpty)
      controller.deactivateServer(client.proxy)
    }
    do {
      api.finalize()
      let client = KeyboardProbeClient()
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      for c in "nix" { _ = send(controller, client, String(c)) }
      _ = send(controller, client, "\u{7f}", code: 51)
      check("pending_backspace_edits_visible_prefix", client.marked == "ni" && client.fallback.isEmpty)
      api.initialize(&traits); pump(0.15)
      for c in "hao" { _ = send(controller, client, String(c)) }
      _ = send(controller, client, " ", code: 49); pump(); _ = send(controller, client, "a")
      check("pending_backspace_replays_exactly_once", client.committed == "你好" && client.fallback.isEmpty)
      controller.deactivateServer(client.proxy)
    }
    do {
      api.finalize()
      let client = KeyboardProbeClient()
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      _ = send(controller, client, "n"); _ = send(controller, client, "i")
      _ = send(controller, client, "\u{1b}", code: 53)
      check("pending_escape_cancels_without_committing", client.marked.isEmpty && client.committed.isEmpty && client.fallback.isEmpty)
      api.initialize(&traits); pump(0.15)
      check("cancelled_prefix_never_reappears", client.marked.isEmpty && client.committed.isEmpty)
      controller.deactivateServer(client.proxy)
    }
    do {
      api.finalize()
      let first = KeyboardProbeClient(), second = KeyboardProbeClient()
      second.bundle = "org.rime.KeyboardProbeSecondClient"
      let controller = SquirrelInputController(server: server, delegate: nil, client: first.proxy)!
      controller.activateServer(first.proxy)
      _ = send(controller, first, "n"); _ = send(controller, first, "i")
      controller.deactivateServer(first.proxy)
      controller.activateServer(second.proxy)
      _ = send(controller, second, "h"); _ = send(controller, second, "a")
      api.initialize(&traits); pump(0.15)
      _ = send(controller, second, "o"); _ = send(controller, second, " ", code: 49)
      pump(); _ = send(controller, second, "a")
      check("blur_keeps_raw_prefix_only_in_original_client", first.committed == "ni" && first.marked.isEmpty)
      check("new_client_never_receives_old_pending_keys", second.committed == "好" && second.fallback.isEmpty)
      controller.deactivateServer(second.proxy)
    }
    do {
      let client = KeyboardProbeClient()
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      NotificationCenter.default.post(name: .init("SquirrelEnhancedDevSetASCIIModeNotification"), object: true)
      for c in "abc123" { _ = send(controller, client, String(c)) }
      check("explicit_ascii_mode_remains_literal", client.fallback == "abc123" && client.committed.isEmpty && client.marked.isEmpty)
      NotificationCenter.default.post(name: .init("SquirrelEnhancedDevSetASCIIModeNotification"), object: false)
      controller.deactivateServer(client.proxy)
    }
    do {
      let client = KeyboardProbeClient()
      client.bundle = "org.rime.SquirrelEnhanced.Development.VoiceHelper"
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      for c in "apikey123" { _ = send(controller, client, String(c)) }
      check("helper_settings_fields_remain_application_owned", client.fallback == "apikey123" && client.marked.isEmpty)
      controller.deactivateServer(client.proxy)
    }
    do {
      let client = KeyboardProbeClient()
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      for c in "nihao" { _ = send(controller, client, String(c)) }
      _ = send(controller, client, " ", code: 49); _ = send(controller, client, "a")
      let before = client.geometryQueries
      pump()
      check("commit_revokes_queued_panel_geometry", client.geometryQueries == before && !delegate.panel!.isVisible)
      controller.deactivateServer(client.proxy)
    }
    do {
      let client = KeyboardProbeClient()
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      for c in "nihao" { _ = send(controller, client, String(c)) }
      _ = send(controller, client, " ", code: 49)
      let before = client.geometryQueries
      controller.deactivateServer(client.proxy); pump()
      check("blur_revokes_queued_panel_geometry", client.geometryQueries == before && !delegate.panel!.isVisible)
    }
    do {
      let client = KeyboardProbeClient()
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      for c in "nihao" { _ = send(controller, client, String(c)) }
      _ = send(controller, client, " ", code: 49)
      client.onGeometry = { controller.deactivateServer(client.proxy) }
      pump()
      check("geometry_reentrant_blur_cannot_reopen_old_panel", !delegate.panel!.isVisible)
      client.onGeometry = nil
    }
    // Hosts can accept marked text before their layout has a usable caret.
    // Exercise the actual asynchronous presentation, without another key to
    // accidentally hide the absence of a retry in the production controller.
    do {
      let client = KeyboardProbeClient(); client.geometryAvailable = false
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      _ = send(controller, client, "n"); _ = send(controller, client, "i")
      _ = send(controller, client, " ", code: 49)
      pump(0.015)
      check("missing_first_caret_shows_visible_centered_fallback", visibleFallback())
      client.geometryAvailable = true
      pump(0.25)
      check("late_host_layout_recovers_without_another_key", delegate.panel!.isVisible && delegate.panel!.position.height == 18)
      check("panel_position_retries_never_insert_or_mark_text", client.committed.isEmpty && !client.marked.isEmpty)
      controller.deactivateServer(client.proxy)
    }
    do {
      let client = KeyboardProbeClient(); client.geometryAvailable = false
      let screen = NSScreen.main!.frame
      client.fallbackRect = NSRect(x: screen.midX + 30, y: screen.midY, width: 0, height: 20)
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      _ = send(controller, client, "n"); _ = send(controller, client, "i")
      _ = send(controller, client, " ", code: 49)
      pump()
      check("document_range_caret_fallback_still_positions_panel", delegate.panel!.isVisible && delegate.panel!.position == client.fallbackRect)
      controller.deactivateServer(client.proxy)
    }
    do {
      let client = KeyboardProbeClient(); client.geometryAvailable = false
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      delegate.panel!.updateStatus(long:"中文模式",short:"中")
      _ = send(controller, client, "\u{1b}", code:53)
      pump(0.015)
      check("initial_mode_hint_does_not_use_stale_or_zero_anchor", !delegate.panel!.isVisible)
      client.geometryAvailable = true; pump(0.25)
      check("pending_mode_hint_recovers_at_current_caret", delegate.panel!.isVisible && delegate.panel!.position.height == 18)
      controller.deactivateServer(client.proxy)
    }
    for action in ["commit", "blur", "empty", "replacement"] {
      let client = KeyboardProbeClient(); client.geometryAvailable = false
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      _ = send(controller, client, "n"); _ = send(controller, client, "i")
      _ = send(controller, client, " ", code: 49)
      pump(0.015)
      let queries = client.geometryQueries
      client.geometryAvailable = true
      switch action {
      case "commit": _ = send(controller, client, "a")
      case "blur": controller.deactivateServer(client.proxy)
      case "empty": _ = send(controller, client, "\u{1b}", code: 53)
      default:
        let other = KeyboardProbeClient()
        controller.activateServer(other.proxy)
        pump(0.25)
      }
      pump(0.25)
      check("delayed_caret_retry_revoked_on_" + action, client.geometryQueries == queries && !delegate.panel!.isVisible)
      if action != "blur" { controller.deactivateServer(client.proxy) }
    }
    do {
      let client = KeyboardProbeClient(); client.geometryAvailable = false
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      _ = send(controller, client, "n"); _ = send(controller, client, "i")
      _ = send(controller, client, " ", code: 49)
      pump(1.3)
      let queries = client.geometryQueries
      pump(0.3)
      check("unavailable_caret_has_bounded_retries_and_visible_fallback", queries > 1 && queries <= 8 && client.geometryQueries == queries && visibleFallback())
      _ = send(controller, client, "a")
      check("fallback_candidates_commit_through_original_client", !client.committed.isEmpty && client.fallback.isEmpty && !delegate.panel!.isVisible)
      controller.deactivateServer(client.proxy)
    }
    do {
      EnhancementBridge.shared.settings.letters["letter_fixture"]?.hideCandidates = false
      let client = KeyboardProbeClient(); client.geometryAvailable = false
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      _ = send(controller, client, "n"); _ = send(controller, client, "i")
      pump(0.015)
      check("editing_candidate_preview_remains_visible_without_caret", visibleFallback() && client.marked == "ni")
      client.geometryAvailable = true
      pump(0.25)
      check("editing_candidate_preview_recovers_at_caret", delegate.panel!.isVisible && delegate.panel!.position.height == 18)
      _ = send(controller, client, "\u{1b}", code: 53)
      controller.deactivateServer(client.proxy)
      EnhancementBridge.shared.settings.letters["letter_fixture"]?.hideCandidates = true
    }
    do {
      let client = KeyboardProbeClient()
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      _ = send(controller, client, "n"); _ = send(controller, client, "i")
      _ = send(controller, client, " ", code: 49); pump()
      check("intermittent_geometry_starts_at_real_caret", delegate.panel!.isVisible && delegate.panel!.position.height == 18)
      client.geometryAvailable = false
      _ = send(controller, client, "=", code: 24); pump(0.015)
      check("lost_geometry_during_paging_keeps_candidates_visible", visibleFallback() && client.committed.isEmpty)
      let before = client.geometryQueries
      // Rapid key updates revoke and restart retries. A fallback cannot depend
      // on exhausting them, or continuous typing/paging would stay invisible.
      for _ in 0..<4 {
        _ = send(controller, client, "-", code: 27); pump(0.004)
        _ = send(controller, client, "=", code: 24); pump(0.004)
      }
      check("rapid_candidate_updates_cannot_starve_visible_fallback", visibleFallback() && client.geometryQueries > before)
      client.geometryAvailable = true; pump(0.25)
      check("intermittent_geometry_recovers_to_real_caret", delegate.panel!.isVisible && delegate.panel!.position.height == 18)
      _ = send(controller, client, "a")
      check("recovered_panel_still_commits_and_hides", !client.committed.isEmpty && client.fallback.isEmpty && !delegate.panel!.isVisible)
      controller.deactivateServer(client.proxy)
    }
    do {
      let previous = KeyboardProbeClient(), current = KeyboardProbeClient()
      current.geometryAvailable = false
      let old = SquirrelInputController(server: server, delegate: nil, client: previous.proxy)!
      old.activateServer(previous.proxy)
      _ = send(old, previous, "n"); _ = send(old, previous, "i")
      _ = send(old, previous, " ", code: 49); pump()
      let controller = SquirrelInputController(server: server, delegate: nil, client: current.proxy)!
      controller.activateServer(current.proxy)
      _ = send(controller, current, "n"); _ = send(controller, current, "i")
      _ = send(controller, current, " ", code: 49); pump(0.015)
      check("new_field_without_geometry_does_not_reuse_previous_caret", visibleFallback() && delegate.panel!.inputController === controller)
      old.deactivateServer(previous.proxy)
      check("old_field_blur_cannot_hide_new_fallback", visibleFallback())
      controller.deactivateServer(current.proxy); pump(0.25)
      check("new_fallback_blur_cancels_retries_and_hides", !delegate.panel!.isVisible)
    }
    do {
      let old = KeyboardProbeClient(), current = KeyboardProbeClient()
      let previous = SquirrelInputController(server: server, delegate: nil, client: old.proxy)!
      previous.activateServer(old.proxy)
      _ = send(previous, old, "n")
      let controller = SquirrelInputController(server: server, delegate: nil, client: current.proxy)!
      controller.activateServer(current.proxy)
      _ = send(controller, current, "n"); _ = send(controller, current, "i")
      _ = send(controller, current, " ", code: 49)
      pump()
      previous.deactivateServer(old.proxy)
      check("late_old_controller_blur_cannot_hide_current_candidates", delegate.panel!.isVisible && delegate.panel!.inputController === controller)
      _ = send(controller, current, "a")
      check("new_controller_still_commits_after_old_controller_blur", !current.committed.isEmpty && current.fallback.isEmpty)
      controller.deactivateServer(current.proxy)
    }
    // A real librime service unavailable at the first two keys. The production
    // controller, not a copied routing function, must retain and replay them.
    do {
      api.finalize()
      let client = KeyboardProbeClient()
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      _ = send(controller, client, "n"); _ = send(controller, client, "i")
      check("unready_first_letters_do_not_escape_as_english", client.fallback.isEmpty)
      check("unready_prefix_is_visible_and_uncommitted", client.marked == "ni" && client.committed.isEmpty)
      api.initialize(&traits)
      pump(0.15)
      for c in "hao" { _ = send(controller, client, String(c)) }
      _ = send(controller, client, " ", code: 49); pump(); _ = send(controller, client, "a")
      check("recovered_session_keeps_whole_nihao_prefix", client.committed == "你好" && client.fallback.isEmpty)
      controller.deactivateServer(client.proxy)
    }
    do {
      let client = KeyboardProbeClient()
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      let literal = "ab2" + String(repeating: "a", count: 600)
      for c in literal { _ = send(controller, client, String(c)) }
      check("long_literal_preedit_is_complete_and_memory_bounded", client.marked == literal && client.fallback.isEmpty)
      _ = send(controller, client, "\r", code: 36)
      check("long_literal_commits_exactly_once", client.committed == literal && client.marked.isEmpty)
      controller.deactivateServer(client.proxy)
    }
    var coldTimes: [Double] = [], coldPasses = 0
    for _ in 0..<100 {
      autoreleasepool {
        let client = KeyboardProbeClient()
        let start = ProcessInfo.processInfo.systemUptime
        let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
        controller.activateServer(client.proxy)
        _ = send(controller, client, "n")
        coldTimes.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        if client.fallback.isEmpty && client.marked == "n" && client.committed.isEmpty { coldPasses += 1 }
        _ = send(controller, client, "\u{1b}", code: 53)
        controller.deactivateServer(client.proxy)
      }
    }
    coldTimes.sort()
    check("one_hundred_fresh_controllers_keep_first_key_in_pinyin", coldPasses == 100)
    metrics["fresh_controller_and_first_key_p50_ms"] = coldTimes[50]
    metrics["fresh_controller_and_first_key_p95_ms"] = coldTimes[95]
    do {
      api.finalize(); KeyboardProbeSecurity.secure = true
      let client = KeyboardProbeClient()
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      _ = send(controller, client, "n"); _ = send(controller, client, "i")
      check("secure_input_never_buffers_unready_first_keys", client.fallback == "ni" && client.marked.isEmpty)
      KeyboardProbeSecurity.secure = false; api.initialize(&traits); pump(0.15)
      check("secure_input_keys_are_never_replayed_later", client.committed.isEmpty && client.marked.isEmpty)
      controller.deactivateServer(client.proxy)
    }
    do {
      let client = KeyboardProbeClient()
      let controller = SquirrelInputController(server: server, delegate: nil, client: client.proxy)!
      controller.activateServer(client.proxy)
      func release(_ text: String, _ code: UInt16) {
        let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
          characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
        _ = controller.handle(up, client: client.proxy)
      }
      func word(_ times: inout [Double]) {
        for (text, code) in [("n", UInt16(45)), ("i", 34), ("h", 4), ("a", 0), ("o", 31), ("\u{1b}", 53)] {
          let start = ProcessInfo.processInfo.systemUptime
          _ = send(controller, client, text, code: code)
          times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
          release(text, code)
        }
      }
      var times: [Double] = []
      client.bundleQueries = 0; client.bundleQueryDelay = 0.002
      let slowStart = ProcessInfo.processInfo.systemUptime
      for _ in 0..<20 { autoreleasepool { word(&times) } }
      metrics["slow_metadata_240_events_wall_ms"] = (ProcessInfo.processInfo.systemUptime - slowStart) * 1000
      metrics["slow_metadata_240_events_bundle_queries"] = client.bundleQueries
      check("ordinary_down_and_up_events_reuse_client_metadata", client.bundleQueries == 0)
      client.bundleQueryDelay = 0
      for _ in 0..<100 { autoreleasepool { word(&times) } }
      pump(0.01)
      let before = KeyboardProbeProcessMetrics().mapValues { $0.doubleValue }
      var memory: [[String: Double]] = [before]
      times.removeAll(keepingCapacity: true)
      let stressStart = ProcessInfo.processInfo.systemUptime
      for index in 0..<2000 {
        autoreleasepool { word(&times) }
        if index % 100 == 99 {
          pump(0.001)
          memory.append(KeyboardProbeProcessMetrics().mapValues { $0.doubleValue })
        }
      }
      let after = KeyboardProbeProcessMetrics().mapValues { $0.doubleValue }
      let cpu = after["cpu_seconds"]! - before["cpu_seconds"]!
      times.sort()
      metrics["sustained_typing"] = [
        "key_downs": 12000, "key_ups": 12000,
        "cpu_seconds": cpu,
        "wall_seconds": ProcessInfo.processInfo.systemUptime - stressStart,
        "key_down_p50_ms": times[times.count / 2],
        "key_down_p95_ms": times[times.count * 95 / 100],
        "cpu_ms_per_key_pair": cpu * 1000 / 12000,
        "physical_footprint_before_bytes": before["physical_footprint_bytes"]!,
        "physical_footprint_after_bytes": after["physical_footprint_bytes"]!,
        "physical_footprint_max_bytes": memory.map { $0["physical_footprint_bytes"]! }.max()!,
        "memory_samples": memory
      ] as [String: Any]
      check("sustained_typing_keeps_all_text_uncommitted_until_cancel", client.committed.isEmpty && client.fallback.isEmpty && client.marked.isEmpty)
      check("sustained_typing_memory_counters_are_available", memory.allSatisfy { $0["memory_counter_status"] == 0 })
      check("sustained_typing_footprint_is_bounded_after_warmup", after["physical_footprint_bytes"]! - before["physical_footprint_bytes"]! < 32 * 1024 * 1024)
      // A different client, including the Helper, must not inherit the old ID.
      let helper = KeyboardProbeClient(); helper.bundle = "org.rime.SquirrelEnhanced.Development.VoiceHelper"
      let handled = controller.handle(event("x"), client: helper.proxy)
      check("different_client_still_queries_its_own_identity", helper.bundleQueries > 0 && !handled && helper.marked.isEmpty)
      controller.deactivateServer(client.proxy)
      let oldQueries = client.bundleQueries
      controller.activateServer(client.proxy)
      check("activation_refreshes_client_metadata_once", client.bundleQueries == oldQueries + 1)
      let activatedQueries = client.bundleQueries
      _ = send(controller, client, "n", code: 45)
      check("first_key_after_activation_uses_fresh_cached_identity", client.bundleQueries == activatedQueries && client.marked == "n")
      _ = send(controller, client, "\u{1b}", code: 53)
      let switchBefore = KeyboardProbeProcessMetrics().mapValues { $0.doubleValue }
      var activationSamples: [[String: Double]] = [switchBefore]
      for index in 0..<500 {
        autoreleasepool {
          controller.deactivateServer(client.proxy)
          controller.activateServer(client.proxy)
          _ = send(controller, client, "n", code: 45)
          _ = send(controller, client, "\u{1b}", code: 53)
        }
        if index % 50 == 49 {
          pump(0.001)
          activationSamples.append(KeyboardProbeProcessMetrics().mapValues { $0.doubleValue })
        }
      }
      pump(0.01)
      let switchAfter = KeyboardProbeProcessMetrics().mapValues { $0.doubleValue }
      metrics["five_hundred_reactivations"] = [
        "physical_footprint_before_bytes": switchBefore["physical_footprint_bytes"]!,
        "physical_footprint_after_bytes": switchAfter["physical_footprint_bytes"]!,
        "cpu_seconds": switchAfter["cpu_seconds"]! - switchBefore["cpu_seconds"]!,
        "memory_samples": activationSamples
      ] as [String: Any]
      check("repeated_activation_keeps_memory_bounded", switchAfter["physical_footprint_bytes"]! - switchBefore["physical_footprint_bytes"]! < 32 * 1024 * 1024)
      controller.deactivateServer(client.proxy)
    }
    let report: [String: Any] = ["status": checks.allSatisfy { $0["passed"] as? Bool == true } ? "PASS" : "FAIL",
      "checks": checks, "metrics": metrics, "real_rime_version": api.get_version().map { String(cString: $0) } ?? "unknown",
      "scope": "actual SquirrelInputController and AppKit panel with real librime, an in-memory IMK client and isolated security-state fixture; simulated slow host; not physical keyboard or live host IPC",
      "system_secure_input_at_start": secureInputAtStart, "system_secure_input_at_end": Carbon.IsSecureEventInputEnabled(),
      "security_state_fixture_only": true,
      "microphone_used": false, "cloud_calls": 0, "personal_dictionary_used": false]
    print("KEYBOARD_PROBE_REPORT=" + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
    delegate.panel?.hide()
    if report["status"] as? String != "PASS" { exit(1) }
  }
}
