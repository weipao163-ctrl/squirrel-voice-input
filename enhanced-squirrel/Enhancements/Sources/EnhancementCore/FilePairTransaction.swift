import Foundation

// Two owned files, byte-exact recovery proof. A crash between atomic renames is
// recoverable; later user edits are a conflict, not permission to overwrite.
public enum FilePairTransaction {
  private struct Change: Codable {
    var name:String
    var before:Data?
    var after:Data?
  }
  private struct Journal: Codable {
    var version = 1
    var changes:[Change]
  }
  private static func file(_ name:String,directory:URL) throws -> URL {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
      throw SettingsError.invalid("事务文件名无效。")
    }
    let url = directory.appendingPathComponent(name)
    if (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true {
      throw SettingsError.invalid("事务文件是符号链接；未写入。")
    }
    return url
  }
  private static func boundedBytes(_ url:URL,limit:Int) throws -> Data {
    let handle = try FileHandle(forReadingFrom:url)
    defer { try? handle.close() }
    var data = Data()
    while data.count <= limit {
      guard let chunk = try handle.read(upToCount:limit + 1 - data.count), !chunk.isEmpty else { break }
      data.append(chunk)
    }
    guard data.count <= limit else { throw SettingsError.invalid("源文件或恢复日志超过事务大小上限；保留现场。") }
    return data
  }
  private static func bytes(_ url:URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath:url.path) else { return nil }
    return try boundedBytes(url,limit:2 * 1024 * 1024)
  }
  public static func recover(directory:URL,journalName:String,ownedNames:[String]) throws {
    let journalURL = try file(journalName,directory:directory)
    guard FileManager.default.fileExists(atPath:journalURL.path) else { return }
    let data = try boundedBytes(journalURL,limit:12 * 1024 * 1024)
    let journal = try JSONDecoder().decode(Journal.self,from:data)
    guard journal.version == 1, journal.changes.count == 2,
          journal.changes.map({$0.name}) == ownedNames, Set(ownedNames).count == 2,
          !ownedNames.contains(journalName) else { throw SettingsError.invalid("恢复日志身份不符；保留现场。") }
    guard journal.changes.allSatisfy({
      ($0.before?.count ?? 0) <= 2 * 1024 * 1024 && ($0.after?.count ?? 0) <= 2 * 1024 * 1024
    }) else { throw SettingsError.invalid("恢复日志中的文件镜像超限；未修改任何当前文件。") }
    // Preflight both BEFORE changing either. Every current file must be one of
    // the recorded transaction states, including an originally absent file.
    for change in journal.changes {
      let current = try bytes(file(change.name,directory:directory))
      guard current == change.before || current == change.after else {
        throw SettingsError.invalid("事务中断后出现用户修改；未覆盖任何当前文件。")
      }
    }
    for change in journal.changes {
      let url = try file(change.name,directory:directory)
      let current = try bytes(url)
      guard current == change.before || current == change.after else { throw SettingsError.invalid("文件在恢复中改变；保留日志。") }
      if current == change.after { continue }
      if let after = change.after { try after.write(to:url,options:.atomic) }
      else if FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
    }
    try FileManager.default.removeItem(at:journalURL)
  }
  public static func apply(directory:URL,journalName:String,first:(String,Data?),second:(String,Data?)) throws {
    let names = [first.0,second.0]
    guard Set(names).count == 2, !names.contains(journalName) else { throw SettingsError.invalid("事务文件冲突。") }
    try recover(directory:directory,journalName:journalName,ownedNames:names)
    let changes = try [first,second].map { item -> Change in
      guard (item.1?.count ?? 0) <= 2 * 1024 * 1024 else { throw SettingsError.invalid("补丁超过大小上限。") }
      return Change(name:item.0,before:try bytes(file(item.0,directory:directory)),after:item.1)
    }
    let journal = try JSONEncoder().encode(Journal(changes:changes))
    try journal.write(to:file(journalName,directory:directory),options:.atomic)
    try recover(directory:directory,journalName:journalName,ownedNames:names)
  }
}
