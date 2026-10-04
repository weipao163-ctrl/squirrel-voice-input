import Foundation
import Darwin
import Security

public enum IPCFailure:Error { case unavailable, identity, protocolViolation }

private enum SocketWire {
  static let maximum=384*1024
  static func prepare(_ fd:Int32) {
    var one:Int32=1
    setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd,F_SETFD,FD_CLOEXEC)
    var timeout=timeval(tv_sec:2,tv_usec:0)
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
  }
  static func address(_ path:String) throws -> sockaddr_un {
    let bytes=Array(path.utf8)+[0]
    var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX)
    address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
    guard bytes.count <= MemoryLayout.size(ofValue:address.sun_path) else { throw IPCFailure.unavailable }
    withUnsafeMutableBytes(of:&address.sun_path) { $0.copyBytes(from:bytes) }
    return address
  }
  static func write(_ data:Data,to fd:Int32) throws {
    try data.withUnsafeBytes { raw in
      var offset=0
      while offset<raw.count {
        let count=Darwin.write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset)
        if count<0 && errno==EINTR { continue }
        guard count>0 else { throw IPCFailure.unavailable };offset += count
      }
    }
  }
  static func read(_ count:Int,from fd:Int32) throws -> Data {
    var data=Data(count:count)
    try data.withUnsafeMutableBytes { raw in
      var offset=0
      while offset<count {
        let got=Darwin.read(fd,raw.baseAddress!.advanced(by:offset),count-offset)
        if got<0 && errno==EINTR { continue }
        guard got>0 else { throw IPCFailure.unavailable };offset += got
      }
    }
    return data
  }
  static func frame(_ data:Data) throws -> Data {
    guard !data.isEmpty,data.count <= maximum else { throw IPCFailure.protocolViolation }
    var length=UInt32(data.count).bigEndian
    return withUnsafeBytes(of:&length) { Data($0) }+data
  }
  static func readFrame(from fd:Int32) throws -> Data {
    let header=try read(4,from:fd)
    let length=header.reduce(UInt32(0)) { ($0<<8)|UInt32($1) }
    guard length>0,length<=maximum else { throw IPCFailure.protocolViolation }
    return try read(Int(length),from:fd)
  }
  static func authenticate(_ fd:Int32,trust:PeerTrust,role:PeerTrust.Role) throws -> (Int32,uid_t) {
    var credentials=xucred(),pid:Int32=0,token=audit_token_t()
    var credentialSize=socklen_t(MemoryLayout<xucred>.size)
    var pidSize=socklen_t(MemoryLayout<Int32>.size)
    var tokenSize=socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd,SOL_LOCAL,LOCAL_PEERCRED,&credentials,&credentialSize)==0,
          credentials.cr_uid==getuid(),
          getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&pidSize)==0,pid>0,
          getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,&token,&tokenSize)==0,
          tokenSize==MemoryLayout<audit_token_t>.size else { throw IPCFailure.identity }
    // A kernel audit token includes the PID version, preventing PID-reuse races.
    let audit=withUnsafeBytes(of:&token) { Data($0) }
    var code:SecCode?,requirement:SecRequirement?
    guard SecCodeCopyGuestWithAttributes(nil,[kSecGuestAttributeAudit as String:audit] as CFDictionary,[],&code)==errSecSuccess,
          let code,
          SecRequirementCreateWithString(trust.requirement(for:role) as CFString,[],&requirement)==errSecSuccess,
          SecCodeCheckValidity(code,[],requirement)==errSecSuccess else { throw IPCFailure.identity }
    return (pid,credentials.cr_uid)
  }
}

public struct IPCBootstrap:Codable {
  public let path:String
  public let token:Data
  public let parentPID:Int32
  public static func decode(_ data:Data) throws -> IPCBootstrap {
    guard data.count<=4096 else { throw IPCFailure.protocolViolation }
    let value=try JSONDecoder().decode(Self.self,from:data)
    guard value.path.hasPrefix("/"),!value.path.contains("\0"),value.path.utf8.count<104,
          value.token.count==32,value.parentPID>0 else { throw IPCFailure.protocolViolation }
    return value
  }
  public func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

public protocol AuthenticatedListenerDelegate:AnyObject {
  func listener(_ listener:AuthenticatedListener,shouldAcceptNewConnection candidate:AuthenticatedConnection) -> Bool
}

public final class AuthenticatedListener {
  public weak var delegate:AuthenticatedListenerDelegate?
  public let bootstrap:IPCBootstrap
  private var descriptor:Int32
  private let directory:String
  private var source:DispatchSourceRead?
  private let queue=DispatchQueue(label:"org.rime.SquirrelEnhanced.listener")
  private let authenticationQueue=DispatchQueue(label:"org.rime.SquirrelEnhanced.authenticate",attributes:.concurrent)
  private let authenticationSlots=DispatchSemaphore(value:8)
  private let trust:PeerTrust
  public init(trust:PeerTrust) throws {
    self.trust=trust
    var template=Array((NSTemporaryDirectory()+"sqv.XXXXXX").utf8CString)
    guard let created=mkdtemp(&template) else { throw IPCFailure.unavailable }
    directory=String(cString:created)
    chmod(directory,0o700)
    var token=Data(count:32)
    guard token.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault,32,$0.baseAddress!) })==errSecSuccess else {
      rmdir(directory);throw IPCFailure.unavailable
    }
    bootstrap=IPCBootstrap(path:directory+"/p",token:token,parentPID:getpid())
    descriptor=socket(AF_UNIX,SOCK_STREAM,0)
    guard descriptor>=0 else { rmdir(directory);throw IPCFailure.unavailable }
    do {
      var address=try SocketWire.address(bootstrap.path)
      let result=withUnsafePointer(to:&address) { pointer in
        pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { bind(descriptor,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) }
      }
      guard result==0,chmod(bootstrap.path,0o600)==0,listen(descriptor,8)==0 else { throw IPCFailure.unavailable }
      SocketWire.prepare(descriptor);_ = fcntl(descriptor,F_SETFL,O_NONBLOCK)
    } catch { close(descriptor);unlink(bootstrap.path);rmdir(directory);throw error }
  }
  public func resume() {
    guard source==nil else { return }
    let source=DispatchSource.makeReadSource(fileDescriptor:descriptor,queue:queue)
    let listeningFD=descriptor,path=bootstrap.path,folder=directory
    source.setEventHandler { [weak self] in self?.acceptConnections(on:listeningFD) }
    source.setCancelHandler { close(listeningFD);unlink(path);rmdir(folder) }
    self.source=source;source.resume()
  }
  private func acceptConnections(on listeningFD:Int32) {
    for _ in 0..<16 {
      let fd=accept(listeningFD,nil,nil)
      guard fd>=0 else { return }
      guard authenticationSlots.wait(timeout:.now()) == .success else { close(fd);continue }
      SocketWire.prepare(fd);_ = fcntl(fd,F_SETFL,fcntl(fd,F_GETFL) & ~O_NONBLOCK)
      authenticationQueue.async { [weak self] in
        guard let self else { close(fd);return }
        defer { self.authenticationSlots.signal() }
        do {
          var timeout=timeval(tv_sec:2,tv_usec:0)
          setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
          let (pid,uid)=try SocketWire.authenticate(fd,trust:self.trust,role:.helper)
          let hello=try SocketWire.readFrame(from:fd)
          guard hello.count==32,zip(hello,self.bootstrap.token).reduce(UInt8(0),{ $0|($1.0^$1.1) })==0 else { throw IPCFailure.identity }
          try SocketWire.write(SocketWire.frame(Data("OK".utf8)),to:fd)
          timeout=timeval(tv_sec:0,tv_usec:0)
          setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
          let connection=AuthenticatedConnection(fd:fd,pid:pid,uid:uid,receivingCommands:false)
          if self.delegate?.listener(self,shouldAcceptNewConnection:connection) != true { connection.invalidate() }
        } catch { close(fd) }
      }
    }
  }
  public func invalidate() {
    if let source { source.cancel();self.source=nil;descriptor = -1 }
    else if descriptor>=0 {
      close(descriptor);descriptor = -1;unlink(bootstrap.path);rmdir(directory)
    }
  }
  deinit { invalidate() }
}

private struct IPCEnvelope:Codable { let method:String;let payload:Data }

public final class AuthenticatedConnection {
  public let processIdentifier:Int32
  public let effectiveUserIdentifier:uid_t
  public var exportedObject:AnyObject?
  public var invalidationHandler:(()->Void)?
  public var interruptionHandler:(()->Void)?
  private let receivingCommands:Bool
  private let lock=NSLock()
  private var descriptor:Int32
  private var started=false
  private var queuedBytes=0
  private let writer=DispatchQueue(label:"org.rime.SquirrelEnhanced.ipc-writer")
  private let reader=DispatchQueue(label:"org.rime.SquirrelEnhanced.ipc-reader")
  private let deliverySlots=DispatchSemaphore(value:8)
  fileprivate init(fd:Int32,pid:Int32,uid:uid_t,receivingCommands:Bool) {
    descriptor=fd;processIdentifier=pid;effectiveUserIdentifier=uid;self.receivingCommands=receivingCommands
  }
  public static func connect(_ bootstrap:IPCBootstrap,trust:PeerTrust) throws -> AuthenticatedConnection {
    guard bootstrap.parentPID==getppid() else { throw IPCFailure.identity }
    let fd=socket(AF_UNIX,SOCK_STREAM,0);guard fd>=0 else { throw IPCFailure.unavailable }
    do {
      SocketWire.prepare(fd)
      var address=try SocketWire.address(bootstrap.path)
      let result=withUnsafePointer(to:&address) { pointer in
        pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) }
      }
      guard result==0 else { throw IPCFailure.unavailable }
      let (pid,uid)=try SocketWire.authenticate(fd,trust:trust,role:.inputMethod)
      guard pid==bootstrap.parentPID else { throw IPCFailure.identity }
      var timeout=timeval(tv_sec:2,tv_usec:0)
      setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
      try SocketWire.write(SocketWire.frame(bootstrap.token),to:fd)
      guard try SocketWire.readFrame(from:fd)==Data("OK".utf8) else { throw IPCFailure.identity }
      timeout=timeval(tv_sec:0,tv_usec:0)
      setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
      return AuthenticatedConnection(fd:fd,pid:pid,uid:uid,receivingCommands:true)
    } catch { close(fd);throw error }
  }
  private func duplicateDescriptor() -> Int32 {
    lock.lock();defer { lock.unlock() };return descriptor>=0 ? fcntl(descriptor,F_DUPFD_CLOEXEC,0) : -1
  }
  public func resume() {
    lock.lock();let shouldStart = !started && descriptor>=0;started=true;lock.unlock()
    guard shouldStart else { return }
    reader.async { [weak self] in
      guard let self else { return }
      let fd=self.duplicateDescriptor();guard fd>=0 else { return };defer { close(fd) }
      do {
        while true {
          let data=try SocketWire.readFrame(from:fd)
          let message=try JSONDecoder().decode(IPCEnvelope.self,from:data)
          guard message.method.utf8.count<=32,message.payload.count<=256*1024 else { throw IPCFailure.protocolViolation }
          guard self.deliverySlots.wait(timeout:.now()+2) == .success else { throw IPCFailure.unavailable }
          DispatchQueue.main.async { [weak self] in
            guard let self else { return };defer { self.deliverySlots.signal() };self.deliver(message)
          }
        }
      } catch { self.invalidate() }
    }
  }
  public func invalidate() {
    lock.lock();let fd=descriptor;descriptor = -1;lock.unlock()
    guard fd>=0 else { return };shutdown(fd,SHUT_RDWR);close(fd)
    DispatchQueue.main.async { [weak self] in self?.invalidationHandler?() }
  }
  public func remoteObjectProxyWithErrorHandler(_ error:@escaping (Error)->Void) -> Any {
    IPCProxy(connection:self,error:error)
  }
  fileprivate func send(_ method:String,_ payload:Data=Data(),error:@escaping (Error)->Void) {
    guard payload.count<=256*1024,
          let data=try? JSONEncoder().encode(IPCEnvelope(method:method,payload:payload)),
          let frame=try? SocketWire.frame(data) else { error(IPCFailure.protocolViolation);return }
    lock.lock();let accepted=descriptor>=0 && queuedBytes+frame.count<=2*1024*1024
    if accepted { queuedBytes += frame.count };lock.unlock()
    guard accepted else { error(IPCFailure.unavailable);invalidate();return }
    writer.async { [weak self] in
      guard let self else { return }
      defer { self.lock.lock();self.queuedBytes -= frame.count;self.lock.unlock() }
      let fd=self.duplicateDescriptor();guard fd>=0 else { error(IPCFailure.unavailable);return };defer { close(fd) }
      do { try SocketWire.write(frame,to:fd) }
      catch let failure { error(failure);self.invalidate() }
    }
  }
  private func deliver(_ value:IPCEnvelope) {
    lock.lock();let active=descriptor>=0;lock.unlock();guard active else { return }
    if receivingCommands,let commands=exportedObject as? HelperCommands {
      switch value.method {
      case "showSettings": guard value.payload.isEmpty else { invalidate();return };commands.showSettings()
      case "begin": commands.begin(value.payload)
      case "release": commands.release(value.payload)
      case "cancel": commands.cancel(value.payload)
      case "lease": commands.lease(value.payload)
      case "deploymentReply": commands.deploymentReply(value.payload)
      case "schemaCatalog": commands.schemaCatalog(value.payload)
      case "settingsApplied": commands.settingsApplied(value.payload)
      case "voiceDeliveryReceipt": commands.voiceDeliveryReceipt(value.payload)
      default: invalidate()
      }
    } else if !receivingCommands,let callbacks=exportedObject as? InputCallbacks {
      switch value.method {
      case "settingsChanged": callbacks.settingsChanged(value.payload)
      case "voiceUpdate": callbacks.voiceUpdate(value.payload)
      case "deploymentRequested": callbacks.deploymentRequested(value.payload)
      default: invalidate()
      }
    } else { invalidate() }
  }
  deinit { invalidate() }
}

private final class IPCProxy:NSObject,HelperCommands,InputCallbacks {
  private weak var connection:AuthenticatedConnection?
  private let error:(Error)->Void
  init(connection:AuthenticatedConnection,error:@escaping (Error)->Void) { self.connection=connection;self.error=error }
  private func send(_ method:String,_ data:Data=Data()) {
    guard let connection else { error(IPCFailure.unavailable);return };connection.send(method,data,error:error)
  }
  func showSettings() { send("showSettings") }
  func begin(_ request:Data) { send("begin",request) }
  func release(_ identity:Data) { send("release",identity) }
  func cancel(_ identity:Data) { send("cancel",identity) }
  func lease(_ identity:Data) { send("lease",identity) }
  func deploymentReply(_ result:Data) { send("deploymentReply",result) }
  func schemaCatalog(_ result:Data) { send("schemaCatalog",result) }
  func settingsApplied(_ result:Data) { send("settingsApplied",result) }
  func voiceDeliveryReceipt(_ result:Data) { send("voiceDeliveryReceipt",result) }
  func settingsChanged(_ configuration:Data) { send("settingsChanged",configuration) }
  func voiceUpdate(_ update:Data) { send("voiceUpdate",update) }
  func deploymentRequested(_ request:Data) { send("deploymentRequested",request) }
}
