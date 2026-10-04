import Foundation

// Text-preserving planner, not a YAML parser. The frontend MUST validate both
// documents with librime's real YAML parser before it writes either file.
// Only explicit block patch entries are edited; unsupported shapes are rejected.
public enum ManagedLetterPatch {
  public static let module = "lua_processor@*letter_selection"
  public static let begin = "  # BEGIN SquirrelEnhanced owned patch v2"
  public static let end = "  # END SquirrelEnhanced owned patch v2"
  private static let oldBegin = "  # BEGIN SquirrelEnhanced owned patch v1"
  private static let oldEnd = "  # END SquirrelEnhanced owned patch v1"
  private static let legacy:Set<String> = ["lua_processor@space_select_gate","lua_processor@*space_select_gate"]
  private static let options:Set<String> = ["menu/page_size","letter_selection/enabled","letter_selection/keys","letter_selection/hide_candidates"]

  public struct Plan {
    public var yaml:String?
    public var ownership:Data?
    public var replacedLegacy:Bool
    public var message:String
    public var expectedProcessors:[String]? = nil
  }
  private struct Ownership:Codable {
    var version = 2
    var schema:String
    var original:String?
    var installed:String
    var block:String
    var removed:[String]
    var beforeProcessors:[String]
    var installedProcessors:[String]
    var patchCreated:Bool
  }
  private struct Entry { var key:String; var range:Range<Int> }
  private struct Document {
    var lines:[String]
    var eol:String
    var patch:Int
    var limit:Int
    var indent:String
    var entries:[Entry]
    var patchCreated:Bool
  }
  private static func match(_ pattern:String,_ line:String) -> String? {
    guard let regex = try? NSRegularExpression(pattern:pattern),
          let found = regex.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)),
          let range = Range(found.range(at:1),in:line) else { return nil }
    return String(line[range])
  }
  private static func isOwned(_ key:String) -> Bool { options.contains(key) || key == "engine/processors" || key.hasPrefix("engine/processors/") }
  private static func lines(_ source:String) throws -> ([String],String) {
    guard source.utf8.count <= 256 * 1024, !source.contains("\0") else { throw SettingsError.invalid("补丁过大或包含 NUL；未写入。") }
    let crlf = source.contains("\r\n")
    let normalized = source.replacingOccurrences(of:"\r\n",with:"\n")
    guard !normalized.contains("\r"), !crlf || !source.replacingOccurrences(of:"\r\n",with:"").contains("\n") else {
      throw SettingsError.invalid("混合/非标准换行；未自动重排用户文件。")
    }
    return (normalized.components(separatedBy:"\n"),crlf ? "\r\n" : "\n")
  }
  private static func document(_ source:String) throws -> Document {
    var (items,eol) = try lines(source)
    let roots = items.indices.filter { match("^(?:patch|\"patch\"|'patch'):([ ]*(?:#.*)?)$",items[$0]) != nil }
    guard roots.count <= 1 else { throw SettingsError.invalid("patch 重复；不猜测 YAML 的重复键语义。") }
    var created = false
    if roots.isEmpty {
      // Only an empty/comment-only document can acquire a new patch root here.
      guard items.allSatisfy({ $0.trimmingCharacters(in:.whitespaces).isEmpty || $0.trimmingCharacters(in:.whitespaces).hasPrefix("#") }) else {
        throw SettingsError.invalid("不支持该 YAML patch 根结构；保留原配置，未自动改写。")
      }
      if items.last == "" { items.removeLast() }
      items += ["patch:",""]; created = true
    }
    let patch = created ? items.count-2 : roots[0]
    let limit = items.indices.first { $0 > patch && !items[$0].isEmpty && !items[$0].hasPrefix(" ") && !items[$0].hasPrefix("#") } ?? items.count
    let nonComments = items[(patch+1)..<limit].filter { !$0.trimmingCharacters(in:.whitespaces).isEmpty && !$0.trimmingCharacters(in:.whitespaces).hasPrefix("#") }
    let spaces = nonComments.map { $0.prefix(while:{$0 == " "}).count }.min() ?? 2
    guard spaces > 0, spaces <= 16 else { throw SettingsError.invalid("patch 缩进不受支持；未写入。") }
    let indent = String(repeating:" ",count:spaces)
    var starts:[(Int,String)] = []
    let pattern = "^" + indent + "(?:\"([^\"]+)\"|'([^']+)'|([^:#]+)):[ ]*(?:.*)$"
    let regex = try NSRegularExpression(pattern:pattern)
    for index in (patch+1)..<limit {
      let line = items[index]
      guard !line.hasPrefix(indent + " "), let found = regex.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)) else { continue }
      let values = (1...3).compactMap { part -> String? in
        guard let range = Range(found.range(at:part),in:line) else { return nil }
        return String(line[range]).trimmingCharacters(in:.whitespaces)
      }
      if let key = values.first { starts.append((index,key)) }
    }
    guard !starts.contains(where:{ ["<<","engine","menu","letter_selection"].contains($0.1) }) else {
      throw SettingsError.invalid("嵌套/merge 的受影响键需要结构化迁移；未覆盖。其他无关嵌套配置保留。")
    }
    guard Set(starts.map({$0.1})).count == starts.count else { throw SettingsError.invalid("patch 存在重复键；未写入。") }
    var entries:[Entry] = []
    for position in starts.indices {
      let start = starts[position].0
      var last = position+1 < starts.count ? starts[position+1].0 : limit
      // Keep comments/blanks BETWEEN entries outside our ownership. Comments
      // within a removed value are retained in its exact restoration fragment.
      while last > start+1 && (items[last-1].trimmingCharacters(in:.whitespaces).isEmpty || items[last-1].trimmingCharacters(in:.whitespaces).hasPrefix("#")) { last -= 1 }
      entries.append(Entry(key:starts[position].1,range:start..<last))
    }
    return Document(lines:items,eol:eol,patch:patch,limit:limit,indent:indent,entries:entries,patchCreated:created)
  }
  public static func isEmptyBlockPatch(_ source:String) throws -> Bool {
    let value = try document(source)
    return value.lines[(value.patch+1)..<value.limit].allSatisfy {
      let line = $0.trimmingCharacters(in:.whitespaces); return line.isEmpty || line.hasPrefix("#")
    }
  }
  private static func validateProof(_ value:Ownership) throws {
    guard value.installed.utf8.count <= 256 * 1024, (value.original?.utf8.count ?? 0) <= 256 * 1024,
          value.block.utf8.count <= 128 * 1024, value.removed.count <= 256,
          value.beforeProcessors.count <= 256, value.installedProcessors.count <= 256 else {
      throw SettingsError.invalid("所有权快照超限；未写入。")
    }
    var before = try document(value.original ?? "patch:\n")
    let owned = before.entries.filter { isOwned($0.key) }
    guard owned.map({before.lines[$0.range].joined(separator:before.eol)}) == value.removed else {
      throw SettingsError.invalid("原字段与恢复片段不一致；所有权证明损坏。")
    }
    for entry in owned.reversed() { before.lines.removeSubrange(entry.range) }
    let stripped = try removeBlock(value.installed,recorded:value.block,first:begin,last:end).0
    guard stripped == before.lines.joined(separator:before.eol) else {
      throw SettingsError.invalid("安装前后无关字节证明不一致；不信任修改过的快照。")
    }
  }
  private static func removeBlock(_ source:String,recorded:String,first:String,last:String) throws -> (String,Int) {
    var (items,eol) = try lines(source)
    guard items.filter({$0 == first}).count == 1, items.filter({$0 == last}).count == 1,
          let begin = items.firstIndex(of:first), let end = items.firstIndex(of:last), end > begin,
          items[begin...end].joined(separator:eol) == recorded else {
      throw SettingsError.invalid("托管标记或本项目拥有的键已改变；未覆盖任何当前文件。")
    }
    items.removeSubrange(begin...end)
    return (items.joined(separator:eol),begin)
  }
  private static func quote(_ value:String) throws -> String {
    guard value.utf8.count <= 256, !value.unicodeScalars.contains(where:{CharacterSet.controlCharacters.union(.newlines).contains($0)}) else { throw SettingsError.invalid("处理器名称异常；未写入。") }
    return "\"" + value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"") + "\""
  }

  public static func plan(schema:String,existing:String?,ownership:Data?,profile:LetterProfile,
                          processors:[String],replaceLegacy:Bool = false,parsedKeys:Set<String>? = nil) throws -> Plan {
    try profile.validate()
    guard schema.range(of:"^[a-zA-Z0-9_-]+$",options:.regularExpression) != nil else { throw SettingsError.invalid("方案 ID 无效。") }
    var base = existing ?? "patch:\n"
    var original = existing
    var baseline = processors
    var old:Ownership?
    if let parsedKeys {
      let input = try document(base)
      guard Set(input.entries.map({$0.key})) == parsedKeys else { throw SettingsError.invalid("文本范围与真实 YAML 键不一致；不猜测复杂/转义键。") }
    }
    if let ownership, !ownership.isEmpty {
      guard ownership.count <= 2 * 1024 * 1024, let current = existing else { throw SettingsError.invalid("托管记录仍在，但源补丁已删除；未复活用户删除的文件。") }
      if let value = try? JSONDecoder().decode(Ownership.self,from:ownership) {
        guard value.version == 2, value.schema == schema else { throw SettingsError.invalid("补丁所有权版本/方案不匹配。") }
        try validateProof(value)
        old = value
        let (unowned,position) = try removeBlock(current,recorded:value.block,first:begin,last:end)
        let check = try document(unowned)
        guard !check.entries.contains(where:{isOwned($0.key)}) else { throw SettingsError.invalid("用户在托管区之外新增了相同键；冲突未覆盖。") }
        if !profile.enabled && current == value.installed { return Plan(yaml:value.original,ownership:nil,replacedLegacy:false,message:"已按完整字节证明恢复本项目安装前的源补丁。") }
        var (items,eol) = try lines(unowned)
        let fragments = value.removed.flatMap { $0.components(separatedBy:eol) }
        items.insert(contentsOf:fragments,at:min(position,items.count))
        if value.patchCreated {
          let parsed = try document(items.joined(separator:eol))
          if parsed.entries.isEmpty { items.remove(at:parsed.patch) }
        }
        base = items.joined(separator:eol)
        original = current == value.installed ? value.original : base
        baseline = value.beforeProcessors
        if profile.enabled && processors != value.beforeProcessors && processors != value.installedProcessors {
          throw SettingsError.invalid("真实方案处理器已改变；先在 GUI 关闭并部署恢复，再重新启用，不复用旧快照。")
        }
      } else {
        guard let recorded = String(data:ownership,encoding:.utf8) else { throw SettingsError.invalid("所有权文件损坏；未覆盖。") }
        // One-way adoption of the old, byte-proven marker format. Never restore
        // an entire unrelated .enhancement-backup as if it were current truth.
        let removed = try removeBlock(current,recorded:recorded,first:oldBegin,last:oldEnd)
        let unowned = try document(removed.0)
        guard !unowned.entries.contains(where:{isOwned($0.key)}) else { throw SettingsError.invalid("旧托管区外出现同名键；不把后来的用户修改冒充原备份。") }
        base = removed.0; original = base
        guard processors.filter({$0 == module}).count <= 1 else { throw SettingsError.invalid("旧托管记录不能证明重复处理器的归属；未接管。") }
        baseline = processors.filter { $0 != module }
      }
    } else if base.contains(begin) || base.contains(end) || base.contains(oldBegin) || base.contains(oldEnd) {
      throw SettingsError.invalid("发现无所有权证明的托管标记；未接管或覆盖。")
    }
    if !profile.enabled { return Plan(yaml:old == nil ? original : base,ownership:nil,replacedLegacy:false,message:"已撤销自有字母补丁，后续无关修改保留。") }
    guard !baseline.isEmpty, baseline.count <= 256 else { throw SettingsError.invalid("真实 Rime 处理器列表不可用或异常；未猜测默认方案。") }
    guard !baseline.contains(where:{$0.contains("letter_selection")}) else { throw SettingsError.invalid("已有未归本安装所有的字母处理器；不重复加载。") }
    let gates = baseline.filter { $0.contains("space_select_gate") }
    guard gates.allSatisfy({legacy.contains($0)}) else { throw SettingsError.invalid("旧 gate 名称不在已识别范围；未猜测替换。") }
    guard gates.isEmpty || replaceLegacy || old != nil else { throw SettingsError.invalid("发现旧 space_select_gate；请用 GUI 的显式迁移确认，不并列注册两个状态机。") }
    var doc = try document(base)
    let affected = doc.entries.filter { isOwned($0.key) }
    guard !affected.contains(where:{$0.key.hasPrefix("letter_selection/")}) else { throw SettingsError.invalid("已有非本项目拥有的 letter_selection 设置；不自动覆盖。") }
    let full = !gates.isEmpty || affected.contains(where:{$0.key.hasPrefix("engine/processors")})
    let selected = [module] + baseline.filter { !legacy.contains($0) }
    var block = [begin]
    if full {
      block.append(doc.indent + "\"engine/processors\":")
      block += try selected.map { doc.indent + "  - " + (try quote($0)) }
    } else { block.append(doc.indent + "\"engine/processors/@before 0\": \"\(module)\"") }
    block += [doc.indent + "letter_selection/enabled: true",doc.indent + "letter_selection/keys: \"\(profile.keys)\"",
              doc.indent + "letter_selection/hide_candidates: \(profile.hideCandidates)",doc.indent + "menu/page_size: \(profile.pageSize)",end]
    let removed = affected.map { doc.lines[$0.range].joined(separator:doc.eol) }
    for entry in affected.reversed() { doc.lines.removeSubrange(entry.range) }
    doc.lines.insert(contentsOf:block,at:doc.patch+1)
    let output = doc.lines.joined(separator:doc.eol)
    let proof = Ownership(schema:schema,original:original,installed:output,block:block.joined(separator:doc.eol),
                          removed:removed,beforeProcessors:baseline,installedProcessors:selected,patchCreated:doc.patchCreated)
    try validateProof(proof) // Prove preservation before the first write, not only on rollback.
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(proof)
    guard data.count <= 2 * 1024 * 1024 else { throw SettingsError.invalid("所有权证明超过事务上限；未写入。") }
    return Plan(yaml:output,ownership:data,replacedLegacy:!gates.isEmpty,
                message:full ? "源补丁已按实际处理器顺序规划；迁移快照只替换已识别 gate，仍需部署验证。" : "最小插入补丁已规划，仍需部署验证。",expectedProcessors:selected)
  }
}
