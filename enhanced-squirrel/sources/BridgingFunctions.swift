//
//  BridgingFunctions.swift
//  Squirrel
//
//  Created by Leo Liu on 5/11/24.
//

import Foundation

protocol DataSizeable {
  // swiftlint:disable:next identifier_name
  var data_size: Int32 { get set }
}

extension RimeContext_stdbool: DataSizeable {}
extension RimeTraits: DataSizeable {}
extension RimeCommit: DataSizeable {}
extension RimeStatus_stdbool: DataSizeable {}
extension RimeModule: DataSizeable {}

extension DataSizeable {
  static func rimeStructInit() -> Self {
    let valuePointer = UnsafeMutablePointer<Self>.allocate(capacity: 1)
    memset(valuePointer, 0, MemoryLayout<Self>.size)
    var value = valuePointer.move()
    valuePointer.deallocate()
    // RIME_STRUCT_INIT subtracts sizeof(data_size), an Int32 field. A Swift
    // key-path object's size is unrelated to the C struct ABI.
    let offset = MemoryLayout<Int32>.size
    value.data_size = Int32(MemoryLayout<Self>.size - offset)
    return value
  }

  mutating func setCString(_ swiftString: String, to keypath: WritableKeyPath<Self, UnsafePointer<CChar>?>) {
    swiftString.withCString { cStr in
      // Rime traits keep C string pointers after this closure returns.
      let mutableCStr = strdup(cStr)
      if let existing = self[keyPath: keypath] {
        free(UnsafeMutableRawPointer(mutating: existing))
      }
      self[keyPath: keypath] = UnsafePointer(mutableCStr)
    }
  }
}

infix operator ?= : AssignmentPrecedence
// swiftlint:disable:next operator_whitespace
func ?=<T>(left: inout T, right: T?) {
  if let right = right {
    left = right
  }
}
// swiftlint:disable:next operator_whitespace
func ?=<T>(left: inout T?, right: T?) {
  if let right = right {
    left = right
  }
}

extension NSRange {
  static let empty = NSRange(location: NSNotFound, length: 0)
}

extension NSPoint {
  static func += (lhs: inout Self, rhs: Self) {
    lhs.x += rhs.x
    lhs.y += rhs.y
  }
  static func - (lhs: Self, rhs: Self) -> Self {
    Self.init(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
  }
  static func -= (lhs: inout Self, rhs: Self) {
    lhs.x -= rhs.x
    lhs.y -= rhs.y
  }
  static func * (lhs: Self, rhs: CGFloat) -> Self {
    Self.init(x: lhs.x * rhs, y: lhs.y * rhs)
  }
  static func / (lhs: Self, rhs: CGFloat) -> Self {
    Self.init(x: lhs.x / rhs, y: lhs.y / rhs)
  }
  var length: CGFloat {
    sqrt(pow(self.x, 2) + pow(self.y, 2))
  }
}

// This is called after the producing librime operation returns, on the main
// queue. A live session may still lack a schema; get_status checks that before
// the label API, whose linked implementation dereferences schema()->config().
func readyRimeOptionLabels(api:RimeApi_stdbool,session:RimeSessionId,name:String,state:Bool) -> (short:String?,long:String?)? {
  guard session != 0, !api.is_maintenance_mode(), api.find_session(session) else { return nil }
  var status=RimeStatus_stdbool.rimeStructInit()
  guard api.get_status(session,&status) else { return nil }
  defer { _ = api.free_status(&status) }
  guard status.schema_id != nil, status.schema_name != nil else { return nil }
  return name.withCString { option in
    guard api.get_option(session,option) == state else { return nil } // Superseded queued notice.
    func copy(_ slice:RimeStringSlice) -> String? {
      guard let pointer=slice.str else { return nil }
      return String(data:Data(bytes:pointer,count:Int(slice.length)),encoding:.utf8)
    }
    return (copy(api.get_state_label_abbreviated(session,option,state,true)),
      copy(api.get_state_label_abbreviated(session,option,state,false)))
  }
}

// IMK and AX can report different coordinate spaces (for example, a native
// editor slice versus the full accessibility value). Freeze each independently.
// AX is mandatory; an unsupported IMK selection is not invented as offset zero.
struct VoiceTargetSelection {
  let native:NSRange
  let accessibility:NSRange
  init?(native:NSRange,accessibility:NSRange?) {
    guard let accessibility,accessibility.location != NSNotFound,accessibility.length == 0,
          native.length == 0 else { return nil }
    self.native=native; self.accessibility=accessibility
  }
  func matches(native:NSRange,accessibility:NSRange?) -> Bool {
    native == self.native && accessibility == self.accessibility
  }
}
