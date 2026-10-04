import Foundation

public enum VoiceDiagnosticMode: String, Codable, Sendable { case production, guiTest }
public enum VoiceDiagnosticOrigin: String, Codable, Sendable { case physicalPress, helperStart }
public enum VoiceDiagnosticFailure: String, Codable, Sendable {
  case setup, audio, audioQueue, connectionTimeout, taskStartTimeout, finalizationTimeout
  case ownerLost, transportSend, protocolOrConnection, cloudTask
  public var title: String {
    switch self {
    case .setup: return "配置/凭据/启动失败"
    case .audio: return "采音/设备/转换失败"
    case .audioQueue: return "待发送音频队列超限"
    case .connectionTimeout: return "连接超时"
    case .taskStartTimeout: return "任务启动超时"
    case .finalizationTimeout: return "停止后收尾超时"
    case .ownerLost: return "所有者租约失效"
    case .transportSend: return "发送失败"
    case .protocolOrConnection: return "连接或协议失败（未推断账户原因）"
    case .cloudTask: return "云任务失败（未推断鉴权或额度原因）"
    }
  }
}
public enum VoiceDiagnosticStage: String, Codable, CaseIterable, Sendable {
  case helperAccepted, captureStarted, firstPCM, webSocketOpened, taskStarted, firstTranscript
  case stopRequested, stopReceived, captureCutoff, tailDrained, finishRequested, taskFinished
  case cancelled, failed, frontendDecision
  public var title: String {
    switch self {
    case .helperAccepted: return "Helper 接受会话"
    case .captureStarted: return "采音引擎启动返回"
    case .firstPCM: return "首批转换 PCM 进入会话队列"
    case .webSocketOpened: return "WebSocket 已打开"
    case .taskStarted: return "有效 task-started"
    case .firstTranscript: return "首条有效识别文本（仅记时间）"
    case .stopRequested: return "停止请求的原始时间"
    case .stopReceived: return "Helper 收到停止请求"
    case .captureCutoff: return "关闭新样本入口"
    case .tailDrained: return "转换尾部确认排空"
    case .finishRequested: return "finish-task 发送请求"
    case .taskFinished: return "有效 task-finished"
    case .cancelled: return "取消"
    case .failed: return "失败"
    case .frontendDecision: return "前端处理回执"
    }
  }
}
public enum VoiceDeliveryDecision: String, Codable, Sendable {
  case nativeCallReturned, reviewRequired
  public var title: String {
    switch self {
    case .nativeCallReturned: return "原生 insertText 调用已返回；不是宿主已写入的确认"
    case .reviewRequired: return "前端拒绝自动插入；仅作待确认草稿"
    }
  }
}
public struct VoiceDeliveryReceipt: Codable, Equatable, Sendable {
  public var identity: VoiceIdentity
  public var decision: VoiceDeliveryDecision
  public var uptime: TimeInterval
  public init(identity: VoiceIdentity, decision: VoiceDeliveryDecision, uptime: TimeInterval) {
    self.identity = identity; self.decision = decision; self.uptime = uptime
  }
  public func validate(receivedAt: TimeInterval) -> Bool {
    VoiceDiagnosticTimeline.validClock(uptime, receivedAt:receivedAt)
  }
}
public struct VoiceDiagnosticSnapshot: Codable, Equatable, Sendable {
  public var identity: VoiceIdentity
  public var revision: UInt64?
  public var mode: VoiceDiagnosticMode
  public var origin: VoiceDiagnosticOrigin
  public var referenceUptime: TimeInterval
  public var phase: VoicePhase
  public var stages: [VoiceDiagnosticStage: TimeInterval]
  public var failure: VoiceDiagnosticFailure?
  public var stopCause: VoiceStopCause?
  public var delivery: VoiceDeliveryDecision?
  public var isValid: Bool {
    referenceUptime.isFinite && referenceUptime >= 0 &&
      stages.count <= VoiceDiagnosticStage.allCases.count &&
      stages.values.allSatisfy { $0.isFinite && (0...900).contains($0) } &&
      (failure == nil || stages[.failed] != nil) &&
      (phase != .ready || failure == nil) &&
      (stopCause == nil || stages[.stopRequested] != nil) &&
      ((stages[.frontendDecision] == nil) == (delivery == nil)) &&
      (delivery == nil || phase == .ready && mode == .production && stages[.taskFinished] != nil)
  }
  public func milliseconds(from: VoiceDiagnosticStage, to: VoiceDiagnosticStage) -> Double? {
    guard isValid, let start=stages[from], let end=stages[to], end >= start else { return nil }
    return (end-start)*1000
  }
  public var startToCaptureMilliseconds: Double? {
    guard isValid, let value=stages[.captureStarted] else { return nil }
    return value*1000
  }
}

// Closed enum + numeric metadata only. No API accepts a Key, endpoint, device
// name, transcript, application/document identity, raw error or audio buffer.
public struct VoiceDiagnosticTimeline: Sendable {
  private var value: VoiceDiagnosticSnapshot
  private var cleared = false
  public init(identity:VoiceIdentity, revision:UInt64?, mode:VoiceDiagnosticMode,
              origin:VoiceDiagnosticOrigin, referenceUptime:TimeInterval) {
    value=VoiceDiagnosticSnapshot(identity:identity,revision:revision,mode:mode,origin:origin,
        referenceUptime:referenceUptime,phase:.preparing,stages:[:])
  }
  public static func validClock(_ uptime:TimeInterval, receivedAt:TimeInterval) -> Bool {
    uptime.isFinite && receivedAt.isFinite && uptime >= 0 && receivedAt >= 0 &&
      uptime <= receivedAt+0.25 && receivedAt-uptime <= 360
  }
  @discardableResult public mutating func record(_ stage:VoiceDiagnosticStage, at uptime:TimeInterval) -> Bool {
    let offset=uptime-value.referenceUptime
    guard !cleared, value.isValid, offset.isFinite, (0...900).contains(offset), value.stages[stage] == nil else { return false }
    value.stages[stage]=offset; return true
  }
  public mutating func requestStop(cause:VoiceStopCause, at uptime:TimeInterval, receivedAt:TimeInterval) {
    if record(.stopRequested,at:uptime) { value.stopCause=cause }
    record(.stopReceived,at:receivedAt)
  }
  public mutating func fail(_ reason:VoiceDiagnosticFailure, at uptime:TimeInterval) {
    if record(.failed,at:uptime) { value.failure=reason }
  }
  public func snapshot(phase:VoicePhase) -> VoiceDiagnosticSnapshot {
    var copy=value; copy.phase=phase; return copy
  }
  public mutating func clear() { value.stages=[:]; value.failure=nil; value.stopCause=nil; value.delivery=nil; cleared=true }
}

// One accepted session at a time, one latest in-memory record. Clearing an
// active session suppresses queued updates; a new accepted session resets it.
public struct VoiceDiagnosticStore: Sendable {
  public private(set) var latest: VoiceDiagnosticSnapshot?
  private var active: VoiceIdentity?
  private var suppressed: VoiceIdentity?
  public init() {}
  public mutating func begin(_ identity:VoiceIdentity) { active=identity; suppressed=nil; latest=nil }
  @discardableResult public mutating func accept(_ value:VoiceDiagnosticSnapshot) -> Bool {
    guard active == value.identity, suppressed != value.identity, value.isValid else { return false }
    latest=value; return true
  }
  public mutating func end(_ identity:VoiceIdentity) { if active == identity { active=nil } }
  public mutating func clear() { suppressed=active; latest=nil }
  @discardableResult public mutating func delivery(_ receipt:VoiceDeliveryReceipt, receivedAt:TimeInterval) -> Bool {
    guard receipt.validate(receivedAt:receivedAt), var value=latest, value.identity == receipt.identity,
          value.mode == .production, value.phase == .ready, value.delivery == nil,
          let finished=value.stages[.taskFinished] else { return false }
    let offset=receipt.uptime-value.referenceUptime
    guard offset.isFinite, (finished...900).contains(offset) else { return false }
    value.stages[.frontendDecision]=offset; value.delivery=receipt.decision
    guard value.isValid else { return false }; latest=value; return true
  }
}
