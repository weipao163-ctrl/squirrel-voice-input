import Foundation

public enum VoiceEventDecision: Equatable {
  case received, taskFinished, taskFailed, ignoredTerminal
}

// Actual Helper event reduction, independent of URLSession/audio/AppKit. Tests
// feed complete JSON packets through this SAME implementation, not a parallel
// mock state machine. The caller still owns transport and physical microphone.
public struct VoiceEventReducer {
  public private(set) var state: VoiceState
  public private(set) var transcript = TranscriptAccumulator()
  public private(set) var cloudFailureMessage: String?
  private var doubaoSequence:Int64?
  private var doubaoPacket:Data?
  public init(identity: VoiceIdentity, settings: VoiceSettings) {
    state = VoiceState(identity:identity,settings:settings)
  }
  public mutating func release(at uptime: TimeInterval) { state.release(at:uptime) }
  public mutating func stop(at uptime:TimeInterval,cause:VoiceStopCause) {
    if cause == .targetInvalidated { state.invalidateTarget(at:uptime) }
    else { state.release(at:uptime) }
  }
  public mutating func cancel() { state.cancel() }
  public mutating func fail() { state.fail() }
  public mutating func sendFinish(queueEmpty: Bool) -> Bool { state.sendFinish(queueEmpty:queueEmpty) }
  public mutating func invalidateTarget(at uptime: TimeInterval) { state.invalidateTarget(at:uptime) }
  public mutating func attemptCommit(validated: Bool) -> Bool { state.attemptCommit(validated:validated) }
  public mutating func configurationSent() {
    // SAUC sends audio after its full-client request, with no task-started
    // control event. Qwen still waits for the server's task-started event.
    if state.settings.model.isDoubao { state.started() }
  }

  public mutating func receive(_ data: Data) throws -> VoiceEventDecision {
    guard !state.terminal else { return .ignoredTerminal }
    do {
      if state.settings.model.isDoubao {
        let value=try DoubaoProtocol.response(data)
        if let code=value.errorCode {
          cloudFailureMessage=DoubaoProtocol.failureMessage(code); state.fail(); return .taskFailed
        }
        if let sequence=value.sequence {
          let order=abs(Int64(sequence))
          if let previous=doubaoSequence, order <= previous {
            if order == previous && data == doubaoPacket { return .received }
            throw SettingsError.invalid("豆包结果序号倒退或重复序号内容冲突。")
          }
          doubaoSequence=order; doubaoPacket=data
        }
        state.started() // A valid response also proves that the request was accepted.
        if let text=value.text {
          try transcript.result(["output":["sentence":["sentence_id":1,"text":text,"sentence_end":value.final]]])
        }
        if value.final {
          // No final full-text snapshot: do not promote the last partial draft.
          state.finished(complete:value.text != nil && transcript.permitsAutomaticInsertion)
          return .taskFinished
        }
        return .received
      }
      let (event,payload) = try QwenProtocol.event(data,task:state.identity.task)
      switch event {
      case "task-started":
        state.started() // Duplicate starts cannot re-arm a released capture.
      case "result-generated":
        guard state.taskStarted else { throw SettingsError.invalid("识别结果早于 task-started。") }
        try transcript.result(payload)
      case "task-finished":
        guard state.taskStarted else { throw SettingsError.invalid("task-finished 早于 task-started。") }
        transcript.recordUsage(payload)
        state.finished(complete:transcript.permitsAutomaticInsertion)
        return .taskFinished
      case "task-failed":
        state.fail(); return .taskFailed
      default:
        throw SettingsError.invalid("未知云端事件。") // Parser also rejects this.
      }
      return .received
    } catch {
      state.fail() // No later valid packet may restore automatic insertion.
      throw error
    }
  }
}
