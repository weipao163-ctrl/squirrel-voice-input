import Foundation
import EnhancementCore
import EnhancementIPC

// The Helper owns session admission and lifecycle; the live implementation
// owns the microphone and transport. Native regression probes replace only
// that boundary, so they can exercise real Helper commands without uploading.
protocol VoiceSession:AnyObject {
  func start(key:String)
  func release(at:TimeInterval,cause:VoiceStopCause)
  func cancel()
  func renewLease()
  func clearDiagnostics()
}
extension VoiceSession {
  func release(cause:VoiceStopCause) {
    release(at:ProcessInfo.processInfo.systemUptime,cause:cause)
  }
}
typealias VoiceSessionFactory = (VoiceIdentity,VoiceSettings,Bool,UInt64?,TimeInterval?,
  @escaping(VoiceUpdate,VoiceDiagnosticSnapshot)->Void)->VoiceSession
