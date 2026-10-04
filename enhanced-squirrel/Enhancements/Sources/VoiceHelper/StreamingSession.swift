import Foundation
import EnhancementCore
import EnhancementIPC

final class StreamingSession: NSObject, VoiceSession, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
  let identity: VoiceIdentity
  let settings: VoiceSettings
  private var reducer: VoiceEventReducer
  private var state: VoiceState { reducer.state }
  private var transcript: TranscriptAccumulator { reducer.transcript }
  private var pcm: PCMQueue
  private let queue = DispatchQueue(label: "org.rime.voice.session")
  private let audio = AudioCapture()
  private var webSocket: URLSessionWebSocketTask?
  private var urlSession: URLSession?
  private var timer: DispatchSourceTimer?
  private var startedAt = ProcessInfo.processInfo.systemUptime
  private var connectedAt: TimeInterval?
  private var lastLease = ProcessInfo.processInfo.systemUptime
  private var tailDrained = false
  private var sending = false
  private var receivedAudio = false
  private var level = 0.0
  private var stopped = false
  private let captureGate = NSLock()
  private var stillHeld = true
  private let update: (VoiceUpdate,VoiceDiagnosticSnapshot) -> Void
  private var diagnostics:VoiceDiagnosticTimeline
  private let test: Bool

  init(identity: VoiceIdentity, settings: VoiceSettings, test: Bool,
       revision:UInt64? = nil, pressUptime:TimeInterval? = nil,
       update: @escaping (VoiceUpdate,VoiceDiagnosticSnapshot) -> Void) {
    self.identity = identity; self.settings = settings; self.test = test; self.update = update
    reducer = VoiceEventReducer(identity:identity,settings:settings); pcm = PCMQueue(seconds: settings.queueSeconds)
    let accepted=ProcessInfo.processInfo.systemUptime; startedAt=accepted
    diagnostics=VoiceDiagnosticTimeline(identity:identity,revision:revision,mode:test ? .guiTest : .production,
        origin:pressUptime == nil ? .helperStart : .physicalPress,referenceUptime:pressUptime ?? accepted)
    diagnostics.record(.helperAccepted,at:accepted)
  }
  func start(key: String) {
    queue.async { [self] in
      do {
        try self.settings.validate(requireReady:true)
        try VoiceCredential.validate(key)
        let endpoint = try self.settings.endpoint()
        var request = URLRequest(url: endpoint); request.timeoutInterval = Double(self.settings.connectSeconds)
        for (name,value) in try self.settings.connectionHeaders(key:key,task:self.identity.task) { request.setValue(value,forHTTPHeaderField:name) }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = Double(self.settings.connectSeconds)
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.urlSession = session
        let socket = session.webSocketTask(with: request); socket.maximumMessageSize = 256 * 1024
        self.webSocket = socket
        self.captureGate.lock()
        guard self.stillHeld else {
          self.captureGate.unlock(); self.reducer.cancel(); self.publish("按键已释放；没有打开麦克风。"); self.cleanup(); return
        }
        self.captureGate.unlock()
        try self.audio.start(uid: self.settings.deviceUID, pcm: { [weak self] data, level in
          self?.queue.async {
            guard let self, !self.stopped else { return }
            do {
              try self.pcm.append(data); self.receivedAudio = self.receivedAudio || !data.isEmpty; self.level = level
              if !data.isEmpty { self.diagnostics.record(.firstPCM,at:ProcessInfo.processInfo.systemUptime) }
            } catch { self.fail("音频队列超限。",reason:.audioQueue) }
          }
        }, failure: { [weak self] message in self?.queue.async { self?.fail(message,reason:.audio) } })
        self.diagnostics.record(.captureStarted,at:ProcessInfo.processInfo.systemUptime)
        socket.resume(); self.receive()
        let timer = DispatchSource.makeTimerSource(queue: self.queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume()
        self.publish()
      } catch { self.fail(error.localizedDescription,reason:.setup) }
    }
  }
  func release(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime, cause:VoiceStopCause = .keyReleased) {
    // Called on receiving real release; immediate cutoff precedes queued network work.
    let received=ProcessInfo.processInfo.systemUptime
    captureGate.lock(); stillHeld = false
    captureGate.unlock()
    let cutoff=audio.stop { [weak self] succeeded in self?.queue.async {
      guard let self, !self.stopped else { return }
      if succeeded { self.tailDrained = true; self.diagnostics.record(.tailDrained,at:ProcessInfo.processInfo.systemUptime) }
      else { self.fail("音频转换未完整排空；已有文字仅作草稿。",reason:.audio) }
    } }
    queue.async {
      guard !self.stopped else { return }
      self.diagnostics.requestStop(cause:cause,at:uptime,receivedAt:received)
      self.diagnostics.record(.captureCutoff,at:cutoff)
      self.reducer.stop(at:uptime,cause:cause)
      self.publish()
    }
  }
  func cancel() {
    captureGate.lock(); stillHeld = false; captureGate.unlock(); let cutoff=audio.stop { _ in }
    queue.async {
      guard !self.stopped else { return }
      self.diagnostics.record(.captureCutoff,at:cutoff)
      self.diagnostics.record(.cancelled,at:ProcessInfo.processInfo.systemUptime)
      self.reducer.cancel(); self.publish(); self.cleanup()
    }
  }
  func clearDiagnostics() { queue.async { self.diagnostics.clear() } }
  func renewLease() { queue.async { self.lastLease = ProcessInfo.processInfo.systemUptime } }
  private func tick() {
    guard !stopped else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if now - lastLease > 2.5 { fail("所有者失联，已保护停止。",reason:.ownerLost); return }
    if state.physicalHeld && now - startedAt > Double(settings.maximumSeconds) {
      release(at:now,cause:.maximumDuration)
      publish("达到录音上限；已停止新采音并正常收尾。完整松开按键后才能重新录音。")
      return
    }
    if connectedAt == nil && now - startedAt > Double(settings.connectSeconds) { fail("WebSocket 连接超时。",reason:.connectionTimeout); return }
    if let connectedAt, !state.taskStarted && now - connectedAt > Double(settings.taskStartSeconds) { fail("云端任务启动超时。",reason:.taskStartTimeout); return }
    if let released = state.releasedAt, now - released > Double(settings.finalizeSeconds) { fail("松键后等待最终结果超时；已有文本仅作草稿。",reason:.finalizationTimeout); return }
    if tailDrained && !state.physicalHeld && !receivedAudio {
      reducer.cancel(); publish("本次按压没有采到音频；没有插入文字。"); cleanup(); return
    }
    // One frame per clock tick, including pre-start buffers: never burst queued audio.
    if state.taskStarted && !sending, let data = pcm.next(final: tailDrained) {
      let packet:Data
      do { packet=settings.model.isDoubao ? try DoubaoProtocol.audio(data) : data }
      catch { fail("音频包编码失败。",reason:.transportSend); return }
      sending = true
      webSocket?.send(.data(packet)) { [weak self] error in
        self?.queue.async { guard let self, !self.stopped else { return }; self.sending = false
          if error != nil { self.fail("音频发送失败。",reason:.transportSend) }
        }
      }
    }
    if !sending && tailDrained && reducer.sendFinish(queueEmpty: pcm.isEmpty) {
      do {
        let final=settings.model.isDoubao ? try DoubaoProtocol.audio(Data(),final:true) : try QwenProtocol.finish(task:identity.task)
        try send(final); diagnostics.record(.finishRequested,at:ProcessInfo.processInfo.systemUptime)
      } catch { fail("无法发送收尾事件。",reason:.transportSend) }
    }
    publish()
  }
  private func send(_ data: Data,configuration:Bool = false) throws {
    let message:URLSessionWebSocketTask.Message
    if settings.model.isDoubao { message = .data(data) }
    else {
      guard let text=String(data:data,encoding:.utf8) else { throw SettingsError.invalid("协议编码失败。") }
      message = .string(text)
    }
    webSocket?.send(message) { [weak self] error in
      self?.queue.async {
        guard let self, !self.stopped else { return }
        if error != nil { self.fail("云端消息发送失败。",reason:.transportSend) }
        else if configuration { self.reducer.configurationSent() }
      }
    }
  }
  private func receive() {
    webSocket?.receive { [weak self] result in
      self?.queue.async {
        guard let self, !self.stopped else { return }
        do {
          let message = try result.get()
          let data: Data
          switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: throw SettingsError.invalid("未知 WebSocket 消息。") }
          switch try self.reducer.receive(data) {
          case .taskFinished:
            self.diagnostics.record(.taskFinished,at:ProcessInfo.processInfo.systemUptime)
            self.audio.stop { _ in }
            self.publish(); self.cleanup(); return
          case .taskFailed: self.fail(self.reducer.cloudFailureMessage ?? "云端任务失败，请检查型号、额度、地域及账户授权。",reason:.cloudTask); return
          case .ignoredTerminal: self.cleanup(); return
          case .received: break
          }
          if self.state.taskStarted { self.diagnostics.record(.taskStarted,at:ProcessInfo.processInfo.systemUptime) }
          if !self.transcript.preview.isEmpty { self.diagnostics.record(.firstTranscript,at:ProcessInfo.processInfo.systemUptime) }
          self.publish(); self.receive()
        } catch { self.fail("连接中断或协议校验失败；已有文本仅作草稿。",reason:.protocolOrConnection) }
      }
    }
  }
  private func publish(_ message: String = "") {
    let value = VoiceUpdate(identity: identity, phase: state.phase, text: transcript.preview,
                            complete: state.resultIsComplete(transcriptComplete:transcript.permitsAutomaticInsertion), level: level,
                            duration: ProcessInfo.processInfo.systemUptime - startedAt, message: message,
                            showPreview:settings.showPreview)
    let snapshot=diagnostics.snapshot(phase:state.phase)
    if state.terminal {
      // Keep the Helper owner reserved until hardware teardown + conversion
      // drain complete. A following session cannot overlap the old microphone.
      audio.stop { _ in DispatchQueue.main.async { self.update(value,snapshot) } }
    } else { DispatchQueue.main.async { self.update(value,snapshot) } }
  }
  private func fail(_ message:String,reason:VoiceDiagnosticFailure) {
    guard !stopped else { return }
    let cutoff=audio.stop { _ in }; diagnostics.record(.captureCutoff,at:cutoff)
    diagnostics.fail(reason,at:ProcessInfo.processInfo.systemUptime)
    reducer.fail(); publish(message); cleanup()
  }
  private func cleanup() {
    stopped = true; timer?.cancel(); timer = nil
    webSocket?.cancel(with: .goingAway, reason: nil); urlSession?.invalidateAndCancel()
  }
  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                  didOpenWithProtocol protocol: String?) {
    queue.async { guard !self.stopped else { return }
      self.connectedAt = ProcessInfo.processInfo.systemUptime
      self.diagnostics.record(.webSocketOpened,at:self.connectedAt!)
      do {
        let request=self.settings.model.isDoubao ? try DoubaoProtocol.run(task:self.identity.task,settings:self.settings) : try QwenProtocol.run(task:self.identity.task,settings:self.settings)
        try self.send(request,configuration:true)
      } catch { self.fail("识别请求编码失败。",reason:.transportSend) }
    }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil) // Never forward credentials across redirects.
  }
}
