import AppKit
import Carbon
import EnhancementCore
import EnhancementIPC

protocol EnhancementInput: AnyObject {
  func voiceReceived(_ value:VoiceUpdate)
  func enhancementConfigurationChanged(_ value:Settings)
  func enhancementDeploy(action:String,schema:String)
  func enhancementInvalidated()
}

/// One exported object per connection: queued callbacks retain their origin.
private final class EnhancementConnectionCallbacks:NSObject,InputCallbacks {
  private weak var bridge:EnhancementBridge?
  private let id:UUID
  init(bridge:EnhancementBridge,id:UUID) { self.bridge=bridge; self.id=id }
  func settingsChanged(_ value:Data) { bridge?.receiveSettings(value,from:id) }
  func voiceUpdate(_ value:Data) { bridge?.receiveVoice(value,from:id) }
  func deploymentRequested(_ value:Data) { bridge?.receiveDeployment(value,from:id) }
}

final class EnhancementBridge: NSObject, AuthenticatedListenerDelegate {
  static let shared = EnhancementBridge()
  private var listener:AuthenticatedListener?
  // Process, connection and input/configuration are main-queue owned.
  private var process:Process?
  private var connection:AuthenticatedConnection?
  private var connectionID:UUID?
  private let trust:PeerTrust?
  private let linkLock=NSLock()
  private var link=HelperLinkState()
  private var expectedPID:Int32? // Protected with linkLock; routing, separate from signer authentication.
  private let endpointWriter=DispatchQueue(label:"org.rime.SquirrelEnhanced.endpoint-writer")
  private var configuration = Settings()
  private let store:SettingsStore
  private var lifecycleObservers:[NSObjectProtocol] = []
  private var sourceObserver:NSObjectProtocol?
  weak var input:EnhancementInput?
  var settings:Settings { configuration }
  var connected:Bool { connection != nil }

  override init() {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/SquirrelEnhancedDev/settings.json")
    store = SettingsStore(url:url); configuration = (try? store.load()) ?? store.lastValidReadOnly() ?? Settings()
    trust=PeerTrust.configured(in:Bundle.main)
    super.init()
    for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.willSleepNotification,
                 NSWorkspace.sessionDidResignActiveNotification] {
      lifecycleObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.input?.enhancementInvalidated() })
    }
    sourceObserver = DistributedNotificationCenter.default().addObserver(
      forName:NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),object:nil,queue:.main
    ) { [weak self] _ in self?.input?.enhancementInvalidated() }
  }
  private func withLink<T>(_ body:(inout HelperLinkState)->T) -> T {
    linkLock.lock(); defer { linkLock.unlock() }; return body(&link)
  }
  // Current-owner loss also retires a reservation not yet installed on main.
  private func retireOwner() {
    linkLock.lock(); expectedPID=nil; link.ownerEnded(); linkLock.unlock()
    let old=connection; connection=nil; connectionID=nil; old?.invalidate()
    listener?.invalidate();listener=nil
    input?.enhancementInvalidated(); EnhancementDeployment.shared.cancelLetterTest()
  }
  private func connectionEnded(_ id:UUID) {
    guard withLink({ $0.end(id) }) else { return }
    // A stale handler cannot clear a replacement or invalidate its input session.
    guard connectionID == id else { return }
    let old=connection; connection=nil; connectionID=nil; old?.invalidate()
    input?.enhancementInvalidated(); EnhancementDeployment.shared.cancelLetterTest()
  }
  @discardableResult func launchIfNeeded() -> Bool {
    guard process?.isRunning != true else { return true }
    if process != nil { process=nil; retireOwner() }
    guard let trust,
          let bundle = Bundle.main.resourceURL?.appendingPathComponent("SquirrelVoiceHelper.app"),
          let helper = Bundle(url:bundle)?.executableURL else { return false }
    if listener == nil {
      guard let newListener=try? AuthenticatedListener(trust:trust) else { return false }
      newListener.delegate=self; newListener.resume(); listener=newListener
    }
    guard let archive=try? listener?.bootstrap.encoded(),archive.count<=4096 else { return false }
    let child = Process(); let pipe = Pipe()
    child.executableURL = helper; child.standardInput = pipe
    child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
    child.terminationHandler = { [weak self] ended in DispatchQueue.main.async {
      guard let self, self.process === ended else { return }
      self.process=nil; self.retireOwner()
    } }
    do {
      try child.run(); process = child
      linkLock.lock(); expectedPID=child.processIdentifier; linkLock.unlock()
      // Helper initializes its GUI/Keychain before reading stdin. Never block the
      // input event queue waiting for that reader to drain a potentially full pipe.
      endpointWriter.async { [weak self] in
        do { try pipe.fileHandleForWriting.write(contentsOf:archive); try pipe.fileHandleForWriting.close() }
        catch {
          try? pipe.fileHandleForWriting.close()
          DispatchQueue.main.async {
            guard let self, self.process === child else { return }
            if child.isRunning { child.terminate() }
            self.process=nil; self.retireOwner()
            EnhancementPreview.shared.notice("增强 Helper 启动通信失败；普通输入不受影响，请重新打开设置。")
          }
        }
      }
      return true
    } catch { return false }
  }
  func listener(_ listener:AuthenticatedListener, shouldAcceptNewConnection candidate:AuthenticatedConnection) -> Bool {
    guard candidate.effectiveUserIdentifier == getuid(), trust != nil else { return false }
    let id=UUID()
    linkLock.lock()
    let reserved=expectedPID == candidate.processIdentifier && link.reserve(id)
    linkLock.unlock()
    guard reserved else { return false }
    // Transport already verified the kernel audit token and exact signer/ID.
    candidate.exportedObject = EnhancementConnectionCallbacks(bridge:self,id:id)
    candidate.invalidationHandler = { [weak self] in DispatchQueue.main.async { self?.connectionEnded(id) } }
    candidate.interruptionHandler = candidate.invalidationHandler
    DispatchQueue.main.async { [weak self] in
      guard let self, let show=self.withLink({ $0.activate(id) }) else { candidate.invalidate(); return }
      self.connection=candidate; self.connectionID=id; candidate.resume()
      if show { self.helper?.showSettings() }
    }
    return true
  }
  var helper:HelperCommands? {
    guard let connection, let id=connectionID, withLink({ $0.accepts(id) }) else { return nil }
    return connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
      DispatchQueue.main.async { self?.connectionEnded(id) }
    } as? HelperCommands
  }
  func openSettings() {
    input?.enhancementInvalidated()
    if trust == nil, let url = Bundle.main.resourceURL?.appendingPathComponent("SquirrelVoiceHelper.app") {
      let config = NSWorkspace.OpenConfiguration(); config.arguments = ["--settings"]
      NSWorkspace.shared.openApplication(at:url,configuration:config) { _, _ in }
      return
    }
    if withLink({ $0.requestSettings() }) { helper?.showSettings(); return }
    if !launchIfNeeded() {
      EnhancementPreview.shared.notice("增强 Helper 无法启动；普通输入不受影响，请检查开发构建后重新打开设置。")
    }
  }
  fileprivate func receiveSettings(_ configuration:Data,from id:UUID) {
    guard withLink({ $0.accepts(id) }), let value = try? Wire.decode(Settings.self,configuration), (try? value.validate()) != nil else { return }
    DispatchQueue.main.async {
      // Check origin again after queueing, then verify the persistent authority.
      guard self.withLink({ $0.accepts(id) }), let disk = try? self.store.load(), disk == value else { return }
      self.configuration = value; self.input?.enhancementConfigurationChanged(value)
      let receipt = SettingsReceipt(revision:value.revision,message:"输入法已接收并缓存配置；开关按安全边界应用，语音从下一完整按键周期生效。字母处理器/页大小未在这里部署，请按 GUI 流程确认。")
      if let data = try? Wire.encode(receipt) { self.helper?.settingsApplied(data) }
    }
  }
  fileprivate func receiveVoice(_ update:Data,from id:UUID) {
    guard withLink({ $0.accepts(id) }), let value = try? Wire.decode(VoiceUpdate.self,update),
          VoiceUpdateBounds.valid(level:value.level,duration:value.duration,
            textBytes:value.text.utf8.count,messageBytes:value.message.utf8.count) else { return }
    DispatchQueue.main.async {
      guard self.withLink({ $0.accepts(id) }) else { return }
      EnhancementDeployment.shared.deliverVoice(value)
    }
  }
  fileprivate func receiveDeployment(_ request:Data,from id:UUID) {
    guard withLink({ $0.accepts(id) }), request.count <= 4096,
          let value = try? JSONSerialization.jsonObject(with:request) as? [String:String],
          let action = value["action"], ["deploy","deploy-migrate","letter-test","letter-test-cancel","authorize-focus","focus-status","schemas"].contains(action) else { return }
    DispatchQueue.main.async {
      guard self.withLink({ $0.accepts(id) }) else { return }
      EnhancementDeployment.shared.perform(action:action,schema:value["schema"] ?? "")
    }
  }
  func reply(_ value:String) { if let data = try? Wire.encode(value) { helper?.deploymentReply(data) } }
  deinit {
    for observer in lifecycleObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
  }
}
