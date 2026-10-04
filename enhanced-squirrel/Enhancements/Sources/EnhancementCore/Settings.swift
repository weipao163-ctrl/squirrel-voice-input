import Foundation

public enum SettingsError: Error, LocalizedError {
  case invalid(String)
  public var errorDescription: String? {
    if case .invalid(let text) = self { return text }; return nil
  }
}

public struct LetterProfile: Codable, Equatable {
  public var enabled = false
  public var keys = "asdfghjkl"
  public var pageSize = 9
  public var hideCandidates = true
  public var useDefaultAppearance = true
  public var appearance = CandidateAppearance()
  public init() {}
  private enum CodingKeys:String,CodingKey { case enabled, keys, pageSize, hideCandidates, useDefaultAppearance, appearance }
  public init(from decoder:Decoder) throws {
    let values = try decoder.container(keyedBy:CodingKeys.self)
    enabled = try values.decodeIfPresent(Bool.self,forKey:.enabled) ?? false
    keys = try values.decodeIfPresent(String.self,forKey:.keys) ?? "asdfghjkl"
    pageSize = try values.decodeIfPresent(Int.self,forKey:.pageSize) ?? 9
    hideCandidates = try values.decodeIfPresent(Bool.self,forKey:.hideCandidates) ?? true
    // Earlier profiles explicitly used the enhancement appearance. Preserve it
    // when reading them; only newly created profiles inherit the IME default.
    useDefaultAppearance = try values.decodeIfPresent(Bool.self,forKey:.useDefaultAppearance) ?? false
    // Old saved bindings are never silently replaced with the new default.
    appearance = try values.decodeIfPresent(CandidateAppearance.self,forKey:.appearance) ?? CandidateAppearance()
  }
  public func validate() throws {
    guard (1...9).contains(pageSize), keys.utf8.count == pageSize,
          keys.utf8.allSatisfy({ (97...122).contains($0) }), Set(keys).count == pageSize else {
      throw SettingsError.invalid("选词键必须是 1～9 个不重复小写字母，并与页大小相等。")
    }
    try appearance.validate()
  }
}

public enum CandidateLayout:String,Codable,CaseIterable { case stacked, linear }
public struct CandidateAppearance:Codable,Equatable {
  public var layout:CandidateLayout = .stacked // vertical LIST, not rotated text
  public var fontFace = "PingFangSC-Regular"
  public var fontPoint = 24
  public var labelFontPoint = 16
  public var lineSpacing = 5
  public var candidateRGB = "#0082E5"
  public var highlightedRGB = "#FF0000"
  public var backgroundRGB = "#FFFFFF"
  public var borderRGB = "#A8C4E0"
  public init() {}
  public func validate() throws {
    guard (10...48).contains(fontPoint), (10...32).contains(labelFontPoint), (0...24).contains(lineSpacing),
          !fontFace.trimmingCharacters(in:.whitespaces).isEmpty, fontFace.utf8.count <= 128,
          !fontFace.unicodeScalars.contains(where:{CharacterSet.controlCharacters.union(.newlines).contains($0)}),
          [candidateRGB,highlightedRGB,backgroundRGB,borderRGB].allSatisfy({$0.range(of:"^#[A-Fa-f0-9]{6}$",options:.regularExpression) != nil}) else {
      throw SettingsError.invalid("字体、字号、行距或 RGB 配色无效。")
    }
  }
}

public enum Region: String, Codable, CaseIterable {
  case beijing = "cn-beijing", singapore = "ap-southeast-1"
}

public struct TriggerBinding: Codable, Equatable {
  // Physical macOS keycodes, not aggregate modifier flags. Both sides are distinct.
  public static let modifierCodes:Set<UInt16> = [54,55,56,58,59,60,61,62]
  public static let supportedCodes:Set<UInt16> = modifierCodes.union([64,79,80,105,106,107,113])
  public var codes: Set<UInt16>
  public init(codes: Set<UInt16>) { self.codes = codes }
  public func validate() throws {
    let modifiers = Self.modifierCodes
    // F13–F19 only, plus side-specific modifiers. No Fn/Caps/printable/media keys.
    let supported = Self.supportedCodes
    guard !codes.isEmpty, codes.count <= 3, codes.isSubset(of: supported),
          codes.subtracting(modifiers).count <= 1 else {
      throw SettingsError.invalid("仅支持左右独立修饰键或 F13～F19；不支持 Fn、Caps Lock、文字键和媒体键。")
    }
  }
  public var label: String {
    let names: [UInt16: String] = [54:"右 Command",55:"左 Command",56:"左 Shift",58:"左 Option",59:"左 Control",60:"右 Shift",61:"右 Option",62:"右 Control",64:"F17",79:"F18",80:"F19",105:"F13",106:"F16",107:"F14",113:"F15"]
    return codes.sorted().map { names[$0] ?? "键 \($0)" }.joined(separator: " + ")
  }
}

public enum VoiceModel: String, Codable, CaseIterable {
  case streaming = "qwen-audio-3.1-asr-flash-streaming"
  case message = "qwen-audio-3.1-asr-flash-message"
  case doubao = "doubao-streaming-asr"
  public var supportsNativePolish: Bool { self != .streaming }
  public var isDoubao: Bool { self == .doubao }
  public var title: String { isDoubao ? "豆包大模型流式语音识别" : rawValue }
}

public enum DoubaoAuthentication: String, Codable, CaseIterable { case apiKey, appAccessToken }
public enum DoubaoResource: String, Codable, CaseIterable {
  case seedDuration = "volc.seedasr.sauc.duration"
  case seedConcurrent = "volc.seedasr.sauc.concurrent"
  case bigDuration = "volc.bigasr.sauc.duration"
  case bigConcurrent = "volc.bigasr.sauc.concurrent"
  public var title: String {
    switch self {
    case .seedDuration: return "豆包 2.0 · 小时版"
    case .seedConcurrent: return "豆包 2.0 · 并发版"
    case .bigDuration: return "豆包 1.0 · 小时版"
    case .bigConcurrent: return "豆包 1.0 · 并发版"
    }
  }
}
public struct DoubaoSettings: Codable, Equatable {
  public var authentication: DoubaoAuthentication = .apiKey
  public var resource: DoubaoResource = .seedDuration
  public var appID = ""
  public var credentialReference: String?
  public var nativePolish = false
  public init() {}
  private enum CodingKeys: String, CodingKey { case authentication, resource, appID, credentialReference, nativePolish }
  public init(from decoder: Decoder) throws {
    let values=try decoder.container(keyedBy:CodingKeys.self)
    authentication=try values.decodeIfPresent(DoubaoAuthentication.self,forKey:.authentication) ?? .apiKey
    resource=try values.decodeIfPresent(DoubaoResource.self,forKey:.resource) ?? .seedDuration
    appID=try values.decodeIfPresent(String.self,forKey:.appID) ?? ""
    credentialReference=try values.decodeIfPresent(String.self,forKey:.credentialReference)
    nativePolish=try values.decodeIfPresent(Bool.self,forKey:.nativePolish) ?? false
  }
  public func validate() throws {
    if authentication == .appAccessToken {
      guard appID.range(of:"^[A-Za-z0-9_-]{1,128}$",options:.regularExpression) != nil else {
        throw SettingsError.invalid("旧版豆包鉴权请填写有效 App ID；不能包含 URL、空白或控制字符。")
      }
    }
  }
}

public struct VoiceSettings: Codable, Equatable {
  public var model: VoiceModel = .streaming
  public var nativePolish = false
  public var doubao = DoubaoSettings()
  public var activeCredentialReference: String? {
    get { model.isDoubao ? doubao.credentialReference : credentialReference }
    set { if model.isDoubao { doubao.credentialReference=newValue } else { credentialReference=newValue } }
  }
  public var enabled = false
  public var binding: TriggerBinding?
  public var region: Region? = nil
  public var workspace = ""
  public var credentialReference: String?
  public var deviceUID: String?
  public var maximumSeconds = 120
  public var connectSeconds = 10
  public var taskStartSeconds = 10
  public var finalizeSeconds = 15
  public var queueSeconds = 10
  public var showPreview = true
  public var previewTransparency = 0.1
  public var previewAtCaret = false
  public init() {}
  private enum CodingKeys:String,CodingKey {
    case model, nativePolish, doubao, enabled, binding, region, workspace, credentialReference, deviceUID
    case maximumSeconds, connectSeconds, taskStartSeconds, finalizeSeconds, queueSeconds, showPreview
    case previewTransparency, previewAtCaret
  }
  public init(from decoder:Decoder) throws {
    let values = try decoder.container(keyedBy:CodingKeys.self)
    // Existing settings keep Streaming without enabling a wording change.
    model = try values.decodeIfPresent(VoiceModel.self,forKey:.model) ?? .streaming
    nativePolish = try values.decodeIfPresent(Bool.self,forKey:.nativePolish) ?? false
    doubao = try values.decodeIfPresent(DoubaoSettings.self,forKey:.doubao) ?? DoubaoSettings()
    enabled = try values.decodeIfPresent(Bool.self,forKey:.enabled) ?? false
    binding = try values.decodeIfPresent(TriggerBinding.self,forKey:.binding)
    region = try values.decodeIfPresent(Region.self,forKey:.region)
    workspace = try values.decodeIfPresent(String.self,forKey:.workspace) ?? ""
    credentialReference = try values.decodeIfPresent(String.self,forKey:.credentialReference)
    deviceUID = try values.decodeIfPresent(String.self,forKey:.deviceUID)
    maximumSeconds = try values.decodeIfPresent(Int.self,forKey:.maximumSeconds) ?? 120
    connectSeconds = try values.decodeIfPresent(Int.self,forKey:.connectSeconds) ?? 10
    taskStartSeconds = try values.decodeIfPresent(Int.self,forKey:.taskStartSeconds) ?? 10
    finalizeSeconds = try values.decodeIfPresent(Int.self,forKey:.finalizeSeconds) ?? 15
    queueSeconds = try values.decodeIfPresent(Int.self,forKey:.queueSeconds) ?? 10
    // Existing version-1 settings retain all choices; only the new field defaults.
    showPreview = try values.decodeIfPresent(Bool.self,forKey:.showPreview) ?? true
    previewTransparency = try values.decodeIfPresent(Double.self,forKey:.previewTransparency) ?? 0.1
    previewAtCaret = try values.decodeIfPresent(Bool.self,forKey:.previewAtCaret) ?? false
  }
  public func endpoint() throws -> URL {
    if model.isDoubao {
      try doubao.validate()
      return URL(string:"wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    }
    guard let region else { throw SettingsError.invalid("请主动选择云账户地域；没有按电脑位置或时区推断。") }
    guard workspace.range(of: "^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$", options: .regularExpression) != nil else {
      throw SettingsError.invalid("Workspace ID 只能包含字母、数字和短横线；不接受 URL 或任意域名。")
    }
    return URL(string: "wss://\(workspace).\(region.rawValue).maas.aliyuncs.com/api-ws/v1/inference")!
  }
  public func validate(requireReady: Bool = false) throws {
    guard previewTransparency.isFinite, (0...0.7).contains(previewTransparency) else {
      throw SettingsError.invalid("浮窗透明度应为 0% 至 70%。")
    }
    guard (10...300).contains(maximumSeconds), (1...60).contains(connectSeconds),
          (1...60).contains(taskStartSeconds), (1...60).contains(finalizeSeconds),
          (1...10).contains(queueSeconds) else { throw SettingsError.invalid("时限或音频队列超出允许范围。") }
    if let binding { try binding.validate() }
    if enabled || requireReady {
      guard binding != nil, activeCredentialReference != nil else { throw SettingsError.invalid("请先保存所选服务的密钥和按住键。") }
      _ = try endpoint()
    } else if model.isDoubao || !workspace.isEmpty { _ = try endpoint() }
  }
}

public struct Settings: Codable, Equatable {
  public var version = 1
  public var revision: UInt64 = 0
  public var letters: [String: LetterProfile] = [:]
  public var voice = VoiceSettings()
  public init() {}
  public func validate() throws {
    guard version == 1 else { throw SettingsError.invalid("不支持的配置版本；保留原文件，不覆盖。") }
    for (schema, profile) in letters {
      guard schema.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil else { throw SettingsError.invalid("方案 ID 非法。") }
      try profile.validate()
    }
    try voice.validate()
  }
}

public final class SettingsStore {
  private static let maximumBytes = 256 * 1024
  public let url: URL
  public init(url: URL) { self.url = url }
  public func load() throws -> Settings {
    guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
    return try read(url)
  }
  private func read(_ source:URL) throws -> Settings {
    // Read at most the budget plus one sentinel byte, not an arbitrarily large
    // file before testing its size. Loop because a legal read may be short.
    let handle = try FileHandle(forReadingFrom:source)
    defer { try? handle.close() }
    var data = Data()
    while data.count <= Self.maximumBytes {
      guard let chunk = try handle.read(upToCount:Self.maximumBytes + 1 - data.count),
            !chunk.isEmpty else { break }
      data.append(chunk)
    }
    guard data.count <= Self.maximumBytes else { throw SettingsError.invalid("配置文件过大；原文件未覆盖。") }
    let value = try JSONDecoder().decode(Settings.self, from: data)
    try value.validate(); return value
  }
  private func nextRevision(_ revision:UInt64) throws -> UInt64 {
    let (next,overflow) = revision.addingReportingOverflow(1)
    guard !overflow else { throw SettingsError.invalid("配置修订号已到上限；原文件与备份保留，未绕回旧版本。") }
    return next
  }
  private func encodeBounded(_ value:Settings) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
    let data = try encoder.encode(value)
    guard data.count <= Self.maximumBytes else {
      throw SettingsError.invalid("生成的配置超过 256 KiB；请减少方案条目，原配置与备份未改动。")
    }
    return data
  }
  // Read-only fallback: never rewrite a corrupt/unknown-version primary file,
  // never re-enable voice, and never read Keychain from the IMK key path.
  public func lastValidReadOnly() -> Settings? {
    guard var value = try? read(url.appendingPathExtension("last-valid")) else { return nil }
    value.voice.enabled = false; return value
  }
  public func restoreLastValid(expectedRevision:UInt64) throws -> Settings {
    guard (try? load()) == nil, var restored = lastValidReadOnly(),
          restored.revision == expectedRevision else {
      throw SettingsError.invalid("源配置或备份已改变；重新载入后再确认恢复。")
    }
    // Preflight the actual output BEFORE creating a recovery copy or changing
    // either file: compact valid input can expand beyond the load budget.
    restored.revision = try nextRevision(restored.revision)
    let data = try encodeBounded(restored)
    let backup = url.appendingPathExtension("recovery-\(UUID().uuidString).invalid")
    // The invalid primary can exceed the load budget by an arbitrary amount.
    // Preserve it on disk without allocating its entire contents in the Helper.
    try FileManager.default.copyItem(at:url,to:backup)
    try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path)
    try data.write(to:url,options:.atomic)
    try? FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    return restored
  }
  public func save(_ draft: Settings) throws -> Settings {
    try draft.validate()
    let old = try load() // Refuse overwriting corrupt/unsupported configurations.
    guard draft.revision == old.revision else { throw SettingsError.invalid("配置已在其他窗口改变，请重新载入。") }
    var next = draft; next.revision = try nextRevision(next.revision)
    let data = try encodeBounded(next)
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
    // Backup only a known-valid predecessor. Data.atomic uses a sibling temp + rename.
    if FileManager.default.fileExists(atPath: url.path) {
      try Data(contentsOf: url).write(to: url.appendingPathExtension("last-valid"), options: .atomic)
    }
    try data.write(to: url, options: .atomic)
    // Persistence has committed: a chmod failure must not roll back the Keychain
    // reference while leaving the new config on disk. Parent directory is 0700.
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    return next
  }
}
