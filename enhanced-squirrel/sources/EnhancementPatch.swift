import Foundation
import EnhancementCore

enum EnhancementPatch {
  static let begin = "  # BEGIN SquirrelEnhanced owned patch v1"
  static let end = "  # END SquirrelEnhanced owned patch v1"
  static func apply(schema:String,profile:LetterProfile,directory:URL,replaceLegacy:Bool = false) throws -> ManagedLetterPatch.Plan {
    try profile.validate()
    guard schema.range(of:"^[a-zA-Z0-9_-]+$",options:.regularExpression) != nil else { throw SettingsError.invalid("方案 ID 无效。") }
    let target = directory.appendingPathComponent("\(schema).custom.yaml")
    let fm = FileManager.default
    guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else {
      throw SettingsError.invalid("开发 Rime 目录包含符号链接；未写入可能指向正式数据的位置。")
    }
    try fm.createDirectory(at:directory,withIntermediateDirectories:true)
    let manifestName = ".enhancement-\(schema).owned.json"
    let transactionName = ".enhancement-\(schema).transaction.json"
    let names = [target.lastPathComponent,manifestName]
    for name in names + [target.lastPathComponent + ".enhancement-backup"] {
      if (try? directory.appendingPathComponent(name).resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true {
        throw SettingsError.invalid("补丁/所有权/备份文件是符号链接；未写入。")
      }
    }
    try FilePairTransaction.recover(directory:directory,journalName:transactionName,ownedNames:names)
    let previousDate = try? fm.attributesOfItem(atPath:target.path)[.modificationDate] as? Date
    let original = fm.fileExists(atPath:target.path) ? try readBounded(target,limit:256 * 1024) : nil
    let existing = try original.map { data -> String in
      guard let text=String(data:data,encoding:.utf8) else { throw SettingsError.invalid("源补丁不是有效 UTF-8；保留现场。") }
      return text
    }
    let manifest = directory.appendingPathComponent(manifestName)
    let ownership = fm.fileExists(atPath:manifest.path) ? try readBounded(manifest,limit:2 * 1024 * 1024) : nil
    let parsed = try patchKeys(existing ?? "patch:\n")
    let processors = profile.enabled ? try readProcessors(schema:schema) : []
    let plan = try ManagedLetterPatch.plan(schema:schema,existing:existing,ownership:ownership,
      profile:profile,processors:processors,replaceLegacy:replaceLegacy,parsedKeys:parsed)
    // libRime's real parser, not a regex, determines whether our preserved text
    // remains YAML. Both validations precede Lua/config/ownership writes.
    if let output = plan.yaml {
      if profile.enabled { _ = try patchKeys(output) }
      else { try validateRestoration(output) }
    }
    let luaDirectory = directory.appendingPathComponent("lua")
    guard luaDirectory.standardizedFileURL == luaDirectory.resolvingSymlinksInPath().standardizedFileURL else {
      throw SettingsError.invalid("Lua 目录包含符号链接；未写入。")
    }
    try fm.createDirectory(at:luaDirectory,withIntermediateDirectories:true)
    let destination = luaDirectory.appendingPathComponent("letter_selection.lua")
    if (try? destination.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true {
      throw SettingsError.invalid("Lua 文件是符号链接；未覆盖。")
    }
    if profile.enabled {
      guard let bundled = Bundle.main.url(forResource:"letter_selection",withExtension:"lua") else { throw SettingsError.invalid("安装包缺少 Lua 资源。") }
      let data = try Data(contentsOf:bundled)
      if fm.fileExists(atPath:destination.path), try readBounded(destination,limit:data.count) != data { throw SettingsError.invalid("现有同名 Lua 不属于本安装包；未覆盖。") }
      try data.write(to:destination,options:.atomic)
    }
    // Preserve unrelated later edits. Never restore a full old custom over current data.
    if fm.fileExists(atPath:target.path) { try readBounded(target,limit:256 * 1024).write(to:target.appendingPathExtension("enhancement-backup"),options:.atomic) }
    try FilePairTransaction.apply(directory:directory,journalName:transactionName,
      first:(target.lastPathComponent,plan.yaml.map({Data($0.utf8)})),second:(manifestName,plan.ownership))
    // Rime stores source timestamps as integer seconds. An atomic rewrite in
    // the same second can otherwise be accepted as "already built". Change only
    // this owned source's timestamp (never build/ or a dictionary). Choose the
    // previous second rather than inventing a future clock; ConfigNeedsUpdate
    // compares inequality, not newer-than. No sleep blocks the input event loop.
    if plan.yaml != nil, let previousDate,
       let currentDate = try fm.attributesOfItem(atPath:target.path)[.modificationDate] as? Date,
       floor(previousDate.timeIntervalSince1970) == floor(currentDate.timeIntervalSince1970) {
      try fm.setAttributes([.modificationDate:Date(timeIntervalSince1970:floor(currentDate.timeIntervalSince1970)-1)],ofItemAtPath:target.path)
    }
    return plan
  }
  private static func readBounded(_ url:URL,limit:Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom:url)
    defer { try? handle.close() }
    var data = Data()
    while data.count <= limit {
      guard let chunk = try handle.read(upToCount:limit + 1 - data.count), !chunk.isEmpty else { break }
      data.append(chunk)
    }
    guard data.count <= limit else { throw SettingsError.invalid("源补丁或所有权文件超过大小上限；保留现场。") }
    return data
  }
  static func readProcessors(schema:String) throws -> [String] {
    let api = rime_get_api_stdbool().pointee
    var config = RimeConfig()
    guard api.schema_open(schema,&config) else { throw SettingsError.invalid("实际 Rime 方案无法读取；没有猜测处理器列表。") }
    defer { _ = api.config_close(&config) }
    let count = api.config_list_size(&config,"engine/processors")
    guard count > 0, count <= 256 else { throw SettingsError.invalid("实际处理器列表为空或异常；未应用。") }
    return try (0..<Int(count)).map { index in
      guard let value = api.config_get_cstring(&config,"engine/processors/@\(index)") else { throw SettingsError.invalid("处理器不是有效字符串。") }
      return String(cString:value)
    }
  }
  private static func validateRestoration(_ yaml:String) throws {
    // Removing a root we created may legitimately leave unrelated root keys
    // and no patch map. Only YAML validity is required for that restoration.
    guard yaml.utf8.count <= 256 * 1024 else { throw SettingsError.invalid("恢复源补丁超过大小上限。") }
    let commentsOnly = yaml.components(separatedBy:.newlines).allSatisfy {
      let line = $0.trimmingCharacters(in:.whitespaces); return line.isEmpty || line.hasPrefix("#")
    }
    if commentsOnly { return }
    let api = rime_get_api_stdbool().pointee
    var config = RimeConfig()
    defer { if config.ptr != nil { _ = api.config_close(&config) } }
    guard api.config_load_string(&config,yaml) else { throw SettingsError.invalid("真实 Rime 恢复 YAML 校验失败；未写入。") }
  }
  private static func patchKeys(_ yaml:String) throws -> Set<String> {
    guard yaml.utf8.count <= 256 * 1024 else { throw SettingsError.invalid("源补丁超过大小上限。") }
    let commentsOnly = yaml.components(separatedBy:.newlines).allSatisfy {
      let line = $0.trimmingCharacters(in:.whitespaces); return line.isEmpty || line.hasPrefix("#")
    }
    if commentsOnly { return [] }
    let api = rime_get_api_stdbool().pointee
    var config = RimeConfig()
    defer { if config.ptr != nil { _ = api.config_close(&config) } }
    guard api.config_load_string(&config,yaml) else { throw SettingsError.invalid("真实 Rime YAML 校验失败；未写入。") }
    var iterator = RimeConfigIterator()
    guard api.config_begin_map(&iterator,&config,"patch") else {
      // A literal empty block is parsed as YAML null, which is a valid no-op
      // custom file. Do not equate other scalar/sequence values with emptiness.
      if try ManagedLetterPatch.isEmptyBlockPatch(yaml) { return [] }
      throw SettingsError.invalid("patch 不是有效 YAML 映射；未改写。")
    }
    defer { api.config_end(&iterator) }
    var keys:Set<String> = []
    while api.config_next(&iterator) {
      guard keys.count < 2048, let key = iterator.key else { throw SettingsError.invalid("patch 键异常或超限。") }
      keys.insert(String(cString:key))
    }
    return keys
  }
}
