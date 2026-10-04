import Foundation
import EnhancementCore

// Private local channel, authenticated code identity, no public broadcasts.
@objc public protocol HelperCommands {
  func showSettings()
  func begin(_ request: Data)
  func release(_ identity: Data)
  func cancel(_ identity: Data)
  func lease(_ identity: Data)
  func deploymentReply(_ result: Data)
  func schemaCatalog(_ result: Data)
  func settingsApplied(_ result: Data)
  func voiceDeliveryReceipt(_ result:Data)
}
@objc public protocol InputCallbacks {
  func settingsChanged(_ configuration: Data)
  func voiceUpdate(_ update: Data)
  func deploymentRequested(_ request: Data)
}

public struct VoiceRequest: Codable {
  public var identity: VoiceIdentity
  public var revision: UInt64
  public var pressUptime:TimeInterval?
  public init(identity: VoiceIdentity, revision: UInt64, pressUptime:TimeInterval? = nil) {
    self.identity = identity; self.revision = revision; self.pressUptime=pressUptime
  }
}
public struct SchemaCatalog: Codable {
  public var ids:[String]
  public var current:String
  public init(ids:[String],current:String) { self.ids = ids; self.current = current }
}
public struct SettingsReceipt:Codable {
  public var revision:UInt64
  public var message:String
  public init(revision:UInt64,message:String) { self.revision = revision; self.message = message }
}
public struct VoiceUpdate: Codable {
  public var identity: VoiceIdentity
  public var phase: VoicePhase
  public var text: String
  public var complete: Bool
  public var level: Double
  public var duration: Double
  public var message: String
  public var showPreview:Bool
  public init(identity: VoiceIdentity, phase: VoicePhase, text: String, complete: Bool,
              level: Double = 0, duration: Double = 0, message: String = "", showPreview:Bool = true) {
    self.identity = identity; self.phase = phase; self.text = text; self.complete = complete
    self.level = level; self.duration = duration; self.message = message
    self.showPreview = showPreview
  }
}
public enum Wire {
  public static func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
  public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    guard data.count <= 256 * 1024 else { throw SettingsError.invalid("IPC 消息超限。") }
    return try JSONDecoder().decode(type, from: data)
  }
}
