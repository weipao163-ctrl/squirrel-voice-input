import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

public struct RecognitionSentence: Equatable {
  public var text: String
  public var final: Bool
}

public struct TranscriptAccumulator {
  public private(set) var sentences: [Int: RecognitionSentence] = [:]
  public private(set) var usage: [String: Double]?
  public private(set) var protocolValid = true
  public init() {}
  // Darwin provides the unambiguous CFBoolean identity. The Windows Swift SDK
  // does not expose CoreFoundation as an importable module. JSONSerialization
  // preserves NSNumber's JSON boolean/number distinction there; do NOT use
  // `as? Bool`, numeric equality to 0/1, or objCType (Int8 can also be "c").
  private static func isBoolean(_ number: NSNumber) -> Bool {
    #if canImport(CoreFoundation)
    return CFGetTypeID(number) == CFBooleanGetTypeID()
    #else
    guard let json = try? JSONSerialization.data(withJSONObject: number, options: [.fragmentsAllowed]) else { return false }
    return json == Data("true".utf8) || json == Data("false".utf8)
    #endif
  }
  public mutating func recordUsage(_ payload: [String: Any]) {
    if let u = payload["usage"] as? [String: Any] {
      let keys:Set<String> = ["duration","input_tokens","output_tokens","total_tokens"]
      usage = u.filter { keys.contains($0.key) }.compactMapValues {
        guard let number = $0 as? NSNumber, !Self.isBoolean(number),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
      }
    }
  }
  public mutating func result(_ payload: [String: Any]) throws {
    do { try accept(payload) }
    catch { protocolValid = false; throw error }
  }
  private static func boolean(_ value:Any?) -> Bool? {
    guard let number = value as? NSNumber, isBoolean(number) else { return nil }
    return number.boolValue
  }
  private static func sentenceID(_ value:Any?) -> Int? {
    guard let number = value as? NSNumber, !isBoolean(number),
          number.doubleValue.isFinite, (1...1024).contains(number.doubleValue),
          number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
    return number.intValue
  }
  private mutating func accept(_ payload:[String:Any]) throws {
    // Consume one documented canonical sentence ONLY; never recurse into words/stash.
    recordUsage(payload)
    guard let output = payload["output"] as? [String: Any],
          let sentence = output["sentence"] as? [String: Any] else { throw SettingsError.invalid("云端结果缺少 sentence。") }
    if let heartbeat = sentence["heartbeat"] {
      guard let value = Self.boolean(heartbeat) else { throw SettingsError.invalid("heartbeat 不是布尔值。") }
      if value { return }
    }
    guard let id = Self.sentenceID(sentence["sentence_id"]),
          let text = sentence["text"] as? String, text.utf8.count <= 64 * 1024,
          let final = Self.boolean(sentence["sentence_end"]) else { throw SettingsError.invalid("云端 sentence 字段非法。") }
    if let before = sentences[id], before.final {
      if !final { return } // An old interim cannot downgrade a final.
      guard before.text == text else { throw SettingsError.invalid("同一句出现矛盾 final；保留原草稿，禁止自动上屏。") }
      return // Identical final is idempotent; usage above remains a snapshot.
    }
    guard sentences[id] != nil || sentences.count < 1024 else { throw SettingsError.invalid("云端句子数量超限。") }
    let total = preview.utf8.count - (sentences[id]?.text.utf8.count ?? 0) + text.utf8.count
    guard total <= 128 * 1024 else { throw SettingsError.invalid("云端文本超限。") }
    sentences[id] = RecognitionSentence(text: text, final: final)
  }
  public var preview: String { sentences.keys.sorted().compactMap { sentences[$0]?.text }.joined() }
  public var isComplete: Bool {
    // The documented normal IDs increment from 1. A missing sentence is not
    // silently dropped merely because all received sentences are final.
    protocolValid && !sentences.isEmpty && sentences.values.allSatisfy(\.final) &&
      sentences.keys.sorted() == Array(1...sentences.count)
  }
  public var permitsAutomaticInsertion: Bool {
    isComplete && !preview.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty &&
      !preview.unicodeScalars.contains { CharacterSet.controlCharacters.union(.newlines).contains($0) }
  }
}

public enum QwenProtocol {
  public static func run(task: UUID, settings: VoiceSettings = VoiceSettings()) throws -> Data {
    guard !settings.model.isDoubao else { throw SettingsError.invalid("豆包模型应使用豆包二进制协议。") }
    var parameters: [String: Any] = ["format": "pcm", "sample_rate": 16000]
    if settings.model == .message {
      // Message defaults to final-only results. Request partials for the same
      // live preview flow; polishing is performed by this ASR model itself.
      parameters["intermediate_result_enabled"] = true
      parameters["disfluency_removal_enabled"] = settings.nativePolish
    }
    return try JSONSerialization.data(withJSONObject: [
      "header": ["action": "run-task", "task_id": task.uuidString.lowercased(), "streaming": "duplex"],
      "payload": ["task_group": "audio", "task": "asr", "function": "recognition",
                  "model": settings.model.rawValue, "parameters": parameters,
                  "input": [:]]
    ])
  }
  public static func finish(task: UUID) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "header": ["action": "finish-task", "task_id": task.uuidString.lowercased(), "streaming": "duplex"],
      "payload": ["input": [:]]
    ])
  }
  public static func event(_ data: Data, task: UUID) throws -> (String, [String: Any]) {
    guard data.count <= 256 * 1024,
          let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let header = value["header"] as? [String: Any],
          let id = header["task_id"] as? String, UUID(uuidString: id) == task,
          let event = header["event"] as? String else { throw SettingsError.invalid("云端消息大小、格式或 task_id 无效。") }
    guard ["task-started", "result-generated", "task-finished", "task-failed"].contains(event) else {
      throw SettingsError.invalid("未知云端事件。")
    }
    guard let payload = value["payload"] as? [String: Any] else {
      throw SettingsError.invalid("云端 payload 不是对象。")
    }
    return (event, payload)
  }
}

public struct PCMQueue {
  public let limit: Int
  private var buffer = Data()
  public init(seconds: Int) { limit = max(1, min(10, seconds)) * 16000 * 2 }
  public mutating func append(_ data: Data) throws {
    guard data.count % 2 == 0, buffer.count + data.count <= limit else {
      throw SettingsError.invalid("音频待发送队列超限，已保护停止。")
    }
    buffer.append(data)
  }
  public mutating func next(final: Bool) -> Data? {
    let length = min(3200, buffer.count) // 100 ms, S16LE, mono, 16 kHz.
    guard length > 0, final || length == 3200 else { return nil }
    let chunk = Data(buffer.prefix(length)); buffer.removeFirst(length); return chunk
  }
  public var isEmpty: Bool { buffer.isEmpty }
  public var count: Int { buffer.count }
}
