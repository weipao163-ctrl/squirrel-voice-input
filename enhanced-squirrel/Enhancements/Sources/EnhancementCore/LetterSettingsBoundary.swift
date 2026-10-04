import Foundation

public struct LetterRuntimeUpdate: Equatable {
  public var schema: String
  public var profile: LetterProfile?
  public var revision: UInt64
}

// Changing an enabled profile during composition must not disarm Selecting or
// relabel its current page. Disabling is immediate and does not clear input.
public struct LetterSettingsBoundary {
  private var applied: LetterRuntimeUpdate?
  private var pending: LetterRuntimeUpdate?
  public init() {}
  public mutating func offer(schema:String,profile:LetterProfile?,revision:UInt64,
                             composing:Bool) -> LetterRuntimeUpdate? {
    let value=LetterRuntimeUpdate(schema:schema,profile:profile,revision:revision)
    if applied?.schema == schema && applied?.profile == profile { pending=nil; return nil }
    // A fresh/new schema has no applied runtime profile to preserve. Deferring
    // its FIRST update would leave the whole first composition on stale/disabled
    // defaults until it commits. Only edits to an existing schema wait for idle.
    if composing && applied?.schema == schema && profile?.enabled == true { pending=value; return nil }
    applied=value; pending=nil; return value
  }
  public mutating func flush(composing:Bool) -> LetterRuntimeUpdate? {
    guard !composing, let value=pending else { return nil }
    return offer(schema:value.schema,profile:value.profile,revision:value.revision,composing:false)
  }
}
