import Foundation
import Darwin

/// The service entry point is deliberately narrower than the maintenance CLI.
/// This file has no AppKit, InputMethodKit or Rime dependencies so admission and
/// lifetime ordering can be tested without starting an input method.
enum LaunchAdmission {
  static let bundleIdentifier = "org.rime.inputmethod.SquirrelEnhanced.Development"
  static let bundleName = "SquirrelEnhancedDev.app"
  enum Action: Equatable { case service, settings, maintenance, rejected }
  enum Failure: Error { case wrongLocation, wrongIdentity, lockUnavailable, serverUnavailable }

  static func action(arguments: [String]) -> Action {
    guard let command = arguments.first else { return .service }
    // Finder/LaunchServices historically supplies one process serial number.
    // Accept only its standard decimal form, never arbitrary unknown options.
    if arguments.count == 1 && isProcessSerialNumber(command) { return .service }
    if command == "--settings" { return arguments.count == 1 ? .settings : .rejected }
    let simple: Set<String> = ["--voice-readiness", "--voice-target-check", "--candidate-position-stats",
      "--candidate-position-check", "--reload", "--input-source-status", "--register-input-source",
      "--install", "--build", "--sync", "--ascii", "--nascii", "--getascii", "--help"]
    if simple.contains(command) { return arguments.count == 1 ? .maintenance : .rejected }
    if command == "--quit" {
      if arguments.count == 1 { return .maintenance }
      return arguments.count == 3 && arguments[1] == "--installed-app-path" &&
        arguments[2].hasPrefix("/") && !arguments[2].contains("\n") && !arguments[2].contains("\0")
        ? .maintenance : .rejected
    }
    if ["--enable-input-source", "--disable-input-source", "--select-input-source"].contains(command) {
      let modes = arguments.dropFirst()
      guard command != "--select-input-source" || modes.count <= 1 else { return .rejected }
      let allowed = Set([bundleIdentifier + ".Hans", bundleIdentifier + ".Hant"])
      return modes.allSatisfy(allowed.contains) ? .maintenance : .rejected
    }
    return .rejected
  }

  private static func isProcessSerialNumber(_ argument: String) -> Bool {
    guard argument.hasPrefix("-psn_") else { return false }
    let numbers = argument.dropFirst(5).split(separator: "_", omittingEmptySubsequences: false)
    return numbers.count == 2 && numbers.allSatisfy { part in
      !part.isEmpty && part.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
  }

  static var homeDirectory: URL {
    if let entry = getpwuid(getuid()) {
      return URL(fileURLWithFileSystemRepresentation: entry.pointee.pw_dir, isDirectory: true, relativeTo: nil)
    }
    return FileManager.default.homeDirectoryForCurrentUser
  }

  static func installedBundle(home: URL) -> URL {
    home.resolvingSymlinksInPath().appendingPathComponent("Library/Input Methods", isDirectory: true)
      .appendingPathComponent(bundleName, isDirectory: true).standardizedFileURL
  }

  static func isInstalledBundle(_ bundle: URL, home: URL) -> Bool {
    let expected = installedBundle(home: home)
    // Requiring the lexical path as well as its resolution rejects aliases or
    // a build/backup copy masquerading as the installed service.
    return bundle.standardizedFileURL.path == expected.path &&
      bundle.resolvingSymlinksInPath().standardizedFileURL.path == expected.path
  }

  static func runService<Server: AnyObject>(bundle: URL, home: URL, identifier: String?, connectionName: String?,
    acquireLease: (URL) throws -> AnyObject = { try InputMethodInstanceLock(directory: $0) },
    makeServer: (String, String) -> Server?, run: (Server) -> Void) throws {
    guard isInstalledBundle(bundle, home: home) else { throw Failure.wrongLocation }
    guard identifier == bundleIdentifier, connectionName == bundleIdentifier + "_Connection" else {
      throw Failure.wrongIdentity
    }
    try withEngineLease(home: home, acquireLease: acquireLease) {
      guard let server = makeServer(connectionName!, bundleIdentifier) else { throw Failure.serverUnavailable }
      // A non-nil IMKServer proves creation only, not a working client session.
      // Keep our own ownership instead of relying on framework-internal retains.
      withExtendedLifetime(server) { run(server) }
    }
  }

  // --build also opens the personal Rime directory. Maintenance commands which
  // only inspect/register/quit stay independent, but every engine uses one lock.
  static func withEngineLease<Result>(home: URL,
    acquireLease: (URL) throws -> AnyObject = { try InputMethodInstanceLock(directory: $0) },
    run: () throws -> Result) throws -> Result {
    let lease = try acquireLease(home.appendingPathComponent("Library/Application Support/SquirrelEnhancedDev", isDirectory: true))
    return try withExtendedLifetime(lease) { try run() }
  }
}

/// Kernel-owned advisory lease: process exit releases it automatically. Never
/// unlink the file as a stale-lock repair, which would permit two live owners.
private final class InputMethodInstanceLock {
  private var descriptor: Int32 = -1
  init(directory: URL) throws {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    } catch { throw LaunchAdmission.Failure.lockUnavailable }
    let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directoryFD >= 0 else { throw LaunchAdmission.Failure.lockUnavailable }
    defer { close(directoryFD) }
    var directoryInfo = stat()
    guard fstat(directoryFD, &directoryInfo) == 0, directoryInfo.st_uid == getuid(),
      directoryInfo.st_mode & 0o022 == 0 else { throw LaunchAdmission.Failure.lockUnavailable }
    let fd = openat(directoryFD, ".input-method.lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { throw LaunchAdmission.Failure.lockUnavailable }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
      info.st_uid == getuid(), info.st_nlink == 1,
      info.st_mode & 0o077 == 0,
      flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      close(fd); throw LaunchAdmission.Failure.lockUnavailable
    }
    descriptor = fd
  }
  deinit { if descriptor >= 0 { close(descriptor) } }
}
