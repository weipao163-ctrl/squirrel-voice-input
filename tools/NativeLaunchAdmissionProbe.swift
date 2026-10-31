import Foundation
import Darwin

@main
enum NativeLaunchAdmissionProbe {
  final class Trace { var events: [String] = [] }
  final class Token {
    let name: String, trace: Trace
    init(_ name: String, _ trace: Trace) { self.name = name; self.trace = trace; trace.events.append("create:" + name) }
    deinit { trace.events.append("release:" + name) }
  }
  static let identifier = LaunchAdmission.bundleIdentifier
  static let connection = identifier + "_Connection"

  static func main() throws {
    let files = FileManager.default
    if CommandLine.arguments.count == 3 && ["--probe-lock", "--probe-build"].contains(CommandLine.arguments[1]) {
      let home = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
      do {
        if CommandLine.arguments[1] == "--probe-build" {
          try LaunchAdmission.withEngineLease(home: home) { /* fake deployment */ }
        } else {
          try LaunchAdmission.runService(bundle: LaunchAdmission.installedBundle(home: home), home: home,
            identifier: identifier, connectionName: connection,
            makeServer: { _, _ in Token("fake-server", Trace()) }, run: { _ in })
        }
        exit(0)
      } catch { exit(73) }
    }
    let home = files.temporaryDirectory.appendingPathComponent("squirrel-launch-fixture-" + UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: home) }
    let app = LaunchAdmission.installedBundle(home: home)
    var checks: [String: Bool] = [:]
    func check(_ name: String, _ condition: Bool) { checks[name] = condition }
    check("no_arguments_is_service", LaunchAdmission.action(arguments: []) == .service)
    check("finder_psn_is_service", LaunchAdmission.action(arguments: ["-psn_0_123456"]) == .service)
    check("finder_psn_rejects_non_decimal_and_empty", ["-psn_1_", "-psn__1", "-psn_1_-2", "-psn_1_2_3", "-psn_1_２"].allSatisfy {
      LaunchAdmission.action(arguments: [$0]) == .rejected
    })
    check("finder_psn_cannot_hide_unknown_option", LaunchAdmission.action(arguments: ["-psn_0_1", "--bad"]) == .rejected)
    check("unknown_and_misspelled_commands_rejected", ["--version", "--input-source-statu", "--unexpected", "file.txt"].allSatisfy {
      LaunchAdmission.action(arguments: [$0]) == .rejected
    })
    check("settings_is_explicit_route", LaunchAdmission.action(arguments: ["--settings"]) == .settings)
    check("settings_extra_argument_rejected", LaunchAdmission.action(arguments: ["--settings", "--bad"]) == .rejected)
    let commands = ["--voice-readiness", "--voice-target-check", "--candidate-position-stats", "--candidate-position-check",
      "--reload", "--input-source-status", "--register-input-source", "--install", "--build", "--sync", "--ascii", "--nascii", "--getascii", "--help", "--quit"]
    check("maintenance_whitelist_preserved", commands.allSatisfy { LaunchAdmission.action(arguments: [$0]) == .maintenance })
    check("maintenance_extra_options_rejected", commands.allSatisfy { LaunchAdmission.action(arguments: [$0, "--bad"]) == .rejected })
    check("candidate_package_quit_supported", LaunchAdmission.action(arguments: ["--quit", "--installed-app-path", app.path]) == .maintenance)
    check("quit_invalid_path_rejected", ["relative.app", "/tmp/x\n--bad", "/tmp/x\0y"].allSatisfy {
      LaunchAdmission.action(arguments: ["--quit", "--installed-app-path", $0]) == .rejected
    })
    check("mode_commands_support_defaults_and_exact_modes", ["--enable-input-source", "--disable-input-source", "--select-input-source"].allSatisfy {
      LaunchAdmission.action(arguments: [$0]) == .maintenance &&
      LaunchAdmission.action(arguments: [$0, identifier + ".Hant"]) == .maintenance &&
      LaunchAdmission.action(arguments: [$0, "Hant"]) == .rejected
    })
    check("select_rejects_multiple_modes", LaunchAdmission.action(arguments: ["--select-input-source", identifier + ".Hans", identifier + ".Hant"]) == .rejected)
    check("exact_installed_path_accepted", LaunchAdmission.isInstalledBundle(app, home: home))
    check("build_and_backup_paths_rejected", !LaunchAdmission.isInstalledBundle(home.appendingPathComponent("build/SquirrelEnhancedDev.app"), home: home) &&
      !LaunchAdmission.isInstalledBundle(home.appendingPathComponent("Library/Input Methods/SquirrelEnhancedDev.app-backup"), home: home))

    func refusal(_ name: String, bundle: URL? = nil, bundleID: String? = identifier,
      nameOfConnection: String? = connection, refuseLock: Bool = false, refuseServer: Bool = false) {
      let trace = Trace()
      do {
        try LaunchAdmission.runService(bundle: bundle ?? app, home: home, identifier: bundleID, connectionName: nameOfConnection,
          acquireLease: { _ in
            trace.events.append("lock")
            if refuseLock { throw LaunchAdmission.Failure.lockUnavailable }
            return Token("lease", trace)
          }, makeServer: { _, _ -> Token? in
            trace.events.append("server")
            return refuseServer ? nil : Token("server", trace)
          }, run: { _ in trace.events.append("rime-and-app-run") })
        check(name, false)
      } catch {
        let allowed: [String] = refuseServer ? ["lock", "create:lease", "server", "release:lease"] : refuseLock ? ["lock"] : []
        check(name, trace.events == allowed)
      }
    }
    refusal("wrong_path_never_reaches_lock_server_or_engine", bundle: home.appendingPathComponent("build/SquirrelEnhancedDev.app"))
    refusal("wrong_identity_never_reaches_lock_server_or_engine", bundleID: "wrong")
    refusal("missing_connection_never_reaches_lock_server_or_engine", nameOfConnection: nil)
    refusal("mismatched_connection_never_reaches_lock_server_or_engine", nameOfConnection: "wrong")
    refusal("duplicate_owner_never_reaches_server_or_engine", refuseLock: true)
    refusal("nil_server_never_reaches_engine_and_releases_lock", refuseServer: true)
    do {
      let trace = Trace()
      weak var lease: Token?
      weak var server: Token?
      try LaunchAdmission.runService(bundle: app, home: home, identifier: identifier, connectionName: connection,
        acquireLease: { _ in let value = Token("lease", trace); lease = value; return value },
        makeServer: { name, id in
          check("factory_receives_exact_identity", name == connection && id == identifier)
          let value = Token("server", trace); server = value; return value
        }, run: { _ in
          check("lease_and_server_alive_through_run", lease != nil && server != nil)
          trace.events.append("run")
        })
      check("service_objects_released_after_run", lease == nil && server == nil &&
        trace.events.firstIndex(of: "run")! < trace.events.firstIndex(of: "release:server")! &&
        trace.events.firstIndex(of: "run")! < trace.events.firstIndex(of: "release:lease")!)
    }

    // Actual flock operations use this private temporary home only. The child
    // calls the same admission code with fake server/engine objects.
    func childLockResult(build: Bool = false) throws -> Int32 {
      let child = Process()
      child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      child.arguments = [build ? "--probe-build" : "--probe-lock", home.path]
      child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
      try child.run(); child.waitUntilExit(); return child.terminationStatus
    }
    try LaunchAdmission.runService(bundle: app, home: home, identifier: identifier, connectionName: connection,
      makeServer: { _, _ in Token("fake-server", Trace()) }, run: { _ in
        check("independent_process_cannot_take_live_lock", (try? childLockResult()) == 73)
        check("offline_build_cannot_take_live_service_lock", (try? childLockResult(build: true)) == 73)
      })
    check("immediate_healthy_restart_can_take_released_lock", try childLockResult() == 0)
    try LaunchAdmission.withEngineLease(home: home) {
      check("service_cannot_take_live_offline_build_lock", (try? childLockResult()) == 73)
      check("second_build_cannot_take_live_offline_build_lock", (try? childLockResult(build: true)) == 73)
    }
    check("offline_build_can_take_released_engine_lock", try childLockResult(build: true) == 0)
    do {
      let trace = Trace()
      do {
        try LaunchAdmission.withEngineLease(home: home, acquireLease: { _ in throw LaunchAdmission.Failure.lockUnavailable }) {
          trace.events.append("prepare-data-and-deploy")
        }
        check("offline_build_lock_failure_never_opens_user_data", false)
      } catch { check("offline_build_lock_failure_never_opens_user_data", trace.events.isEmpty) }
    }
    let support = home.appendingPathComponent("Library/Application Support/SquirrelEnhancedDev")
    let lock = support.appendingPathComponent(".input-method.lock")
    check("no_legacy_launch_timestamp_created", !files.fileExists(atPath: home.appendingPathComponent("squirrel_enhanced_dev_launch.json").path))
    try files.removeItem(at: lock)
    let sentinel = home.appendingPathComponent("untouched-sentinel")
    try Data("unchanged".utf8).write(to: sentinel)
    try files.createSymbolicLink(at: lock, withDestinationURL: sentinel)
    check("symlink_lock_is_rejected", try childLockResult() == 73)
    check("symlink_target_unmodified", try Data(contentsOf: sentinel) == Data("unchanged".utf8))
    try files.removeItem(at: lock)
    try files.createDirectory(at: app.deletingLastPathComponent(), withIntermediateDirectories: true)
    let external = home.appendingPathComponent("build/SquirrelEnhancedDev.app", isDirectory: true)
    try files.createDirectory(at: external, withIntermediateDirectories: true)
    try files.createSymbolicLink(at: app, withDestinationURL: external)
    check("installed_symlink_to_build_is_rejected", !LaunchAdmission.isInstalledBundle(app, home: home))

    let report: [String: Any] = ["status": checks.values.allSatisfy { $0 } ? "PASS" : "FAIL", "checks": checks,
      "real_imk_server_started": false, "real_rime_started": false, "real_appkit_started": false,
      "personal_data_accessed": false, "system_input_preferences_changed": false]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print("LAUNCH_ADMISSION_PROBE_REPORT=" + String(decoding: data, as: UTF8.self))
    if checks.values.contains(false) { exit(1) }
  }
}
