import Foundation
import Darwin
import Security
import EnhancementIPC

final class ProbeCallbacks:NSObject,InputCallbacks {
  var echoed=false
  func settingsChanged(_ configuration:Data) {}
  func voiceUpdate(_ update:Data) { echoed = update == Data(repeating:65,count:65536) }
  func deploymentRequested(_ request:Data) {}
}
final class ProbeCommands:NSObject,HelperCommands {
  weak var connection:AuthenticatedConnection?
  func showSettings() {}
  func begin(_ request:Data) {
    (connection?.remoteObjectProxyWithErrorHandler { _ in } as? InputCallbacks)?.voiceUpdate(request)
  }
  func release(_ identity:Data) {}
  func cancel(_ identity:Data) {}
  func lease(_ identity:Data) {}
  func deploymentReply(_ result:Data) {}
  func schemaCatalog(_ result:Data) {}
  func settingsApplied(_ result:Data) {}
  func voiceDeliveryReceipt(_ result:Data) {}
}
final class ProbeListener:NSObject,AuthenticatedListenerDelegate {
  var expectedPID:Int32 = -1
  var connected:AuthenticatedConnection?
  var rejectPID=false
  var error=false
  let callbacks=ProbeCallbacks()
  func listener(_ listener:AuthenticatedListener,shouldAcceptNewConnection c:AuthenticatedConnection) -> Bool {
    guard !rejectPID,c.processIdentifier==expectedPID,c.effectiveUserIdentifier==getuid() else { return false }
    c.exportedObject=callbacks;connected=c
    c.invalidationHandler={ self.error=true };c.resume()
    (c.remoteObjectProxyWithErrorHandler { _ in self.error=true } as? HelperCommands)?.begin(Data(repeating:65,count:65536))
    return true
  }
}
@main enum NativeIPCTrustProbe {
  static func rawAttack(_ bootstrap:IPCBootstrap,mode:String) throws {
    let fd=socket(AF_UNIX,SOCK_STREAM,0);defer { close(fd) }
    var one:Int32=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,4)
    var timeout=timeval(tv_sec:2,tv_usec:0);setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
    var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
    address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of:&address.sun_path) { $0.copyBytes(from:Array(bootstrap.path.utf8)+[0]) }
    guard withUnsafePointer(to:&address,{ $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } })==0 else { throw IPCFailure.unavailable }
    func send(_ data:Data) throws {
      try data.withUnsafeBytes { raw in
        var offset=0
        while offset<raw.count {
          let n=Darwin.write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset)
          guard n>0 else { throw IPCFailure.unavailable };offset += n
        }
      }
    }
    func frame(_ data:Data) -> Data { var count=UInt32(data.count).bigEndian;return withUnsafeBytes(of:&count) { Data($0) }+data }
    try send(frame(bootstrap.token))
    var acknowledgement=Data(count:6)
    var received=0
    while received<6 {
      let n=acknowledgement.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress!.advanced(by:received),6-received) }
      guard n>0 else { throw IPCFailure.unavailable };received += n
    }
    if mode == "oversized" { var length=UInt32(384*1024+1).bigEndian;try send(withUnsafeBytes(of:&length) { Data($0) }) }
    else if mode == "malformed" { try send(frame(Data("{invalid}".utf8))) }
    else {
      let message:[String:Any] = ["method":mode == "unknown" ? "inventedCommand" : "voiceUpdate",
        "payload":mode == "oversizedPayload" ? Data(repeating:65,count:256*1024+1).base64EncodedString() : ""]
      try send(frame(JSONSerialization.data(withJSONObject:message)))
    }
    var buffer=[UInt8](repeating:0,count:8192)
    while Darwin.read(fd,&buffer,buffer.count)>0 {}
  }
  static func main() throws {
    let args=CommandLine.arguments
    if args.count == 2 && args[1] == "validate" {
      let fingerprint=String(repeating:"A",count:40)
      let cases:[(String,String,Bool)] = [("","",false),("",fingerprint,true),("TEAM123","",true),
        ("TEAM123",fingerprint,false),("bad team","",false),("","ABC",false),
        ("",String(repeating:"Z",count:40),false),("\" or always","",false),
        ("",fingerprint+"\" or always",false),("TEAM123\n","",false),("",fingerprint+"\n",false)]
      var passed=0
      for (team,cert,expected) in cases {
        let trust=PeerTrust(team:team,certificateSHA1:cert)
        guard (trust != nil) == expected else { exit(1) }
        if let trust {
          for role:PeerTrust.Role in [.inputMethod,.helper] {
            var requirement:SecRequirement?
            guard SecRequirementCreateWithString(trust.requirement(for:role) as CFString,[],&requirement) == errSecSuccess else { exit(1) }
          }
        }
        passed += 1
      }
      let sample:[String:Any] = ["path":"/tmp/private/p","token":Data(repeating:0,count:32).base64EncodedString(),"parentPID":1]
      var bootstrapChecks=0
      for (field,value) in [("path","relative" as Any),("path","/bad\0path" as Any),("path","/"+String(repeating:"a",count:104)),
        ("token",Data(repeating:0,count:31).base64EncodedString()),("token",Data(repeating:0,count:33).base64EncodedString()),
        ("parentPID",0),("parentPID",-1),("parentPID","not-a-pid")] {
        var broken=sample;broken[field]=value
        guard (try? IPCBootstrap.decode(JSONSerialization.data(withJSONObject:broken)))==nil else { exit(1) }
        bootstrapChecks += 1
      }
      guard (try? IPCBootstrap.decode(Data(repeating:65,count:4097)))==nil,
            (try? IPCBootstrap.decode(Data("{invalid}".utf8)))==nil,
            (try? IPCBootstrap.decode(JSONSerialization.data(withJSONObject:sample))) != nil else { exit(1) }
      bootstrapChecks += 3
      print("{\"passed\":\(passed),\"bootstrap_checks\":\(bootstrapChecks)}"); return
    }
    guard args.count >= 4 else { exit(2) }
    let trust=PeerTrust(team:"",certificateSHA1:args[3])!
    if args[1] == "child" {
      let data=FileHandle.standardInput.readDataToEndOfFile()
      do {
        let mode=args.count>4 ? args[4] : "normal"
        var changed=data
        if mode == "wrongToken" || mode == "wrongParentPID" {
          var fields=try JSONSerialization.jsonObject(with:data) as! [String:Any]
          if mode == "wrongToken" { fields["token"]=Data(repeating:0,count:32).base64EncodedString() }
          else { fields["parentPID"]=getppid()+1 }
          changed=try JSONSerialization.data(withJSONObject:fields)
        }
        let bootstrap=try IPCBootstrap.decode(changed)
        if ["oversized","malformed","unknown","oversizedPayload"].contains(mode) {
          try rawAttack(bootstrap,mode:mode);return
        }
        let connection=try AuthenticatedConnection.connect(bootstrap,trust:trust)
        let service=ProbeCommands();service.connection=connection;connection.exportedObject=service
        var ended=false;connection.invalidationHandler={ ended=true };connection.resume()
        withExtendedLifetime((connection,service)) {
          let until=Date().addingTimeInterval(12)
          while Date()<until && !ended { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
        }
        connection.invalidate()
      } catch { return }
    } else {
      let delegate=ProbeListener()
      delegate.rejectPID = args.count > 6 && args[6] == "rejectPID"
      let listener=try AuthenticatedListener(trust:trust);listener.delegate=delegate;listener.resume()
      let child=Process();let pipe=Pipe();child.executableURL=URL(fileURLWithPath:args[2]);child.standardInput=pipe
      child.standardOutput=FileHandle.nullDevice;child.standardError=FileHandle.nullDevice
      child.arguments=["child","unused",args[4],args.count>7 ? args[7] : "normal"]
      try child.run();delegate.expectedPID=child.processIdentifier
      try pipe.fileHandleForWriting.write(contentsOf:listener.bootstrap.encoded());try pipe.fileHandleForWriting.close()
      let until=Date().addingTimeInterval(3)
      while Date()<until && !delegate.callbacks.echoed && !delegate.error { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
      delegate.connected?.invalidate();listener.invalidate()
      let exitDeadline=Date().addingTimeInterval(2)
      while child.isRunning && Date()<exitDeadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
      let ownerLossStopped = !child.isRunning
      if child.isRunning { child.terminate() };child.waitUntilExit()
      let expected=args[5] == "accept"
      let frameAttack=args.count>7 && ["oversized","malformed","unknown","oversizedPayload"].contains(args[7])
      let passed=delegate.callbacks.echoed == expected && (!expected || ownerLossStopped) && (!frameAttack || delegate.error)
      let output:[String:Any] = ["echoed":delegate.callbacks.echoed,"connection_error":delegate.error,
        "expected_accept":expected,"owner_loss_stops_peer":ownerLossStopped,"passed":passed]
      print(String(data:try JSONSerialization.data(withJSONObject:output,options:.sortedKeys),encoding:.utf8)!)
      exit(passed ? 0 : 1)
    }
  }
}
