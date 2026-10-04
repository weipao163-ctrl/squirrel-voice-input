import AVFoundation

// The system implementation is the only production permission source. An
// injected client lets the native offline probe exercise denial/reentrancy
// without asking for TCC access, opening a microphone or changing user consent.
struct MicrophonePermissionClient {
  var authorization: () -> AVAuthorizationStatus
  var request: (@escaping (Bool) -> Void) -> Void
  static let system = MicrophonePermissionClient(
    authorization: { AVCaptureDevice.authorizationStatus(for:.audio) },
    request: { completion in AVCaptureDevice.requestAccess(for:.audio,completionHandler:completion) })
}
