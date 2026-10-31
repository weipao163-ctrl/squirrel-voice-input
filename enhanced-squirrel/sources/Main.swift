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
    let action = LaunchAdmission.action(arguments: Array(CommandLine.arguments.dropFirst()))
    guard action != .rejected else {
      fputs("未知命令或参数无效；未启动输入法服务。请使用 --help 查看支持的命令。\n", stderr)
      exit(EX_USAGE)
    }
    func hasInstalledServiceOwner() -> Bool {
      NSRunningApplication.runningApplications(withBundleIdentifier: LaunchAdmission.bundleIdentifier)
        .contains { application in
          application.processIdentifier != getpid() && application.bundleURL.map {
            LaunchAdmission.isInstalledBundle($0, home: LaunchAdmission.homeDirectory)
          } == true
        }
    }

    let handled = autoreleasepool {
      let installer = SquirrelInstaller()
      let args = CommandLine.arguments
      if action == .maintenance || action == .settings {
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
        case "--voice-target-check", "--candidate-position-stats", "--candidate-position-check":
          let candidateStats = args[1] != "--voice-target-check"
          let responseName = candidateStats ? "SquirrelEnhancedDevCandidatePositionResponse" : "SquirrelEnhancedDevVoiceTargetCheckResponse"
          let requestName = candidateStats ? "SquirrelEnhancedDevCandidatePositionNotification" : "SquirrelEnhancedDevCheckVoiceTargetNotification"
          let request=UUID().uuidString
          var response:String?
          let center=DistributedNotificationCenter.default()
          let token=center.addObserver(forName:.init(responseName),object:request,queue:.main) { notice in
            if let value=notice.userInfo?["report"] as? String,value.utf8.count <= 4096 { response=value }
          }
          defer { center.removeObserver(token) }
          DistributedNotificationCenter.default().postNotificationName(
            .init(requestName),object:request,userInfo:candidateStats ? ["inspect":args[1] == "--candidate-position-check"] : nil,deliverImmediately:true)
          let deadline=Date(timeIntervalSinceNow:3)
          while response == nil && Date() < deadline { RunLoop.main.run(until:Date(timeIntervalSinceNow:0.03)) }
          print(response ?? "当前输入法没有返回位置检查结果；未采音、未发送识别任务。")
          return true
        case "--quit":
          let bundleId = Bundle.main.bundleIdentifier!
          let updatePath=args.count == 4 && args[2] == "--installed-app-path" ? args[3] : nil
          if let path=updatePath {
            guard path.hasPrefix("/"),!path.contains("\n") else { exit(EXIT_FAILURE) }
            guard installer.selectKeyboardLayoutForUpdate() == noErr else {
              print("无法暂时切换到键盘输入源；原应用与输入内容保留，未开始替换。")
              exit(EXIT_FAILURE)
            }
          }
          let identities=updatePath == nil ? [bundleId] : [bundleId,"org.rime.SquirrelEnhanced.Development"]
          let runningSquirrels=identities.flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier:$0)
          }.filter { application in
            guard application.processIdentifier != getpid() else { return false }
            guard let path=updatePath else { return true }
            return application.bundleURL?.standardizedFileURL == URL(fileURLWithPath:path).standardizedFileURL
          }
          let helperURLs=Set(runningSquirrels.compactMap { $0.bundleURL?.appendingPathComponent("Contents/Resources/SquirrelVoiceHelper.app").standardizedFileURL })
            .union(updatePath.map { [URL(fileURLWithPath:$0).appendingPathComponent("Contents/Resources/SquirrelVoiceHelper.app").standardizedFileURL] } ?? [])
          func runningHelpers() -> [NSRunningApplication] {
            NSRunningApplication.runningApplications(withBundleIdentifier:"org.rime.SquirrelEnhanced.Development.VoiceHelper")
              .filter { $0.bundleURL.map{helperURLs.contains($0.standardizedFileURL)} == true }
          }
          // Ask the Helper to quit FIRST, while its owner is still alive. Its
          // existing unsaved-edit dialog remains authoritative; never turn a
          // maintenance quit into forced owner-loss cleanup/discard.
          runningHelpers().forEach { _ = $0.terminate() }
          let deadline=Date(timeIntervalSinceNow:updatePath == nil ? 8 : 60)
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
          if hasInstalledServiceOwner() {
            DistributedNotificationCenter.default().postNotificationName(.init("SquirrelEnhancedDevOpenSettingsNotification"), object: nil, userInfo: nil, deliverImmediately: true)
            return true
          }
          return false
        case "--input-source-status":
          do {
            let data = try JSONSerialization.data(withJSONObject: installer.inputSourceStatus(), options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
          } catch {
            fputs("输入源状态无法编码为 JSON。\n", stderr)
            exit(EXIT_FAILURE)
          }
          return true
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
          // Older installed versions do not own the lease yet. Refuse their
          // canonical running process too; never build over its live user data.
          guard !hasInstalledServiceOwner() else {
            fputs("输入法正在运行；未执行离线部署。请使用 --reload 请求现用实例部署。\n", stderr)
            exit(EX_TEMPFAIL)
          }
          do {
            try LaunchAdmission.withEngineLease(home: LaunchAdmission.homeDirectory) {
              let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
              do { try prepareUserDirectory() } catch { print("Cannot prepare isolated Rime directory: \(error.localizedDescription)"); exit(EXIT_FAILURE) }
              SquirrelApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_update", comment: ""))
              var builderTraits = RimeTraits.rimeStructInit()
              builderTraits.setCString(Bundle.main.sharedSupportPath!, to: \.shared_data_dir)
              builderTraits.setCString(Self.userDir.path, to: \.user_data_dir)
              builderTraits.setCString(Self.logDir.path, to: \.log_dir)
              builderTraits.setCString("rime.squirrel-builder", to: \.app_name)
              rimeAPI.setup(&builderTraits)
              rimeAPI.deployer_initialize(nil)
              defer { rimeAPI.finalize() }
              _ = rimeAPI.deploy()
            }
          } catch {
            fputs("无法取得输入引擎独占锁；未执行离线部署。\n", stderr)
            exit(EX_TEMPFAIL)
          }
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
          // Keep this fail-closed even if the admission whitelist changes.
          fputs("命令分发不匹配；未启动输入法服务。\n", stderr)
          exit(EX_USAGE)
        }
      }
      return false
    }
    if handled {
      return
    }

    autoreleasepool {
      let main = Bundle.main
      do {
        try LaunchAdmission.runService(bundle: main.bundleURL, home: LaunchAdmission.homeDirectory,
          identifier: main.bundleIdentifier,
          connectionName: main.object(forInfoDictionaryKey: "InputMethodConnectionName") as? String,
          makeServer: { IMKServer(name: $0, bundleIdentifier: $1) }) { _ in
          let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
          let app = NSApplication.shared
          let delegate = SquirrelApplicationDelegate()
          app.delegate = delegate
          app.setActivationPolicy(.accessory)

          // OpenCC uses relative dictionary paths from SharedSupport.
          FileManager.default.changeCurrentDirectoryPath(main.sharedSupportPath!)

          // A recent normal launch is not evidence of a crash. Admission already
          // excludes duplicate owners; every admitted service initializes Rime.
          NSApp.squirrelAppDelegate.setupRime()
          NSApp.squirrelAppDelegate.startRime(fullCheck: false)
          NSApp.squirrelAppDelegate.loadSettings()
          print("Squirrel reporting!")

          if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { EnhancementBridge.shared.openSettings() }
          }

          withExtendedLifetime(delegate) { app.run() }
          print("Squirrel is quitting...")
          rimeAPI.finalize()
        }
      } catch LaunchAdmission.Failure.wrongLocation {
        fputs("拒绝从非正式安装位置启动输入法服务；请使用已安装的鼠须管增强版。\n", stderr)
        exit(EX_CONFIG)
      } catch LaunchAdmission.Failure.wrongIdentity {
        fputs("输入法标识或连接名无效；未启动服务。\n", stderr)
        exit(EX_CONFIG)
      } catch LaunchAdmission.Failure.lockUnavailable {
        fputs("输入法服务已在运行或无法取得独占锁；未创建重复服务。\n", stderr)
        exit(EX_TEMPFAIL)
      } catch {
        fputs("无法创建输入法服务器；未初始化输入引擎。\n", stderr)
        exit(EX_UNAVAILABLE)
      }
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
  --input-source-status                read input-source registration/enablement as JSON
  --install, --register-input-source    register input source
  --enable-input-source [source id...]  input source list optional
  --disable-input-source [source id...] input source list optional
  --select-input-source [source id]     input source optional
"""
}
