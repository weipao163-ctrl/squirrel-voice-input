//
//  InputSource.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit
import Carbon

final class SquirrelInstaller {
  enum InputMode: String, CaseIterable {
    static let primary = Self.hans
    case hans = "org.rime.inputmethod.SquirrelEnhanced.Development.Hans"
    case hant = "org.rime.inputmethod.SquirrelEnhanced.Development.Hant"
  }
  // TIS objects are snapshots. Registration and enablement can change the list
  // during this install command; never reuse a pre-registration snapshot.
  private var inputSources: [String: TISInputSource] {
    var inputSources = [String: TISInputSource]()
    let sourceList = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
    for inputSource in sourceList {
      let sourceIDRef = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
      guard let sourceID = unsafeBitCast(sourceIDRef, to: CFString?.self) as String? else { continue }
      inputSources[sourceID] = inputSource
    }
    return inputSources
  }

  // Installation commands have injectable system boundaries so a cached TIS
  // default cannot be mistaken for a successful, persisted user choice.
  struct SourceAccess {
    var enabledIDs: () -> Set<String>
    var installedIDs: () -> Set<String>
    var savedSources: () -> [[String: String]]
    var enable: (String) -> OSStatus
  }

  private let identifier: String
  private let access: SourceAccess

  init(identifier: String = Bundle.main.bundleIdentifier ?? "", access: SourceAccess? = nil) {
    self.identifier = identifier
    self.access = access ?? Self.systemAccess(identifier: identifier)
  }

  private static func sourceID(_ source: TISInputSource) -> String? {
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
  }

  private static func sources(identifier: String, allInstalled: Bool) -> [TISInputSource] {
    let filter = [kTISPropertyBundleID as String: identifier] as CFDictionary
    return TISCreateInputSourceList(filter, allInstalled).takeRetainedValue() as! [TISInputSource]
  }

  struct SavedSourceState {
    let domain: String
    let records: [[String: String]]
    let legacyRecords: [[String: String]]
    let modernRecords: [[String: String]]
  }

  static func savedSourceState(modern: Any?, legacy: Any?) -> SavedSourceState {
    func sanitized(_ value: Any?) -> [[String: String]] {
      let keys = ["Bundle ID", "Input Mode", "InputSourceKind", "KeyboardLayout Name", "KeyboardLayout ID"]
      return (value as? [[String: Any]] ?? []).map { record in
        var clean: [String: String] = [:]
        for key in keys {
          if let text = record[key] as? String { clean[key] = text }
          else if let number = record[key] as? NSNumber { clean[key] = number.stringValue }
        }
        return clean
      }
    }
    let older = sanitized(legacy), newer = sanitized(modern)
    // macOS 27 stores third-party choices separately. An explicitly empty new
    // domain is authoritative; do not resurrect stale HIToolbox entries.
    return SavedSourceState(domain: modern == nil ? "com.apple.HIToolbox" : "com.apple.inputsources",
      records: modern == nil ? older : newer, legacyRecords: older, modernRecords: newer)
  }

  static func readSavedSourceState() -> SavedSourceState {
    // Read only, using a whitelist of input-source metadata. No preferences
    // writes/synchronization, arbitrary settings, credentials or user text.
    let modern = CFPreferencesCopyValue("AppleEnabledThirdPartyInputSources" as CFString,
      "com.apple.inputsources" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    let legacy = CFPreferencesCopyValue("AppleEnabledInputSources" as CFString,
      "com.apple.HIToolbox" as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    return savedSourceState(modern: modern, legacy: legacy)
  }

  static func savedInputSources() -> [[String: String]] { readSavedSourceState().records }

  private static func systemAccess(identifier: String) -> SourceAccess {
    SourceAccess(
      enabledIDs: { Set(sources(identifier: identifier, allInstalled: false).compactMap(sourceID)) },
      installedIDs: { Set(sources(identifier: identifier, allInstalled: true).compactMap(sourceID)) },
      savedSources: savedInputSources,
      enable: { id in
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let matches = TISCreateInputSourceList(filter, true).takeRetainedValue() as! [TISInputSource]
        guard let source = matches.first(where: { sourceID($0) == id }) else { return OSStatus(paramErr) }
        return TISEnableInputSource(source)
      })
  }

  private func savedModes(in records: [[String: String]]) -> [InputMode] {
    let ids = Set(records.compactMap { record -> String? in
      guard record["Bundle ID"] == identifier, record["InputSourceKind"] == "Input Mode" else { return nil }
      return record["Input Mode"]
    })
    return InputMode.allCases.filter { ids.contains($0.rawValue) }
  }

  private func hasSavedParent(in records: [[String: String]]) -> Bool {
    records.contains { $0["Bundle ID"] == identifier && $0["InputSourceKind"] == "Keyboard Input Method" }
  }

  func enabledModes() -> [InputMode] {
    // allInstalled=true can expose default-enabled modes absent from the saved
    // menu. Require both the saved parent/modes and the enabled-only TIS list.
    let saved = access.savedSources()
    guard hasSavedParent(in: saved) else { return [] }
    let enabled = access.enabledIDs()
    guard enabled.contains(identifier) else { return [] }
    return savedModes(in: saved).filter { enabled.contains($0.rawValue) }
  }

  @discardableResult func register() -> OSStatus {
    // Enabled modes do not prove that LaunchServices points at this app. An
    // update moves bundles, and build/backup copies can retain the same ID.
    // Refresh both registries even when the user's modes are already enabled.
    let launchStatus = LSRegisterURL(SquirrelApp.appDir as CFURL, true)
    guard launchStatus == noErr else {
      fputs("Application registration failed (OSStatus \(launchStatus)).\n", stderr)
      return launchStatus
    }
    let status = TISRegisterInputSource(SquirrelApp.appDir as CFURL)
    if status == noErr {
      // noErr alone can silently accept a bundle that macOS does not classify
      // as an input method. Query afresh instead of the pre-registration cache.
      let registered = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
      let identifiers = Set(registered.compactMap { source -> String? in
        let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        return unsafeBitCast(pointer, to: CFString?.self) as String?
      })
      guard Set(InputMode.allCases.map(\.rawValue)).isSubset(of: identifiers) else {
        fputs("Input source registration returned noErr, but the isolated input modes are absent from the system list; preserving the previous installation.\n", stderr)
        return OSStatus(-1)
      }
      print("Registered input source from \(SquirrelApp.appDir)")
    } else {
      fputs("Input source registration failed (OSStatus \(status)); no input source was enabled or selected.\n", stderr)
    }
    return status
  }

  @discardableResult func enable(modes: [InputMode] = []) -> OSStatus {
    let saved = savedModes(in: access.savedSources())
    // A Hant-only user choice remains Hant-only even if TIS has lost its state.
    let modesToEnable = modes.isEmpty ? (saved.isEmpty ? [.primary] : saved) : modes
    let installed = access.installedIDs()
    guard installed.contains(identifier),
          modesToEnable.allSatisfy({ installed.contains($0.rawValue) }) else { return OSStatus(paramErr) }
    // This is an explicit enable command. Always call the supported API: an
    // all-installed snapshot reporting enabled is not an enablement receipt.
    let parentStatus = access.enable(identifier)
    guard parentStatus == noErr else { return parentStatus }
    for mode in InputMode.allCases where modesToEnable.contains(mode) {
      let status = access.enable(mode.rawValue)
      guard status == noErr else { return status }
    }
    let verified = Set(enabledModes())
    guard Set(modesToEnable).isSubset(of: verified) else {
      fputs("输入源 API 已返回成功，但系统保存记录与可用输入源列表未能同时核验通过；未确认启用成功。请在系统设置 → 键盘 → 文本输入 → 编辑中添加鼠须管增强版并点击完成，再运行 --input-source-status 核验。未直接修改系统偏好文件，也未禁用或切换任何输入源。\n", stderr)
      return OSStatus(-1)
    }
    print("已核验系统保存的输入模式：\(modesToEnable.map { $0.rawValue }.joined(separator: ", "))")
    return noErr
  }

  func inputSourceStatus() -> [String: Any] {
    // The enabled-only query MUST run first in a fresh diagnostic process.
    // Loading all installed sources can reveal defaults and change later TIS
    // observations; preserve both snapshots instead of conflating them.
    let enabled = access.enabledIDs().sorted()
    let saved = access.savedSources()
    let storage = Self.readSavedSourceState()
    let current = Self.currentInputSourceID() ?? "unknown"
    let preferred = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?.path ?? "missing"
    let installed = access.installedIDs().sorted()
    return [
      "bundle_id": identifier,
      "enabled_only_ids_before_all_installed": enabled,
      "all_installed_ids": installed,
      "saved_enabled_input_sources": saved,
      "saved_source_domain": storage.domain,
      "hitoolbox_enabled_input_sources": storage.legacyRecords,
      "inputsources_enabled_third_party_sources": storage.modernRecords,
      "saved_parent_present": hasSavedParent(in: saved),
      "saved_mode_ids": savedModes(in: saved).map { $0.rawValue },
      "current_source": current,
      "preferred_app_path": preferred,
      "self_app_path": Bundle.main.bundleURL.path,
      "self_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
      "secure_input": IsSecureEventInputEnabled(),
      "query_order": ["enabled-only", "saved-preferences", "current-source", "preferred-app", "all-installed"],
      "registration_attempted": false, "enable_attempted": false,
      "preferences_written": false, "microphone_used": false, "cloud_calls": 0
    ]
  }

  @discardableResult func select(mode: InputMode? = nil) -> OSStatus {
    let enabledInputModes = enabledModes()
    let modeToSelect = mode ?? .primary
    if !enabledInputModes.contains(modeToSelect) {
      if mode != nil {
        let status = enable(modes: [modeToSelect])
        guard status == noErr else { return status }
      } else {
        print("Default method not enabled yet: \(modeToSelect.rawValue)")
        return OSStatus(paramErr)
      }
    }
    for (mode, inputSource) in getInputSource(modes: [modeToSelect]) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled),
         let selectable = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelectCapable),
         let selected = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelected),
         enabled && selectable {
        if selected { return noErr }
        let error = TISSelectInputSource(inputSource)
        print("Selection \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
        return error
      } else {
        print("Failed to select \(mode.rawValue)")
      }
    }
    return OSStatus(paramErr)
  }

  static func currentInputSourceID() -> String? {
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    return unsafeBitCast(idRef, to: CFString?.self) as String?
  }

  // Only an explicit package upgrade uses this. Switching away lets IMK
  // finish/deactivate its current composition before cooperative termination.
  // Never enables, disables or changes the user's other input sources.
  func selectKeyboardLayoutForUpdate() -> OSStatus {
    guard let current=Self.currentInputSourceID(),
      current.hasPrefix("org.rime.inputmethod.SquirrelEnhanced.Development") ||
      current.hasPrefix("org.rime.SquirrelEnhanced.Development") else { return noErr }
    let layouts=inputSources.filter { _,source in
      let pointer=TISGetInputSourceProperty(source,kTISPropertyInputSourceType)
      let kind=unsafeBitCast(pointer,to:CFString?.self)
      return kind == kTISTypeKeyboardLayout &&
        getBool(for:source,key:kTISPropertyInputSourceIsEnabled) == true &&
        getBool(for:source,key:kTISPropertyInputSourceIsSelectCapable) == true
    }.sorted { left,right in
      if left.key == "com.apple.keylayout.ABC" { return true }
      if right.key == "com.apple.keylayout.ABC" { return false }
      return left.key < right.key
    }
    for (_,source) in layouts {
      let status=TISSelectInputSource(source)
      if status == noErr { return status }
    }
    return OSStatus(paramErr)
  }

  func disable(modes: [InputMode] = []) {
    let modesToDisable = modes.isEmpty ? InputMode.allCases : modes
    for (mode, inputSource) in getInputSource(modes: modesToDisable) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), enabled {
        let error = TISDisableInputSource(inputSource)
        print("Disable \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
      }
    }
  }

  private func getInputSource(modes: [InputMode]) -> [InputMode: TISInputSource] {
    var matchingSources = [InputMode: TISInputSource]()
    for mode in modes {
      if let inputSource = inputSources[mode.rawValue] {
        matchingSources[mode] = inputSource
      }
    }
    return matchingSources
  }

  private func getBool(for inputSource: TISInputSource, key: CFString!) -> Bool? {
    let enabledRef = TISGetInputSourceProperty(inputSource, key)
    guard let enabled = unsafeBitCast(enabledRef, to: CFBoolean?.self) else { return nil }
    return CFBooleanGetValue(enabled)
  }
}
