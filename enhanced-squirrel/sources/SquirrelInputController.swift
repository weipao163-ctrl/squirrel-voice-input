//
//  SquirrelInputController.swift
//  Squirrel
//
//  Created by Leo Liu on 5/7/24.
//

import InputMethodKit
import EnhancementCore
import EnhancementIPC
import ApplicationServices

final class SquirrelInputController: IMKInputController {
  private static let keyRollOver = 50
  private static var unknownAppCnt: UInt = 0

  private weak var client: IMKTextInput?
  private let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var lastModifiers: NSEvent.ModifierFlags = .init()
  private var session: RimeSessionId = 0
  private var schemaId: String = ""
  private var appliedScriptMode: String = ""
  private static let settingsBundleID = "org.rime.SquirrelEnhanced.Development.VoiceHelper"
  private var inlinePreedit = false
  private var inlineCandidate = false
  private var chordKeyCodes: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordModifiers: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordKeyCount: Int = 0
  private var chordTimer: Timer?
  private var chordDuration: TimeInterval = 0
  private var currentApp: String = ""
  // BEGIN ENHANCEMENT STATE
  private var physicalKeys = PhysicalKeys()
  private var letterSettings = LetterSettingsBoundary()
  private var letterRepeats:LetterRepeatGuard {
    get { EnhancementDeployment.shared.letterRepeats }
    set { EnhancementDeployment.shared.letterRepeats = newValue }
  }
  private var inputGeneration: UInt64 = 0
  private var voiceIdentity: VoiceIdentity?
  private var voiceTarget: EnhancementTarget?
  private var voiceStopRelay = VoiceStopRelay()
  private var voiceReleased:Bool { voiceStopRelay.released }
  private var voiceAttempted = false
  private var voiceTerminal = false
  private var voiceCapturePending = false
  private var voiceLease: Timer?
  private var enhancementObservers: [NSObjectProtocol] = []
  // END ENHANCEMENT STATE

  // swiftlint:disable:next cyclomatic_complexity
  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event = event else { return false }
    // Configuration fields and the local hotkey recorder belong to the Helper.
    // Routing them through our own IMK handler can consume their key events.
    guard (sender as? IMKTextInput)?.bundleIdentifier() != Self.settingsBundleID else { return false }
    let modifiers = event.modifierFlags
    let changes = lastModifiers.symmetricDifference(modifiers)

    // Return true to consume the key event; return false to pass it to the client app.
    var handled = false

    if session == 0 || !rimeAPI.find_session(session) {
      createSession()
      if session == 0 {
        return false
      }
    }

    self.client ?= sender as? IMKTextInput
    if let app = client?.bundleIdentifier(), currentApp != app {
      currentApp = app
      updateAppOptions()
    }

    if enhancementHandle(event) {
      if event.type == .flagsChanged { lastModifiers = modifiers }
      return true
    }

    switch event.type {
    case .flagsChanged:
      if lastModifiers == modifiers {
        handled = true
        break
      }
      var rimeModifiers: UInt32 = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
      // Some remote desktop tools send flagsChanged with keyCode 0; infer the real modifier key when needed.
      var keyCode = event.keyCode
      if !SquirrelKeycode.modifierKeycodes.contains(keyCode) {
        guard let inferred = SquirrelKeycode.inferModifierKeycode(from: changes) else {
          lastModifiers = modifiers
          rimeUpdate()
          handled = true
          break
        }
        keyCode = inferred
      }
      let rimeKeycode: UInt32 = SquirrelKeycode.osxKeycodeToRime(keycode: keyCode, keychar: nil, shift: false, caps: false)

      if changes.contains(.capsLock) {
        // Rime expects XK_Caps_Lock before the lock mask changes; NSFlagsChanged has already applied it.
        rimeModifiers ^= kLockMask.rawValue
        _ = processKey(rimeKeycode, modifiers: rimeModifiers)
      }

      // Process releases first because some modifier releases arrive with the next keydown.
      var buffer = [(keycode: UInt32, modifier: UInt32)]()
      for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] where changes.contains(flag) {
        if modifiers.contains(flag) {
          buffer.append((keycode: rimeKeycode, modifier: rimeModifiers))
        } else {
          buffer.insert((keycode: rimeKeycode, modifier: rimeModifiers | kReleaseMask.rawValue), at: 0)
        }
      }
      for (keycode, modifier) in buffer {
        _ = processKey(keycode, modifiers: modifier)
      }

      lastModifiers = modifiers
      rimeUpdate()

    case .keyDown:
      // Let client apps handle Command shortcuts.
      if modifiers.contains(.command) {
        break
      }

      let keyCode = event.keyCode
      var keyChars = event.charactersIgnoringModifiers
      let capitalModifiers = modifiers.isSubset(of: [.shift, .capsLock])
      if let code = keyChars?.first,
         (capitalModifiers && !code.isLetter) || (!capitalModifiers && !code.isASCII) {
        keyChars = event.characters
      }
      if let char = keyChars?.first {
        let rimeKeycode = SquirrelKeycode.osxKeycodeToRime(keycode: keyCode, keychar: char,
                                                           shift: modifiers.contains(.shift),
                                                           caps: modifiers.contains(.capsLock))
        if rimeKeycode != 0 {
          let rimeModifiers = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
          let consumedBefore = enhancementProperty("_letter_selection_consumed")
          handled = processKey(rimeKeycode, modifiers: rimeModifiers)
          if consumedBefore != enhancementProperty("_letter_selection_consumed") {
            letterRepeats.accepted(code: event.keyCode)
          }
          rimeUpdate()
        }
      }

    default:
      break
    }

    return handled
  }

  func selectCandidate(_ index: Int) -> Bool {
    let success = rimeAPI.select_candidate_on_current_page(session, index)
    if success {
      rimeUpdate()
    }
    return success
  }

  // swiftlint:disable:next identifier_name
  func page(up: Bool) -> Bool {
    var handled = false
    handled = rimeAPI.change_page(session, up)
    if handled {
      rimeUpdate()
    }
    return handled
  }

  func moveCaret(forward: Bool) -> Bool {
    let currentCaretPos = rimeAPI.get_caret_pos(session)
    guard let input = rimeAPI.get_input(session) else { return false }
    if forward {
      if currentCaretPos <= 0 {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos - 1)
    } else {
      let inputStr = String(cString: input)
      if currentCaretPos >= inputStr.utf8.count {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos + 1)
    }
    rimeUpdate()
    return true
  }

  override func recognizedEvents(_ sender: Any!) -> Int {
    if (sender as? IMKTextInput)?.bundleIdentifier() == Self.settingsBundleID { return 0 }
    return Int(NSEvent.EventTypeMask.Element(arrayLiteral: .keyDown, .keyUp, .flagsChanged).rawValue)
  }

  override func activateServer(_ sender: Any!) {
    enhancementInvalidated()
    inputGeneration &+= 1
    self.client ?= sender as? IMKTextInput
    if client?.bundleIdentifier() == Self.settingsBundleID {
      enhancementInvalidated(); physicalKeys.lostLifecycle(); cleanReleasedPhysicalKeys()
      return
    }
    cleanReleasedPhysicalKeys()
    EnhancementBridge.shared.input = self
    EnhancementBridge.shared.launchIfNeeded()
    physicalKeys.reconcileAfterActivation(pressed:Set((0..<128).compactMap { code -> UInt16? in
      CGEventSource.keyState(.combinedSessionState,key:CGKeyCode(code)) ? UInt16(code) : nil
    }))
    enhancementConfigurationChanged(EnhancementBridge.shared.settings)
    self.client ?= sender as? IMKTextInput
    var keyboardLayout = NSApp.squirrelAppDelegate.config?.getString("keyboard_layout") ?? ""
    if keyboardLayout == "last" || keyboardLayout == "" {
      keyboardLayout = ""
    } else if keyboardLayout == "default" {
      keyboardLayout = "com.apple.keylayout.ABC"
    } else if !keyboardLayout.hasPrefix("com.apple.keylayout.") {
      keyboardLayout = "com.apple.keylayout.\(keyboardLayout)"
    }
    if keyboardLayout != "" {
      client?.overrideKeyboard(withKeyboardNamed: keyboardLayout)
    }
    // Activation delivers no flagsChanged event, and NSEvent.modifierFlags
    // only reflects this process's own event stream, so lastModifiers may
    // disagree with the actual Caps Lock state by now. Seed it from the
    // session-wide hardware state; otherwise the next Caps Lock press can
    // compare equal to the stale lastModifiers and be dropped by the
    // early-return in handle().
    if CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift) {
      lastModifiers.insert(.capsLock)
    } else {
      lastModifiers.remove(.capsLock)
    }
    preedit = ""
    applyInputScriptMode()
    if session != 0 {
      let state = rimeAPI.get_option(session, "ascii_mode")
      let label = rimeAPI.get_state_label_abbreviated(session, "ascii_mode", state, true).asString
      NSApp.squirrelAppDelegate.updateStatusIcon(asciiMode: state, schemaLabel: label)
    }
  }

  override init!(server: IMKServer!, delegate: Any!, client: Any!) {
    self.client = client as? IMKTextInput
    super.init(server: server, delegate: delegate, client: client)
    EnhancementDeployment.shared.controllers.add(self)
    createSession()

    enhancementObservers.append(NotificationCenter.default.addObserver(
      forName: .init("SquirrelEnhancedDevSetASCIIModeNotification"),
      object: nil,
      queue: nil
    ) { [weak self] notification in
      self?.handleASCIIModeToggle(notification)
    })

    enhancementObservers.append(NotificationCenter.default.addObserver(
      forName: .init("SquirrelEnhancedDevReportASCIIModeNotification"),
      object: nil,
      queue: nil
    ) { [weak self] notification in
      self?.reportASCIIMode(notification)
    })
  }

  override func deactivateServer(_ sender: Any!) {
    enhancementInvalidated()
    inputGeneration &+= 1
    physicalKeys.lostLifecycle()
    cleanReleasedPhysicalKeys()
    rimeAPI.set_property(session, "_letter_selection_reset", UUID().uuidString)
    hidePalettes()
    commitComposition(sender)
    client = nil
  }

  override func hidePalettes() {
    NSApp.squirrelAppDelegate.panel?.hide()
    super.hidePalettes()
  }

  override func commitComposition(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    if session != 0 {
      if let input = rimeAPI.get_input(session) {
        commit(string: String(cString: input))
        rimeAPI.clear_composition(session)
      }
    }
  }

  override func menu() -> NSMenu! {
    let deploy = NSMenuItem(title: NSLocalizedString("Deploy", comment: "Menu item"), action: #selector(deploy), keyEquivalent: "`")
    deploy.target = self
    deploy.keyEquivalentModifierMask = [.control, .option]
    let sync = NSMenuItem(title: NSLocalizedString("Sync user data", comment: "Menu item"), action: #selector(syncUserData), keyEquivalent: "")
    sync.target = self
    let logDir = NSMenuItem(title: NSLocalizedString("Logs...", comment: "Menu item"), action: #selector(openLogFolder), keyEquivalent: "")
    logDir.target = self
    let setting = NSMenuItem(title: NSLocalizedString("Settings...", comment: "Menu item"), action: #selector(openRimeFolder), keyEquivalent: "")
    setting.target = self
    let wiki = NSMenuItem(title: NSLocalizedString("Rime Wiki...", comment: "Menu item"), action: #selector(openWiki), keyEquivalent: "")
    wiki.target = self
    let update = NSMenuItem(title: NSLocalizedString("Check for updates...", comment: "Menu item"), action: #selector(checkForUpdates), keyEquivalent: "")
    update.target = self

    let menu = NSMenu()
    menu.addItem(deploy)
    menu.addItem(sync)
    menu.addItem(logDir)
    menu.addItem(setting)
    let enhancements = NSMenuItem(title: "增强输入设置…", action: #selector(openEnhancementSettings), keyEquivalent: "")
    enhancements.target = self
    menu.addItem(enhancements)
    if EnhancementPreview.shared.hasRecoverableDraft {
      let recovery = NSMenuItem(title: "恢复语音草稿…", action: #selector(showVoiceDraft), keyEquivalent: "")
      recovery.target = self
      menu.addItem(recovery)
    }
    menu.addItem(wiki)
    menu.addItem(update)

    return menu
  }

  @objc func deploy() {
    NSApp.squirrelAppDelegate.deploy()
  }

  @objc func syncUserData() {
    NSApp.squirrelAppDelegate.syncUserData()
  }

  @objc func openLogFolder() {
    NSApp.squirrelAppDelegate.openLogFolder()
  }

  @objc func openRimeFolder() {
    NSApp.squirrelAppDelegate.openRimeFolder()
  }

  @objc func checkForUpdates() {
    NSApp.squirrelAppDelegate.checkForUpdates()
  }

  @objc func openWiki() {
    NSApp.squirrelAppDelegate.openWiki()
  }

  private(set) var specialCommentIndices: [ReservedPropertyKey: Set<Int>] = [:]

  func handleReservedProperty(key rawKey: String, value rawValue: String, for sessionId: RimeSessionId) throws(ReservedPropertyError) {
    guard session == sessionId, session != 0, rimeAPI.find_session(session) else { return }
    if rawKey.hasPrefix("_letter_selection_") { return } // Consumed by coordinator/readback, not a panel hint.
    guard let key = ReservedPropertyKey(rawValue: rawKey) else { throw .unknownInput(rawKey) }
    let parsed = try ReservedPropertyValue.parse(rawValue)
    switch key {
    case .commentHighlight:
      specialCommentIndices[.commentHighlight] = try parsed.indices()
    case .commentWarning:
      specialCommentIndices[.commentWarning] = try parsed.indices()
    case .refreshUI:
      rimeUpdate(clearReservedComments: false)
    }
  }

  deinit {
    for observer in enhancementObservers { NotificationCenter.default.removeObserver(observer) }
    EnhancementDeployment.shared.controllers.remove(self)
    enhancementInvalidated()
    voiceLease?.invalidate()
    destroySession()
  }
}

private extension SquirrelInputController {

  func onChordTimer(_: Timer) {
    var processedKeys = false
    if chordKeyCount > 0 && session != 0 {
      // Chord typing releases are synthesized after the configured timeout.
      for i in 0..<chordKeyCount {
        let handled = rimeAPI.process_key(session, Int32(chordKeyCodes[i]), Int32(chordModifiers[i] | kReleaseMask.rawValue))
        if handled {
          processedKeys = true
        }
      }
    }
    clearChord()
    if processedKeys {
      rimeUpdate()
    }
  }

  func updateChord(keycode: UInt32, modifiers: UInt32) {
    for i in 0..<chordKeyCount where chordKeyCodes[i] == keycode {
      return
    }
    if chordKeyCount >= Self.keyRollOver {
      return
    }
    chordKeyCodes[chordKeyCount] = keycode
    chordModifiers[chordKeyCount] = modifiers
    chordKeyCount += 1
    if let timer = chordTimer, timer.isValid {
      timer.invalidate()
    }
    chordDuration = 0.1
    if let duration = NSApp.squirrelAppDelegate.config?.getDouble("chord_duration"), duration > 0 {
      chordDuration = duration
    }
    chordTimer = Timer.scheduledTimer(withTimeInterval: chordDuration, repeats: false, block: onChordTimer)
  }

  func clearChord() {
    chordKeyCount = 0
    if let timer = chordTimer {
      if timer.isValid {
        timer.invalidate()
      }
      chordTimer = nil
    }
  }

  func createSession() {
    enhancementInvalidated(); inputGeneration += 1; cleanReleasedPhysicalKeys()
    let app = client?.bundleIdentifier() ?? {
      SquirrelInputController.unknownAppCnt &+= 1
      return "UnknownApp\(SquirrelInputController.unknownAppCnt)"
    }()
    print("createSession: \(app)")
    currentApp = app
    session = rimeAPI.create_session()
    schemaId = ""
    appliedScriptMode = ""
    letterSettings = LetterSettingsBoundary()

    if session != 0 {
      updateAppOptions()
    }
  }

  func updateAppOptions() {
    if currentApp == "" {
      return
    }
    if let appOptions = NSApp.squirrelAppDelegate.config?.getAppOptions(currentApp) {
      for (key, value) in appOptions {
        print("set app option: \(key) = \(value)")
        rimeAPI.set_option(session, key, value)
      }
    }
    if let reportBundleID = NSApp.squirrelAppDelegate.config?.getBool("unsafe/report_bundleid"), reportBundleID {
      currentApp.withCString { name in
        rimeAPI.set_property(session, "client_app", name)
      }
    }
  }

  private func applyInputScriptMode() {
    guard session != 0, rimeAPI.find_session(session),
          let mode = SquirrelInstaller.currentInputSourceID(),
          mode.hasPrefix("org.rime.inputmethod.SquirrelEnhanced.Development."),
          mode != appliedScriptMode else { return }
    appliedScriptMode = mode
    let simplified = mode.hasSuffix(".Hans")
    // The bundled Luna schema uses zh_hans; older compatible schemas use
    // simplification. Script variants must be mutually exclusive.
    for (name, value) in [("zh_hant", !simplified), ("zh_hant_hk", false),
                          ("zh_hant_tw", false), ("zh_hans", simplified),
                          ("simplification", simplified), ("traditionalization", !simplified)] {
      if rimeAPI.get_option(session, name) != value { rimeAPI.set_option(session, name, value) }
    }
  }

  func destroySession() {
    if session != 0 {
      _ = rimeAPI.destroy_session(session)
      session = 0
    }
    clearChord()
  }

  func processKey(_ rimeKeycode: UInt32, modifiers rimeModifiers: UInt32) -> Bool {
    if let panel = NSApp.squirrelAppDelegate.panel {
      if panel.linear != rimeAPI.get_option(session, "_linear") {
        rimeAPI.set_option(session, "_linear", panel.linear)
      }
      if panel.vertical != rimeAPI.get_option(session, "_vertical") {
        rimeAPI.set_option(session, "_vertical", panel.vertical)
      }
    }

    let handled = rimeAPI.process_key(session, Int32(rimeKeycode), Int32(rimeModifiers))

    if !handled {
      let isVimBackInCommandMode = rimeKeycode == XK_Escape || ((rimeModifiers & kControlMask.rawValue != 0) && (rimeKeycode == XK_c || rimeKeycode == XK_C || rimeKeycode == XK_bracketleft))
      if isVimBackInCommandMode && rimeAPI.get_option(session, "vim_mode") &&
          !rimeAPI.get_option(session, "ascii_mode") {
        rimeAPI.set_option(session, "ascii_mode", true)
      }
    } else {
      let isChordingKey = switch Int32(rimeKeycode) {
      case XK_space...XK_asciitilde, XK_Control_L, XK_Control_R, XK_Alt_L, XK_Alt_R, XK_Shift_L, XK_Shift_R:
        true
      default:
        false
      }
      if isChordingKey && rimeAPI.get_option(session, "_chord_typing") {
        updateChord(keycode: rimeKeycode, modifiers: rimeModifiers)
      } else if (rimeModifiers & kReleaseMask.rawValue) == 0 {
        clearChord()
      }
    }

    return handled
  }

  func rimeConsumeCommittedText() {
    var commitText = RimeCommit.rimeStructInit()
    if rimeAPI.get_commit(session, &commitText) {
      if let text = commitText.text {
        commit(string: String(cString: text))
      }
      _ = rimeAPI.free_commit(&commitText)
    }
  }

  // Preserve reserved comment marks when librime requests a UI-only refresh.
  func rimeUpdate(clearReservedComments: Bool = true) {
    if clearReservedComments {
      specialCommentIndices = [:]
    }
    rimeConsumeCommittedText()

    var status = RimeStatus_stdbool.rimeStructInit()
    if rimeAPI.get_status(session, &status) {
      // swiftlint:disable:next identifier_name
      if let schema_id = status.schema_id, schemaId == "" || schemaId != String(cString: schema_id) {
        enhancementInvalidated()
        schemaId = String(cString: schema_id)
        appliedScriptMode = ""
        applyInputScriptMode()
        enhancementConfigurationChanged(EnhancementBridge.shared.settings)
        NSApp.squirrelAppDelegate.loadSettings(for: schemaId)
        if let panel = NSApp.squirrelAppDelegate.panel {
          inlinePreedit = (panel.inlinePreedit && !rimeAPI.get_option(session, "no_inline")) || rimeAPI.get_option(session, "inline")
          inlineCandidate = panel.inlineCandidate && !rimeAPI.get_option(session, "no_inline")
          rimeAPI.set_option(session, "soft_cursor", !inlinePreedit)
        }
      }
      _ = rimeAPI.free_status(&status)
    }

    var ctx = RimeContext_stdbool.rimeStructInit()
    if rimeAPI.get_context(session, &ctx) {
      let preedit = ctx.composition.preedit.map({ String(cString: $0) }) ?? ""

      let start = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_start)), within: preedit) ?? preedit.startIndex
      let end = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_end)), within: preedit) ?? preedit.startIndex
      let caretPos = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.cursor_pos)), within: preedit) ?? preedit.startIndex

      let hideInlineCandidate = enhancementProperty("_letter_selection_phase") == "editing" && enhancementProperty("_letter_selection_hide_editing") == "true"
      if inlineCandidate && !hideInlineCandidate {
        var candidatePreview = ctx.commit_text_preview.map { String(cString: $0) } ?? ""
        let endOfCandidatePreview = candidatePreview.endIndex
        if inlinePreedit {
          // 左移光標後的情形：
          // preedit:             ^已選某些字[xiang zuo yi dong]|guangbiao$
          // commit_text_preview: ^已選某些字向左移動$
          // candidate_preview:   ^已選某些字[向左移動]|guangbiao$
          // 繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidong$
          // candidate_preview:   ^已選某些字[向左]yidong|guangbiao$
          // 光標移至當前段落最左端的情形：
          // preedit:             ^已選某些字|[xiang zuo yi dong guang biao]$
          // commit_text_preview: ^已選某些字向左移動光標$
          // candidate_preview:   ^已選某些字|[向左移動光標]$
          // 討論：
          // preedit 與 commit_text_preview 中“已選某些字”部分一致
          // 因此，選中範圍即正在翻譯的碼段“向左移動”中，兩者的 start 值一致
          // 光標位置的範圍是 start ..= endOfCandidatePreview
          if caretPos >= end && caretPos < preedit.endIndex {
            // 從 preedit 截取光標後未翻譯的編碼“guangbiao”
            candidatePreview += preedit[caretPos...]
          }
        } else {
          // 翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字[向左???]|$
          // 光標移至當前段落最左端，繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字|[xiang zuo]yidongguangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字|[向左]???$
          // FIXME: add librime APIs to support preview candidate without remaining code.
        }
        // preedit can contain additional prompt text before start:
        // ^(prompt)[selection]$
        let start = min(start, candidatePreview.endIndex)
        let caretPos = caretPos <= start ? caretPos : endOfCandidatePreview
        show(preedit: candidatePreview,
             selRange: NSRange(location: start.utf16Offset(in: candidatePreview),
                               length: candidatePreview.utf16.distance(from: start, to: candidatePreview.endIndex)),
             caretPos: caretPos.utf16Offset(in: candidatePreview))
      } else {
        if inlinePreedit {
          show(preedit: preedit, selRange: NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end)), caretPos: caretPos.utf16Offset(in: preedit))
        } else {
          // Use a full-width space placeholder to prevent iTerm2 from echoing raw preedit;
          // half-width placeholders make the Chinese composition baseline unstable.
          show(preedit: preedit.isEmpty ? "" : "　", selRange: NSRange(location: 0, length: 0), caretPos: 0)
        }
      }

      let numCandidates = Int(ctx.menu.num_candidates)
      var candidates = [String]()
      var comments = [String]()
      for i in 0..<numCandidates {
        let candidate = ctx.menu.candidates[i]
        candidates.append(candidate.text.map { String(cString: $0) } ?? "")
        comments.append(candidate.comment.map { String(cString: $0) } ?? "")
      }
      var labels = [String]()
      // swiftlint:disable identifier_name
      if let select_keys = ctx.menu.select_keys {
        labels = String(cString: select_keys).map { String($0) }
      } else if let select_labels = ctx.select_labels {
        let pageSize = Int(ctx.menu.page_size)
        for i in 0..<pageSize {
          labels.append(select_labels[i].map { String(cString: $0) } ?? "")
        }
      }
      // swiftlint:enable identifier_name
      let page = Int(ctx.menu.page_no)
      let lastPage = ctx.menu.is_last_page

      let selRange = NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end))
      showPanel(preedit: inlinePreedit ? "" : preedit, selRange: selRange, caretPos: caretPos.utf16Offset(in: preedit),
                candidates: candidates, comments: comments, labels: labels, highlighted: Int(ctx.menu.highlighted_candidate_index),
                page: page, lastPage: lastPage)
      _ = rimeAPI.free_context(&ctx)
    } else {
      hidePalettes()
    }
    if let update = letterSettings.flush(composing:enhancementComposing()) {
      applyLetterSettings(update)
    }
  }

  func commit(string: String) {
    guard let client = client else { return }

    let forceMarkedText =
      session != 0 &&
      rimeAPI.get_option(session, "force_marked_text_for_direct_commit")

    // Direct commits such as full-width punctuation do not necessarily have an
    // active marked-text phase. Some NSTextInputClient implementations require
    // one before accepting insertText.
    if forceMarkedText && preedit.isEmpty && !string.isEmpty {
      let markedText = NSMutableAttributedString(string: string)
      client.setMarkedText(
        markedText,
        selectionRange: NSRange(location: markedText.length, length: 0),
        replacementRange: .empty
      )
    }

    client.insertText(string, replacementRange: .empty)
    preedit = ""
    hidePalettes()
  }

  func show(preedit: String, selRange: NSRange, caretPos: Int) {
    guard let client = client else { return }
    if self.preedit == preedit && self.caretPos == caretPos && self.selRange == selRange {
      return
    }

    self.preedit = preedit
    self.caretPos = caretPos
    self.selRange = selRange

    let start = selRange.location
    let attrString = NSMutableAttributedString(string: preedit)
    if start > 0 {
      let attrs = mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: start))! as! [NSAttributedString.Key: Any]
      attrString.setAttributes(attrs, range: NSRange(location: 0, length: start))
    }
    let remainingRange = NSRange(location: start, length: preedit.utf16.count - start)
    let attrs = mark(forStyle: kTSMHiliteSelectedRawText, at: remainingRange)! as! [NSAttributedString.Key: Any]
    attrString.setAttributes(attrs, range: remainingRange)
    client.setMarkedText(attrString, selectionRange: NSRange(location: caretPos, length: 0), replacementRange: .empty)
  }

  // swiftlint:disable:next function_parameter_count
  func showPanel(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted: Int, page: Int, lastPage: Bool) {
    guard let client = client else { return }
    var inputPos = NSRect()
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &inputPos)
    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.position = inputPos
      panel.inputController = self
      panel.update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels,
                   highlighted: highlighted, page: page, lastPage: lastPage, update: true)
    }
  }

  private func handleASCIIModeToggle(_ notification: Notification) {
    guard let enableASCII = notification.object as? Bool else { return }
    guard session != 0 && rimeAPI.find_session(session) else { return }

    rimeAPI.set_option(session, "ascii_mode", enableASCII)
    rimeUpdate()
  }

  private func reportASCIIMode(_: Notification) {
    guard client != nil else { return }
    guard session != 0 && rimeAPI.find_session(session) else { return }

    let isASCIIMode = rimeAPI.get_option(session, "ascii_mode")
    let status = isASCIIMode ? "ascii" : "nascii"

    DistributedNotificationCenter.default().postNotificationName(
      .init("SquirrelEnhancedDevASCIIModeResponse"),
      object: status
    )
  }

}

// Only the per-controller coordinator owns native consumption/commit decisions.
extension SquirrelInputController: EnhancementInput {
  @objc func showVoiceDraft() { EnhancementPreview.shared.showDraft() }
  @objc func openEnhancementSettings() {
    guard !enhancementComposing() else { EnhancementPreview.shared.notice("请先确认或取消当前拼音，再打开增强设置；没有代替您提交或清空组合。"); return }
    EnhancementBridge.shared.openSettings()
  }

  private func enhancementProperty(_ name:String) -> String {
    var buffer = [CChar](repeating:0,count:256)
    guard session != 0, rimeAPI.get_property(session,name,&buffer,buffer.count) else { return "" }
    return String(cString:buffer)
  }
  private func enhancementComposing() -> Bool {
    guard session != 0, let input = rimeAPI.get_input(session) else { return false }
    return input.pointee != 0 || !preedit.isEmpty
  }
  private func enhancementHandle(_ event:NSEvent) -> Bool {
    let code = event.keyCode
    if event.type == .keyDown && !event.isARepeat { letterRepeats.released(code:code) }
    let letterRelease = event.type == .keyUp && letterRepeats.owns(code:code)
    if event.type == .keyUp { letterRepeats.released(code:code) }
    if event.type == .keyDown && letterRepeats.consumeRepeat(code:code,isRepeat:event.isARepeat) { return true }
    let binding = EnhancementBridge.shared.settings.voice.binding
    let frozen = physicalKeys.ownsRelease
    let down:Bool
    if event.type == .flagsChanged {
      guard SquirrelKeycode.modifierKeycodes.contains(code) else { return false }
      down = CGEventSource.keyState(.combinedSessionState,key:CGKeyCode(code))
      // Side-specific hardware state; aggregate Option/Shift flags cannot prove release.
    } else if event.type == .keyDown || event.type == .keyUp { down = event.type == .keyDown }
    else { return false }
    if event.type == .keyDown && code == 53 && voiceIdentity != nil && !voiceTerminal {
      if let identity = voiceIdentity, let data = try? Wire.encode(identity) { EnhancementBridge.shared.helper?.cancel(data) }
      voiceTarget?.invalidate(); voiceTerminal = true; voiceLease?.invalidate()
      physicalKeys.cancel(); EnhancementPreview.shared.clear(); return true
    }
    let candidateBinding = binding?.codes.contains(code) == true
    let settings = EnhancementBridge.shared.settings
    let canStart = settings.voice.enabled && EnhancementBridge.shared.connected &&
      (voiceIdentity == nil || voiceTerminal) && !enhancementComposing() && client != nil &&
      AXIsProcessTrusted() && !IsSecureEventInputEnabled()
    let action = physicalKeys.event(code:code,down:down,repeated:event.type == .keyDown && event.isARepeat,
                                    binding:binding,canStart:canStart)
    if candidateBinding && down && !(event.type == .keyDown && event.isARepeat) {
      if action == .start {
        EnhancementBridge.shared.reply("voice-target:已收到语音热键，正在检查原输入框；尚未采音。")
      } else if canStart {
        EnhancementBridge.shared.reply("voice-target:已收到语音热键，正在等待完整按键周期；请先松开所有修饰键，再按住已设置热键。")
      }
    }
    switch action {
    case .start:
      let identity = VoiceIdentity(generation:inputGeneration)
      voiceIdentity = identity; voiceTarget = nil; voiceStopRelay.begin(identity)
      voiceAttempted = false; voiceTerminal = false; voiceCapturePending = true
      voiceLease?.invalidate()
      // The host is synchronously waiting for handle(_:client:) to return.
      // Querying its AX server here can time out even in TextEdit. Reserve the
      // physical cycle now, then verify the target after the event is returned.
      let pressUptime=event.timestamp
      let originalClient=client
      let originalRange=client?.selectedRange()
      let originalPID=NSWorkspace.shared.frontmostApplication?.processIdentifier
      DispatchQueue.main.asyncAfter(deadline:.now()+0.02) { [weak self] in
        self?.enhancementPrepareVoice(identity,settings:settings,pressUptime:pressUptime,
          originalClient:originalClient,originalRange:originalRange,originalPID:originalPID)
      }
      return true
    case .stop:
      if voiceCapturePending {
        if let identity=voiceIdentity { _ = voiceStopRelay.release(identity,at:event.timestamp) }
        voiceCapturePending=false; voiceTerminal=true
        return true // A quick tap cannot start a delayed microphone task.
      }
      if let identity = voiceIdentity,
         let release=voiceStopRelay.release(identity,at:event.timestamp),
         let data = try? Wire.encode(release) { EnhancementBridge.shared.helper?.release(data) }
      return true
    case .none: break
    }
    if candidateBinding, voiceIdentity != nil, !voiceTerminal, voiceReleased {
      // A second binding press while finalizing is not ordinary editing and must
      // not revoke the first task. It owns a rejected cycle until full key-up.
      if down, let binding { physicalKeys.rejectBusyCycle(binding:binding) }
      EnhancementPreview.shared.notice("正在收尾上一段；本次按压不创建任务、不排队。请完整松开后再录音。")
      return true
    }
    if frozen.contains(code) || letterRelease { return true } // only owned repeats/releases.
    if settings.voice.enabled && candidateBinding && down && !(event.type == .keyDown && event.isARepeat) && !canStart {
      let message:String
      if enhancementComposing() { message="请先确认或取消当前拼音，再按住语音热键。" }
      else if !EnhancementBridge.shared.connected {
        _ = EnhancementBridge.shared.launchIfNeeded()
        message="语音助手正在连接，请完整松开热键，稍后再次按住。"
      } else if IsSecureEventInputEnabled() { message="当前处于安全输入模式，无法启动语音。请切换到普通文本框。" }
      else if !AXIsProcessTrusted() { message="需要输入法焦点检测权限。请在语音输入设置中点击“授权输入法焦点检测”，并在系统辅助功能中允许鼠须管增强开发版。" }
      else { message="当前输入会话尚未就绪；请重新聚焦普通文本框，再按住热键。" }
      EnhancementPreview.shared.notice(message)
      EnhancementBridge.shared.reply("voice-target:"+message)
    }
    let activityKind:VoiceKeyboardEventKind = event.type == .flagsChanged ? .modifierChange :
      (event.type == .keyDown ? .keyDown : .keyUp)
    if VoiceKeyInterruptionPolicy.shouldInvalidate(code:code,kind:activityKind,
      liveVoice:voiceIdentity != nil && !voiceTerminal,ownedCycle:frozen,
      binding:binding,finalizing:voiceReleased) { enhancementInvalidated() }
    if event.type == .flagsChanged && (event.modifierFlags.contains(.shift) || code == 57) {
      rimeAPI.set_property(session,"_letter_selection_reset",UUID().uuidString)
    }
    return false
  }
  private func enhancementPrepareVoice(_ identity:VoiceIdentity,settings:Settings,pressUptime:TimeInterval,
      originalClient:IMKTextInput?,originalRange:NSRange?,originalPID:Int32?) {
    guard voiceIdentity == identity, !voiceTerminal, voiceCapturePending else { return }
    do {
      guard !voiceReleased, identity.generation == inputGeneration,
            EnhancementBridge.shared.settings.revision == settings.revision,
            EnhancementBridge.shared.settings.voice.enabled,EnhancementBridge.shared.connected,
            !enhancementComposing(),let client,let originalClient,client === originalClient,
            client.selectedRange() == originalRange,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == originalPID else {
        throw EnhancementTarget.CaptureFailure.unavailable
      }
      let target=try EnhancementTarget(client:client,generation:inputGeneration)
      guard target.valid else { throw EnhancementTarget.CaptureFailure.unavailable }
      voiceCapturePending=false; voiceTarget=target
      target.invalidated={ [weak self] in self?.enhancementInvalidated() }
      EnhancementPreview.shared.begin(identity,showPreview:settings.voice.showPreview,
        transparency:settings.voice.previewTransparency,atCaret:settings.voice.previewAtCaret,
        anchor:target.previewAnchor())
      if let data=try? Wire.encode(VoiceRequest(identity:identity,revision:settings.revision,pressUptime:pressUptime)) {
        EnhancementBridge.shared.helper?.begin(data)
      }
      voiceLease=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in
        guard let self,self.voiceIdentity == identity,!self.voiceTerminal else { return }
        if let data=try? Wire.encode(identity) { EnhancementBridge.shared.helper?.lease(data) }
        if self.voiceTarget?.valid != true { self.enhancementInvalidated() }
      }
    } catch {
      voiceCapturePending=false; voiceTerminal=true; physicalKeys.cancel()
      let message=(error as? EnhancementTarget.CaptureFailure)?.message ?? "当前输入框的位置检查失败；未启动采音。"
      EnhancementPreview.shared.notice(message)
      EnhancementBridge.shared.reply("voice-target:"+message)
    }
  }
  // Support command: the same target verifier, with no begin/capture/cloud call.
  // It reports only bounded failure metadata, never text or clipboard contents.
  func enhancementCheckVoiceTarget(requestID:String? = nil) {
    var report:[String:Any] = ["microphone_used":false,"cloud_calls":0,"app_version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown"]
    func reply(_ message:String) {
      EnhancementBridge.shared.reply("voice-target:"+message)
      report["message"]=message
      guard let requestID,UUID(uuidString:requestID) != nil,
            let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),data.count <= 4096,
            let text=String(data:data,encoding:.utf8) else { return }
      DistributedNotificationCenter.default().postNotificationName(.init("SquirrelEnhancedDevVoiceTargetCheckResponse"),object:requestID,userInfo:["report":text],deliverImmediately:true)
    }
    guard !enhancementIsBusy(),let client else {
      reply("当前没有空闲输入会话；位置检查未执行，未采音。")
      return
    }
    // Capability metadata only: no value, filename, selected text, coordinates,
    // clipboard, microphone, Keychain or recognition request.
    let range=client.selectedRange()
    report["native_selection_length_known"]=range.length != NSNotFound
    report["native_has_selection"]=range.length != NSNotFound && range.length > 0
    report["native_offset_known"]=range.location != NSNotFound
    var caret=NSRect.zero; client.attributes(forCharacterIndex:0,lineHeightRectangle:&caret)
    report["native_caret_available"]=NativeVoiceTargetSnapshot.validCaret(caret)
    if let front=NSWorkspace.shared.frontmostApplication {
      report["finder_target"]=front.bundleIdentifier == "com.apple.finder"
      report["native_window_available"]=NativeVoiceTargetSnapshot.frontWindow(processID:front.processIdentifier,caret:caret,includeFinderDesktop:front.bundleIdentifier == "com.apple.finder") != nil
      if front.bundleIdentifier == "com.apple.finder",client.bundleIdentifier() == "com.apple.finder" {
        var actual=NSRange(location:NSNotFound,length:NSNotFound)
        let first=client.firstRect(forCharacterRange:NSRange(location:0,length:0),actualRange:&actual)
        report["native_first_rect_available"]=NativeVoiceTargetSnapshot.validCaret(first)
      }
      let app=AXUIElementCreateApplication(front.processIdentifier);AXUIElementSetMessagingTimeout(app,0.3)
      var focus:CFTypeRef?
      let error=AXUIElementCopyAttributeValue(app,kAXFocusedUIElementAttribute as CFString,&focus)
      report["ax_focus_error"]=error.rawValue
      var focusedWindow:CFTypeRef?
      report["ax_window_error"]=AXUIElementCopyAttributeValue(app,kAXFocusedWindowAttribute as CFString,&focusedWindow).rawValue
    }
    do {
      let target=try EnhancementTarget(client:client,generation:inputGeneration)
      let matches=target.matches(client:client,generation:inputGeneration)
      report["target_verified"]=matches
      reply(matches ? "\(target.verificationDescription)的位置检查通过；未采音、未联网。" :
        "输入框在检查期间发生变化；未采音、未联网。")
    } catch {
      report["target_verified"]=false
      reply((error as? EnhancementTarget.CaptureFailure)?.message ?? "位置检查失败；未采音。")
    }
  }
  func enhancementInvalidated() {
    guard let identity = voiceIdentity, !voiceTerminal else { return }
    if voiceCapturePending {
      voiceCapturePending=false; voiceTerminal=true; physicalKeys.cancel()
      _ = voiceStopRelay.invalidate(identity,at:ProcessInfo.processInfo.systemUptime)
      return // No begin has been sent; the deferred callback loses ownership.
    }
    voiceTarget?.invalidate()
    if let release=voiceStopRelay.invalidate(identity,at:ProcessInfo.processInfo.systemUptime),
       let data = try? Wire.encode(release) { EnhancementBridge.shared.helper?.release(data) }
    // Invalidation is not a synthetic physical release and never rearms a held key.
    physicalKeys.cancel()
  }
  func enhancementConfigurationChanged(_ value:Settings) {
    if voiceIdentity == nil || voiceTerminal {
      EnhancementPreview.shared.configure(transparency:value.voice.previewTransparency,atCaret:value.voice.previewAtCaret)
    }
    if !value.voice.enabled, let identity = voiceIdentity, !voiceTerminal {
      if let data = try? Wire.encode(identity) { EnhancementBridge.shared.helper?.cancel(data) }
      voiceTerminal = true; physicalKeys.cancel(); voiceLease?.invalidate(); voiceTarget?.invalidate()
      voiceCapturePending=false
      voiceTarget=nil
      EnhancementPreview.shared.clear()
    }
    guard session != 0, !schemaId.isEmpty else { return }
    if let update = letterSettings.offer(schema:schemaId,profile:value.letters[schemaId],
                                        revision:value.revision,composing:enhancementComposing()) {
      applyLetterSettings(update)
    }
  }
  private func applyLetterSettings(_ update:LetterRuntimeUpdate) {
    let profile = update.profile
    rimeAPI.set_option(session,"letter_selection_disabled",profile?.enabled != true)
    if let profile {
      rimeAPI.set_property(session,"_letter_selection_runtime_keys",profile.keys)
      rimeAPI.set_property(session,"_letter_selection_runtime_hide",profile.hideCandidates ? "true" : "false")
      rimeAPI.set_property(session,"_letter_selection_runtime_revision",String(update.revision))
    }
    rimeAPI.set_property(session,"_letter_selection_reset",UUID().uuidString)
    if !enhancementComposing() { NSApp.squirrelAppDelegate.loadSettings(for:schemaId) }
  }
  func voiceReceived(_ value:VoiceUpdate) {
    guard voiceIdentity == value.identity, !voiceTerminal else { return }
    var display = value
    if [.ready,.review,.failed,.cancelled].contains(value.phase) {
      voiceLease?.invalidate(); physicalKeys.cancel()
      if value.phase == .ready {
        let valid = voiceReleased && !voiceAttempted && value.complete && !enhancementComposing() &&
          voiceTarget?.matches(client:client,generation:inputGeneration) == true &&
          !value.text.unicodeScalars.contains(where:{CharacterSet.controlCharacters.union(.newlines).contains($0)})
        if valid, let client {
          voiceAttempted = true // Before insertion. Do not retry an unknown native outcome.
          // Reuse the ordinary keyboard commit, including the marked-text
          // compatibility option required by some embedded web clients.
          withExtendedLifetime(client) { commit(string:value.text) }
          voiceDiagnosticReceipt(value.identity,decision:.nativeCallReturned)
          EnhancementPreview.shared.clear(); voiceTerminal = true; voiceTarget = nil; return
        }
        display.phase = .review; display.message = "目标/位置无法再次证实；没有自动插入，文本仅作草稿。"
        voiceDiagnosticReceipt(value.identity,decision:.reviewRequired)
      }
      voiceTerminal = true; voiceTarget = nil
    }
    EnhancementPreview.shared.update(display)
  }
  func enhancementDeploy(action:String,schema:String) {
    EnhancementDeployment.shared.perform(action:action,schema:schema)
  }
  private func voiceDiagnosticReceipt(_ identity:VoiceIdentity,decision:VoiceDeliveryDecision) {
    let receipt=VoiceDeliveryReceipt(identity:identity,decision:decision,uptime:ProcessInfo.processInfo.systemUptime)
    if let data=try? Wire.encode(receipt) { EnhancementBridge.shared.helper?.voiceDeliveryReceipt(data) }
  }
  private func cleanReleasedPhysicalKeys() {
    for code in letterRepeats.ownedCodes where !CGEventSource.keyState(.combinedSessionState,key:CGKeyCode(code)) {
      letterRepeats.released(code:code)
    }
  }
  func enhancementIsBusy() -> Bool { enhancementComposing() || (voiceIdentity != nil && !voiceTerminal) }
  func enhancementCurrentSchema() -> String { schemaId }
  func enhancementOwnsVoice(_ identity:VoiceIdentity) -> Bool { voiceIdentity == identity && !voiceTerminal }
  func enhancementWillDeploy() { enhancementInvalidated(); inputGeneration += 1; cleanReleasedPhysicalKeys() }
}
