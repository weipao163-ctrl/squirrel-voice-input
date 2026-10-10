import Foundation

// The caller supplies active IMK client/session ownership and position evidence.
// AX role and AXValue writability describe accessibility, not keyboard support.
public enum VoiceTargetEligibility {
  public static func currentlyEligible(expectedPID:Int32, expectedBundle:String?,
      currentPID:Int32?, currentBundle:String?, clientBundle:String?, trusted:Bool,
      secureInput:Bool, subrole:String?, enabled:Bool?) -> Bool {
    expectedPID > 0 && currentPID == expectedPID && expectedBundle?.isEmpty == false &&
      currentBundle == expectedBundle && clientBundle == expectedBundle && trusted &&
      !secureInput && subrole != "AXSecureTextField" && enabled != false
  }
}
