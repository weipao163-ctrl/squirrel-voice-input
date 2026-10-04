import Foundation

// Applied at IPC ingress BEFORE native rendering/Int conversion or routing.
// The 900-second message horizon exceeds every configured capture/final timeout;
// it is a transport bound, NOT a measured runtime duration or service limit.
public enum VoiceUpdateBounds {
  public static func valid(level:Double,duration:Double,textBytes:Int,messageBytes:Int) -> Bool {
    level.isFinite && (0...1).contains(level) && duration.isFinite && (0...900).contains(duration) &&
      (0...128*1024).contains(textBytes) && (0...4096).contains(messageBytes)
  }
}
