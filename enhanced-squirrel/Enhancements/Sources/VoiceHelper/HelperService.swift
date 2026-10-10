import AppKit
import AVFoundation
import EnhancementCore
import EnhancementIPC
import EnhancementUI
import Combine
import CryptoKit

final class HelperModel: NSObject, ObservableObject, HelperCommands {
  @Published var draft = Settings()
  @Published var status = "未就绪：默认关闭语音与字母增强。"
  @Published var newKey = ""
  @Published var newDoubaoKey = ""
  @Published private(set) var connectionStatus="填写地域、Workspace ID 和 API Key 后自动校验连接。"
  @Published private(set) var checkingConnection=false
  @Published var connectionError:String?
  @Published private(set) var inputMethodConnected=false
  @Published private(set) var productionTargetStatus="尚无普通应用语音启动检查记录。"
  @Published private(set) var focusPermissionStatus="输入法焦点检测权限尚未确认。"
  @Published var showKey = false
  @Published var devices: [InputDevice] = []
  private var deviceInventoryObserver:InputDeviceInventoryObserver?
  let fonts = NSFontManager.shared.availableFonts.sorted()
  @Published var schemas: [String] = []
  @Published var selectedSchema = ""
  @Published var schemaSource = "源文件列表（未连接真实 Rime）"
  @Published private(set) var preview = ""
  @Published private(set) var previewIsComplete=false
  @Published var voiceTestText=""
  @Published private(set) var voiceTestHint="点击测试框，再按住配置的语音热键说话；松开后整段输入。"
  lazy var testEditorController=VoiceTestEditorController(model:self)
  private var testInsertion:VoiceTestInsertion?
  private var insertingTestResult=false
  private let testPreviewPanel=EnhancementPreview(title:"语音输入测试 · 实时预览")
  private var testPreviewAtCaret=false
  private var testDrafts=VoiceDraftStore()
  private var replacedTestDraft=false
  var canCopyTestDraft:Bool { testDrafts.canCopy }
  @Published var level = 0.0
  @Published private(set) var localPCMSamples=0
  private var localMicrophoneTimer:Timer?
  @Published var recordingKeys = false
  @Published var testingKeys = false
  @Published var downCount = 0
  @Published var upCount = 0
  @Published var needsRecovery = false
  @Published var recoveryAvailable = false
  @Published var waitingKeyRelease = false
  @Published private(set) var microphoneAuthorization:AVAuthorizationStatus = .notDetermined
  @Published private(set) var requestingMicrophone = false
  private let microphonePermission:MicrophonePermissionClient
  @Published var applicationState = "输入法尚未确认配置；文件保存与运行应用分别报告。"
  @Published private(set) var diagnostic:VoiceDiagnosticSnapshot?
  private var diagnosticStore=VoiceDiagnosticStore()
  private var productionAdmission=VoiceRequestAdmission()
  let store: SettingsStore
  let credentials = CredentialStore()
  private var saved = Settings()
  private var cachedKey: String?
  private var cachedDoubaoKey: String?
  private var doubaoKeyReadID=UUID()
  private var doubaoKeyReadPending=false
  private var doubaoKeyReadTimer:Timer?
  private var draftKey:String? { draft.voice.model.isDoubao ? (newDoubaoKey.isEmpty ? cachedDoubaoKey : newDoubaoKey) : (newKey.isEmpty ? cachedKey : newKey) }
  private var productionKey:String? { saved.voice.model.isDoubao ? cachedDoubaoKey : cachedKey }
  private var activeKeyReadPending:Bool { draft.voice.model.isDoubao ? doubaoKeyReadPending : keyReadPending }
  private let credentialLoader:(String)throws->String
  private let credentialReadTimeout:TimeInterval
  private let credentialQueue=DispatchQueue(label:"org.rime.voice.credential-read")
  private var keyReadID=UUID()
  private var keyReadPending=false
  private var keyReadTimer:Timer?
  private var active:VoiceSession?
  private let sessionFactory:VoiceSessionFactory
  private var activeID: VoiceIdentity?
  private var discardPreviewSession: VoiceIdentity?
  private var testSession = false
  private var testAudio: AudioCapture?
  private var stoppingLocalAudio = false
  private var connectionProbe: ConnectionProbeTask?
  private let probeFactory:ConnectionProbeFactory
  private var probeID:UUID?
  private var lastProbedFingerprint:String?
  private var connectionEdits:AnyCancellable?
  private var keys = PhysicalKeys()
  private var recorded: Set<UInt16> = []
  private var held: Set<UInt16> = []
  private var monitor: Any?
  private var testLease: Timer?
  private var testHoldOwner = GUITestHoldOwner()
  private var windowController: NSWindowController?
  var connection: AuthenticatedConnection? {
    didSet {
      inputMethodConnected = connection != nil
      if inputMethodConnected { refreshFocusPermission() }
      else { focusPermissionStatus="输入法尚未连接，无法确认焦点检测权限。" }
    }
  }
  let rimeDirectory: URL

  init(baseDirectory:URL? = nil,microphonePermission:MicrophonePermissionClient = .system,
       automaticConnectionCheck:Bool = true,
       credentialReadTimeout:TimeInterval = 5,
       credentialLoader:@escaping(String)throws->String = { try CredentialStore().get($0) },
       probeFactory:@escaping ConnectionProbeFactory = { try ConnectionProbe(settings:$0,key:$1,result:$2) },
       sessionFactory:@escaping VoiceSessionFactory = {
         StreamingSession(identity:$0,settings:$1,test:$2,revision:$3,pressUptime:$4,update:$5)
       }) {
    self.microphonePermission=microphonePermission
    self.probeFactory=probeFactory
    self.sessionFactory=sessionFactory
    self.credentialLoader=credentialLoader
    self.credentialReadTimeout=credentialReadTimeout
    let base = baseDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SquirrelEnhancedDev")
    store = SettingsStore(url: base.appendingPathComponent("settings.json"))
    rimeDirectory = base.appendingPathComponent("Rime")
    super.init()
    do { saved = try store.load(); draft = saved; refreshKey(); refreshDoubaoKey() }
    catch {
      // Preserve the failed primary file. A known-valid fallback is read-only,
      // voice-off, and cannot be saved over the primary until explicit recovery.
      needsRecovery = (try? store.load()) == nil
      if needsRecovery, let fallback = store.lastValidReadOnly() {
        saved = fallback; draft = fallback; recoveryAvailable = true
      }
      cachedKey = nil
      status = "配置/凭据读取失败；语音未就绪，原文件未覆盖。\n\(error.localizedDescription)"
    }
    refreshDevices(); refreshSchemas(); refreshMicrophoneAuthorization()
    deviceInventoryObserver=InputDeviceInventoryObserver { [weak self] in self?.refreshDevices() }
    NotificationCenter.default.addObserver(self, selector: #selector(deactivated), name: NSApplication.didResignActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(activated), name: NSApplication.didBecomeActiveNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(testWindowResigned), name: NSWindow.didResignKeyNotification, object:nil)
    NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(sleep), name: NSWorkspace.willSleepNotification, object: nil)
    if automaticConnectionCheck {
      connectionEdits=Publishers.CombineLatest3($draft,$newKey,$newDoubaoKey)
        .debounce(for:.seconds(1),scheduler:RunLoop.main)
        .sink { [weak self] _ in self?.checkConnectionAutomatically() }
    }
  }
  private func refreshKey() {
    keyReadTimer?.invalidate(); keyReadID=UUID(); let id=keyReadID; cachedKey=nil; keyReadPending=false
    guard let ref=saved.voice.credentialReference else { return }
    keyReadPending=true
    connectionStatus="正在读取已保存 Key；设置页可继续操作。"
    keyReadTimer=Timer.scheduledTimer(withTimeInterval:credentialReadTimeout,repeats:false) { [weak self] _ in
      guard let self, self.keyReadID == id, self.keyReadPending else { return }
      self.keyReadPending=false; self.keyReadTimer=nil
      // Permission may be granted after the UI deadline. A matching late read
      // remains valid; replacing/deleting the credential still revokes its ID.
      guard !self.draft.voice.model.isDoubao, self.newKey.isEmpty, self.cachedKey == nil else { return }
      self.connectionStatus="读取已保存 Key 超时。请处理系统钥匙串提示，或重新填写 API Key 并保存；原密钥与配置未删除。"
      self.connectionError=self.connectionStatus
    }
    let loader=credentialLoader
    credentialQueue.async { [weak self] in
      let result=Result { try loader(ref) }
      DispatchQueue.main.async {
        guard let self, self.keyReadID == id, self.saved.voice.credentialReference == ref else { return }
        self.keyReadTimer?.invalidate(); self.keyReadTimer=nil; self.keyReadPending=false
        switch result {
        case .success(let key):
          self.cachedKey=key
          if !self.draft.voice.model.isDoubao && self.newKey.isEmpty { self.connectionError=nil }
          if self.connectionEdits != nil { self.checkConnectionAutomatically() }
        case .failure:
          guard !self.draft.voice.model.isDoubao, self.newKey.isEmpty else { return }
          self.connectionStatus="无法读取已保存 Key。请处理系统钥匙串授权后点击“重新校验”；也可重新填写 API Key 并保存。词库和其他设置已保留。"
          self.status=self.connectionStatus; self.connectionError=self.connectionStatus
        }
      }
    }
  }
  private func refreshDoubaoKey() {
    doubaoKeyReadTimer?.invalidate(); doubaoKeyReadID=UUID(); let id=doubaoKeyReadID; cachedDoubaoKey=nil; doubaoKeyReadPending=false
    guard let ref=saved.voice.doubao.credentialReference else { return }
    doubaoKeyReadPending=true
    connectionStatus="正在读取已保存 Key；设置页可继续操作。"
    doubaoKeyReadTimer=Timer.scheduledTimer(withTimeInterval:credentialReadTimeout,repeats:false) { [weak self] _ in
      guard let self, self.doubaoKeyReadID == id, self.doubaoKeyReadPending else { return }
      self.doubaoKeyReadPending=false; self.doubaoKeyReadTimer=nil
      // Permission may be granted after the UI deadline. A matching late read
      // remains valid; replacing/deleting the credential still revokes its ID.
      guard self.draft.voice.model.isDoubao, self.newDoubaoKey.isEmpty, self.cachedDoubaoKey == nil else { return }
      self.connectionStatus="读取已保存 Key 超时。请处理系统钥匙串提示，或重新填写 API Key 并保存；原密钥与配置未删除。"
      self.connectionError=self.connectionStatus
    }
    let loader=credentialLoader
    credentialQueue.async { [weak self] in
      let result=Result { try loader(ref) }
      DispatchQueue.main.async {
        guard let self, self.doubaoKeyReadID == id, self.saved.voice.doubao.credentialReference == ref else { return }
        self.doubaoKeyReadTimer?.invalidate(); self.doubaoKeyReadTimer=nil; self.doubaoKeyReadPending=false
        switch result {
        case .success(let key):
          self.cachedDoubaoKey=key
          if self.draft.voice.model.isDoubao && self.newDoubaoKey.isEmpty { self.connectionError=nil }
          if self.connectionEdits != nil { self.checkConnectionAutomatically() }
        case .failure:
          guard self.draft.voice.model.isDoubao, self.newDoubaoKey.isEmpty else { return }
          self.connectionStatus="无法读取已保存 Key。请处理系统钥匙串授权后点击“重新校验”；也可重新填写 API Key 并保存。词库和其他设置已保留。"
          self.status=self.connectionStatus; self.connectionError=self.connectionStatus
        }
      }
    }
  }
  func refreshDevices() { devices = InputDevice.available() }
  var productionMicrophoneStatus:String {
    let name:String
    if let uid=saved.voice.deviceUID {
      name=devices.first(where:{$0.id == uid})?.name ?? "指定设备当前不可用（不会自动换用其他设备）"
    } else { name="系统默认设备" }
    let pending=draft.voice.deviceUID != saved.voice.deviceUID ? "；当前表单的麦克风修改尚未保存" : ""
    return "普通应用使用已保存的麦克风：\(name)\(pending)。"
  }
  func refreshFocusPermission() {
    guard let data=try? JSONSerialization.data(withJSONObject:["action":"focus-status"]) else { return }
    callbacks?.deploymentRequested(data)
  }
  func refreshSchemas() {
    if let callbacks, let data = try? JSONSerialization.data(withJSONObject:["action":"schemas"]) {
      callbacks.deploymentRequested(data); return
    }
    schemas = ((try? FileManager.default.contentsOfDirectory(atPath: rimeDirectory.path)) ?? [])
      .filter { $0.hasSuffix(".schema.yaml") }.map { String($0.dropLast(12)) }.sorted()
    if selectedSchema.isEmpty { selectedSchema = schemas.first ?? "" }
  }
  func validate() {
    do { try draft.validate(); status = "本地配置校验通过；没有采音、没有联网，不代表云识别通过。" }
    catch { status = error.localizedDescription }
  }
  func testConnection() {
    checkConnection(force:true)
  }
  func checkConnectionAutomatically() { checkConnection(force:false) }
  private func connectionFingerprint(_ settings:VoiceSettings,_ key:String) -> String {
    SHA256.hash(data:Data("\(settings.model.isDoubao)\n\(settings.model.isDoubao ? settings.doubao.resource.rawValue + settings.doubao.authentication.rawValue + settings.doubao.appID : (settings.region?.rawValue ?? "") + "\n" + settings.workspace)\n\(key)".utf8)).map { String(format:"%02x",$0) }.joined()
  }
  private func cancelConnectionCheck() {
    probeID=nil; connectionProbe?.cancel(); connectionProbe=nil; checkingConnection=false
  }
  private func checkConnection(force:Bool) {
    guard active == nil, testAudio == nil else { return }
    let settings=draft.voice
    let candidateKey=draftKey
    guard (settings.model.isDoubao || (settings.region != nil && !settings.workspace.isEmpty)),
          let key=candidateKey, !key.isEmpty else {
      cancelConnectionCheck(); lastProbedFingerprint=nil
      if force, candidateKey == nil, settings.activeCredentialReference != nil, !activeKeyReadPending { if settings.model.isDoubao { refreshDoubaoKey() } else { refreshKey() } }
      if activeKeyReadPending { connectionStatus="正在读取已保存 Key；也可直接填写新 Key 进行校验。" }
      else if settings.activeCredentialReference != nil && candidateKey == nil {
        connectionStatus="已保存的 Key 尚未能读取。请处理系统钥匙串提示，或重新填写 Key；填写后会自动校验。"
      } else { connectionStatus=settings.model.isDoubao ? "请填写豆包密钥并选择账户已开通的模型资源；填完后会自动校验。" : "请填写地域、Workspace ID 和 API Key；填完后会自动校验。" }
      if force && !activeKeyReadPending { connectionError=connectionStatus }; return
    }
    let fingerprint=connectionFingerprint(settings,key)
    guard force || fingerprint != lastProbedFingerprint else { return }
    cancelConnectionCheck(); connectionError=nil; lastProbedFingerprint=fingerprint
    do {
      try VoiceCredential.validate(key); _ = try settings.validatedConnectionEndpoint()
      let id=UUID(); probeID=id; checkingConnection=true
      connectionStatus="正在校验 API Key 与语音服务连接…（不采音）"
      let task = try probeFactory(settings,key) { [weak self] result in
        guard let self, self.probeID == id else { return }
        self.probeID=nil; self.connectionProbe=nil; self.checkingConnection=false
        // A response for an edited token/address never becomes current success.
        let currentKey=self.draftKey
        guard let currentKey, self.connectionFingerprint(self.draft.voice,currentKey) == fingerprint else { return }
        self.connectionStatus=result.message
        if !result.authenticationVerified { self.connectionError=result.message }
      }
      if probeID == id { connectionProbe=task } else { task.cancel() }
    } catch {
      cancelConnectionCheck(); connectionStatus=error.localizedDescription; connectionError=error.localizedDescription
    }
  }
  var hasUnsavedChanges:Bool { draft != saved || !newKey.isEmpty || !newDoubaoKey.isEmpty }
  var credentialDestinationChanged:Bool {
    saved.voice.credentialReference != nil &&
      (draft.voice.region != saved.voice.region || draft.voice.workspace != saved.voice.workspace)
  }
  var helperVersion:String {
    let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String
    let build=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String
    return "Helper \(version ?? "版本未提供") · build \(build ?? "未提供") · 配置版本 \(saved.revision)"
  }
  func clearDiagnostics() {
    diagnosticStore.clear(); diagnostic=nil; active?.clearDiagnostics()
    // No transcript/credential/settings side effect; queued current-session
    // diagnostic updates cannot repopulate a cleared record.
  }
  func discardTestDraft() {
    testDrafts.discard(); preview=""; previewIsComplete=false
    invalidateTestEditorTarget(); testPreviewPanel.clear()
    // Discarding text does not pretend to stop the held audio test. Its late
    // updates remain suppressed until a NEW accepted test identity begins.
  }
  // Used by window close and explicit application quit. Never silently saves.
  func confirmClosing(stoppingProduction:Bool = false) -> Bool {
    if stoppingProduction { stopAll(cancel:true) } else { stopSettingsActivity() }
    guard hasUnsavedChanges else { return true }
    let alert = NSAlert()
    alert.messageText = "设置有未保存修改"
    alert.informativeText = "保存、丢弃或返回继续编辑。新输入的 API Key 不会自动保存；当前测试已经停止。"
    alert.addButton(withTitle:"保存并关闭")
    alert.addButton(withTitle:"丢弃修改")
    alert.addButton(withTitle:"继续编辑")
    switch alert.runModal() {
    case .alertFirstButtonReturn: return save() && !hasUnsavedChanges
    case .alertSecondButtonReturn: revert(); return true
    default: return false
    }
  }
  @discardableResult func save() -> Bool {
    let enteredKey=newKey
    let enteredDoubaoKey=newDoubaoKey
    var next = draft; var newReference: String?
    var newDoubaoReference:String?
    var persisted = false
    let oldReference = saved.voice.credentialReference
    let oldDoubaoReference = saved.voice.doubao.credentialReference
    let destinationWarning = credentialDestinationChanged && newKey.isEmpty
    do {
      for profile in next.letters.values {
        guard NSFont(name:profile.appearance.fontFace,size:CGFloat(profile.appearance.fontPoint)) != nil else {
          throw SettingsError.invalid("所选字体在此 Mac 不可用；请选择已安装字体。")
        }
      }
      // New immutable credential reference -> atomic config -> publish -> retire old.
      if !newKey.isEmpty { newReference = try credentials.put(newKey); next.voice.credentialReference = newReference }
      if !newDoubaoKey.isEmpty {
        newDoubaoReference=try credentials.put(newDoubaoKey); next.voice.doubao.credentialReference=newDoubaoReference
      }
      next = try store.save(next)
      persisted = true
      let letterSchemas = Set(next.letters.keys).union(saved.letters.keys)
      let structuralLetters = letterSchemas.contains { schema in
        let before = saved.letters[schema]
        let profile = next.letters[schema]
        return before?.enabled == true && profile?.enabled != true ||
          profile?.enabled == true && (before?.enabled != true || before?.pageSize != profile?.pageSize)
      }
      let disable = saved.voice.enabled && !next.voice.enabled
      saved = next; draft = next; newKey = ""; newDoubaoKey = ""
      if disable { stopAll(cancel: true) }
      if let data = try? Wire.encode(next) { callbacks?.settingsChanged(data) }
      applicationState = callbacks == nil ? "配置已持久化；输入法 IPC 未连接，尚未确认应用。" : "版本 \(next.revision) 已持久化；等待输入法运行端确认，结构配置仍需部署。"
      if newReference != nil {
        keyReadTimer?.invalidate(); keyReadTimer=nil; keyReadPending=false
        keyReadID=UUID(); cachedKey=enteredKey
      }
      else if cachedKey == nil { refreshKey() }
      if newDoubaoReference != nil {
        doubaoKeyReadTimer?.invalidate(); doubaoKeyReadTimer=nil; doubaoKeyReadPending=false
        doubaoKeyReadID=UUID(); cachedDoubaoKey=enteredDoubaoKey
      } else if cachedDoubaoKey == nil { refreshDoubaoKey() }
      status = structuralLetters ? "已保存。首次启用、页大小变化或关闭后还原原方案结构需确认部署；尚未宣称部署完成，现有组合没有提交/清空。" : "已保存；字体、排列、配色及字母键从安全组合生效。语音绑定、API、设备、预览和超时从下次完整按键周期生效。运行端确认见下方独立状态。"
      if destinationWarning { status += "\n地域/工作空间已变化，将自动校验保留的 Key 是否能连接当前服务。" }
      if let newReference, let oldReference, newReference != oldReference {
        // Active sessions hold their already-frozen in-memory key, not a new lookup.
        try credentials.remove(oldReference)
      }
      if let newDoubaoReference, let oldDoubaoReference, newDoubaoReference != oldDoubaoReference {
        try credentials.remove(oldDoubaoReference)
      }
      return true
    } catch {
      if let newReference, saved.voice.credentialReference != newReference { try? credentials.remove(newReference) }
      if let newDoubaoReference, saved.voice.doubao.credentialReference != newDoubaoReference { try? credentials.remove(newDoubaoReference) }
      status = persisted ? "配置已保存；凭据读取/旧项清理未完成，不能称全部应用成功：\(error.localizedDescription)" : "保存失败，未发布新配置：\(error.localizedDescription)"
      return false
    }
  }
  func deleteKey() {
    var next = saved; let doubao=draft.voice.model.isDoubao
    let ref=doubao ? next.voice.doubao.credentialReference : next.voice.credentialReference
    if doubao {
      next.voice.doubao.credentialReference=nil
      doubaoKeyReadTimer?.invalidate(); doubaoKeyReadTimer=nil; doubaoKeyReadPending=false
      doubaoKeyReadID=UUID(); cachedDoubaoKey=nil; newDoubaoKey=""
    } else {
      next.voice.credentialReference=nil
      keyReadTimer?.invalidate(); keyReadTimer=nil; keyReadPending=false
      keyReadID=UUID(); cachedKey=nil; newKey=""
    }
    if next.voice.model.isDoubao == doubao { next.voice.enabled=false }
    do {
      stopAll(cancel: true)
      next = try store.save(next); saved = next; draft = next
      if let data = try? Wire.encode(next) { callbacks?.settingsChanged(data) }
      if let ref { try credentials.remove(ref) }
      status = "所选服务的密钥已移除；另一服务的凭据、用户词库和其他设置保留。"
    } catch { status = "删除未完整成功：\(error.localizedDescription)" }
  }
  func revert() { draft = saved; newKey = ""; newDoubaoKey = ""; status = "未保存修改已取消。" }
  func restoreKnownValid() {
    do {
      stopAll(cancel:true)
      let value = try store.restoreLastValid(expectedRevision:saved.revision)
      saved = value; draft = value; newKey = ""; newDoubaoKey = ""; needsRecovery = false; recoveryAvailable = false
      refreshKey(); refreshDoubaoKey()
      if let data = try? Wire.encode(value) { callbacks?.settingsChanged(data) }
      status = "已恢复已知有效备份，损坏原文件另存 .recovery-*.invalid；语音保持关闭。请核对后再启用。"
    } catch { status = "恢复未成功：\(error.localizedDescription)" }
  }
  func defaults() {
    let ref = draft.voice.credentialReference
    let doubaoRef = draft.voice.doubao.credentialReference
    let schemas = Set(saved.letters.keys).union(draft.letters.keys)
    draft = Settings(); draft.revision = saved.revision; draft.voice.credentialReference = ref; draft.voice.doubao.credentialReference = doubaoRef
    // Retain schema identities so the GUI can explicitly remove their managed
    // patches. Dropping the map would leave enabled source patches unreachable.
    for schema in schemas { draft.letters[schema] = LetterProfile() }
    status = "已恢复非秘密默认值，尚未保存；Key 不自动删除。已配置方案保留为关闭条目，保存后逐方案安全部署恢复原结构。"
  }
  func requestMicrophone() {
    refreshMicrophoneAuthorization()
    guard !requestingMicrophone else { return }
    guard microphoneAuthorization == .notDetermined else {
      status = microphoneAuthorization == .authorized ? "麦克风已允许。按住配置的语音热键或测试按钮才会录音。" : "系统已记录麦克风权限。请点击“打开系统麦克风设置”查看或开启，返回后自动刷新。"
      return
    }
    requestingMicrophone=true
    status="请在系统权限提示中选择是否允许麦克风；此次申请不会录音。"
    microphonePermission.request { [weak self] _ in DispatchQueue.main.async {
      guard let self else { return }
      self.requestingMicrophone=false
      self.refreshMicrophoneAuthorization()
      self.refreshFocusPermission()
      self.status=self.microphoneAuthorization == .authorized ? "麦克风已允许；授权完成不会自动录音。可聚焦语音测试框，按住配置的热键开始测试。" : "麦克风尚未允许。请到系统设置 → 隐私与安全性 → 麦克风查看；返回设置页会自动刷新权限。"
    } }
  }
  func refreshMicrophoneAuthorization() {
    let next=microphonePermission.authorization()
    microphoneAuthorization=next
    if next != .authorized && (active != nil || testAudio != nil) { stopAll(cancel:true) }
  }
  func openMicrophoneSettings() {
    guard let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"),
          NSWorkspace.shared.open(url) else {
      status="无法打开系统设置。请手动前往系统设置 → 隐私与安全性 → 麦克风。"; return
    }
    status="请在系统麦克风列表查看“鼠须管增强开发版”或“鼠须管增强设置开发版”。返回本页后会自动刷新；开启权限不会自动录音。"
  }
  var microphoneStatus:String {
    if requestingMicrophone { return "正在等待系统授权…" }
    switch microphoneAuthorization {
    case .authorized: return "麦克风已允许"
    case .denied: return "麦克风未允许 · 请在系统设置中开启"
    case .restricted: return "麦克风受系统策略限制"
    case .notDetermined: return "尚未申请麦克风权限"
    @unknown default: return "麦克风权限未知 · 暂不可录音"
    }
  }
  func deployLetters(test: Bool,replaceLegacy:Bool = false) {
    guard !selectedSchema.isEmpty else { status = "隔离目录中未发现源方案。"; return }
    guard !hasUnsavedChanges else { status = "请先保存或取消当前表单修改；没有使用旧设置替代未保存设置进行部署/测试。"; return }
    guard let data = try? JSONSerialization.data(withJSONObject: ["action":test ? "letter-test" : (replaceLegacy ? "deploy-migrate" : "deploy"), "schema":selectedSchema]) else { return }
    if callbacks == nil { status = "输入法 IPC 未连接；不能伪称部署/真实 Rime 测试通过。"; return }
    callbacks?.deploymentRequested(data)
  }
  func requestFocusPermission() {
    guard let callbacks else {
      status="输入法尚未连接，无法发起焦点检测授权。请从已连接的增强输入法菜单打开设置后重试；没有申请权限。"
      return
    }
    guard let data = try? JSONSerialization.data(withJSONObject:["action":"authorize-focus"]) else { return }
    callbacks.deploymentRequested(data)
    status="已请求输入法检查焦点检测权限；请按系统提示操作，当前尚未收到授权完成回执。"
  }
  private var callbacks: InputCallbacks? {
    connection?.remoteObjectProxyWithErrorHandler { _ in } as? InputCallbacks
  }
  func showSettings() {
    DispatchQueue.main.async {
      self.stopAll(cancel:true)
      self.productionAdmission.revokePending(at:ProcessInfo.processInfo.systemUptime)
      self.refreshMicrophoneAuthorization()
      self.refreshSchemas()
      // Parent has invalidated its target before opening us. Never reactivate old apps.
      if self.windowController == nil { self.windowController = SettingsWindow(model: self) }
      self.windowController?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
      self.windowController?.window?.makeKeyAndOrderFront(nil)
    }
  }
  func begin(_ request: Data) {
    DispatchQueue.main.async {
      guard let value = try? Wire.decode(VoiceRequest.self, request) else { return }
      if self.activeID == value.identity { return } // Duplicate must not fail a live/finalizing owner.
      let available=self.active == nil && self.testAudio == nil && self.saved.voice.enabled &&
        value.revision == self.saved.revision && !self.settingsOwnFocus && self.productionKey != nil &&
        !self.recordingKeys && !self.testingKeys && !self.waitingKeyRelease
      let decision=self.productionAdmission.admit(value.identity,pressUptime:value.pressUptime,
        receivedAt:ProcessInfo.processInfo.systemUptime,canStart:available)
      switch decision {
      case .duplicate: return
      case .start: break
      case .stoppedBeforeBegin, .unavailable, .invalidClock, .capacityLimited:
        let message:String
        switch decision {
        case .stoppedBeforeBegin: message="本次按压在启动前已结束/取消/失效；未打开麦克风。"
        case .invalidClock: message="触发时间缺失或无效；未开始采音，请使用配套输入法前端。"
        case .capacityLimited: message="近期请求记录达到保护上限；未排队、未开麦，请稍后用新的完整按压重试。"
        default:
          if self.settingsOwnFocus {
            message="当前焦点在增强设置。请在设置页测试框测试，或切回目标文本框使用热键。"
          } else if !self.saved.voice.enabled { message="语音输入尚未启用。请在语音输入设置中开启并保存。" }
          else if self.productionKey == nil { message="尚未读取到 API Key。请在语音输入设置中填写密钥并保存。" }
          else if value.revision != self.saved.revision { message="设置正在同步，请完整松开热键，稍后再次按住。" }
          else { message="上一段语音或本地测试仍在结束，请稍后再次按住热键。" }
        }
        let update=VoiceUpdate(identity:value.identity,
          phase:decision == .stoppedBeforeBegin ? .cancelled : .failed,text:"",complete:false,message:message)
        self.status=message
        self.productionTargetStatus=message
        if let data=try? Wire.encode(update) { self.callbacks?.voiceUpdate(data) }; return
      }
      guard let key=self.productionKey else { return } // Main queue: same frozen readiness decision.
      self.productionTargetStatus="输入法已确认原文本框，助手已接受本次普通应用语音请求。"
      self.start(identity:value.identity,settings:self.saved.voice,key:key,test:false,pressUptime:value.pressUptime)
    }
  }
  private func start(identity:VoiceIdentity,settings:VoiceSettings,key:String,test:Bool,pressUptime:TimeInterval? = nil,intoTestEditor:Bool = false) {
    cancelConnectionCheck()
    activeID = identity; discardPreviewSession = nil; testSession = test
    if test { beginTestPresentation(identity:identity,intoTestEditor:intoTestEditor,settings:settings) }
    else { testInsertion=nil; testPreviewPanel.clear() }
    if test { replacedTestDraft=testDrafts.begin(identity) }
    else { testDrafts.clear(); replacedTestDraft=false }
    preview=""; previewIsComplete=false
    diagnosticStore.begin(identity); diagnostic=nil
    let stream=sessionFactory(identity,settings,test,test ? nil : saved.revision,pressUptime) { [weak self] update, snapshot in
      guard let self, self.activeID == update.identity else { return }
      if self.diagnosticStore.accept(snapshot) { self.diagnostic=self.diagnosticStore.latest }
      let discard = self.discardPreviewSession == update.identity || (self.testSession && update.phase == .cancelled)
      if self.testSession {
        if discard { self.testDrafts.discard() }
        if self.testDrafts.accept(update.identity,phase:update.phase,text:update.text,complete:update.complete) {
          self.preview=self.testDrafts.text; self.previewIsComplete=self.testDrafts.complete
        }
      } // Production text is routed only to the native preview, never the GUI test result.
      self.level = update.level
      self.status = "\(update.phase.title) · \(String(format: "%.1f", update.duration)) 秒\n\(update.message)"
      if self.testSession { self.renderTestVoiceUpdate(update) }
      if self.testSession && self.replacedTestDraft { self.status += "\n上一条测试草稿已被本次录音替换，不保存历史。" }
      if !self.testSession, let data = try? Wire.encode(update) { self.callbacks?.voiceUpdate(data) }
      if [.ready, .review, .cancelled, .failed].contains(update.phase) {
        self.diagnosticStore.end(update.identity)
        if !self.testSession { self.productionAdmission.close(update.identity,receivedAt:ProcessInfo.processInfo.systemUptime) }
        self.active = nil; self.activeID = nil; self.testLease?.invalidate(); self.testLease = nil
        if self.testSession { self.testInsertion=nil }
      }
    }
    active = stream; stream.start(key: key)
    if test {
      testLease = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak stream] _ in stream?.renewLease() }
    }
  }
  func release(_ identity: Data) {
    guard let value = try? Wire.decode(VoiceRelease.self, identity),
          (try? value.validate(receivedAt:ProcessInfo.processInfo.systemUptime)) != nil else { return }
    DispatchQueue.main.async {
      if self.testSession && self.activeID == value.identity { return }
      self.productionAdmission.close(value.identity,receivedAt:ProcessInfo.processInfo.systemUptime)
      if !self.testSession && self.activeID == value.identity { self.active?.release(at:value.uptime,cause:value.cause ?? .unspecified) }
    }
  }
  func voiceDeliveryReceipt(_ result:Data) {
    guard let receipt=try? Wire.decode(VoiceDeliveryReceipt.self,result) else { return }
    DispatchQueue.main.async {
      if self.diagnosticStore.delivery(receipt,receivedAt:ProcessInfo.processInfo.systemUptime) {
        self.diagnostic=self.diagnosticStore.latest
      }
    }
  }
  func cancel(_ identity: Data) {
    guard let id = try? Wire.decode(VoiceIdentity.self, identity) else { return }
    DispatchQueue.main.async {
      if self.testSession && self.activeID == id { return }
      self.productionAdmission.close(id,receivedAt:ProcessInfo.processInfo.systemUptime)
      if !self.testSession && self.activeID == id { self.discardPreviewSession = id; self.active?.cancel(); self.preview = "" }
    }
  }
  func lease(_ identity: Data) {
    guard let id = try? Wire.decode(VoiceIdentity.self, identity) else { return }
    DispatchQueue.main.async { if !self.testSession && self.activeID == id { self.active?.renewLease() } }
  }
  func deploymentReply(_ result: Data) {
    guard let value = try? Wire.decode(String.self, result) else { return }
    DispatchQueue.main.async {
      if value == "focus-status:allowed" { self.focusPermissionStatus="输入法焦点检测已允许，可在普通文本框使用语音。" }
      else if value == "focus-status:required" { self.focusPermissionStatus="普通应用语音需要焦点检测权限；请点击下方授权按钮，在系统辅助功能中允许鼠须管增强开发版。设置页测试无需此权限。" }
      else if value.hasPrefix("voice-target:"), value.utf8.count <= 4096 { self.productionTargetStatus=String(value.dropFirst("voice-target:".count)) }
      else { self.status = value }
    }
  }
  func settingsApplied(_ result:Data) {
    guard let value = try? Wire.decode(SettingsReceipt.self,result), value.message.utf8.count <= 4096 else { return }
    DispatchQueue.main.async {
      guard value.revision == self.saved.revision else { return } // Ignore a stale acknowledgment.
      self.applicationState = "版本 \(value.revision)：\(value.message)"
    }
  }
  func schemaCatalog(_ result:Data) {
    guard let value = try? Wire.decode(SchemaCatalog.self,result), value.ids.count <= 512,
          value.ids.allSatisfy({$0.range(of:"^[a-zA-Z0-9_-]+$",options:.regularExpression) != nil}) else { return }
    DispatchQueue.main.async {
      self.schemas = value.ids; self.schemaSource = "真实隔离 Rime 启用方案（C API）"
      if !self.schemas.contains(self.selectedSchema) {
        self.selectedSchema = self.schemas.contains(value.current) ? value.current : self.schemas.first ?? ""
      }
      self.status = "已读取实际启用方案；没有切换方案、修改词库或触发部署。"
    }
  }
  func beginTestPresentation(identity:VoiceIdentity,intoTestEditor:Bool,settings:VoiceSettings? = nil) {
    testInsertion=nil
    if intoTestEditor, testEditorController.isFocused, let editor=testEditorController.editor, !editor.hasMarkedText() {
      testInsertion=VoiceTestInsertion(identity:identity,text:editor.string,selection:editor.selectedRange())
      voiceTestHint="按住说话，松开停止采音；完整结果将插入此测试框。"
    }
    let presentation=settings ?? draft.voice
    testPreviewAtCaret=presentation.previewAtCaret
    testPreviewPanel.begin(identity,showPreview:true,transparency:presentation.previewTransparency,
      atCaret:testPreviewAtCaret,anchor:testEditorController.anchor())
  }
  func renderTestVoiceUpdate(_ update:VoiceUpdate) {
    var display=update; display.showPreview=true
    if update.phase == .ready, testInsertion != nil {
      if let editor=testEditorController.editor,
         let range=testInsertion?.claim(identity:update.identity,phase:update.phase,complete:update.complete,
           text:update.text,current:editor.string,selection:editor.selectedRange(),
           focused:testEditorController.isFocused,marked:editor.hasMarkedText()) {
        insertingTestResult=true
        editor.insertText(update.text,replacementRange:range)
        insertingTestResult=false
        voiceTestText=editor.string
        voiceTestHint="完整最终文字已输入测试框，可继续编辑或再次按住热键输入。"
        status += "\n完整结果已插入本窗口测试框。"
        testPreviewPanel.clear()
      } else {
        display.phase = .review; display.message="测试框焦点、文字或光标已改变；结果保留为草稿，没有自动插入。"
        voiceTestHint=display.message; testPreviewPanel.update(display)
      }
    } else { testPreviewPanel.update(display) }
    if testPreviewAtCaret { testPreviewPanel.position(near:testEditorController.anchor()) }
  }
  var hasEditorVoiceSession:Bool { testSession && activeID != nil && testInsertion != nil }
  var editorVoiceReadiness:String? {
    if testEditorController.editor?.hasMarkedText() == true { return "请先确认或取消测试框中的拼音组合，再按住语音热键。没有开始采音。" }
    guard active == nil, testAudio == nil,
          !recordingKeys, !testingKeys, !waitingKeyRelease else { return "请先结束上一段录音、收尾或其他测试，再完整松开热键重试。" }
    do {
      var settings=draft.voice
      guard let key=draftKey, !key.isEmpty else { return "请先填写 API Key；没有开始采音。" }
      try VoiceCredential.validate(key)
      settings.activeCredentialReference=settings.activeCredentialReference ?? "draft-memory-only"
      try settings.validate(requireReady:true)
      return nil
    } catch { return "\(error.localizedDescription) 没有开始采音。" }
  }
  func invalidateTestEditorTarget() { testInsertion?.invalidate() }
  func testEditorChanged() {
    guard hasEditorVoiceSession, !insertingTestResult else { return }
    invalidateTestEditorTarget(); testEditorController.stopOwned(cancel:false)
    active?.release(cause:.targetInvalidated)
    voiceTestHint="测试框已编辑或光标移动；停止新采音，识别结果保留为草稿。"
  }
  func testHold(cloud: Bool, action:GUITestHoldAction,intoTestEditor:Bool = false) {
    let pressID:UUID
    switch action {
    case .none: return
    case .release(let id):
      guard testHoldOwner.finish(id) else { return }
      if testAudio != nil {
        let message = "本地测试已停止接收样本；等待设备与尾部清理，未联网、未保存音频。"
        status = message
        stopLocalAudio { [weak self] succeeded in
          guard let self, self.status == message else { return }
          self.status = succeeded ? "本地麦克风测试已停止；未联网、未保存音频。" : "本地麦克风已停止；转换未完整排空，未联网、未保存音频。"
        }
      } else if testSession { active?.release(cause:.guiReleased) }
      return
    case .cancel(let id):
      guard testHoldOwner.finish(id) else { return }
      discardPreviewSession = activeID; discardTestDraft(); stopAll(cancel:true); return
    case .start(let id): pressID = id
    }
    guard active == nil, testAudio == nil,
          !recordingKeys, !testingKeys, !waitingKeyRelease else {
      status = "请先结束上一项录音/收尾、连接测试或按键录制/测试；本次按钮没有开始采音。"; return
    }
    guard testHoldOwner.begin(pressID) else {
      status = "上一次测试按压尚未释放；本次没有开始采音。"; return
    }
    cancelConnectionCheck() // A no-audio background check cannot block a real held test.
    do {
      if cloud {
        var settings = draft.voice
        // Draft snapshot never changes saved production state; new Key is memory-only.
        let key = draftKey
        guard let key, !key.isEmpty else { throw SettingsError.invalid("尚未提供测试 Key。") }
        settings.activeCredentialReference = settings.activeCredentialReference ?? "draft-memory-only"
        if settings.binding == nil { settings.binding = TriggerBinding(codes: [61]) }
        try settings.validate(requireReady: true)
        if intoTestEditor { settings.showPreview=true }
        start(identity: VoiceIdentity(generation: UInt64.random(in: 1...UInt64.max)), settings: settings, key: key,
              test:true,intoTestEditor:intoTestEditor)
        status = "显式按住云测试：使用当前表单快照\(hasUnsavedChanges ? "（尚未保存）" : "（已保存）")；上传音频并可能计费，结果仅供本窗口测试。" + (replacedTestDraft ? "上一条测试草稿将被替换，不保存历史。" : "")
      } else {
        let audio = AudioCapture(); testAudio = audio
        localPCMSamples=0
        let uid = draft.voice.deviceUID // Freeze on the GUI thread.
        status = "正在启动本地麦克风测试；不联网、不保存音频。松开即停止。"
        DispatchQueue.global(qos:.userInitiated).async { [weak self,audio] in
          do {
            try audio.start(uid:uid,pcm:{ [weak self,weak audio] data,level in
              DispatchQueue.main.async {
                guard let self, let audio, self.testAudio === audio else { return }
                self.localPCMSamples += data.count / 2
                if self.testHoldOwner.owns(pressID) { self.level=level }
              }
            },failure:{ [weak self] message in DispatchQueue.main.async {
              guard let self, self.testHoldOwner.owns(pressID) else { return }
              self.stopAll(cancel:true); self.status=message
            } })
            DispatchQueue.main.async {
              guard let self, self.testHoldOwner.owns(pressID), self.testAudio === audio else { return }
              self.status="本地麦克风测试；不联网、不保存音频。松开即停止。"
            }
          } catch {
            DispatchQueue.main.async {
              guard let self, self.testHoldOwner.owns(pressID), self.testAudio === audio else { return }
              _ = self.testHoldOwner.finish(pressID); self.stopLocalAudio(); self.status=error.localizedDescription
            }
          }
        }
      }
    } catch { _ = testHoldOwner.finish(pressID); stopLocalAudio(); status = error.localizedDescription }
  }
  private func stopLocalAudio(finished:((Bool)->Void)? = nil) {
    guard let audio=testAudio, !stoppingLocalAudio else { return }
    stoppingLocalAudio=true; level=0
    // Keep testAudio as the busy owner until hardware teardown AND conversion
    // finish. A rapid new gesture cannot open a second engine during cleanup.
    audio.stop { [weak self, weak audio] succeeded in
      DispatchQueue.main.async {
        guard let self, let audio, self.testAudio === audio else { return }
        self.testAudio=nil; self.stoppingLocalAudio=false; finished?(succeeded)
      }
    }
  }
  func testMicrophoneForTwoSeconds() {
    let id=UUID()
    testHold(cloud:false,action:.start(id))
    guard testHoldOwner.owns(id), testAudio != nil else { return }
    localMicrophoneTimer?.invalidate()
    localMicrophoneTimer=Timer.scheduledTimer(withTimeInterval:2,repeats:false) { [weak self] _ in
      self?.localMicrophoneTimer=nil; self?.testHold(cloud:false,action:.release(id))
    }
  }
  func keyMode(record: Bool) {
    if waitingKeyRelease {
      guard held.allSatisfy({!CGEventSource.keyState(.combinedSessionState,key:CGKeyCode($0))}) else {
        status = "上次录制/测试键仍按住；请全部松开后重新开始。"; return
      }
      held = []; waitingKeyRelease = false; removeMonitor()
    }
    guard !(0..<128).contains(where:{CGEventSource.keyState(.combinedSessionState,key:CGKeyCode($0))}) else {
      status = "请先松开所有物理按键，再开始录制/测试。"; return
    }
    stopAll(cancel: true); removeMonitor()
    recordingKeys = record; testingKeys = !record; recorded = []; held = []; keys = PhysicalKeys()
    downCount = 0; upCount = 0
    monitor = NSEvent.addLocalMonitorForEvents(matching:[.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
      guard let self else { return event }
      if self.waitingKeyRelease {
        let owns = self.held.contains(event.keyCode)
        let down = event.type == .flagsChanged ? CGEventSource.keyState(.combinedSessionState,key:CGKeyCode(event.keyCode)) : event.type == .keyDown
        if !down { self.held.remove(event.keyCode) }
        if self.held.isEmpty { self.waitingKeyRelease = false; self.removeMonitor(); self.status = "上次按键已完整释放；可重新录制/测试。" }
        return owns ? nil : event
      }
      if event.type == .keyDown && event.keyCode == 53 { self.finishKeyMode(cancel: true); return nil }
      let down = event.type == .flagsChanged
        ? CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(event.keyCode)) : event.type == .keyDown
      if down { self.held.insert(event.keyCode); self.recorded.insert(event.keyCode) } else { self.held.remove(event.keyCode) }
      if self.recordingKeys {
        if !down && self.held.isEmpty {
          let binding = TriggerBinding(codes:self.recorded)
          do { try binding.validate(); self.draft.voice.binding = binding; self.status = "已录制 \(binding.label)，未保存；需实际按键测试检查冲突。" }
          catch { self.status = error.localizedDescription }
          self.finishKeyMode(cancel:false)
        }
      } else {
        let action = self.keys.event(code:event.keyCode, down:down, repeated:event.type == .keyDown && event.isARepeat,
                                     binding:self.draft.voice.binding, canStart:true)
        if action == .start { self.downCount += 1 }
        if action == .stop { self.upCount += 1 }
        self.status = "物理按键测试：按下 \(self.downCount)，释放 \(self.upCount)。不采音、不联网；系统级冲突仍需真机确认。"
      }
      return nil
    }
  }
  func clearVoiceBinding() {
    stopAll(cancel:true)
    draft.voice.binding=nil
    draft.voice.enabled=false
    status="语音热键已清除，语音输入已关闭；尚未保存，点击“保存并应用”后生效。"
  }
  func finishKeyMode(cancel: Bool) {
    recordingKeys = false; testingKeys = false
    if monitor != nil && !held.isEmpty {
      waitingKeyRelease = true; recorded = []
      status = "录制/测试已退出；等待原按键全部释放，不保存未完成的绑定。"; return
    }
    waitingKeyRelease = false; removeMonitor()
    if cancel { status = "按键录制/测试已取消，保存的绑定未改变。" }
  }
  private func removeMonitor() { if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil } }
  func stopAll(cancel: Bool) {
    localMicrophoneTimer?.invalidate(); localMicrophoneTimer=nil
    invalidateTestEditorTarget(); testEditorController.cancelLifecycle()
    if cancel { testPreviewPanel.clear() }
    productionAdmission.revokePending(at:ProcessInfo.processInfo.systemUptime)
    if !testSession, let identity=activeID {
      productionAdmission.close(identity,receivedAt:ProcessInfo.processInfo.systemUptime)
    }
    testHoldOwner.cancelAll()
    if cancel, let data = try? JSONSerialization.data(withJSONObject:["action":"letter-test-cancel"]) {
      callbacks?.deploymentRequested(data)
    }
    if cancel { cancelConnectionCheck() }
    if cancel { active?.cancel() } else { active?.release(cause:testSession ? .guiReleased : .unspecified) }
    stopLocalAudio()
    finishKeyMode(cancel:false)
    testEditorController.restoreFocusIfNeeded()
  }
  private var settingsOwnFocus:Bool { NSApp.isActive && windowController?.window?.isKeyWindow == true }
  func stopSettingsActivity() {
    // Leaving the settings window cancels its own tests. A background settings
    // window cannot cancel/revoke a production press owned by another app.
    if testSession && active != nil || testAudio != nil { stopAll(cancel:true) }
    else {
      invalidateTestEditorTarget(); testEditorController.cancelLifecycle()
      cancelConnectionCheck(); finishKeyMode(cancel:false)
    }
  }
  @objc private func deactivated() { stopSettingsActivity() }
  @objc private func activated() { refreshDevices(); refreshMicrophoneAuthorization(); refreshFocusPermission(); testEditorController.restoreFocusIfNeeded() }
  @objc private func testWindowResigned(_ note:Notification) {
    if let window=note.object as? NSWindow, window === windowController?.window { stopSettingsActivity() }
  }
  @objc private func sleep() { stopAll(cancel:true) }
}
