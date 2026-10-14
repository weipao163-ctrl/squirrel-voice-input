import Foundation

public enum BundledLetterDefaults {
  public static let schema = "luna_pinyin"
  // A shared default is replaced by a user custom file, not merged into it.
  // Normalize only that proven shared insertion before planning a user patch.
  // Foreign processors and existing user files still require ownership proof.
  public static func deploymentBaseline(schema:String, hasUserPatch:Bool,
      hasOwnership:Bool, trustedBundledDefault:Bool, processors:[String]) -> [String] {
    guard schema == Self.schema, !hasUserPatch, !hasOwnership,
          trustedBundledDefault, processors.first == ManagedLetterPatch.module,
          processors.filter({$0 == ManagedLetterPatch.module}).count == 1 else { return processors }
    return Array(processors.dropFirst())
  }
}
