import Foundation
import Darwin

enum AuditIOError: Error { case unsafePath, oversizedEvent, oversizedExistingFile, system(Int32) }

final class PrivateAuditLog {
  let directory: URL
  let limit: Int
  let files = FileManager.default
  init(directory: URL, limit: Int = 1024 * 1024) throws {
    self.directory = directory; self.limit = limit
    guard directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else { throw AuditIOError.unsafePath }
    let attributes = try files.attributesOfItem(atPath: directory.path)
    guard attributes[.type] as? FileAttributeType == .typeDirectory,
          (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
          ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else { throw AuditIOError.unsafePath }
  }
  func checkedSize(_ path: URL) throws -> Int {
    var value = stat()
    if lstat(path.path, &value) != 0 {
      if errno == ENOENT { return 0 }
      throw AuditIOError.system(errno)
    }
    guard value.st_mode & S_IFMT == S_IFREG, value.st_uid == getuid(), value.st_nlink == 1 else { throw AuditIOError.unsafePath }
    guard value.st_size <= limit else { throw AuditIOError.oversizedExistingFile }
    return Int(value.st_size)
  }
  func append(_ event: AuditEvent) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var bytes = try encoder.encode(event); bytes.append(0x0a)
    guard bytes.count <= limit else { throw AuditIOError.oversizedEvent }
    let paths = ["events.jsonl", "events.1.jsonl", "events.2.jsonl"].map { directory.appendingPathComponent($0) }
    let sizes = try paths.map(checkedSize)
    if sizes[0] + bytes.count > limit {
      if files.fileExists(atPath: paths[2].path) { try files.removeItem(at: paths[2]) }
      if files.fileExists(atPath: paths[1].path) { try files.moveItem(at: paths[1], to: paths[2]) }
      if files.fileExists(atPath: paths[0].path) { try files.moveItem(at: paths[0], to: paths[1]) }
    }
    let descriptor = open(paths[0].path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw AuditIOError.system(errno) }
    defer { close(descriptor) }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0 else { throw AuditIOError.system(errno) }
    guard opened.st_mode & S_IFMT == S_IFREG, opened.st_uid == getuid(), opened.st_nlink == 1,
          opened.st_size + Int64(bytes.count) <= limit else { throw AuditIOError.unsafePath }
    guard fchmod(descriptor, 0o600) == 0 else { throw AuditIOError.system(errno) }
    try bytes.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { throw AuditIOError.system(errno) }
        offset += written
      }
    }
  }
  func status(_ value: AuditRuntimeStatus) throws {
    let path = directory.appendingPathComponent("status.json")
    _ = try checkedSize(path)
    let data = try JSONEncoder().encode(value)
    try data.write(to: path, options: .atomic)
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
  }
}
