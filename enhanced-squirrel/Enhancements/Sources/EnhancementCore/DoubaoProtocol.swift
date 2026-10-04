import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
#if canImport(zlib)
import zlib
#endif

public struct DoubaoResponse {
  public let text: String?
  public let final: Bool
  public let sequence: Int32?
  public let errorCode: UInt32?
}

// Version-1 SAUC WebSocket binary protocol. Outgoing packets use the documented
// no-compression mode; incoming gzip is decoded with a strict output budget.
public enum DoubaoProtocol {
  private static let budget=256 * 1024
  private static func isBoolean(_ number:NSNumber) -> Bool {
    #if canImport(CoreFoundation)
    return CFGetTypeID(number) == CFBooleanGetTypeID()
    #else
    guard let json=try? JSONSerialization.data(withJSONObject:number,options:[.fragmentsAllowed]) else { return false }
    return json == Data("true".utf8) || json == Data("false".utf8)
    #endif
  }
  public static func run(task:UUID,settings:VoiceSettings) throws -> Data {
    guard settings.model.isDoubao else { throw SettingsError.invalid("豆包请求需要豆包模型配置。") }
    try settings.doubao.validate()
    let json=try JSONSerialization.data(withJSONObject:[
      "user":["uid":task.uuidString.lowercased()], // Per-task ID, no hardware/user identifier.
      "audio":["format":"pcm","codec":"raw","rate":16000,"bits":16,"channel":1],
      "request":["model_name":"bigmodel","result_type":"full","enable_itn":true,
                 "enable_punc":true,"enable_ddc":settings.doubao.nativePolish,"show_utterances":false]
    ])
    return try frame(type:1,flags:0,serialization:1,payload:json)
  }
  public static func audio(_ pcm:Data,final:Bool = false) throws -> Data {
    guard pcm.count % 2 == 0, pcm.count <= 6400 else { throw SettingsError.invalid("豆包音频包长度无效。") }
    return try frame(type:2,flags:final ? 2 : 0,serialization:0,payload:pcm)
  }
  private static func frame(type:UInt8,flags:UInt8,serialization:UInt8,payload:Data) throws -> Data {
    guard payload.count <= budget else { throw SettingsError.invalid("豆包请求超出大小限制。") }
    var value=Data([0x11,(type<<4)|flags,serialization<<4,0])
    let size=UInt32(payload.count)
    value.append(contentsOf:[UInt8((size>>24)&255),UInt8((size>>16)&255),UInt8((size>>8)&255),UInt8(size&255)])
    value.append(payload); return value
  }
  public static func response(_ data:Data) throws -> DoubaoResponse {
    guard data.count >= 8, data.count <= budget, data[0] == 0x11, data[3] == 0 else {
      throw SettingsError.invalid("豆包数据包版本、头部或长度无效。")
    }
    let type=data[1]>>4, flags=data[1]&15, serialization=data[2]>>4, compression=data[2]&15
    guard [0,1].contains(compression), [9,15].contains(type), flags <= 3 else {
      throw SettingsError.invalid("豆包数据包类型或编码无效。")
    }
    var offset=4
    func integer() throws -> UInt32 {
      guard data.count-offset >= 4 else { throw SettingsError.invalid("豆包数据包被截断。") }
      let value=(0..<4).reduce(UInt32(0)) { ($0<<8)|UInt32(data[offset+$1]) }
      offset += 4; return value
    }
    let code:UInt32?, sequence:Int32?
    if type == 15 { code=try integer(); sequence=nil }
    else {
      code=nil
      sequence=flags&1 == 1 ? Int32(bitPattern:try integer()) : nil
      guard serialization == 1, sequence == nil || sequence != 0,
            flags != 1 || (sequence ?? 0)>0 else { throw SettingsError.invalid("豆包结果序号或序列化方式无效。") }
    }
    let size=Int(try integer())
    guard size <= budget, size == data.count-offset else { throw SettingsError.invalid("豆包数据包声明长度与实际长度不符。") }
    let packed=Data(data[offset...])
    let payload=compression == 1 ? try gunzip(packed) : packed
    if let code { return DoubaoResponse(text:nil,final:false,sequence:nil,errorCode:code) }
    guard let object=try JSONSerialization.jsonObject(with:payload) as? [String:Any] else {
      throw SettingsError.invalid("豆包结果不是 JSON 对象。")
    }
    if let codeValue=object["code"] {
      guard let number=codeValue as? NSNumber, !isBoolean(number),
            number.doubleValue.isFinite, number.doubleValue.rounded(.towardZero)==number.doubleValue,
            (0...Double(UInt32.max)).contains(number.doubleValue) else { throw SettingsError.invalid("豆包结果错误码无效。") }
      if number.uint32Value != 20000000 { return DoubaoResponse(text:nil,final:false,sequence:sequence,errorCode:number.uint32Value) }
    }
    var text:String?
    if let result=object["result"] {
      let full:[String:Any]?
      if let dictionary=result as? [String:Any] { full=dictionary }
      else if let list=result as? [[String:Any]], list.count == 1 { full=list[0] }
      else { full=nil }
      guard let full else { throw SettingsError.invalid("豆包全量结果格式无效。") }
      if let value=full["text"] {
        guard let value=value as? String, value.utf8.count <= 64 * 1024 else { throw SettingsError.invalid("豆包识别文字无效或超限。") }
        text=value
      }
    }
    // Header flags indicate the whole task finished. Utterance 'definite' is
    // deliberately ignored: a final sentence is not the complete recording.
    return DoubaoResponse(text:text,final:flags&2 == 2,sequence:sequence,errorCode:nil)
  }
  private static func gunzip(_ data:Data) throws -> Data {
    #if canImport(zlib)
    var stream=z_stream()
    guard inflateInit2_(&stream,MAX_WBITS+16,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
      throw SettingsError.invalid("豆包压缩结果解码无法启动。")
    }
    defer { inflateEnd(&stream) }
    return try data.withUnsafeBytes { input in
      stream.next_in=UnsafeMutablePointer(mutating:input.bindMemory(to:Bytef.self).baseAddress)
      stream.avail_in=uInt(data.count)
      var result=Data(), chunk=[UInt8](repeating:0,count:8192)
      while true {
        let status=chunk.withUnsafeMutableBytes { output -> Int32 in
          stream.next_out=output.bindMemory(to:Bytef.self).baseAddress; stream.avail_out=8192
          return inflate(&stream,Z_NO_FLUSH)
        }
        let count=8192-Int(stream.avail_out)
        guard result.count+count <= budget else { throw SettingsError.invalid("豆包压缩结果解压后超限。") }
        result.append(contentsOf:chunk.prefix(count))
        if status == Z_STREAM_END {
          guard stream.avail_in == 0 else { throw SettingsError.invalid("豆包压缩结果有额外数据。") }
          return result
        }
        guard status == Z_OK, count>0 else { throw SettingsError.invalid("豆包压缩结果损坏或被截断。") }
      }
    }
    #else
    throw SettingsError.invalid("当前运行环境不支持豆包 Gzip 结果。")
    #endif
  }
  public static func failureMessage(_ code:UInt32) -> String {
    let detail:String
    switch code {
    case 45000001: detail="请求参数无效，请检查模型资源与鉴权配置"
    case 45000002: detail="空音频，请检查所选麦克风是否收到声音"
    case 45000081: detail="服务等待音频超时，请检查网络"
    case 45000151: detail="服务不接受当前音频格式"
    case 55000031: detail="服务繁忙，请稍后重试"
    default: detail="服务拒绝或未完成识别，请检查凭据、资源权限及额度"
    }
    return "豆包识别失败（\(code)）：\(detail)。已有文字仅作草稿。"
  }
}
