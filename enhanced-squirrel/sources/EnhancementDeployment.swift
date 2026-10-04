import AppKit
import InputMethodKit
import ApplicationServices
import EnhancementCore
import EnhancementIPC
import Darwin

final class EnhancementDeployment {
  static let shared = EnhancementDeployment()
  let controllers = NSHashTable<SquirrelInputController>.weakObjects()
  var letterRepeats = LetterRepeatGuard() // A physical key cycle spans IMK clients/schemas.
  private let rimeAPI = rime_get_api_stdbool().pointee
  private var deploymentInFlight = false
  private var letterProbeProcess: Process?
  private var letterProbeCancellation: String?
  func deliverVoice(_ value:VoiceUpdate) {
    let owners = controllers.allObjects.filter { $0.enhancementOwnsVoice(value.identity) }
    for owner in owners { owner.voiceReceived(value) }
    if owners.isEmpty && value.phase != .cancelled {
      var draft = value
      if value.phase == .ready { draft.phase = .review; draft.message = "原输入会话已结束；只保留草稿，没有自动插入。" }
      EnhancementPreview.shared.update(draft)
    }
  }
  func perform(action:String,schema:String) {
    if action == "letter-test-cancel" { cancelLetterTest(); return }
    if action == "schemas" { sendSchemas(); return }
    if action == "focus-status" {
      // Read-only status is checked by the actual input-method process, not the
      // Helper (the two processes have different TCC responsibilities).
      EnhancementBridge.shared.reply(AXIsProcessTrusted() ? "focus-status:allowed" : "focus-status:required")
      return
    }
    if action == "authorize-focus" {
      let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      let trusted = AXIsProcessTrustedWithOptions([key:true] as CFDictionary)
      EnhancementBridge.shared.reply(trusted ? "输入法焦点检测已授权。" : "请在系统设置 → 辅助功能授予本开发输入法权限；授权完成不会自动开麦。")
      EnhancementBridge.shared.reply(trusted ? "focus-status:allowed" : "focus-status:required")
      return
    }
    guard controllers.allObjects.allSatisfy({ !$0.enhancementIsBusy() }) else {
      EnhancementBridge.shared.reply("当前有拼音组合或语音任务；未部署、未清空，请完成或主动取消后重试。"); return
    }
    guard !deploymentInFlight && letterProbeProcess == nil && !rimeAPI.is_maintenance_mode() else {
      EnhancementBridge.shared.reply("正在部署或等待部署校验；未再次修改配置，请完成后重试。"); return
    }
    if action == "letter-test" { enhancementLetterProbe(schema:schema); return }
    guard let profile = EnhancementBridge.shared.settings.letters[schema] else { EnhancementBridge.shared.reply("请先保存此方案设置。"); return }
    do {
      let plan = try EnhancementPatch.apply(schema:schema,profile:profile,directory:SquirrelApp.userDir,replaceLegacy:action == "deploy-migrate")
      for controller in controllers.allObjects { controller.enhancementWillDeploy() }
      deploymentInFlight = true
      NSApp.squirrelAppDelegate.deploy()
      // Maintenance runs asynchronously. Probe after it finishes, not immediately.
      var checks = 0
      Timer.scheduledTimer(withTimeInterval:0.2,repeats:true) { [weak self] timer in
        guard let self else { timer.invalidate(); return }; checks += 1
        if self.rimeAPI.is_maintenance_mode() && checks < 300 { return }
        timer.invalidate()
        self.deploymentInFlight = false
        if self.rimeAPI.is_maintenance_mode() { EnhancementBridge.shared.reply("部署等待超时；已备份源配置，未宣称部署成功。"); return }
        if let expected = plan.expectedProcessors {
          do {
            guard try EnhancementPatch.readProcessors(schema:schema) == expected else {
              EnhancementBridge.shared.reply("部署后的真实处理器顺序与迁移计划不同；未报告应用成功，请保留备份并检查。")
              return
            }
          } catch { EnhancementBridge.shared.reply("部署后处理器校验失败：\(error.localizedDescription)"); return }
        }
        self.enhancementLetterProbe(schema:schema)
      }
    } catch {
      EnhancementBridge.shared.reply("应用未完整成功；校验失败不写源补丁，事务或后续失败可能保留源文件/恢复日志。未宣称已生效或已回滚：\(error.localizedDescription)")
    }
  }
  private func sendSchemas() {
    guard !rimeAPI.is_maintenance_mode() else { EnhancementBridge.shared.reply("正在部署；维护结束后再刷新真实方案。"); return }
    var list = RimeSchemaList()
    guard rimeAPI.get_schema_list(&list) else { EnhancementBridge.shared.reply("实际 Rime 方案列表读取失败；没有用文件名冒充启用方案。"); return }
    defer { rimeAPI.free_schema_list(&list) }
    guard list.size <= 512 else { EnhancementBridge.shared.reply("方案数量异常；未载入。"); return }
    var ids:[String] = []
    if let items = list.list {
      for index in 0..<Int(list.size) {
        if let id = items[index].schema_id { ids.append(String(cString:id)) }
      }
    }
    let current = (EnhancementBridge.shared.input as? SquirrelInputController)?.enhancementCurrentSchema() ?? ""
    if let data = try? Wire.encode(SchemaCatalog(ids:ids,current:current)) { EnhancementBridge.shared.helper?.schemaCatalog(data) }
  }
  private func enhancementLetterProbe(schema:String) {
    guard let profile = EnhancementBridge.shared.settings.letters[schema] else {
      EnhancementBridge.shared.reply("请先保存选中方案的设置，再运行自测。"); return
    }
    do {
      try profile.validate()
      if profile.enabled {
        let processors = try EnhancementPatch.readProcessors(schema:schema)
        guard let first = processors.first, ["lua_processor@*letter_selection","lua_processor@letter_selection"].contains(first) else {
          throw SettingsError.invalid("选中方案的已部署首位处理器不匹配；请先安全部署，没有把固定词库测试当作当前方案已生效。")
        }
        var config = RimeConfig()
        guard rimeAPI.schema_open(schema,&config) else { throw SettingsError.invalid("无法只读打开已部署方案。") }
        defer { _ = rimeAPI.config_close(&config) }
        var size:Int32 = 0
        guard rimeAPI.config_get_int(&config,"menu/page_size",&size), Int(size) == profile.pageSize else {
          throw SettingsError.invalid("已部署页大小与保存设置不一致；未报告成功，请安全部署后再测试。")
        }
      }
      // Never type/select in a user-schema session: even a broken gate may
      // commit and learn on the first Space. Query deployed metadata only.
      launchIsolatedLetterTests(profile:profile,revision:EnhancementBridge.shared.settings.revision)
    } catch { EnhancementBridge.shared.reply(error.localizedDescription) }
  }
  func cancelLetterTest() {
    guard let process = letterProbeProcess else { return }
    letterProbeCancellation = "字母自测已取消；没有向应用插字，也没有使用个人词库/学习记录。"
    if process.isRunning { process.terminate() }
  }
  private func launchIsolatedLetterTests(profile:LetterProfile,revision:UInt64) {
    // No in-process global Rime reinitialization and no candidate selections in
    // the user's engine. The child owns a NEW fixture directory and fixed dict.
    guard let resources = Bundle.main.resourceURL else { EnhancementBridge.shared.reply("缺少测试资源；未宣称通过。"); return }
    let worker = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SquirrelLetterProbe")
    let library = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/librime.1.dylib")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("squirrel-letter-probe-"+UUID().uuidString,isDirectory:true)
    var handles:[FileHandle] = []
    do {
      try profile.validate()
      guard FileManager.default.isExecutableFile(atPath:worker.path), FileManager.default.fileExists(atPath:library.path) else {
        throw SettingsError.invalid("缺少已构建的原生自测程序或 librime；请用 build-enhanced.sh 完整构建，不以缺能力报告通过。")
      }
      try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
      let outputURL=root.appendingPathComponent("report.json"),errorURL=root.appendingPathComponent("stderr.txt")
      guard FileManager.default.createFile(atPath:outputURL.path,contents:nil,attributes:[.posixPermissions:0o600]),
            FileManager.default.createFile(atPath:errorURL.path,contents:nil,attributes:[.posixPermissions:0o600]) else {
        throw SettingsError.invalid("无法建立私有自测输出文件。")
      }
      let output=try FileHandle(forWritingTo:outputURL); handles.append(output)
      let errors=try FileHandle(forWritingTo:errorURL); handles.append(errors)
      let process=Process(); process.executableURL=worker
      process.arguments=[library.path,resources.appendingPathComponent("LetterProbe").path,
                         root.appendingPathComponent("runtime").path,profile.keys,profile.hideCandidates ? "true" : "false"]
      process.currentDirectoryURL=root; process.standardInput=FileHandle.nullDevice
      process.standardOutput=output; process.standardError=errors
      // File-backed bounded output avoids pipe-buffer deadlock; no waitUntilExit
      // or synchronous read while running on the normal keyboard/UI path.
      try process.run(); letterProbeProcess=process; letterProbeCancellation=nil
      let started=ProcessInfo.processInfo.systemUptime
      var stoppingAt:TimeInterval?
      Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] timer in
        guard let self else { if process.isRunning { process.terminate() }; timer.invalidate(); return }
        let now=ProcessInfo.processInfo.systemUptime
        if process.isRunning {
          let outputSize=(try? FileManager.default.attributesOfItem(atPath:outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
          if now-started>60 || outputSize>256*1024 {
            self.letterProbeCancellation="字母自测超时或输出超限；已停止测试，未报告成功。"
          }
          if self.letterProbeCancellation != nil {
            if let stoppingAt, now-stoppingAt>2 { _ = Darwin.kill(process.processIdentifier,SIGKILL) }
            else if stoppingAt == nil { stoppingAt=now; process.terminate() }
          }
          return
        }
        timer.invalidate(); try? output.close(); try? errors.close()
        self.letterProbeProcess=nil
        var message=self.letterProbeCancellation
        self.letterProbeCancellation=nil
        if message == nil {
          do {
            guard process.terminationReason == .exit && process.terminationStatus == 0 else { throw SettingsError.invalid("原生自测进程异常或用例失败；未报告通过。") }
            let size=(try FileManager.default.attributesOfItem(atPath:outputURL.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size>0 && size<=256*1024 else { throw SettingsError.invalid("字母自测报告为空或超限。") }
            let report=try LetterProbeReport.decode(Data(contentsOf:outputURL))
            message=(profile.enabled ? "选中方案的已部署首位处理器和页大小只读校验通过。\n" : "当前保存的功能开关为关闭；以下验证固定词库中的关闭/恢复路径，不声称选中方案已完成关闭部署。\n")+(try report.validatedSummary(expectedKeys:profile.keys,expectedHide:profile.hideCandidates))
            if EnhancementBridge.shared.settings.revision != revision { message="测试使用保存版本 \(revision)，当前版本已变化；不是新配置通过证据。\n"+(message ?? "") }
          } catch { message=error.localizedDescription }
        }
        do { try FileManager.default.removeItem(at:root) }
        catch { message=(message ?? "")+"\n固定词库测试临时目录未能清理：\(root.path)；没有删除用户数据。" }
        EnhancementBridge.shared.reply(message ?? "没有完整自测结果；未报告通过。")
      }
      EnhancementBridge.shared.reply("已只读核对选中方案；独立固定词库的 14 项真实 Rime 自测正在运行，不阻塞拼音，也不使用个人学习库。")
    } catch {
      for handle in handles { try? handle.close() }
      // root was selected here, never an IPC/user-supplied deletion path.
      if FileManager.default.fileExists(atPath:root.path) { try? FileManager.default.removeItem(at:root) }
      EnhancementBridge.shared.reply("字母自测未完成：\(error.localizedDescription)")
    }
  }
}
