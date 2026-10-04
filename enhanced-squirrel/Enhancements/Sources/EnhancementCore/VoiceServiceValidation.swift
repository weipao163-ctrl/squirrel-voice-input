import Foundation

// Validates transport safety only, NOT whether a token has account/model access.
// The same check applies to newly entered, Keychain-loaded and test-only keys.
// Keep rejected values out of errors (including partial prefixes/suffixes).
public enum VoiceCredential {
  public static func validate(_ key: String) throws {
    guard !key.isEmpty, key.utf8.count <= 4096,
          key.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
      throw SettingsError.invalid("API Key 为空、过长或包含空白、控制字符、非 ASCII 字符；请检查输入，密钥内容未写入诊断。")
    }
  }
}

public extension VoiceSettings {
  func connectionHeaders(key:String,task:UUID) throws -> [String:String] {
    try VoiceCredential.validate(key)
    if model.isDoubao {
      try doubao.validate()
      var headers=["X-Api-Resource-Id":doubao.resource.rawValue,
                   "X-Api-Request-Id":task.uuidString.lowercased(),
                   "X-Api-Connect-Id":task.uuidString.lowercased(),"X-Api-Sequence":"-1"]
      if doubao.authentication == .apiKey { headers["X-Api-Key"]=key }
      else { headers["X-Api-App-Key"]=doubao.appID; headers["X-Api-Access-Key"]=key }
      return headers
    }
    return ["Authorization":"Bearer \(key)","X-DashScope-WorkSpace":workspace]
  }
  func validatedConnectionEndpoint() throws -> URL {
    guard (1...60).contains(connectSeconds) else {
      throw SettingsError.invalid("连接超时必须为 1～60 秒。")
    }
    // Connection testing precedes microphone/key-binding onboarding. No-audio
    // probing must not require a saved binding or Keychain reference.
    return try endpoint()
  }
}

public enum ConnectionProbeResult: Equatable, Sendable {
  case webSocketOpened
  case timedOut
  case failed(httpStatus: Int?)
  case closedBeforeHandshake

  public var transportEstablished: Bool { self == .webSocketOpened }
  // The fixed Model Studio inference endpoint authenticates Authorization
  // during its WebSocket handshake (official WebSocket connection guide).
  // This validates the token/endpoint, not access to a particular model.
  public var authenticationVerified: Bool { self == .webSocketOpened }
  public var modelVerified: Bool { false }
  public var message: String {
    switch self {
    case .webSocketOpened:
      return "API Key 鉴权与服务连接通过，可以按住热键测试。未采音、未发送识别任务；指定模型权限与识别结果将在实际语音测试中验证。"
    case .timedOut:
      return "TLS / WebSocket 连接测试超时；未采音、未发送任务，不能据此断言 Key 或模型不可用。"
    case .failed(let status):
      if status == 401 { return "API Key 鉴权失败（HTTP 401）。使用旧版豆包鉴权时，请同时检查 App ID 与 Access Token；其他服务请检查对应密钥与账户配置。" }
      if status == 403 { return "语音服务拒绝访问（HTTP 403）。请检查密钥、模型资源或工作空间权限。" }
      if let status { return "服务连接失败（HTTP \(status)）。请检查网络、所选服务配置或服务额度后重试。" }
      return "连接失败；无法仅据此确定网络或鉴权原因，未执行识别。"
    case .closedBeforeHandshake:
      return "连接在握手确认前结束；未采音、未发送任务，没有认证或识别通过证据。"
    }
  }
}
