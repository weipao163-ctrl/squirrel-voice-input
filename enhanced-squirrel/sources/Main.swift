//
//  Main.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit
import ApplicationServices
import Carbon

@main
struct SquirrelApp {
  static let userDir = if let pwuid = getpwuid(getuid()) {
    URL(fileURLWithFileSystemRepresentation: pwuid.pointee.pw_dir, isDirectory: true, relativeTo: nil).appending(components: "Library", "Application Support", "SquirrelEnhancedDev", "Rime")
  } else {
    try! FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("Application Support/SquirrelEnhancedDev/Rime", isDirectory: true)
  }
  static let appDir = Bundle.main.bundleURL
  static let logDir = FileManager.default.temporaryDirectory.appending(component: "rime.squirrel-enhanced-dev", directoryHint: .isDirectory)

  // URL.path() percent-encodes spaces by default. The earlier isolated build
  // consequently created a second Rime directory under Application%20Support.
  // Preserve missing user files there without replacing GUI-owned patches or
  // copying generated build caches. Keep the original directory for rollback.
  static func prepareUserDirectory() throws {
    let files = FileManager.default
    try files.createDirectory(at: userDir, withIntermediateDirectories: true)
    let legacy = URL(fileURLWithPath: userDir.path(percentEncoded: true), isDirectory: true)
    guard legacy != userDir, files.fileExists(atPath: legacy.path) else { return }
    guard legacy.standardizedFileURL == legacy.resolvingSymlinksInPath().standardizedFileURL else {
      throw CocoaError(.fileReadInvalidFileName)
    }
    for item in try files.contentsOfDirectory(at: legacy, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
      guard item.lastPathComponent != "build", !item.lastPathComponent.hasPrefix("."),
            try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
      let destination = userDir.appendingPathComponent(item.lastPathComponent)
      guard !files.fileExists(atPath: destination.path) else { continue }
      let temporary = userDir.appendingPathComponent(".migration-" + UUID().uuidString)
      do {
        try files.copyItem(at: item, to: temporary)
        try files.moveItem(at: temporary, to: destination)
      } catch {
        try? files.removeItem(at: temporary)
        throw error
      }
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  static func main() {
    let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee

    let handled = autoreleasepool {
      let installer = SquirrelInstaller()
      let args = CommandLine.arguments
      if args.count > 1 {
        switch args[1] {
        case "--voice-readiness":
          // Support-only read of this signed process's existing permission.
          // No prompt, target inspection, capture, Keychain or network access.
          let value:[String:Any] = [
            "input_method_focus_permission":AXIsProcessTrusted(),
            "secure_event_input":IsSecureEventInputEnabled(),
            "app_version":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown",
            "permission_requested":false,"microphone_used":false,"cloud_calls":0
          ]
          if let data=try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),
             let text=String(data:data,encoding:.utf8) { print(text) }
          return true
        case "--voice-target-check":
          let request=UUID().uuidString
          var response:String?
          let center=DistributedNotificationCenter.default()
          let token=center.addObserver(forName:.init("SquirrelEnhancedDevVoiceTargetCheckResponse"),object:request,queue:.main) { notice in
            if let value=notice.userInfo?["report"] as? String,value.utf8.count <= 4096 { response=value }
          }
          defer { center.removeObserver(token) }
          DistributedNotificationCenter.default().postNotificationName(
            .init("SquirrelEnhancedDevCheckVoiceTargetNotification"),object:request,userInfo:nil,deliverImmediately:true)
          let deadline=Date(timeIntervalSinceNow:3)
          while response == nil && Date() < deadline { RunLoop.main.run(until:Date(timeIntervalSinceNow:0.03)) }
          print(response ?? "当前输入法没有返回位置检查结果；未采音、未发送识别任务。")
          return true
        case "--quit":
          let bundleId = Bundle.main.bundleIdentifier!
          let runningSquirrels = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
          let helperURLs=Set(runningSquirrels.compactMap { $0.bundleURL?.appendingPathComponent("Contents/Resources/SquirrelVoiceHelper.app").standardizedFileURL })
          func runningHelpers() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier:"org.rime.SquirrelEnhanced.Development.VoiceHelper")
              .filter { $0.bundleURL.map{helperURLs.contains($0.standardizedFileURL)} == true }
          }
          // Ask the Helper to quit FIRST, while its owner is still alive. Its
          // existing unsaved-edit dialog remains authoritative; never turn a
          // maintenance quit into forced owner-loss cleanup/discard.
          runningHelpers().forEach { _ = $0.terminate() }
          let deadline=Date(timeIntervalSinceNow:8)
          while !runningHelpers().isEmpty && Date() < deadline {
            RunLoop.current.run(until:Date(timeIntervalSinceNow:0.1))
          }
          guard runningHelpers().isEmpty else {
            print("增强设置尚未退出。请处理未保存修改提示后重试；输入法及安装文件未替换。")
            exit(EXIT_FAILURE)
          }
          runningSquirrels.forEach { $0.terminate() }
          return true
        case "--reload":
          // Squirrel is a background app, and AppKit suspends distributed-notification delivery to inactive apps;
          // deliverImmediately is required for these notifications to reach Squirrel while it stays in the background
          DistributedNotificationCenter.default().postNotificationName(.init("SquirrelEnhancedDevReloadNotification"), object: nil, userInfo: nil, deliverImmediately: true)
          return true
        case "--settings":
          if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
            .contains(where: { $0.processIdentifier != getpid() }) {
            DistributedNotificationCenter.default().postNotificationName(.init("SquirrelEnhancedDevOpenSettingsNotification"), object: nil, userInfo: nil, deliverImmediately: true)
            return true
          }
          return false
        case "--register-input-source", "--install":
          guard installer.register() == noErr else { exit(EXIT_FAILURE) }
          return true
        case "--enable-input-source":
          if args.count > 2 {
            let modes = args[2...].map { SquirrelInstaller.InputMode(rawValue: $0) }.compactMap { $0 }
            if !modes.isEmpty {
              guard installer.enable(modes: modes) == noErr else { exit(EXIT_FAILURE) }
              return true
            }
          }
          guard installer.enable() == noErr else { exit(EXIT_FAILURE) }
          return true
        case "--disable-input-source":
          if args.count > 2 {
            let modes = args[2...].map { SquirrelInstaller.InputMode(rawValue: $0) }.compactMap { $0 }
            if !modes.isEmpty {
              installer.disable(modes: modes)
              return true
            }
          }
          installer.disable()
          return true
        case "--select-input-source":
          if args.count > 2, let mode = SquirrelInstaller.InputMode(rawValue: args[2]) {
            guard installer.select(mode: mode) == noErr else { exit(EXIT_FAILURE) }
          } else {
            guard installer.select() == noErr else { exit(EXIT_FAILURE) }
          }
          return true
        case "--build":
          do { try prepareUserDirectory() } catch { print("Cannot prepare isolated Rime directory: \(error.localizedDescription)"); exit(EXIT_FAILURE) }
          SquirrelApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_update", comment: ""))
          var builderTraits = RimeTraits.rimeStructInit()
          builderTraits.setCString(Bundle.main.sharedSupportPath!, to: \.shared_data_dir)
          builderTraits.setCString(Self.userDir.path, to: \.user_data_dir)
          builderTraits.setCString(Self.logDir.path, to: \.log_dir)
          builderTraits.setCString("rime.squirrel-builder", to: \.app_name)
          rimeAPI.setup(&builderTraits)
          rimeAPI.deployer_initialize(nil)
          _ = rimeAPI.deploy()
          return true
        case "--sync":
          DistributedNotificationCenter.default().postNotificationName(.init("SquirrelEnhancedDevSyncNotification"), object: nil, userInfo: nil, deliverImmediately: true)
          return true
        case "--ascii":
          DistributedNotificationCenter.default().postNotificationName(.init("SquirrelEnhancedDevToggleASCIIModeNotification"), object: "ascii", userInfo: nil, deliverImmediately: true)
          return true
        case "--nascii":
          DistributedNotificationCenter.default().postNotificationName(.init("SquirrelEnhancedDevToggleASCIIModeNotification"), object: "nascii", userInfo: nil, deliverImmediately: true)
          return true
        case "--getascii":
          var responseReceived = false
          var asciiStatus = ""
          let observer = DistributedNotificationCenter.default().addObserver(
            forName: .init("SquirrelEnhancedDevASCIIModeResponse"),
            object: nil,
            queue: .main
          ) { notification in
            if let status = notification.object as? String {
              asciiStatus = status
              responseReceived = true
            }
          }
          DistributedNotificationCenter.default().postNotificationName(.init("SquirrelEnhancedDevGetASCIIModeNotification"), object: nil, userInfo: nil, deliverImmediately: true)
          let timeout = Date().addingTimeInterval(2.0)
          while !responseReceived && Date() < timeout {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
          }
          DistributedNotificationCenter.default().removeObserver(observer)
          if responseReceived {
            print(asciiStatus)
          } else {
            print("nascii")
          }
          return true
        case "--help":
          print(helpDoc)
          return true
        default:
          break
        }
      }
      return false
    }
    if handled {
      return
    }

    autoreleasepool {
      let main = Bundle.main
      let connectionName = main.object(forInfoDictionaryKey: "InputMethodConnectionName") as! String
      _ = IMKServer(name: connectionName, bundleIdentifier: main.bundleIdentifier!)
      let app = NSApplication.shared
      let delegate = SquirrelApplicationDelegate()
      app.delegate = delegate
      app.setActivationPolicy(.accessory)

      // OpenCC uses relative dictionary paths from SharedSupport.
      FileManager.default.changeCurrentDirectoryPath(main.sharedSupportPath!)

      if NSApp.squirrelAppDelegate.problematicLaunchDetected() {
        print("Problematic launch detected!")
        let args = ["Problematic launch detected! Squirrel may be suffering a crash due to improper configuration. Revert previous modifications to see if the problem recurs."]
        let task = Process()
        task.executableURL = "/usr/bin/say".withCString { dir in
          URL(fileURLWithFileSystemRepresentation: dir, isDirectory: false, relativeTo: nil)
        }
        task.arguments = args
        try? task.run()
      } else {
        NSApp.squirrelAppDelegate.setupRime()
        NSApp.squirrelAppDelegate.startRime(fullCheck: false)
        NSApp.squirrelAppDelegate.loadSettings()
        print("Squirrel reporting!")
      }

      if CommandLine.arguments.contains("--settings") {
        DispatchQueue.main.async { EnhancementBridge.shared.openSettings() }
      }

      app.run()
      print("Squirrel is quitting...")
      rimeAPI.finalize()
    }
    return
  }

  static let helpDoc = """
Supported arguments:
Perform actions:
  --quit                     quit all Squirrel process
  --reload                   deploy
  --settings                 open enhanced input settings
  --sync                     sync user data
  --build                    build all schemas in current directory
  --ascii                    turn on ASCII mode
  --nascii                   turn off ASCII mode
  --getascii                 get current ASCII mode status
Install Squirrel:
  --install, --register-input-source    register input source
  --enable-input-source [source id...]  input source list optional
  --disable-input-source [source id...] input source list optional
  --select-input-source [source id]     input source optional
"""
}
