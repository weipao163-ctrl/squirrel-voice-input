import Foundation
import Darwin

/// Prefer a protected all-users installation. User installations remain
/// supported for development; they can be disabled by macOS Secure Input.
enum InputMethodLocation {
  static let name = "SquirrelEnhancedDev.app"
  static let systemApp = URL(fileURLWithPath: "/Library/Input Methods/" + name, isDirectory: true)

  static func userApp(home: URL) -> URL {
    home.resolvingSymlinksInPath().appendingPathComponent("Library/Input Methods", isDirectory: true)
      .appendingPathComponent(name, isDirectory: true).standardizedFileURL
  }

  static func protectedSystemApp(_ app: URL = systemApp) -> Bool {
    guard app.standardizedFileURL.path == app.resolvingSymlinksInPath().standardizedFileURL.path,
      let bundle = Bundle(url: app), bundle.bundleIdentifier == "org.rime.inputmethod.SquirrelEnhanced.Development" else { return false }
    for path in [app.deletingLastPathComponent(), app, app.appendingPathComponent("Contents"),
      app.appendingPathComponent("Contents/MacOS"), app.appendingPathComponent("Contents/MacOS/SquirrelEnhancedDev")] {
      var info = stat()
      guard lstat(path.path, &info) == 0, info.st_uid == 0,
        info.st_mode & 0o022 == 0, info.st_mode & S_IFMT != S_IFLNK else { return false }
    }
    return true
  }

  static func preferred(home: URL, system: URL = systemApp) -> URL {
    protectedSystemApp(system) ? system : userApp(home: home)
  }

  static func matches(_ bundle: URL, user: URL, system: URL, systemTrusted: Bool) -> Bool {
    let expected = systemTrusted ? system : user
    return bundle.standardizedFileURL.path == expected.standardizedFileURL.path &&
      bundle.resolvingSymlinksInPath().standardizedFileURL.path == expected.standardizedFileURL.path
  }
}
