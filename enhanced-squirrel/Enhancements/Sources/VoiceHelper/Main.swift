import AppKit
import EnhancementIPC
import Darwin

private final class HelperInstanceLock {
  private var descriptor:Int32 = -1
  init?(directory:URL) {
    let base = directory
    do { try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]) }
    catch { return nil }
    descriptor = open(base.appendingPathComponent(".helper.lock").path,O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,0o600)
    guard descriptor >= 0 else { return nil }
    guard flock(descriptor,LOCK_EX | LOCK_NB) == 0 else { close(descriptor); descriptor = -1; return nil }
  }
  deinit { if descriptor >= 0 { close(descriptor) } }
}

private final class HelperApplicationDelegate:NSObject,NSApplicationDelegate {
  let model:HelperModel
  var ownerLost = false
  init(model:HelperModel) { self.model = model }
  func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
    // Human Quit follows the same unsaved-edit contract as the close button.
    // Owner death is forced cleanup, not a prompt that can keep an orphan alive.
    if ownerLost { model.stopAll(cancel:true); return .terminateNow }
    return model.confirmClosing(stoppingProduction:true) ? .terminateNow : .terminateCancel
  }
}

@main enum HelperMain {
  static func main() {
    let app = NSApplication.shared
    let arguments=CommandLine.arguments
    var base=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SquirrelEnhancedDev")
    if let index=arguments.firstIndex(of:"--isolated-settings-root") {
      // Standalone GUI verification only. Production IPC never accepts a
      // test-root override; current settings/Keychain references stay untouched.
      guard arguments.contains("--settings"), index+1<arguments.count,
            arguments[index+1].hasPrefix("/") else { return }
      base=URL(fileURLWithPath:arguments[index+1],isDirectory:true).standardizedFileURL
      guard base == base.resolvingSymlinksInPath().standardizedFileURL else { return }
    }
    guard let instance = HelperInstanceLock(directory:base) else { return } // One audio owner across GUI/production processes.
    app.setActivationPolicy(.accessory)
    let model = HelperModel(baseDirectory:base)
    let lifecycle = HelperApplicationDelegate(model:model); app.delegate = lifecycle
    if !CommandLine.arguments.contains("--settings") {
      // Parent writes a bounded private bootstrap to an inherited pipe.
      // Socket identity uses a kernel audit token and the exact pinned signer.
      var input = Data()
      do {
        while let chunk = try FileHandle.standardInput.read(upToCount:16 * 1024), !chunk.isEmpty {
          guard input.count + chunk.count <= 256 * 1024 else { return }; input.append(chunk)
        }
      } catch { return }
      guard input.count <= 256 * 1024,
            let bootstrap = try? IPCBootstrap.decode(input),
            let trust=PeerTrust.configured(in:Bundle.main) else { return }
      guard let connection = try? AuthenticatedConnection.connect(bootstrap,trust:trust) else { return }
      connection.exportedObject = model
      connection.invalidationHandler = { DispatchQueue.main.async { lifecycle.ownerLost = true; model.stopAll(cancel:true); model.connection = nil; NSApp.terminate(nil) } }
      connection.interruptionHandler = connection.invalidationHandler
      model.connection = connection; connection.resume()
      if let data = try? Wire.encode(model.draft) {
        (connection.remoteObjectProxyWithErrorHandler { _ in } as? InputCallbacks)?.settingsChanged(data)
      }
    } else { model.showSettings() }
    let menu = NSMenu(); let application = NSMenuItem(); menu.addItem(application)
    let commands = NSMenu(); commands.addItem(withTitle:"退出增强设置",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
    application.submenu = commands; app.mainMenu = menu
    withExtendedLifetime((model,instance,lifecycle)) { app.run() }
    model.stopAll(cancel:true)
  }
}
