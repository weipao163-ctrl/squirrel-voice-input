import Foundation
import EnhancementCore

protocol ConnectionProbeTask:AnyObject { func cancel() }
typealias ConnectionProbeFactory = (VoiceSettings,String,@escaping(ConnectionProbeResult)->Void) throws -> ConnectionProbeTask

final class ConnectionProbe:NSObject,URLSessionWebSocketDelegate,URLSessionTaskDelegate,ConnectionProbeTask {
  private var session:URLSession?
  private var socket:URLSessionWebSocketTask?
  private var timer:Timer?
  private var completed = false
  private let result:(ConnectionProbeResult)->Void
  init(settings:VoiceSettings,key:String,result:@escaping(ConnectionProbeResult)->Void) throws {
    self.result = result; super.init()
    try VoiceCredential.validate(key)
    var request = URLRequest(url:try settings.validatedConnectionEndpoint())
    for (name,value) in try settings.connectionHeaders(key:key,task:UUID()) { request.setValue(value,forHTTPHeaderField:name) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil; configuration.httpCookieStorage = nil
    session = URLSession(configuration:configuration,delegate:self,delegateQueue:nil)
    socket = session?.webSocketTask(with:request)
    socket?.maximumMessageSize = 256 * 1024
    timer = Timer.scheduledTimer(withTimeInterval:Double(settings.connectSeconds),repeats:false) { [weak self] _ in
      self?.finish(.timedOut)
    }
    socket?.resume()
  }
  private func finish(_ evidence:ConnectionProbeResult) {
    DispatchQueue.main.async {
      guard !self.completed else { return }; self.completed = true
      self.timer?.invalidate(); self.socket?.cancel(with:.normalClosure,reason:nil)
      self.session?.invalidateAndCancel(); self.result(evidence)
    }
  }
  func cancel() {
    // All completion state is confined to the main thread. A queued handshake
    // completion must not revive a cancelled test or clear a later test owner.
    assert(Thread.isMainThread)
    guard !completed else { return }; completed = true
    timer?.invalidate(); socket?.cancel(with:.goingAway,reason:nil)
    session?.invalidateAndCancel()
  }
  func urlSession(_ session:URLSession,webSocketTask:URLSessionWebSocketTask,didOpenWithProtocol protocol:String?) {
    finish(.webSocketOpened)
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
    if error != nil {
      let code = (task.response as? HTTPURLResponse)?.statusCode
      finish(.failed(httpStatus:code))
    } else { finish(.closedBeforeHandshake) }
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,
                  newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) { completionHandler(nil) }
}
