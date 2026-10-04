import AVFoundation
import AudioToolbox
import CoreAudio
import EnhancementCore

struct InputDevice: Identifiable, Equatable {
  var id: String
  var name: String
  var device: AudioDeviceID
  static func available() -> [InputDevice] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
      var input = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
          mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
      var streams: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(id, &input, 0, nil, &streams) == noErr, streams > 0 else { return nil }
      func string(_ selector: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?; var bytes = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &bytes, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
      }
      guard let uid = string(kAudioDevicePropertyDeviceUID), let name = string(kAudioObjectPropertyName) else { return nil }
      return InputDevice(id: uid, name: name, device: id)
    }
  }
}

final class AudioCapture {
  private let engine = AVAudioEngine()
  private let lock = NSLock()
  private let convertQueue = DispatchQueue(label: "org.rime.audio.convert")
  private let controlQueue = DispatchQueue(label: "org.rime.audio.control")
  private var accepting = false
  private var tapInstalled = false
  private var pendingFrames: UInt64 = 0
  private var pendingBytes: UInt64 = 0
  private var converter: PCMBufferConverter?
  private let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                     channels: 1, interleaved: true)!
  private var onPCM: ((Data, Double) -> Void)?
  private var onFailure: ((String) -> Void)?
  private var observer: NSObjectProtocol?
  private var drainCycle = PCMDrainLifecycle() // Protected by lock.
  private var drainCompletions: [(Bool) -> Void] = []
  private var cutoffUptime:TimeInterval? // Protected by lock; first cutoff wins.
  private func cutoffLocked() -> TimeInterval {
    accepting=false
    if cutoffUptime == nil { cutoffUptime=ProcessInfo.processInfo.systemUptime }
    return cutoffUptime!
  }

  func start(uid: String?, pcm: @escaping (Data, Double) -> Void, failure: @escaping (String) -> Void) throws {
    try controlQueue.sync { try startOnControlQueue(uid:uid,pcm:pcm,failure:failure) }
  }
  private func startOnControlQueue(uid:String?,pcm:@escaping(Data,Double)->Void,failure:@escaping(String)->Void) throws {
    lock.lock(); let alreadyStopped = drainCycle.requested; lock.unlock()
    guard !alreadyStopped else { throw SettingsError.invalid("本次采音已停止；必须新建按压会话。") }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      throw SettingsError.invalid("麦克风未授权；请在设置中主动授权。")
    }
    let input = engine.inputNode
    if let uid {
      guard let selected = InputDevice.available().first(where: { $0.id == uid }), let unit = input.audioUnit else {
        throw SettingsError.invalid("指定麦克风已不可用。")
      }
      var id = selected.device
      guard AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                                0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
        throw SettingsError.invalid("无法实际切换到指定设备；未回退到其他设备。")
      }
    }
    let source = input.outputFormat(forBus: 0)
    let initialDevice = Self.deviceID(input.audioUnit)
    guard source.sampleRate.isFinite, source.sampleRate > 0, source.channelCount > 0,
          source.channelCount <= 64 else {
      throw SettingsError.invalid("输入设备格式不可转换为 16 kHz 单声道 PCM。")
    }
    self.converter = try PCMBufferConverter(source:source,output:format,pcm:pcm,failure: { [weak self] message in
      guard let self else { return }; self.lock.lock(); _ = self.cutoffLocked(); self.lock.unlock(); failure(message)
    })
    lock.lock()
    guard !drainCycle.requested else { lock.unlock(); throw SettingsError.invalid("本次按压已释放；没有安装采音回调。") }
    accepting = true; tapInstalled = true; lock.unlock()
    input.installTap(onBus: 0, bufferSize: 1024, format: source) { [weak self] buffer, _ in
      guard let self else { return }
      self.lock.lock()
      guard self.accepting else { self.lock.unlock(); return }
      guard buffer.frameLength > 0 else { self.lock.unlock(); return } // No audio, not a fake sample.
      let (frameBytes, overflow1) = UInt64(buffer.frameLength).multipliedReportingOverflow(by:
          UInt64(buffer.format.streamDescription.pointee.mBytesPerFrame))
      let (bytes, overflow2) = frameBytes.multipliedReportingOverflow(by:
          UInt64(buffer.format.isInterleaved ? 1 : buffer.format.channelCount))
      guard !overflow1, !overflow2, bytes > 0, bytes <= 64 * 1024 * 1024,
            Double(self.pendingFrames) + Double(buffer.frameLength) <= source.sampleRate * 10,
            self.pendingBytes <= 64 * 1024 * 1024 - bytes else {
        _ = self.cutoffLocked(); self.lock.unlock(); failure("原始音频转换队列超限，已保护停止。"); return
      }
      guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
        _ = self.cutoffLocked(); self.lock.unlock(); failure("音频缓冲分配失败，已保护停止。"); return
      }
      copy.frameLength = buffer.frameLength
      let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
      let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
      guard src.count == dst.count, !src.isEmpty else {
        _ = self.cutoffLocked(); self.lock.unlock(); failure("输入音频缓冲布局不一致，已保护停止。"); return
      }
      for index in 0..<src.count {
        guard src[index].mDataByteSize > 0, src[index].mDataByteSize <= dst[index].mDataByteSize,
              let s = src[index].mData, let d = dst[index].mData else {
          _ = self.cutoffLocked(); self.lock.unlock(); failure("输入音频缓冲无效或超出容量，已保护停止。"); return
        }
        memcpy(d,s,Int(src[index].mDataByteSize))
      }
      // Enqueue while locked: stop's drain marker follows every pre-cutoff buffer.
      self.pendingFrames += UInt64(copy.frameLength); self.pendingBytes += bytes
      self.convertQueue.async {
        _ = self.convert(copy)
        self.lock.lock(); self.pendingFrames -= UInt64(copy.frameLength); self.pendingBytes -= bytes; self.lock.unlock()
      }
      self.lock.unlock()
    }
    observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                      object: engine, queue: nil) { [weak self] _ in
      // Selecting a device/startup also emits configuration notifications.
      // Inspect the settled engine on its control queue, rather than treating
      // every notification as a physical route loss (which stopped at 0.1 s).
      self?.controlQueue.async { [weak self] in
        guard let self else { return }
        self.lock.lock()
        let live = self.accepting && !self.drainCycle.requested
        self.lock.unlock()
        guard live else { return }
        let changedDevice = Self.deviceID(input.audioUnit) != initialDevice
        let changedFormat = !input.outputFormat(forBus:0).isEqual(source)
        guard AudioRouteChangePolicy.shouldStop(accepting:live,stopRequested:false,
          engineRunning:self.engine.isRunning,deviceChanged:changedDevice,formatChanged:changedFormat) else { return }
        self.lock.lock(); _ = self.cutoffLocked(); self.lock.unlock()
        failure("麦克风设备或格式确实发生变化，已停止采音。请重新选择设备后再按住热键。")
      }
    }
    lock.lock(); let ended = drainCycle.requested; lock.unlock()
    guard !ended else { throw SettingsError.invalid("启动期间按压已结束；没有启动麦克风。") }
    do { try engine.start() } catch { stop { _ in }; throw SettingsError.invalid("麦克风启动失败。") }
  }
  private func convert(_ buffer:AVAudioPCMBuffer?) -> Bool {
    guard let converter else { return buffer == nil }
    return converter.convert(buffer)
  }
  private static func deviceID(_ unit:AudioUnit?) -> AudioDeviceID? {
    guard let unit else { return nil }
    var id=AudioDeviceID(0); var size=UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioUnitGetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,
      0,&id,&size) == noErr else { return nil }
    return id
  }
  @discardableResult func stop(completion: @escaping (Bool) -> Void) -> TimeInterval {
    lock.lock()
    let cutoff=cutoffLocked()
    let drain = drainCycle.request()
    if case .finished(let result) = drain {
      lock.unlock(); convertQueue.async { completion(result) }; return cutoff
    }
    drainCompletions.append(completion)
    let firstDrain = drain == .begin
    lock.unlock()
    guard firstDrain else { return cutoff }
    // The synchronous part is ONLY the sample admission cutoff. Slow engine
    // stop/removeTap and startup serialization never run on the keyboard queue.
    controlQueue.async {
      if let observer=self.observer { NotificationCenter.default.removeObserver(observer); self.observer=nil }
      if self.tapInstalled {
        self.engine.inputNode.removeTap(onBus:0); self.engine.stop(); self.tapInstalled=false
      }
      // Startup/control teardown precede the drain marker; every accepted tap
      // enqueue was completed while holding the same short admission lock.
      self.convertQueue.async {
        let result=self.convert(nil)
        self.lock.lock(); self.drainCycle.finish(result)
        let callbacks=self.drainCompletions; self.drainCompletions=[]; self.lock.unlock()
        for callback in callbacks { callback(result) }
      }
    }
    return cutoff
  }
  deinit { engine.stop(); if let observer { NotificationCenter.default.removeObserver(observer) } }
}
