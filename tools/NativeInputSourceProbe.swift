import AppKit
import Carbon
import Foundation

// Compile the production installer without starting the input-method server.
enum SquirrelApp { static let appDir = Bundle.main.bundleURL }

@main
struct NativeInputSourceProbe {
  static let parent = "org.rime.inputmethod.SquirrelEnhanced.Development"
  static let hans = SquirrelInstaller.InputMode.hans.rawValue
  static let hant = SquirrelInstaller.InputMode.hant.rawValue
  static func parentRecord() -> [String: String] {
    ["Bundle ID": parent, "InputSourceKind": "Keyboard Input Method"]
  }
  static func modeRecord(_ id: String) -> [String: String] {
    ["Bundle ID": parent, "InputSourceKind": "Input Mode", "Input Mode": id]
  }

  final class Fixture {
    var installed = Set([parent, hans, hant])
    var enabled = Set([parent, hans, hant])
    var saved: [[String: String]] = []
    var calls: [String] = []
    var queries: [String] = []
    var failures: [String: OSStatus] = [:]
    var persist = false
    func installer() -> SquirrelInstaller {
      SquirrelInstaller(identifier: parent, access: .init(
        enabledIDs: { self.queries.append("enabled-only"); return self.enabled },
        installedIDs: { self.queries.append("all-installed"); return self.installed },
        savedSources: { self.queries.append("saved"); return self.saved },
        enable: { id in
          self.calls.append(id)
          if let failure = self.failures[id] { return failure }
          if self.persist {
            self.enabled.insert(id)
            let record = id == parent ? parentRecord() : modeRecord(id)
            if !self.saved.contains(record) { self.saved.append(record) }
          }
          return noErr
        }))
    }
  }

  static func emit(_ report: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  }

  static func main() {
    let args = CommandLine.arguments
    if args.count > 1, args[1] == "--status" {
      emit(SquirrelInstaller(identifier: parent).inputSourceStatus()); return
    }
    if args.count > 2, args[1] == "--snapshot-order" {
      let order = args[2] == "enabled-first" ? [false, true, false] : [true, false]
      var samples: [[String: Any]] = []
      for all in order {
        let filter = [kTISPropertyBundleID as String: parent] as CFDictionary
        let sources = TISCreateInputSourceList(filter, all).takeRetainedValue() as! [TISInputSource]
        let ids = sources.compactMap { source -> String? in
          guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
          return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
        }
        samples.append(["include_all_installed": all, "ids": ids.sorted()])
      }
      emit(["pid": getpid(), "samples": samples, "registration_attempted": false,
        "enable_attempted": false, "preferences_written": false]); return
    }
    var checks: [String: Bool] = [:]
    let legacy = [parentRecord(), modeRecord(hans)]
    let modern = [parentRecord(), modeRecord(hant)]
    let oldState = SquirrelInstaller.savedSourceState(modern: nil, legacy: legacy)
    checks["legacy_storage_supported"] = oldState.domain == "com.apple.HIToolbox" && oldState.records == legacy
    let newState = SquirrelInstaller.savedSourceState(modern: modern, legacy: legacy)
    checks["macos27_storage_takes_precedence"] = newState.domain == "com.apple.inputsources" && newState.records == modern
    checks["empty_modern_storage_does_not_resurrect_legacy"] = SquirrelInstaller.savedSourceState(modern: [], legacy: legacy).records.isEmpty
    checks["malformed_modern_storage_fails_closed"] = SquirrelInstaller.savedSourceState(modern: "bad", legacy: legacy).records.isEmpty
    var extra = parentRecord(); extra["api_key"] = "fixture-secret"
    checks["diagnostics_whitelist_preferences"] = SquirrelInstaller.savedSourceState(modern: [extra], legacy: nil).records == [parentRecord()]

    do {
      let f = Fixture(), i = f.installer()
      checks["default_enabled_flags_are_not_saved_choice"] = i.enabledModes().isEmpty
      checks["enabled_modes_never_load_all_installed"] = !f.queries.contains("all-installed")
      f.saved = [parentRecord(), modeRecord(hans)]
      checks["saved_parent_and_mode_recognized"] = i.enabledModes() == [.hans]
      f.saved = [modeRecord(hans)]
      checks["mode_without_saved_parent_rejected"] = i.enabledModes().isEmpty
      f.saved = [parentRecord(), modeRecord(hans)]; f.enabled.remove(parent)
      checks["saved_choice_requires_tis_parent"] = i.enabledModes().isEmpty
      f.enabled.insert(parent); f.enabled.remove(hans)
      checks["saved_choice_requires_tis_mode"] = i.enabledModes().isEmpty
    }
    do {
      let f = Fixture(), i = f.installer()
      checks["api_noerr_without_saved_choice_rejected"] = i.enable() != noErr
      checks["explicit_enable_calls_parent_then_mode_even_if_flags_true"] = f.calls == [parent, hans]
    }
    do {
      let f = Fixture(); f.persist = true; f.enabled = []
      checks["confirmed_enable_succeeds"] = f.installer().enable() == noErr && f.saved == legacy
    }
    do {
      let f = Fixture(); f.saved = modern; f.persist = true
      checks["hant_only_is_preserved"] = f.installer().enable() == noErr && f.calls == [parent, hant] && f.saved == modern
    }
    do {
      let f = Fixture(); f.saved = modern; f.persist = true
      checks["explicit_hans_does_not_disable_hant"] = f.installer().enable(modes: [.hans]) == noErr && f.saved.contains(modeRecord(hant)) && f.calls == [parent, hans]
    }
    do {
      let f = Fixture(); f.failures[parent] = -50
      checks["parent_failure_stops_before_mode"] = f.installer().enable() == -50 && f.calls == [parent]
    }
    do {
      let f = Fixture(); f.failures[hans] = -50
      checks["mode_failure_propagates"] = f.installer().enable() == -50 && f.calls == [parent, hans]
    }
    do {
      let f = Fixture(); f.installed.remove(hans)
      checks["missing_mode_no_partial_enable"] = f.installer().enable() != noErr && f.calls.isEmpty
    }
    do {
      let f = Fixture(); f.installed.remove(parent)
      checks["missing_parent_no_partial_enable"] = f.installer().enable() != noErr && f.calls.isEmpty
    }
    do {
      let f = Fixture(); f.saved = legacy
      let report = f.installer().inputSourceStatus()
      checks["diagnostic_enabled_query_precedes_all_installed"] = f.queries == ["enabled-only", "saved", "all-installed"]
      checks["diagnostic_never_enables"] = f.calls.isEmpty && report["enable_attempted"] as? Bool == false
    }
    let pass = checks.values.allSatisfy { $0 }
    print("INPUT_SOURCE_PROBE_REPORT=" + String(decoding: try! JSONSerialization.data(withJSONObject: ["status": pass ? "PASS" : "FAIL", "checks": checks], options: [.sortedKeys]), as: UTF8.self))
    if !pass { exit(1) }
  }
}
