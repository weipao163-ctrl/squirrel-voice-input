//
//  InputSource.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit

final class SquirrelInstaller {
  enum InputMode: String, CaseIterable {
    static let primary = Self.hans
    case hans = "org.rime.inputmethod.SquirrelEnhanced.Development.Hans"
    case hant = "org.rime.inputmethod.SquirrelEnhanced.Development.Hant"
  }
  private lazy var inputSources: [String: TISInputSource] = {
    var inputSources = [String: TISInputSource]()
    var matchingSources = [InputMode: TISInputSource]()
    let sourceList = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
    for inputSource in sourceList {
      let sourceIDRef = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
      guard let sourceID = unsafeBitCast(sourceIDRef, to: CFString?.self) as String? else { continue }
      inputSources[sourceID] = inputSource
    }
    return inputSources
  }()

  func enabledModes() -> [InputMode] {
    // A mode can have a true default state while its parent method is disabled.
    guard let identifier = Bundle.main.bundleIdentifier,
          let method = inputSources[identifier],
          getBool(for: method, key: kTISPropertyInputSourceIsEnabled) == true else { return [] }
    var enabledModes = Set<InputMode>()
    for (mode, inputSource) in getInputSource(modes: InputMode.allCases) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), enabled {
        enabledModes.insert(mode)
      }
      if enabledModes.count == InputMode.allCases.count {
        break
      }
    }
    return Array(enabledModes)
  }

  @discardableResult func register() -> OSStatus {
    let enabledInputModes = enabledModes()
    if !enabledInputModes.isEmpty {
      print("User already registered Squirrel method(s): \(enabledInputModes.map { $0.rawValue })")
      return noErr
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
    let enabledInputModes = enabledModes()
    if !enabledInputModes.isEmpty && modes.isEmpty {
      print("User already enabled Squirrel method(s): \(enabledInputModes.map { $0.rawValue })")
      // Preserve manually enabled input modes.
      return noErr
    }
    let modesToEnable = modes.isEmpty ? [.primary] : modes
    guard getInputSource(modes: modesToEnable).count == modesToEnable.count,
          let identifier = Bundle.main.bundleIdentifier, let method = inputSources[identifier] else { return OSStatus(paramErr) }
    if getBool(for: method, key: kTISPropertyInputSourceIsEnabled) != true {
      let status = TISEnableInputSource(method)
      guard status == noErr else { return status }
    }
    for (mode, inputSource) in getInputSource(modes: modesToEnable) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), !enabled {
        let error = TISEnableInputSource(inputSource)
        print("Enable \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
        guard error == noErr else { return error }
      }
    }
    return noErr
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
