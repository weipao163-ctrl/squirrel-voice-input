import Foundation

// Portable decisions used by the actual AVAudioConverter adapter. These are
// converter statuses, not a resampler and not proof of microphone behavior.
public enum PCMConversionStatus: Sendable { case haveData, inputRanDry, endOfStream, error, unknown }
public enum PCMConversionStep: Equatable, Sendable { case again, complete }

public enum PCMDrainRequest: Equatable, Sendable { case begin, join, finished(Bool) }
public struct PCMDrainLifecycle: Sendable {
  public private(set) var requested = false
  public private(set) var result: Bool?
  public init() {}
  public mutating func request() -> PCMDrainRequest {
    if let result { return .finished(result) }
    if requested { return .join }
    requested = true; return .begin
  }
  @discardableResult public mutating func finish(_ value: Bool) -> Bool {
    guard requested, result == nil else { return false }
    result = value; return true
  }
}

public struct PCMConversionProgress: Sendable {
  public let draining: Bool
  public private(set) var calls = 0
  public private(set) var complete = false
  public private(set) var failed = false
  public static let maximumCalls = 16
  public init(draining: Bool) { self.draining = draining }

  public mutating func observe(_ status: PCMConversionStatus, frames: UInt32,
                               capacity: UInt32, inputSupplied: Bool) throws -> PCMConversionStep {
    guard !complete, !failed, calls < Self.maximumCalls, capacity > 0, frames <= capacity else {
      failed = true
      throw SettingsError.invalid("PCM 转换状态或缓冲长度无效；仅保留草稿。")
    }
    calls += 1
    switch status {
    case .error, .unknown:
      failed = true
      throw SettingsError.invalid("PCM 转换失败或返回未知状态；仅保留草稿。")
    case .endOfStream:
      guard draining, frames == 0 else {
        failed = true
        throw SettingsError.invalid("PCM 转换提前结束或结束状态带有数据；仅保留草稿。")
      }
      complete = true; return .complete
    case .inputRanDry:
      if !draining {
        guard inputSupplied else {
          failed = true
          throw SettingsError.invalid("PCM 转换没有接收本次输入；仅保留草稿。")
        }
        complete = true; return .complete
      }
    case .haveData:
      // Real macOS AVAudioConverter can return haveData with a positive
      // partial buffer, particularly the resampler tail. FrameLength is the
      // authoritative payload size; keep draining until explicit endOfStream.
      guard frames > 0 else {
        failed = true
        throw SettingsError.invalid("PCM 转换输出与状态不一致；仅保留草稿。")
      }
    }
    // No output is NOT end-of-stream. A bounded retry is conversion work on
    // already accepted audio, never a timer or permission to collect more.
    guard calls < Self.maximumCalls else {
      failed = true
      throw SettingsError.invalid("PCM 转换未能在有界次数内排空；仅保留草稿。")
    }
    return .again
  }

  public static func outputCapacity(inputFrames: UInt32, sampleRate: Double) throws -> UInt32 {
    guard sampleRate.isFinite, sampleRate > 0, inputFrames > 0 else {
      throw SettingsError.invalid("输入音频帧数或采样率无效。")
    }
    let value = ceil(Double(inputFrames) * 16000 / sampleRate) + 128
    guard value.isFinite, value >= 128, value <= Double(UInt32.max) else {
      throw SettingsError.invalid("PCM 输出缓冲容量超出范围。")
    }
    return UInt32(value)
  }
}
