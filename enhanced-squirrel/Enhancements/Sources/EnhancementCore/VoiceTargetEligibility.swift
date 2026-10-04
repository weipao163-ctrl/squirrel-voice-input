import Foundation

// Local current-state checks, not a substitute for client/AX/window/range
// identity checks. Nothing here reads document text or enters IPC/diagnostics.
public enum VoiceTargetEligibility {
  public static func currentlyEligible(expectedPID:Int32, expectedBundle:String?,
      currentPID:Int32?, currentBundle:String?, clientBundle:String?, trusted:Bool,
      secureInput:Bool, role:String?, subrole:String?, writable:Bool) -> Bool {
    guard expectedPID > 0, currentPID == expectedPID,
          let expectedBundle, !expectedBundle.isEmpty,
          currentBundle == expectedBundle, clientBundle == expectedBundle,
          trusted, !secureInput, writable,
          role == "AXTextField" || role == "AXTextArea", subrole != "AXSecureTextField" else { return false }
    return true
  }
}
