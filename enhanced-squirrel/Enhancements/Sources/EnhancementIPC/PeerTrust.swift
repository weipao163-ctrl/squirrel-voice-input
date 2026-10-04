import Foundation

/// Both peers require a cryptographic signer and an exact code identifier.
/// A local certificate is explicitly pinned; a missing/invalid signer never
/// falls back to identifier-only, PID-only or ad-hoc authentication.
public struct PeerTrust {
  public enum Role {
    case inputMethod, helper
    var identifier:String {
      switch self {
      case .inputMethod: return "org.rime.inputmethod.SquirrelEnhanced.Development"
      case .helper: return "org.rime.SquirrelEnhanced.Development.VoiceHelper"
      }
    }
  }
  private enum Signer { case appleTeam(String), certificate(String) }
  private let signer:Signer
  public init?(team:String,certificateSHA1:String) {
    if !team.isEmpty {
      guard certificateSHA1.isEmpty,
            team.range(of:"\\A[A-Z0-9]+\\z",options:.regularExpression) != nil else { return nil }
      signer = .appleTeam(team)
    } else {
      guard certificateSHA1.range(of:"\\A[A-Fa-f0-9]{40}\\z",options:.regularExpression) != nil else { return nil }
      signer = .certificate(certificateSHA1.uppercased())
    }
  }
  public static func configured(in bundle:Bundle) -> PeerTrust? {
    PeerTrust(team:bundle.object(forInfoDictionaryKey:"SquirrelEnhancementTeamID") as? String ?? "",
      certificateSHA1:bundle.object(forInfoDictionaryKey:"SquirrelEnhancementCertificateSHA1") as? String ?? "")
  }
  public func requirement(for role:Role) -> String {
    let identity = "identifier \"\(role.identifier)\""
    switch signer {
    case .appleTeam(let team):
      return "anchor apple generic and \(identity) and certificate leaf[subject.OU] = \"\(team)\""
    case .certificate(let fingerprint):
      return "\(identity) and certificate leaf = H\"\(fingerprint)\""
    }
  }
}
