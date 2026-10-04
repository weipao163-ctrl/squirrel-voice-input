import Foundation

public enum VoicePhase: String, Codable, Sendable {
  case preparing, recording, finalizing, ready, review, cancelled, failed
  public var title:String {
    switch self {
    case .preparing: return "正在启动"
    case .recording: return "按住录音"
    case .finalizing: return "等待整段最终结果"
    case .ready: return "完整结果已就绪"
    case .review: return "已保留草稿"
    case .cancelled: return "已取消"
    case .failed: return "失败，未自动上屏"
    }
  }
}
public struct VoiceIdentity: Codable, Equatable, Sendable {
  public var session: UUID
  public var generation: UInt64
  public var task: UUID
  public init(generation: UInt64) { self.session = UUID(); self.generation = generation; self.task = UUID() }
}

// NSEvent.timestamp and systemUptime are host boot-relative monotonic seconds.
// Carry the physical release time across IPC: a delayed callback must NOT extend
// the user-selected finalization deadline. This contains no audio or target data.
public enum VoiceStopCause: String, Codable, Sendable {
  case keyReleased, targetInvalidated, maximumDuration, guiReleased, unspecified
  public var title:String {
    switch self {
    case .keyReleased: return "生产触发键真实松开"
    case .targetInvalidated: return "输入目标失效（不是物理松键）"
    case .maximumDuration: return "达到录音上限（不是物理松键）"
    case .guiReleased: return "设置页按住测试释放"
    case .unspecified: return "旧消息未标注停止原因"
    }
  }
}
public struct VoiceRelease: Codable, Equatable {
  public var identity: VoiceIdentity
  public var uptime: TimeInterval
  public var cause:VoiceStopCause?
  public init(identity: VoiceIdentity, uptime: TimeInterval, cause:VoiceStopCause = .keyReleased) {
    self.identity = identity; self.uptime = uptime; self.cause=cause
  }
  public func validate(receivedAt: TimeInterval) throws {
    guard uptime.isFinite, uptime >= 0, uptime <= receivedAt + 0.25,
          receivedAt - uptime <= 360 else {
      throw SettingsError.invalid("释放事件时间无效；未延长收尾时限。")
    }
  }
}

public struct VoiceState {
  public let identity: VoiceIdentity
  public let settings: VoiceSettings
  public private(set) var phase: VoicePhase = .preparing
  public private(set) var physicalHeld = true
  public private(set) var capturePermitted = true
  public private(set) var taskStarted = false
  public private(set) var finishSent = false
  public private(set) var commitAttempted = false
  public private(set) var targetValid = true
  public private(set) var releasedAt: TimeInterval?
  public init(identity: VoiceIdentity, settings: VoiceSettings) { self.identity = identity; self.settings = settings }
  public mutating func started() {
    guard !terminal, !taskStarted else { return }; taskStarted = true
    phase = physicalHeld ? .recording : .finalizing
  }
  public mutating func release(at time: TimeInterval) {
    guard !terminal, physicalHeld else { return }
    physicalHeld = false; capturePermitted = false; releasedAt = time; phase = .finalizing
  }
  public mutating func invalidateTarget(at time: TimeInterval) {
    targetValid = false; release(at: time)
  }
  public mutating func sendFinish(queueEmpty: Bool) -> Bool {
    guard !terminal, taskStarted, !physicalHeld, queueEmpty, !finishSent else { return false }
    finishSent = true; return true
  }
  public mutating func finished(complete: Bool) {
    guard !terminal else { return }
    capturePermitted = false
    phase = !physicalHeld && finishSent && complete && targetValid ? .ready : .review
    physicalHeld = false
  }
  public mutating func cancel() { capturePermitted = false; physicalHeld = false; phase = .cancelled; targetValid = false }
  public mutating func fail() { capturePermitted = false; physicalHeld = false; phase = .failed; targetValid = false }
  public mutating func attemptCommit(validated: Bool) -> Bool {
    guard phase == .ready, validated, !commitAttempted else { if phase == .ready { phase = .review }; return false }
    commitAttempted = true // BEFORE native insertText; unknown outcome must not retry.
    return true
  }
  public var terminal: Bool { [.cancelled, .failed, .ready, .review].contains(phase) }
  // Sentence-final alone does NOT mean that the complete recording finished.
  // Early server termination/failed capture still yields unconfirmed text.
  public func resultIsComplete(transcriptComplete:Bool) -> Bool {
    [.ready,.review].contains(phase) && taskStarted && finishSent && !physicalHeld && transcriptComplete
  }
}
