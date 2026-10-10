import XCTest
@testable import EnhancementCore

final class CoreTests:XCTestCase {
  private var doubaoVoice:VoiceSettings {
    var value=VoiceSettings(); value.model = .doubao; return value
  }
  // Independent wire construction: server headers/lengths are not produced by
  // DoubaoProtocol, so decoder assertions do not round-trip its own encoder.
  private func doubaoPacket(_ object:[String:Any],flags:UInt8=0,sequence:Int32?=nil) throws -> Data {
    doubaoWire(try JSONSerialization.data(withJSONObject:object),flags:flags,sequence:sequence)
  }
  private func doubaoWire(_ payload:Data,flags:UInt8=0,sequence:Int32?=nil,compression:UInt8=0) -> Data {
    var packet=Data([0x11,0x90|flags,0x10|compression,0])
    func integer(_ value:UInt32) { packet.append(contentsOf:[UInt8((value>>24)&255),UInt8((value>>16)&255),UInt8((value>>8)&255),UInt8(value&255)]) }
    if let sequence { integer(UInt32(bitPattern:sequence)) }; integer(UInt32(payload.count)); packet.append(payload); return packet
  }
  private func gzipFixture() throws -> [String:String] {
    let url=try XCTUnwrap(Bundle.module.url(forResource:"doubao-gzip",withExtension:"json"))
    return try JSONDecoder().decode([String:String].self,from:Data(contentsOf:url))
  }
  func testDoubaoMigrationPreservesExistingProviderAndPolishChoices() throws {
    let old=try JSONDecoder().decode(VoiceSettings.self,from:Data("{\"model\":\"qwen-audio-3.1-asr-flash-message\",\"credentialReference\":\"qwen-ref\",\"nativePolish\":true}".utf8))
    XCTAssertEqual(old.model,.message); XCTAssertEqual(old.activeCredentialReference,"qwen-ref"); XCTAssertTrue(old.nativePolish)
    XCTAssertNil(old.doubao.credentialReference); XCTAssertFalse(old.doubao.nativePolish)
    XCTAssertEqual(old.doubao.resource,.seedDuration); XCTAssertEqual(old.doubao.authentication,.apiKey)
    XCTAssertFalse(VoiceModel.streaming.supportsNativePolish); XCTAssertTrue(VoiceModel.doubao.supportsNativePolish)
  }
  func testDoubaoSettingsPersistSeparateCredentialsAndPolishWithoutCloud() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store=SettingsStore(url:directory.appendingPathComponent("settings.json"))
    var value=Settings(); value.voice=doubaoVoice; value.voice.credentialReference="qwen-ref"
    value.voice.nativePolish=true; value.voice.doubao.credentialReference="doubao-ref"
    value.voice.doubao.authentication = .appAccessToken; value.voice.doubao.appID="12345"
    value.voice.doubao.resource = .bigConcurrent; value.voice.doubao.nativePolish=false
    let saved=try store.save(value), loaded=try store.load()
    XCTAssertEqual(loaded,saved); XCTAssertEqual(loaded.voice.activeCredentialReference,"doubao-ref")
    XCTAssertTrue(loaded.voice.nativePolish); XCTAssertFalse(loaded.voice.doubao.nativePolish)
    XCTAssertFalse(try String(contentsOf:store.url).contains("fixture-secret"))
  }
  func testDoubaoHeadersNeverReuseOrSendQwenCredentialsAndWorkspace() throws {
    var voice=doubaoVoice; voice.workspace="ws-private"; voice.credentialReference="qwen-ref"
    XCTAssertNil(voice.activeCredentialReference)
    voice.activeCredentialReference="doubao-ref"; XCTAssertEqual(voice.credentialReference,"qwen-ref")
    let task=UUID(), headers=try voice.connectionHeaders(key:"fixture-doubao",task:task)
    XCTAssertEqual(headers["X-Api-Key"],"fixture-doubao"); XCTAssertNil(headers["Authorization"])
    XCTAssertNil(headers["X-Api-App-Key"]); XCTAssertNil(headers["X-Api-Access-Key"]); XCTAssertNil(headers["X-DashScope-WorkSpace"])
    XCTAssertEqual(headers["X-Api-Resource-Id"],"volc.seedasr.sauc.duration")
    XCTAssertEqual(headers["X-Api-Request-Id"].flatMap(UUID.init(uuidString:)),task); XCTAssertEqual(headers["X-Api-Sequence"],"-1")
    XCTAssertEqual(try voice.endpoint().absoluteString,"wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")
    voice.model = .streaming; XCTAssertEqual(voice.activeCredentialReference,"qwen-ref")
  }
  func testDoubaoLegacyAuthenticationRequiresSafeAppIDAndUsesOnlyLegacyHeaders() throws {
    var voice=doubaoVoice; voice.doubao.authentication = .appAccessToken
    for app in ["","bad\nheader","https://example.com",String(repeating:"x",count:129)] {
      voice.doubao.appID=app; XCTAssertThrowsError(try voice.connectionHeaders(key:"fixture",task:UUID()))
    }
    voice.doubao.appID="12345"; voice.doubao.resource = .seedConcurrent
    let headers=try voice.connectionHeaders(key:"fixture-access-token",task:UUID())
    XCTAssertEqual(headers["X-Api-App-Key"],"12345"); XCTAssertEqual(headers["X-Api-Access-Key"],"fixture-access-token")
    XCTAssertNil(headers["X-Api-Key"]); XCTAssertEqual(headers["X-Api-Resource-Id"],"volc.seedasr.sauc.concurrent")
    XCTAssertThrowsError(try voice.connectionHeaders(key:"fixture\r\nsecret",task:UUID()))
  }
  func testDoubaoRunContainsOnlyDocumentedAudioAndExplicitNativePolish() throws {
    for polish in [false,true] {
      var voice=doubaoVoice; voice.doubao.nativePolish=polish; voice.nativePolish = !polish
      let packet=try DoubaoProtocol.run(task:UUID(),settings:voice)
      XCTAssertEqual(Array(packet.prefix(4)),[0x11,0x10,0x10,0])
      let object=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(packet.dropFirst(8))) as? [String:Any])
      let audio=try XCTUnwrap(object["audio"] as? [String:Any]), request=try XCTUnwrap(object["request"] as? [String:Any])
      XCTAssertEqual(audio["rate"] as? Int,16000); XCTAssertEqual(audio["bits"] as? Int,16); XCTAssertEqual(audio["channel"] as? Int,1)
      XCTAssertEqual(request["model_name"] as? String,"bigmodel"); XCTAssertEqual(request["result_type"] as? String,"full")
      XCTAssertEqual(request["enable_ddc"] as? Bool,polish); XCTAssertNil(request["context"]); XCTAssertNil(request["hotwords"])
      XCTAssertThrowsError(try QwenProtocol.run(task:UUID(),settings:voice))
    }
    XCTAssertThrowsError(try DoubaoProtocol.run(task:UUID(),settings:VoiceSettings()))
  }
  func testDoubaoPCMFramesPreserveSamplesAndExplicitLastEmptyFrame() throws {
    let pcm=Data((0..<3200).map{UInt8($0%256)}), packet=try DoubaoProtocol.audio(pcm)
    XCTAssertEqual(Array(packet.prefix(8)),[0x11,0x20,0,0,0,0,0x0c,0x80]); XCTAssertEqual(Data(packet.dropFirst(8)),pcm)
    XCTAssertEqual(try DoubaoProtocol.audio(Data(),final:true),Data([0x11,0x22,0,0,0,0,0,0]))
    XCTAssertThrowsError(try DoubaoProtocol.audio(Data([1]))); XCTAssertThrowsError(try DoubaoProtocol.audio(Data(repeating:0,count:6402)))
  }
  func testDoubaoDecoderRejectsMalformedHeadersLengthsAndAmbiguousText() throws {
    let valid=try doubaoPacket(["result":["text":"结果"]])
    for offset in [0,1,2,3,7] {
      var malformed=valid; malformed[offset]=255; XCTAssertThrowsError(try DoubaoProtocol.response(malformed))
    }
    XCTAssertThrowsError(try DoubaoProtocol.response(Data(valid.dropLast())))
    var appended=valid; appended.append(0); XCTAssertThrowsError(try DoubaoProtocol.response(appended))
    for result:Any in [["text":123],[["text":"甲"],["text":"乙"]],["text":String(repeating:"a",count:65537)]] {
      XCTAssertThrowsError(try DoubaoProtocol.response(doubaoPacket(["result":result])))
    }
    for code:Any in [true,-1,0.1,"20000000"] { XCTAssertThrowsError(try DoubaoProtocol.response(doubaoPacket(["code":code]))) }
    let single=try DoubaoProtocol.response(doubaoPacket(["result":[["text":"单段"]]]))
    XCTAssertEqual(single.text,"单段")
  }
  func testDoubaoGzipServerResponseUsesIndependentCompressedFixture() throws {
    let fixture=try gzipFixture(), gzip=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(fixture["gzip"])))
    let result=try DoubaoProtocol.response(doubaoWire(gzip,flags:3,sequence:-3,compression:1))
    XCTAssertEqual(result.text,"豆包原生润色测试。"); XCTAssertTrue(result.final); XCTAssertEqual(result.sequence,-3)
    let positiveSample=try DoubaoProtocol.response(doubaoWire(gzip,flags:3,sequence:3,compression:1))
    XCTAssertTrue(positiveSample.final); XCTAssertEqual(positiveSample.text,result.text)
  }
  func testDoubaoGzipRejectsTruncationCRCExtraMembersAndInflationBomb() throws {
    let fixture=try gzipFixture(), gzip=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(fixture["gzip"])))
    var corrupt=gzip; corrupt[corrupt.count-8] ^= 255
    let bomb=try XCTUnwrap(Data(base64Encoded:try XCTUnwrap(fixture["overBudgetGzip"])))
    for payload in [Data(gzip.dropLast()),corrupt,gzip+Data([0]),gzip+gzip,bomb] {
      XCTAssertThrowsError(try DoubaoProtocol.response(doubaoWire(payload,compression:1)))
    }
  }
  func testDoubaoFullSnapshotsReplacePartialAndCommitFinalOnlyOnce() throws {
    var reducer=VoiceEventReducer(identity:VoiceIdentity(generation:1),settings:doubaoVoice)
    reducer.configurationSent()
    _ = try reducer.receive(doubaoPacket(["result":["text":"今天" ]],flags:1,sequence:1))
    _ = try reducer.receive(doubaoPacket(["result":["text":"今天测试语音。"]],flags:1,sequence:2))
    XCTAssertEqual(reducer.transcript.preview,"今天测试语音。"); XCTAssertFalse(reducer.transcript.isComplete)
    reducer.release(at:1); XCTAssertFalse(reducer.sendFinish(queueEmpty:false)); XCTAssertTrue(reducer.sendFinish(queueEmpty:true))
    XCTAssertFalse(reducer.sendFinish(queueEmpty:true))
    let final=try doubaoPacket(["result":["text":"今天测试语音。"]],flags:3,sequence:-3)
    XCTAssertEqual(try reducer.receive(final),.taskFinished); XCTAssertEqual(reducer.state.phase,.ready)
    XCTAssertTrue(reducer.attemptCommit(validated:true)); XCTAssertFalse(reducer.attemptCommit(validated:true))
    XCTAssertEqual(try reducer.receive(final),.ignoredTerminal)
  }
  func testDoubaoDefiniteUtteranceDoesNotFinishWholeRecording() throws {
    var reducer=VoiceEventReducer(identity:VoiceIdentity(generation:1),settings:doubaoVoice)
    _ = try reducer.receive(doubaoPacket(["result":["text":"单句完成", "utterances":[["definite":true,"text":"单句完成"]]]]))
    XCTAssertEqual(reducer.state.phase,.recording); XCTAssertTrue(reducer.state.physicalHeld)
    XCTAssertFalse(reducer.transcript.isComplete); XCTAssertFalse(reducer.state.resultIsComplete(transcriptComplete:false))
  }
  func testDoubaoMissingFinalSnapshotCannotPromotePriorDraft() throws {
    var reducer=VoiceEventReducer(identity:VoiceIdentity(generation:1),settings:doubaoVoice)
    _ = try reducer.receive(doubaoPacket(["result":["text":"临时文本"]]))
    reducer.release(at:1); XCTAssertTrue(reducer.sendFinish(queueEmpty:true))
    XCTAssertEqual(try reducer.receive(doubaoPacket(["code":20000000],flags:2)),.taskFinished)
    XCTAssertEqual(reducer.state.phase,.review); XCTAssertEqual(reducer.transcript.preview,"临时文本")
    XCTAssertFalse(reducer.state.resultIsComplete(transcriptComplete:reducer.transcript.permitsAutomaticInsertion))
  }
  func testDoubaoEarlyFinalAndUndrainedFinishRemainUnconfirmed() throws {
    for released in [false,true] {
      var reducer=VoiceEventReducer(identity:VoiceIdentity(generation:1),settings:doubaoVoice)
      reducer.configurationSent(); if released { reducer.release(at:1) }
      _ = try reducer.receive(doubaoPacket(["result":["text":"提前结束"]],flags:2))
      XCTAssertEqual(reducer.state.phase,.review); XCTAssertFalse(reducer.attemptCommit(validated:true))
      XCTAssertFalse(reducer.state.resultIsComplete(transcriptComplete:reducer.transcript.permitsAutomaticInsertion))
    }
  }
  func testDoubaoSequenceDuplicatesAreIdempotentButConflictsFailClosed() throws {
    let packet=try doubaoPacket(["result":["text":"草稿"]],flags:1,sequence:2)
    for late in [try doubaoPacket(["result":["text":"不同"]],flags:1,sequence:2),try doubaoPacket(["result":["text":"旧"]],flags:1,sequence:1)] {
      var reducer=VoiceEventReducer(identity:VoiceIdentity(generation:1),settings:doubaoVoice)
      _ = try reducer.receive(packet); XCTAssertNoThrow(try reducer.receive(packet))
      XCTAssertEqual(reducer.transcript.preview,"草稿"); XCTAssertThrowsError(try reducer.receive(late))
      XCTAssertEqual(reducer.state.phase,.failed)
      XCTAssertEqual(try reducer.receive(doubaoPacket(["result":["text":"迟到"]],flags:2)),.ignoredTerminal)
    }
  }
  func testDoubaoServiceErrorsAreTerminalAndDoNotEchoServerSecrets() throws {
    var reducer=VoiceEventReducer(identity:VoiceIdentity(generation:1),settings:doubaoVoice)
    let body=Data("fixture-secret-token".utf8)
    var packet=Data([0x11,0xf0,0,0,2,0xae,0xa5,0x42,0,0,0,UInt8(body.count)]) // 45000002, empty audio.
    packet.append(body)
    XCTAssertEqual(try reducer.receive(packet),.taskFailed); XCTAssertEqual(reducer.state.phase,.failed)
    XCTAssertTrue(reducer.cloudFailureMessage?.contains("空音频") == true)
    XCTAssertFalse(reducer.cloudFailureMessage?.contains("fixture-secret-token") == true)
    XCTAssertEqual(try reducer.receive(doubaoPacket(["result":["text":"迟到"]],flags:2)),.ignoredTerminal)
    let jsonError=try DoubaoProtocol.response(doubaoPacket(["code":55000031,"message":"fixture-secret-token"]))
    XCTAssertEqual(jsonError.errorCode,55000031)
  }
  func testDoubaoConfigurationCompletionNeverRearmsReleasedOrCancelledCapture() {
    var reducer=VoiceEventReducer(identity:VoiceIdentity(generation:1),settings:doubaoVoice)
    reducer.release(at:1); reducer.configurationSent()
    XCTAssertTrue(reducer.state.taskStarted); XCTAssertEqual(reducer.state.phase,.finalizing)
    XCTAssertFalse(reducer.state.capturePermitted); XCTAssertFalse(reducer.state.physicalHeld)
    reducer.cancel(); reducer.configurationSent(); XCTAssertEqual(reducer.state.phase,.cancelled)
    var qwen=VoiceEventReducer(identity:VoiceIdentity(generation:1),settings:VoiceSettings())
    qwen.configurationSent(); XCTAssertFalse(qwen.state.taskStarted)
  }
  func testDoubaoInvalidTargetAndMalformedWireCanNeverInsertLateFinal() throws {
    var reducer=VoiceEventReducer(identity:VoiceIdentity(generation:1),settings:doubaoVoice)
    reducer.configurationSent(); reducer.invalidateTarget(at:1); XCTAssertTrue(reducer.sendFinish(queueEmpty:true))
    _ = try reducer.receive(doubaoPacket(["result":["text":"目标已变"]],flags:2))
    XCTAssertEqual(reducer.state.phase,.review); XCTAssertFalse(reducer.attemptCommit(validated:true))
    var malformed=VoiceEventReducer(identity:VoiceIdentity(generation:2),settings:doubaoVoice)
    XCTAssertThrowsError(try malformed.receive(Data([0]))); XCTAssertEqual(malformed.state.phase,.failed)
    XCTAssertEqual(try malformed.receive(doubaoPacket(["result":["text":"迟到"]],flags:2)),.ignoredTerminal)
  }
  func testLegacyVoiceSettingsUseReadableDockOverlayDefaults() throws {
    let old=try JSONDecoder().decode(VoiceSettings.self,from:Data("{\"showPreview\":false,\"deviceUID\":\"fixture-usb\"}".utf8))
    XCTAssertEqual(old.previewTransparency,0.1); XCTAssertFalse(old.previewAtCaret)
    XCTAssertFalse(old.showPreview); XCTAssertEqual(old.deviceUID,"fixture-usb")
  }
  func testVoiceOverlayPreferencesPersistWithOtherSettings() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store=SettingsStore(url:directory.appendingPathComponent("settings.json"))
    var settings=Settings(); settings.voice.previewTransparency=0.45; settings.voice.previewAtCaret=true
    settings.voice.deviceUID="fixture-usb"
    let saved=try store.save(settings), loaded=try store.load()
    XCTAssertEqual(loaded,saved); XCTAssertEqual(loaded.voice.previewTransparency,0.45)
    XCTAssertTrue(loaded.voice.previewAtCaret); XCTAssertEqual(loaded.voice.deviceUID,"fixture-usb")
  }
  func testVoiceOverlayTransparencyRejectsUnreadableAndNonfiniteValues() throws {
    for value in [-0.01,0.71,Double.nan,Double.infinity] {
      var voice=VoiceSettings();voice.previewTransparency=value;XCTAssertThrowsError(try voice.validate())
    }
    for value in [0.0,0.1,0.7] {
      var voice=VoiceSettings();voice.previewTransparency=value;XCTAssertNoThrow(try voice.validate())
    }
  }
  func testVoiceTestInsertionClaimsFinalOnceAtUTF16Selection() {
    let id=VoiceIdentity(generation:1), source="甲😀乙"
    var target=VoiceTestInsertion(identity:id,text:source,selection:NSRange(location:1,length:2))
    XCTAssertNil(target.claim(identity:id,phase:.recording,complete:false,text:"中",current:source,selection:NSRange(location:1,length:2),focused:true,marked:false))
    XCTAssertEqual(target.claim(identity:id,phase:.ready,complete:true,text:"中文",current:source,selection:NSRange(location:1,length:2),focused:true,marked:false),NSRange(location:1,length:2))
    XCTAssertNil(target.claim(identity:id,phase:.ready,complete:true,text:"中文",current:source,selection:NSRange(location:1,length:2),focused:true,marked:false))
  }
  func testVoiceTestInsertionRejectsMovedCursorOrEditedText() {
    let id=VoiceIdentity(generation:1)
    var target=VoiceTestInsertion(identity:id,text:"原文",selection:NSRange(location:2,length:0))
    XCTAssertNil(target.claim(identity:id,phase:.ready,complete:true,text:"结果",current:"原文",selection:NSRange(location:0,length:0),focused:true,marked:false))
    XCTAssertNil(target.claim(identity:id,phase:.ready,complete:true,text:"结果",current:"原文修改",selection:NSRange(location:2,length:0),focused:true,marked:false))
    target.invalidate()
    XCTAssertNil(target.claim(identity:id,phase:.ready,complete:true,text:"结果",current:"原文",selection:NSRange(location:2,length:0),focused:true,marked:false))
  }
  func testVoiceTestInsertionRejectsUnconfirmedUnsafeAndForeignResults() {
    let id=VoiceIdentity(generation:1)
    var target=VoiceTestInsertion(identity:id,text:"",selection:NSRange(location:0,length:0))
    for phase in [VoicePhase.failed,.review,.cancelled,.finalizing] {
      XCTAssertNil(target.claim(identity:id,phase:phase,complete:true,text:"结果",current:"",selection:NSRange(location:0,length:0),focused:true,marked:false))
    }
    for value in ["", "结果\n", "结果\t", String(repeating:"a",count:128*1024+1)] {
      XCTAssertNil(target.claim(identity:id,phase:.ready,complete:true,text:value,current:"",selection:NSRange(location:0,length:0),focused:true,marked:false))
    }
    XCTAssertNil(target.claim(identity:VoiceIdentity(generation:2),phase:.ready,complete:true,text:"结果",current:"",selection:NSRange(location:0,length:0),focused:true,marked:false))
    XCTAssertNil(target.claim(identity:id,phase:.ready,complete:false,text:"结果",current:"",selection:NSRange(location:0,length:0),focused:true,marked:false))
    XCTAssertNil(target.claim(identity:id,phase:.ready,complete:true,text:"结果",current:"",selection:NSRange(location:0,length:0),focused:false,marked:false))
    XCTAssertNil(target.claim(identity:id,phase:.ready,complete:true,text:"结果",current:"",selection:NSRange(location:0,length:0),focused:true,marked:true))
  }
  func testVoiceTestInsertionRejectsInvalidRanges() {
    let id=VoiceIdentity(generation:1)
    for range in [NSRange(location:NSNotFound,length:0),NSRange(location:2,length:0),NSRange(location:0,length:2),NSRange(location:-1,length:0),NSRange(location:0,length:-1)] {
      var target=VoiceTestInsertion(identity:id,text:"a",selection:range)
      XCTAssertNil(target.claim(identity:id,phase:.ready,complete:true,text:"结果",current:"a",selection:range,focused:true,marked:false))
    }
  }
  func testLetterSettingsWaitForIdleAndVoiceSaveDoesNotDisarm() throws {
    var boundary=LetterSettingsBoundary(); var old=LetterProfile(); old.enabled=true
    XCTAssertNotNil(boundary.offer(schema:"test",profile:old,revision:1,composing:false))
    XCTAssertNil(boundary.offer(schema:"test",profile:old,revision:2,composing:true))
    var changed=old; changed.keys="qwertyuio"
    XCTAssertNil(boundary.offer(schema:"test",profile:changed,revision:3,composing:true))
    XCTAssertNil(boundary.flush(composing:true))
    changed.hideCandidates=false
    XCTAssertNil(boundary.offer(schema:"test",profile:changed,revision:4,composing:true))
    let latest=try XCTUnwrap(boundary.flush(composing:false))
    XCTAssertEqual(latest.profile,changed); XCTAssertEqual(latest.revision,4)
    XCTAssertNil(boundary.flush(composing:false))
    changed.enabled=false
    XCTAssertNotNil(boundary.offer(schema:"test",profile:changed,revision:5,composing:true))
    XCTAssertNil(boundary.flush(composing:false))
    XCTAssertNotNil(boundary.offer(schema:"other",profile:old,revision:5,composing:false))
  }
  func testGoalDefaultsAndExplicitExistingKeys() throws {
    XCTAssertEqual(LetterProfile().keys,"asdfghjkl")
    XCTAssertEqual(try JSONDecoder().decode(LetterProfile.self,from:Data("{}".utf8)).keys,"asdfghjkl")
    let old=try JSONDecoder().decode(LetterProfile.self,from:Data("{\"keys\":\"abcdefghi\"}".utf8))
    XCTAssertEqual(old.keys,"abcdefghi")
    XCTAssertFalse(Settings().voice.enabled); XCTAssertNil(Settings().voice.binding)
  }
  func testVoiceRegionRequiresExplicitChoiceAndDNSWorkspace() throws {
    var settings=VoiceSettings(); settings.workspace="ws-test"
    XCTAssertNil(settings.region); XCTAssertThrowsError(try settings.endpoint())
    settings.region = .beijing; XCTAssertNoThrow(try settings.endpoint())
    for id in ["trailing-","-leading","dot.invalid",String(repeating:"a",count:64)] {
      settings.workspace=id; XCTAssertThrowsError(try settings.endpoint())
    }
    settings.workspace="a"; XCTAssertNoThrow(try settings.endpoint())
    XCTAssertNil(try JSONDecoder().decode(VoiceSettings.self,from:Data("{}".utf8)).region)
  }
  func testRejectedBindingCycleDoesNotRearmOnAnotherKey() {
    var keys=PhysicalKeys(); let binding=TriggerBinding(codes:[59,61])
    XCTAssertEqual(keys.event(code:59,down:true,repeated:false,binding:binding,canStart:false),.none)
    XCTAssertEqual(keys.event(code:61,down:true,repeated:false,binding:binding,canStart:false),.none)
    XCTAssertEqual(keys.event(code:61,down:false,repeated:false,binding:binding,canStart:true),.none)
    XCTAssertEqual(keys.event(code:61,down:true,repeated:false,binding:binding,canStart:true),.none)
    _ = keys.event(code:61,down:false,repeated:false,binding:binding,canStart:true)
    _ = keys.event(code:59,down:false,repeated:false,binding:binding,canStart:true)
    _ = keys.event(code:59,down:true,repeated:false,binding:binding,canStart:true)
    XCTAssertEqual(keys.event(code:61,down:true,repeated:false,binding:binding,canStart:true),.start)
  }
  func testActivationWithPreviouslyHeldModifierRequiresRelease() {
    var keys=PhysicalKeys(); let binding=TriggerBinding(codes:[61])
    keys.reconcileAfterActivation(pressed:[59])
    XCTAssertTrue(keys.ownsRelease.isEmpty)
    XCTAssertEqual(keys.event(code:61,down:true,repeated:false,binding:binding,canStart:true),.none)
    XCTAssertEqual(keys.event(code:59,down:false,repeated:false,binding:binding,canStart:true),.none)
    XCTAssertEqual(keys.event(code:61,down:false,repeated:false,binding:binding,canStart:true),.none)
    XCTAssertEqual(keys.event(code:61,down:true,repeated:false,binding:binding,canStart:true),.start)
  }
  func testNativePositivePartialPCMOutputStillDrainsToExplicitEnd() throws {
    var progress=PCMConversionProgress(draining:true)
    XCTAssertEqual(try progress.observe(.haveData,frames:6,capacity:2048,inputSupplied:false),.again)
    XCTAssertFalse(progress.complete)
    XCTAssertEqual(try progress.observe(.endOfStream,frames:0,capacity:2048,inputSupplied:false),.complete)
    var empty=PCMConversionProgress(draining:true)
    XCTAssertThrowsError(try empty.observe(.haveData,frames:0,capacity:2048,inputSupplied:false))
    var oversized=PCMConversionProgress(draining:true)
    XCTAssertThrowsError(try oversized.observe(.haveData,frames:2049,capacity:2048,inputSupplied:false))
  }
  func testHelperLinkDelayedReadinessRetainsOneMenuRequest() {
    var link=HelperLinkState(); let id=UUID()
    XCTAssertFalse(link.requestSettings())
    for _ in 0..<100 { XCTAssertFalse(link.requestSettings()) }
    XCTAssertTrue(link.settingsPending); XCTAssertFalse(link.ready)
    XCTAssertTrue(link.reserve(id)); XCTAssertFalse(link.accepts(id))
    // No timer or deadline: readiness consumes exactly one retained intent.
    XCTAssertEqual(link.activate(id),true); XCTAssertFalse(link.settingsPending)
    XCTAssertTrue(link.accepts(id)); XCTAssertNil(link.activate(id))
    XCTAssertTrue(link.requestSettings()); XCTAssertFalse(link.settingsPending)
  }
  func testHelperLinkOnlyOneProvisionalConnectionAndNoStaleActivation() {
    var link=HelperLinkState(); let old=UUID(),new=UUID()
    XCTAssertTrue(link.reserve(old)); XCTAssertFalse(link.reserve(new))
    XCTAssertNil(link.activate(new)); XCTAssertFalse(link.accepts(old))
    XCTAssertTrue(link.end(old)); XCTAssertTrue(link.reserve(new))
    for _ in 0..<100 { XCTAssertNil(link.activate(old)); XCTAssertFalse(link.end(old)) }
    XCTAssertEqual(link.connectionID,new); XCTAssertFalse(link.ready)
    XCTAssertEqual(link.activate(new),false); XCTAssertTrue(link.accepts(new))
  }
  func testHelperLinkOldLossAndQueuedCallbacksCannotAffectReplacement() {
    var link=HelperLinkState(); let old=UUID(),new=UUID()
    XCTAssertTrue(link.reserve(old)); XCTAssertEqual(link.activate(old),false)
    XCTAssertTrue(link.accepts(old)) // callback queued by old connection here
    XCTAssertTrue(link.end(old)); XCTAssertTrue(link.reserve(new))
    XCTAssertEqual(link.activate(new),false)
    for _ in 0..<100 {
      XCTAssertFalse(link.end(old)); XCTAssertFalse(link.accepts(old))
      XCTAssertTrue(link.accepts(new)); XCTAssertEqual(link.connectionID,new)
    }
  }
  func testHelperLinkOwnerLossBeforeReadyKeepsExplicitIntentWithoutResurrection() {
    var link=HelperLinkState(); let old=UUID(),new=UUID()
    XCTAssertFalse(link.requestSettings()); XCTAssertTrue(link.reserve(old))
    link.ownerEnded(); XCTAssertTrue(link.settingsPending)
    XCTAssertNil(link.activate(old)); XCTAssertFalse(link.accepts(old))
    XCTAssertTrue(link.reserve(new)); XCTAssertEqual(link.activate(new),true)
    XCTAssertFalse(link.settingsPending); XCTAssertFalse(link.end(old))
    XCTAssertTrue(link.accepts(new))
  }
  func testHelperLinkDeliveredMenuDoesNotAutomaticallyReplayAfterRestart() {
    var link=HelperLinkState(); let old=UUID(),new=UUID()
    XCTAssertFalse(link.requestSettings()); XCTAssertTrue(link.reserve(old))
    XCTAssertEqual(link.activate(old),true); link.ownerEnded()
    XCTAssertFalse(link.settingsPending)
    XCTAssertTrue(link.reserve(new)); XCTAssertEqual(link.activate(new),false)
    XCTAssertTrue(link.requestSettings()) // actual new menu click can reopen
  }
  func testHelperLinkRepeatedCyclesHaveNoCrossConnectionRouting() {
    var link=HelperLinkState(); var previous:UUID?
    for _ in 0..<100 {
      let id=UUID(); XCTAssertFalse(link.requestSettings()); XCTAssertTrue(link.reserve(id))
      XCTAssertEqual(link.activate(id),true); XCTAssertTrue(link.accepts(id))
      if let previous { XCTAssertFalse(link.accepts(previous)); XCTAssertFalse(link.end(previous)) }
      XCTAssertTrue(link.end(id)); XCTAssertFalse(link.accepts(id)); previous=id
    }
    XCTAssertNil(link.connectionID); XCTAssertFalse(link.ready); XCTAssertFalse(link.settingsPending)
  }
  private func manyProfiles(_ count:Int,revision:UInt64 = 0) -> Settings {
    var value=Settings(); value.revision=revision
    for index in 0..<count { value.letters["profile\(index)"]=LetterProfile() }
    return value
  }
  func testSettingsOversizedSaveCreatesNoFiles() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store=SettingsStore(url:directory.appendingPathComponent("settings.json"))
    let value=manyProfiles(1000)
    XCTAssertNoThrow(try value.validate()) // Valid fields are not a byte-budget proof.
    XCTAssertThrowsError(try store.save(value))
    XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
  }
  func testSettingsOversizedSavePreservesPrimaryAndBackup() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store=SettingsStore(url:directory.appendingPathComponent("settings.json"))
    var saved=try store.save(Settings()); saved.voice.showPreview=false
    saved=try store.save(saved)
    let primary=try Data(contentsOf:store.url),backup=try Data(contentsOf:store.url.appendingPathExtension("last-valid"))
    XCTAssertThrowsError(try store.save(manyProfiles(1000,revision:saved.revision)))
    XCTAssertEqual(try Data(contentsOf:store.url),primary)
    XCTAssertEqual(try Data(contentsOf:store.url.appendingPathExtension("last-valid")),backup)
    XCTAssertEqual(try store.load(),saved)
  }
  func testSettingsRecoveryEncodingLimitPreservesCorruptPrimary() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store=SettingsStore(url:directory.appendingPathComponent("settings.json"))
    let value=manyProfiles(650,revision:10),encoder=JSONEncoder()
    let compact=try encoder.encode(value)
    encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
    XCTAssertLessThanOrEqual(compact.count,256*1024)
    XCTAssertGreaterThan(try encoder.encode(value).count,256*1024)
    let bad=Data("{broken}".utf8)
    try bad.write(to:store.url); try compact.write(to:store.url.appendingPathExtension("last-valid"))
    XCTAssertEqual(store.lastValidReadOnly(),value)
    XCTAssertThrowsError(try store.restoreLastValid(expectedRevision:10))
    XCTAssertEqual(try Data(contentsOf:store.url),bad)
    XCTAssertEqual(try Data(contentsOf:store.url.appendingPathExtension("last-valid")),compact)
    XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:directory.path)),["settings.json","settings.json.last-valid"])
  }
  func testSettingsExactReadLimitAndLargeRoundTripDoNotTruncate() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store=SettingsStore(url:directory.appendingPathComponent("settings.json"))
    let saved=try store.save(manyProfiles(500))
    XCTAssertEqual(try store.load(),saved); XCTAssertEqual(saved.letters.count,500)
    var exact=try JSONEncoder().encode(saved)
    XCTAssertLessThan(exact.count,256*1024)
    exact.append(Data(repeating:0x20,count:256*1024-exact.count)) // Legal JSON trailing whitespace.
    try exact.write(to:store.url); XCTAssertEqual(try store.load(),saved)
    var oversized=exact; oversized.append(0x20)
    try oversized.write(to:store.url); XCTAssertThrowsError(try store.load())
    XCTAssertEqual(try Data(contentsOf:store.url),oversized)
  }
  func testSettingsExhaustedRevisionSaveDoesNotTrapOrWrite() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store=SettingsStore(url:directory.appendingPathComponent("settings.json"))
    var value=Settings(); value.revision=UInt64.max
    let primary=try JSONEncoder().encode(value),backup=Data("preserve earlier backup".utf8)
    try primary.write(to:store.url); try backup.write(to:store.url.appendingPathExtension("last-valid"))
    XCTAssertEqual(try store.load(),value)
    XCTAssertThrowsError(try store.save(value))
    XCTAssertEqual(try Data(contentsOf:store.url),primary)
    XCTAssertEqual(try Data(contentsOf:store.url.appendingPathExtension("last-valid")),backup)
  }
  func testSettingsExhaustedRevisionRecoveryDoesNotTrapOrCreateBackup() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store=SettingsStore(url:directory.appendingPathComponent("settings.json"))
    var value=Settings(); value.revision=UInt64.max
    let bad=Data("{broken}".utf8),backup=try JSONEncoder().encode(value)
    try bad.write(to:store.url); try backup.write(to:store.url.appendingPathExtension("last-valid"))
    XCTAssertEqual(store.lastValidReadOnly(),value)
    XCTAssertThrowsError(try store.restoreLastValid(expectedRevision:UInt64.max))
    XCTAssertEqual(try Data(contentsOf:store.url),bad)
    XCTAssertEqual(try Data(contentsOf:store.url.appendingPathExtension("last-valid")),backup)
    XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:directory.path)),["settings.json","settings.json.last-valid"])
  }
  func testSettingsLastRevisionCanCommitOnceThenStopsSafely() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store=SettingsStore(url:directory.appendingPathComponent("settings.json"))
    var value=Settings(); value.revision=UInt64.max-1
    try JSONEncoder().encode(value).write(to:store.url)
    let saved=try store.save(value); XCTAssertEqual(saved.revision,UInt64.max)
    XCTAssertEqual(try store.load(),saved)
    XCTAssertThrowsError(try store.save(saved)); XCTAssertEqual(try store.load(),saved)
    XCTAssertEqual(store.lastValidReadOnly(),value)
  }
  func testVoiceTargetEligibilityRequiresCurrentForegroundNonsecureEnabledEvidence() {
    func allowed(pid:Int32? = 7,bundle:String? = "example.editor",client:String? = "example.editor",
                 trusted:Bool = true,secure:Bool = false,subrole:String? = nil,enabled:Bool? = nil,
                 expectedPID:Int32 = 7,expectedBundle:String? = "example.editor") -> Bool {
      VoiceTargetEligibility.currentlyEligible(expectedPID:expectedPID,expectedBundle:expectedBundle,
        currentPID:pid,currentBundle:bundle,clientBundle:client,trusted:trusted,secureInput:secure,
        subrole:subrole,enabled:enabled)
    }
    XCTAssertTrue(allowed()); XCTAssertTrue(allowed(enabled:true)); XCTAssertTrue(allowed(subrole:"AXSearchField"))
    XCTAssertFalse(allowed(pid:8)); XCTAssertFalse(allowed(pid:nil)); XCTAssertFalse(allowed(bundle:"other.app"))
    XCTAssertFalse(allowed(bundle:nil)); XCTAssertFalse(allowed(client:"other.app")); XCTAssertFalse(allowed(client:nil))
    XCTAssertFalse(allowed(trusted:false)); XCTAssertFalse(allowed(secure:true)); XCTAssertFalse(allowed(enabled:false))
    XCTAssertFalse(allowed(subrole:"AXSecureTextField"))
    XCTAssertFalse(allowed(expectedPID:0)); XCTAssertFalse(allowed(expectedPID:-1))
    XCTAssertFalse(allowed(expectedBundle:nil)); XCTAssertFalse(allowed(expectedBundle:""))
  }
  func testVoiceUpdateBoundsAcceptsSupportedFiniteValuesAndRejectsDangerousNumbers() {
    XCTAssertTrue(VoiceUpdateBounds.valid(level:0,duration:0,textBytes:0,messageBytes:0))
    XCTAssertTrue(VoiceUpdateBounds.valid(level:1,duration:900,textBytes:128*1024,messageBytes:4096))
    for number:Double in [.nan,.infinity,-Double.infinity,-1,1.0001,1e308] {
      XCTAssertFalse(VoiceUpdateBounds.valid(level:number,duration:1,textBytes:1,messageBytes:1))
    }
    for number:Double in [.nan,.infinity,-1,900.0001,1e308] {
      XCTAssertFalse(VoiceUpdateBounds.valid(level:0.5,duration:number,textBytes:1,messageBytes:1))
    }
  }
  func testVoiceUpdateBoundsRejectsOversizedAndNegativeLengthsWithoutTruncation() {
    for count in [-1,128*1024+1,Int.max] {
      XCTAssertFalse(VoiceUpdateBounds.valid(level:0.5,duration:1,textBytes:count,messageBytes:1))
    }
    for count in [-1,4097,Int.max] {
      XCTAssertFalse(VoiceUpdateBounds.valid(level:0.5,duration:1,textBytes:1,messageBytes:count))
    }
    XCTAssertTrue(VoiceUpdateBounds.valid(level:0.5,duration:100,textBytes:4096,messageBytes:4096))
  }
  func testVoiceStopRelayReleaseAndInvalidationEachOnce() throws {
    let id=VoiceIdentity(generation:10); var relay=VoiceStopRelay(); relay.begin(id)
    let first=try XCTUnwrap(relay.invalidate(id,at:100)); XCTAssertEqual(first.cause,.targetInvalidated)
    XCTAssertTrue(relay.released)
    for _ in 0..<100 { XCTAssertNil(relay.invalidate(id,at:101)); XCTAssertNil(relay.release(id,at:102)) }
    let next=VoiceIdentity(generation:10); relay.begin(next); XCTAssertFalse(relay.released)
    XCTAssertEqual(try XCTUnwrap(relay.release(next,at:103)).cause,.keyReleased)
    XCTAssertNil(relay.release(next,at:104))
  }
  func testVoiceStopRelayRevokesAfterPhysicalRelease() throws {
    let id=VoiceIdentity(generation:11); var relay=VoiceStopRelay(); relay.begin(id)
    XCTAssertEqual(try XCTUnwrap(relay.release(id,at:100)).cause,.keyReleased)
    let changed=try XCTUnwrap(relay.invalidate(id,at:101))
    XCTAssertEqual(changed.identity,id); XCTAssertEqual(changed.cause,.targetInvalidated); XCTAssertEqual(changed.uptime,101)
    for _ in 0..<100 { XCTAssertNil(relay.invalidate(id,at:102)) }
  }
  func testVoiceStopRelayLateTargetChangeKeepsFirstDeadlineAndDraft() throws {
    let id=VoiceIdentity(generation:12); var relay=VoiceStopRelay(); relay.begin(id)
    var reducer=VoiceEventReducer(identity:id,settings:VoiceSettings())
    _ = try reducer.receive(packet("task-started",task:id.task))
    _ = try reducer.receive(packet("result-generated",task:id.task,payload:result(id:1,text:"retained draft",final:true)))
    let physical=try XCTUnwrap(relay.release(id,at:100)); reducer.stop(at:physical.uptime,cause:physical.cause ?? .unspecified)
    if let changed=relay.invalidate(id,at:101) { reducer.stop(at:changed.uptime,cause:changed.cause ?? .unspecified) }
    XCTAssertEqual(reducer.state.releasedAt,100); XCTAssertTrue(reducer.sendFinish(queueEmpty:true))
    _ = try reducer.receive(packet("task-finished",task:id.task))
    XCTAssertEqual(reducer.state.phase,.review); XCTAssertEqual(reducer.transcript.preview,"retained draft")
    XCTAssertFalse(reducer.attemptCommit(validated:true)); XCTAssertTrue(reducer.state.resultIsComplete(transcriptComplete:true))
  }
  func testVoiceStopRelayRejectsWrongIdentityAndInvalidClock() {
    let id=VoiceIdentity(generation:13); var relay=VoiceStopRelay(); relay.begin(id)
    var wrong=id; wrong.task=UUID(); XCTAssertNil(relay.release(wrong,at:100))
    wrong=id; wrong.session=UUID(); XCTAssertNil(relay.invalidate(wrong,at:100))
    wrong=id; wrong.generation += 1; XCTAssertNil(relay.invalidate(wrong,at:100))
    for time:Double in [.nan,.infinity,-1] { XCTAssertNil(relay.release(id,at:time)); XCTAssertNil(relay.invalidate(id,at:time)) }
    XCTAssertFalse(relay.released); XCTAssertNotNil(relay.release(id,at:100))
  }
  func testVoiceResultCompletenessRequiresWholeTaskAndNormalFinish() {
    let id=VoiceIdentity(generation:14); var state=VoiceState(identity:id,settings:VoiceSettings())
    XCTAssertFalse(state.resultIsComplete(transcriptComplete:true)); state.started()
    XCTAssertFalse(state.resultIsComplete(transcriptComplete:true)); state.release(at:100)
    XCTAssertFalse(state.resultIsComplete(transcriptComplete:true)); XCTAssertTrue(state.sendFinish(queueEmpty:true))
    XCTAssertFalse(state.resultIsComplete(transcriptComplete:true)); state.finished(complete:true)
    XCTAssertTrue(state.resultIsComplete(transcriptComplete:true)); XCTAssertFalse(state.resultIsComplete(transcriptComplete:false))
  }
  func testVoiceResultCompletenessEarlyServerEndAndFailureStayUnconfirmed() {
    let id=VoiceIdentity(generation:15); var early=VoiceState(identity:id,settings:VoiceSettings()); early.started()
    early.finished(complete:true); XCTAssertEqual(early.phase,.review); XCTAssertFalse(early.resultIsComplete(transcriptComplete:true))
    var failed=VoiceState(identity:id,settings:VoiceSettings()); failed.started(); failed.release(at:100)
    XCTAssertTrue(failed.sendFinish(queueEmpty:true)); failed.fail()
    XCTAssertFalse(failed.resultIsComplete(transcriptComplete:true))
  }
  func testVoiceResultCompletenessInvalidTargetKeepsCompleteReviewNotInsertion() {
    let id=VoiceIdentity(generation:16); var state=VoiceState(identity:id,settings:VoiceSettings()); state.started()
    state.release(at:100); state.invalidateTarget(at:101); XCTAssertTrue(state.sendFinish(queueEmpty:true)); state.finished(complete:true)
    XCTAssertEqual(state.phase,.review); XCTAssertTrue(state.resultIsComplete(transcriptComplete:true))
    XCTAssertFalse(state.attemptCommit(validated:true)); XCTAssertEqual(state.releasedAt,100)
  }
  func testVoiceDraftActiveFinalSentenceIsNotWholeTaskOrCopyable() {
    let id=VoiceIdentity(generation:17); var draft=VoiceDraftStore(); XCTAssertFalse(draft.begin(id))
    XCTAssertTrue(draft.accept(id,phase:.recording,text:"first",complete:true)); XCTAssertFalse(draft.complete); XCTAssertFalse(draft.canCopy)
    XCTAssertTrue(draft.accept(id,phase:.finalizing,text:"revised text",complete:true)); XCTAssertEqual(draft.text,"revised text")
    XCTAssertFalse(draft.complete); XCTAssertFalse(draft.canCopy)
    XCTAssertTrue(draft.accept(id,phase:.ready,text:"final text",complete:true)); XCTAssertTrue(draft.complete); XCTAssertTrue(draft.canCopy)
    XCTAssertFalse(draft.accept(id,phase:.ready,text:"duplicate",complete:true)); XCTAssertEqual(draft.text,"final text")
  }
  func testVoiceDraftExplicitDiscardSuppressesQueuedUpdatesUntilNewIdentity() {
    let id=VoiceIdentity(generation:18); var draft=VoiceDraftStore(); draft.begin(id)
    XCTAssertTrue(draft.accept(id,phase:.recording,text:"partial",complete:false)); draft.discard()
    for _ in 0..<100 { XCTAssertTrue(draft.accept(id,phase:.recording,text:"late",complete:false)); XCTAssertTrue(draft.text.isEmpty) }
    XCTAssertTrue(draft.accept(id,phase:.ready,text:"late final",complete:true)); XCTAssertFalse(draft.complete); XCTAssertFalse(draft.canCopy)
    XCTAssertFalse(draft.begin(id)); XCTAssertTrue(draft.text.isEmpty)
    let next=VoiceIdentity(generation:18); XCTAssertFalse(draft.begin(next))
    XCTAssertTrue(draft.accept(next,phase:.recording,text:"new",complete:false)); XCTAssertEqual(draft.text,"new")
  }
  func testVoiceDraftReplacementWarningAndFullIdentityDoNotKeepHistory() {
    let id=VoiceIdentity(generation:19),next=VoiceIdentity(generation:19); var draft=VoiceDraftStore(); draft.begin(id)
    XCTAssertTrue(draft.accept(id,phase:.review,text:"recoverable",complete:true)); XCTAssertTrue(draft.begin(next))
    XCTAssertTrue(draft.text.isEmpty); XCTAssertFalse(draft.complete); XCTAssertEqual(draft.identity,next)
    XCTAssertFalse(draft.accept(id,phase:.ready,text:"old",complete:true))
    for component in 0..<3 {
      var wrong=next; if component == 0 { wrong.task=UUID() } else if component == 1 { wrong.session=UUID() } else { wrong.generation += 1 }
      XCTAssertFalse(draft.accept(wrong,phase:.ready,text:"wrong",complete:true))
    }
    XCTAssertTrue(draft.accept(next,phase:.failed,text:"new incomplete",complete:true)); XCTAssertFalse(draft.complete); XCTAssertTrue(draft.canCopy)
  }
  func testVoiceDraftCancellationClearAndOversizeNeverRefillOrTruncate() {
    let id=VoiceIdentity(generation:20); var draft=VoiceDraftStore(); draft.begin(id)
    XCTAssertTrue(draft.accept(id,phase:.recording,text:"keep",complete:false))
    XCTAssertFalse(draft.accept(id,phase:.recording,text:String(repeating:"x",count:128*1024+1),complete:false)); XCTAssertEqual(draft.text,"keep")
    XCTAssertTrue(draft.accept(id,phase:.cancelled,text:"ignored",complete:true)); XCTAssertTrue(draft.text.isEmpty); XCTAssertFalse(draft.canCopy)
    XCTAssertFalse(draft.accept(id,phase:.ready,text:"late",complete:true)); draft.clear(); XCTAssertNil(draft.identity)
    XCTAssertFalse(draft.accept(id,phase:.review,text:"late",complete:true)); XCTAssertTrue(draft.text.isEmpty)
  }
  func testVoiceDraftExactPunctuationUnicodeAndTerminalQualityArePreserved() {
    let id=VoiceIdentity(generation:21); var draft=VoiceDraftStore(); draft.begin(id)
    let text="你好，Rime 123!  trailing  "
    XCTAssertTrue(draft.accept(id,phase:.review,text:text,complete:false)); XCTAssertEqual(draft.text,text)
    XCTAssertTrue(draft.canCopy); XCTAssertFalse(draft.complete)
    XCTAssertFalse(draft.accept(id,phase:.review,text:"mutation",complete:true)); XCTAssertEqual(draft.text,text)
    draft.discard(); XCTAssertTrue(draft.text.isEmpty); XCTAssertFalse(draft.canCopy)
  }
  func testVoiceAdmissionStopBeforeBeginNeverStarts() {
    for _ in 0..<100 {
      let id=VoiceIdentity(generation:1); var admission=VoiceRequestAdmission()
      XCTAssertFalse(admission.close(id,receivedAt:100.1))
      XCTAssertEqual(admission.admit(id,pressUptime:100,receivedAt:100.2,canStart:true),.stoppedBeforeBegin)
      XCTAssertEqual(admission.admit(id,pressUptime:100,receivedAt:100.3,canStart:true),.duplicate)
    }
  }
  func testVoiceAdmissionAcceptedBeginAndTerminalAreExactlyOnce() {
    let id=VoiceIdentity(generation:2); var admission=VoiceRequestAdmission()
    XCTAssertEqual(admission.admit(id,pressUptime:100,receivedAt:100.1,canStart:true),.start)
    XCTAssertEqual(admission.admit(id,pressUptime:100,receivedAt:100.2,canStart:true),.duplicate)
    XCTAssertTrue(admission.close(id,receivedAt:101)); XCTAssertFalse(admission.close(id,receivedAt:102))
    for _ in 0..<100 { XCTAssertEqual(admission.admit(id,pressUptime:100,receivedAt:103,canStart:true),.duplicate) }
    XCTAssertEqual(admission.recordCount,1)
  }
  func testVoiceAdmissionBusyAndUnavailableNeverQueueOrRetryOldPress() {
    let a=VoiceIdentity(generation:3),b=VoiceIdentity(generation:3),c=VoiceIdentity(generation:4)
    var admission=VoiceRequestAdmission()
    XCTAssertEqual(admission.admit(a,pressUptime:100,receivedAt:100,canStart:true),.start)
    XCTAssertEqual(admission.admit(b,pressUptime:101,receivedAt:101,canStart:true),.unavailable)
    XCTAssertTrue(admission.close(a,receivedAt:102))
    XCTAssertEqual(admission.admit(b,pressUptime:101,receivedAt:103,canStart:true),.duplicate)
    XCTAssertEqual(admission.admit(c,pressUptime:103,receivedAt:103,canStart:false),.unavailable)
    XCTAssertEqual(admission.admit(c,pressUptime:103,receivedAt:104,canStart:true),.duplicate)
    XCTAssertEqual(admission.admit(VoiceIdentity(generation:4),pressUptime:104,receivedAt:104,canStart:true),.start)
  }
  func testVoiceAdmissionFullIdentityCannotStealAnotherOwner() {
    let id=VoiceIdentity(generation:5); var admission=VoiceRequestAdmission()
    XCTAssertEqual(admission.admit(id,pressUptime:100,receivedAt:100,canStart:true),.start)
    var wrong=id; wrong.task=UUID(); XCTAssertFalse(admission.close(wrong,receivedAt:101))
    wrong=id; wrong.session=UUID(); XCTAssertFalse(admission.close(wrong,receivedAt:101))
    wrong=id; wrong.generation += 1; XCTAssertFalse(admission.close(wrong,receivedAt:101))
    XCTAssertEqual(admission.admit(VoiceIdentity(generation:5),pressUptime:102,receivedAt:102,canStart:true),.unavailable)
    XCTAssertTrue(admission.close(id,receivedAt:103))
  }
  func testVoiceAdmissionInvalidClockCannotAcquireOrCloseOwnership() {
    let id=VoiceIdentity(generation:6); var admission=VoiceRequestAdmission()
    for value:Double? in [nil,.nan,.infinity,-1,1000] {
      XCTAssertEqual(admission.admit(id,pressUptime:value,receivedAt:100,canStart:true),.invalidClock)
    }
    XCTAssertEqual(admission.admit(id,pressUptime:100,receivedAt:.nan,canStart:true),.invalidClock)
    XCTAssertEqual(admission.recordCount,0)
    XCTAssertEqual(admission.admit(id,pressUptime:99,receivedAt:100,canStart:true),.start)
    XCTAssertFalse(admission.close(id,receivedAt:.nan)); XCTAssertFalse(admission.close(id,receivedAt:-1))
    XCTAssertTrue(admission.close(id,receivedAt:101))
  }
  func testVoiceAdmissionCapacityDoesNotEvictStopAndOverflowFailsClosed() {
    var admission=VoiceRequestAdmission(); let first=VoiceIdentity(generation:7)
    admission.close(first,receivedAt:100)
    for _ in 1..<VoiceRequestAdmission.maximumRecords { admission.close(VoiceIdentity(generation:7),receivedAt:100) }
    let overflow=VoiceIdentity(generation:7); XCTAssertFalse(admission.close(overflow,receivedAt:100))
    XCTAssertEqual(admission.recordCount,VoiceRequestAdmission.maximumRecords)
    XCTAssertEqual(admission.admit(first,pressUptime:99,receivedAt:101,canStart:true),.stoppedBeforeBegin)
    XCTAssertEqual(admission.admit(overflow,pressUptime:100.2,receivedAt:101,canStart:true),.stoppedBeforeBegin)
    XCTAssertEqual(admission.admit(VoiceIdentity(generation:7),pressUptime:101,receivedAt:101,canStart:true),.capacityLimited)
  }
  func testVoiceAdmissionExpiryDoesNotReviveOldOriginAndNewPressWorks() {
    var admission=VoiceRequestAdmission(); let old=VoiceIdentity(generation:8)
    admission.close(old,receivedAt:100)
    XCTAssertEqual(admission.admit(old,pressUptime:100,receivedAt:461,canStart:true),.invalidClock)
    let new=VoiceIdentity(generation:8)
    XCTAssertEqual(admission.admit(new,pressUptime:461,receivedAt:461,canStart:true),.start)
    XCTAssertEqual(admission.recordCount,1)
    // An active record itself never expires, even when the caller is faulty.
    XCTAssertEqual(admission.admit(VoiceIdentity(generation:8),pressUptime:900,receivedAt:900,canStart:true),.unavailable)
  }
  func testVoiceAdmissionPendingRevocationUsesOriginalPressNotDispatchTime() {
    var admission=VoiceRequestAdmission(); admission.revokePending(at:101)
    admission.revokePending(at:.nan); admission.revokePending(at:100)
    XCTAssertEqual(admission.admit(VoiceIdentity(generation:9),pressUptime:100,receivedAt:102,canStart:true),.stoppedBeforeBegin)
    XCTAssertEqual(admission.admit(VoiceIdentity(generation:9),pressUptime:101,receivedAt:102,canStart:true),.stoppedBeforeBegin)
    XCTAssertEqual(admission.admit(VoiceIdentity(generation:9),pressUptime:102,receivedAt:102,canStart:true),.start)
  }
  private func diagnosticTimeline(_ identity:VoiceIdentity,mode:VoiceDiagnosticMode = .production) -> VoiceDiagnosticTimeline {
    VoiceDiagnosticTimeline(identity:identity,revision:mode == .production ? 7 : nil,mode:mode,
        origin:.physicalPress,referenceUptime:100)
  }
  private func readyDiagnostic(_ identity:VoiceIdentity,mode:VoiceDiagnosticMode = .production) -> VoiceDiagnosticSnapshot {
    var value=diagnosticTimeline(identity,mode:mode)
    value.record(.helperAccepted,at:100.1); value.record(.captureStarted,at:100.2)
    value.requestStop(cause:mode == .production ? .keyReleased : .guiReleased,at:102,receivedAt:102.1)
    value.record(.captureCutoff,at:102.11); value.record(.taskFinished,at:103)
    return value.snapshot(phase:.ready)
  }
  func testVoiceDiagnosticTimestampsAreFirstObservationAndMeasured() throws {
    let id=VoiceIdentity(generation:1); var value=diagnosticTimeline(id)
    XCTAssertTrue(value.record(.helperAccepted,at:100.1)); XCTAssertTrue(value.record(.captureStarted,at:100.2))
    XCTAssertTrue(value.record(.firstTranscript,at:101.5))
    for _ in 0..<100 { XCTAssertFalse(value.record(.firstTranscript,at:102.5)) }
    value.requestStop(cause:.keyReleased,at:102,receivedAt:102.1)
    value.record(.captureCutoff,at:102.11); value.record(.tailDrained,at:102.2); value.record(.taskFinished,at:103)
    let snapshot=value.snapshot(phase:.ready); XCTAssertTrue(snapshot.isValid)
    XCTAssertEqual(try XCTUnwrap(snapshot.startToCaptureMilliseconds),200,accuracy:0.00001)
    XCTAssertEqual(try XCTUnwrap(snapshot.milliseconds(from:.captureStarted,to:.firstTranscript)),1300,accuracy:0.00001)
    XCTAssertEqual(try XCTUnwrap(snapshot.milliseconds(from:.stopRequested,to:.captureCutoff)),110,accuracy:0.00001)
    XCTAssertEqual(try XCTUnwrap(snapshot.milliseconds(from:.stopRequested,to:.taskFinished)),1000,accuracy:0.00001)
  }
  func testVoiceDiagnosticClockAndOffsetsRejectInvalidData() {
    for time in [Double.nan,Double.infinity,-Double.infinity,-1,461,1000] {
      XCTAssertFalse(VoiceDiagnosticTimeline.validClock(time,receivedAt:100))
    }
    XCTAssertTrue(VoiceDiagnosticTimeline.validClock(100.25,receivedAt:100))
    XCTAssertTrue(VoiceDiagnosticTimeline.validClock(99,receivedAt:100)) // One second of delivery delay is valid, not a future clock.
    XCTAssertFalse(VoiceDiagnosticTimeline.validClock(100.26,receivedAt:100))
    XCTAssertTrue(VoiceDiagnosticTimeline.validClock(0,receivedAt:360))
    XCTAssertFalse(VoiceDiagnosticTimeline.validClock(0,receivedAt:360.1))
    XCTAssertFalse(VoiceDiagnosticTimeline.validClock(100,receivedAt:.nan))
    let id=VoiceIdentity(generation:2); var value=diagnosticTimeline(id)
    for time in [99.9,1001,Double.nan,Double.infinity] { XCTAssertFalse(value.record(.captureStarted,at:time)) }
    XCTAssertTrue(value.snapshot(phase:.preparing).stages.isEmpty)
    var bad=VoiceDiagnosticTimeline(identity:id,revision:nil,mode:.guiTest,origin:.helperStart,referenceUptime:.nan)
    XCTAssertFalse(bad.record(.captureStarted,at:100)); XCTAssertFalse(bad.snapshot(phase:.recording).isValid)
  }
  func testVoiceDiagnosticNoMissingOrNegativeLatencyPretendsZero() {
    let id=VoiceIdentity(generation:3); var value=diagnosticTimeline(id)
    XCTAssertNil(value.snapshot(phase:.preparing).startToCaptureMilliseconds)
    value.record(.captureStarted,at:102); value.record(.firstPCM,at:101)
    let snapshot=value.snapshot(phase:.recording)
    XCTAssertNil(snapshot.milliseconds(from:.captureStarted,to:.firstPCM))
    XCTAssertNil(snapshot.milliseconds(from:.stopRequested,to:.taskFinished))
    var bad=snapshot; bad.stages[.tailDrained]=Double.infinity
    XCTAssertFalse(bad.isValid); XCTAssertNil(bad.startToCaptureMilliseconds)
    var failure=value; failure.fail(.audio,at:103)
    XCTAssertFalse(failure.snapshot(phase:.ready).isValid)
  }
  func testVoiceDiagnosticClearSuppressesActiveAndResetsOnNewSession() {
    let old=VoiceIdentity(generation:4),next=VoiceIdentity(generation:5)
    var store=VoiceDiagnosticStore(); store.begin(old)
    XCTAssertTrue(store.accept(readyDiagnostic(old))); store.clear(); XCTAssertNil(store.latest)
    for _ in 0..<100 { XCTAssertFalse(store.accept(readyDiagnostic(old))) }
    var timeline=diagnosticTimeline(old); timeline.record(.helperAccepted,at:100.1); timeline.fail(.audio,at:101)
    timeline.clear(); XCTAssertFalse(timeline.record(.taskFinished,at:102)); timeline.fail(.setup,at:102)
    let cleared=timeline.snapshot(phase:.failed)
    XCTAssertTrue(cleared.stages.isEmpty); XCTAssertNil(cleared.failure); XCTAssertNil(cleared.stopCause)
    store.begin(next); XCTAssertFalse(store.accept(readyDiagnostic(old)))
    XCTAssertTrue(store.accept(readyDiagnostic(next))); XCTAssertEqual(store.latest?.identity,next)
  }
  func testVoiceDiagnosticStoreRejectsOldIdentityAndTerminalUpdates() {
    let id=VoiceIdentity(generation:6); var store=VoiceDiagnosticStore(); store.begin(id)
    var other=id; other.generation += 1
    XCTAssertFalse(store.accept(readyDiagnostic(other)))
    XCTAssertTrue(store.accept(readyDiagnostic(id))); store.end(other)
    XCTAssertTrue(store.accept(readyDiagnostic(id))) // Wrong end cannot steal the live owner.
    store.end(id); let before=store.latest
    XCTAssertFalse(store.accept(readyDiagnostic(id))); XCTAssertEqual(store.latest,before)
  }
  func testVoiceDiagnosticReceiptsAreMatchingOnceAndNotAppConfirmation() throws {
    let id=VoiceIdentity(generation:7); var store=VoiceDiagnosticStore(); store.begin(id)
    XCTAssertTrue(store.accept(readyDiagnostic(id))); store.end(id)
    let receipt=VoiceDeliveryReceipt(identity:id,decision:.nativeCallReturned,uptime:103.2)
    XCTAssertTrue(store.delivery(receipt,receivedAt:103.3))
    XCTAssertEqual(store.latest?.delivery,.nativeCallReturned)
    XCTAssertTrue(VoiceDeliveryDecision.nativeCallReturned.title.contains("不是宿主已写入的确认"))
    XCTAssertEqual(try XCTUnwrap(store.latest?.milliseconds(from:.stopRequested,to:.frontendDecision)),1200,accuracy:0.00001)
    XCTAssertFalse(store.delivery(VoiceDeliveryReceipt(identity:id,decision:.reviewRequired,uptime:103.4),receivedAt:103.5))
    XCTAssertEqual(store.latest?.delivery,.nativeCallReturned)
  }
  func testVoiceDiagnosticReceiptRejectsGUIFailureInvalidTimingAndCleared() {
    let id=VoiceIdentity(generation:8),other=VoiceIdentity(generation:9)
    let valid=VoiceDeliveryReceipt(identity:id,decision:.reviewRequired,uptime:103.2)
    var gui=VoiceDiagnosticStore(); gui.begin(id); XCTAssertTrue(gui.accept(readyDiagnostic(id,mode:.guiTest))); gui.end(id)
    XCTAssertFalse(gui.delivery(valid,receivedAt:103.3))
    var store=VoiceDiagnosticStore(); store.begin(id); store.accept(readyDiagnostic(id)); store.end(id)
    for receipt in [VoiceDeliveryReceipt(identity:other,decision:.reviewRequired,uptime:103.2),
                    VoiceDeliveryReceipt(identity:id,decision:.reviewRequired,uptime:102.9),
                    VoiceDeliveryReceipt(identity:id,decision:.reviewRequired,uptime:.infinity),
                    VoiceDeliveryReceipt(identity:id,decision:.reviewRequired,uptime:104)] {
      XCTAssertFalse(store.delivery(receipt,receivedAt:103.3))
    }
    var failure=readyDiagnostic(id); failure.phase = .failed
    var failedStore=VoiceDiagnosticStore(); failedStore.begin(id); failedStore.accept(failure); failedStore.end(id)
    XCTAssertFalse(failedStore.delivery(valid,receivedAt:103.3))
    store.clear(); XCTAssertFalse(store.delivery(valid,receivedAt:103.3)); XCTAssertNil(store.latest)
    var review=VoiceDiagnosticStore(); review.begin(id); review.accept(readyDiagnostic(id)); review.end(id)
    XCTAssertTrue(review.delivery(valid,receivedAt:103.3)); XCTAssertEqual(review.latest?.delivery,.reviewRequired)
  }
  func testVoiceDiagnosticSerializationContainsOnlyClosedMetadata() throws {
    let snapshot=readyDiagnostic(VoiceIdentity(generation:10))
    let data=try JSONEncoder().encode(snapshot)
    XCTAssertEqual(try JSONDecoder().decode(VoiceDiagnosticSnapshot.self,from:data),snapshot)
    let object=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
    let allowed:Set<String>=["identity","revision","mode","origin","referenceUptime","phase","stages","failure","stopCause","delivery"]
    XCTAssertTrue(Set(object.keys).isSubset(of:allowed)); XCTAssertLessThan(data.count,4096)
    for field in ["text","key","Authorization","audio","workspace","deviceUID","application","clipboard","errorMessage"] { XCTAssertNil(object[field]) }
    XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("PRIVATE_TEST_TRANSCRIPT"))
  }
  func testVoiceStopCausePreservesFirstRequestAndLegacyDecode() throws {
    let id=VoiceIdentity(generation:11); var value=diagnosticTimeline(id)
    value.requestStop(cause:.maximumDuration,at:102,receivedAt:102.1)
    value.requestStop(cause:.keyReleased,at:103,receivedAt:103.1)
    let snapshot=value.snapshot(phase:.finalizing)
    XCTAssertEqual(snapshot.stopCause,.maximumDuration); XCTAssertEqual(snapshot.stages[.stopRequested],2)
    var legacy=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(VoiceRelease(identity:id,uptime:102))) as? [String:Any])
    legacy.removeValue(forKey:"cause")
    let decoded=try JSONDecoder().decode(VoiceRelease.self,from:JSONSerialization.data(withJSONObject:legacy))
    XCTAssertNil(decoded.cause); XCTAssertNoThrow(try decoded.validate(receivedAt:103))
  }
  func testTargetInvalidatedStopRetainsDraftAndPreventsAutomaticInsertion() throws {
    let id=VoiceIdentity(generation:12); var reducer=VoiceEventReducer(identity:id,settings:VoiceSettings())
    _ = try reducer.receive(packet("task-started",task:id.task))
    _ = try reducer.receive(packet("result-generated",task:id.task,payload:result(id:1,text:"review draft",final:true)))
    reducer.stop(at:5,cause:.targetInvalidated)
    XCTAssertFalse(reducer.state.targetValid); XCTAssertFalse(reducer.state.capturePermitted)
    XCTAssertTrue(reducer.sendFinish(queueEmpty:true)); _ = try reducer.receive(packet("task-finished",task:id.task))
    XCTAssertEqual(reducer.state.phase,.review); XCTAssertEqual(reducer.transcript.preview,"review draft")
    XCTAssertFalse(reducer.attemptCommit(validated:true))
  }
  func testPCMDrainLifecycleJoinsOnceAndCachesFailureOrSuccess() {
    for result in [false,true] {
      var drain=PCMDrainLifecycle()
      XCTAssertFalse(drain.finish(result)); XCTAssertFalse(drain.requested)
      XCTAssertEqual(drain.request(),.begin); XCTAssertTrue(drain.requested)
      for _ in 0..<100 { XCTAssertEqual(drain.request(),.join) }
      XCTAssertTrue(drain.finish(result)); XCTAssertEqual(drain.result,result)
      XCTAssertFalse(drain.finish(!result)); XCTAssertEqual(drain.result,result)
      for _ in 0..<100 { XCTAssertEqual(drain.request(),.finished(result)) }
      var next=PCMDrainLifecycle(); XCTAssertEqual(next.request(),.begin)
    }
  }
  func testPCMNormalConversionNeedsInputAndCanHaveZeroOutput() throws {
    var normal=PCMConversionProgress(draining:false)
    XCTAssertEqual(try normal.observe(.haveData,frames:500,capacity:500,inputSupplied:false),.again)
    XCTAssertEqual(try normal.observe(.inputRanDry,frames:100,capacity:500,inputSupplied:true),.complete)
    XCTAssertTrue(normal.complete); XCTAssertEqual(normal.calls,2)
    var priming=PCMConversionProgress(draining:false)
    XCTAssertEqual(try priming.observe(.inputRanDry,frames:0,capacity:500,inputSupplied:true),.complete)
    var missing=PCMConversionProgress(draining:false)
    XCTAssertThrowsError(try missing.observe(.inputRanDry,frames:0,capacity:500,inputSupplied:false))
    XCTAssertFalse(missing.complete)
  }
  func testPCMDrainRequiresExplicitEndEvenWhenOutputIsEmpty() throws {
    var drain=PCMConversionProgress(draining:true)
    for _ in 0..<2 {
      XCTAssertEqual(try drain.observe(.inputRanDry,frames:0,capacity:2048,inputSupplied:false),.again)
      XCTAssertFalse(drain.complete)
    }
    XCTAssertEqual(try drain.observe(.haveData,frames:2048,capacity:2048,inputSupplied:false),.again)
    XCTAssertEqual(try drain.observe(.inputRanDry,frames:412,capacity:2048,inputSupplied:false),.again)
    XCTAssertEqual(try drain.observe(.endOfStream,frames:0,capacity:2048,inputSupplied:false),.complete)
    XCTAssertTrue(drain.complete); XCTAssertEqual(drain.calls,5)
    XCTAssertThrowsError(try drain.observe(.endOfStream,frames:0,capacity:2048,inputSupplied:false))
  }
  func testPCMDrainBoundFailsInsteadOfPretendingTailComplete() throws {
    for status in [PCMConversionStatus.inputRanDry,.haveData] {
      var drain=PCMConversionProgress(draining:true)
      let frames:UInt32 = status == .haveData ? 2048 : 0
      for _ in 1..<PCMConversionProgress.maximumCalls {
        XCTAssertEqual(try drain.observe(status,frames:frames,capacity:2048,inputSupplied:false),.again)
      }
      XCTAssertThrowsError(try drain.observe(status,frames:frames,capacity:2048,inputSupplied:false))
      XCTAssertFalse(drain.complete); XCTAssertEqual(drain.calls,16)
      XCTAssertThrowsError(try drain.observe(.endOfStream,frames:0,capacity:2048,inputSupplied:false))
    }
    var last=PCMConversionProgress(draining:true)
    for _ in 1..<16 { _ = try last.observe(.inputRanDry,frames:0,capacity:2048,inputSupplied:false) }
    XCTAssertEqual(try last.observe(.endOfStream,frames:0,capacity:2048,inputSupplied:false),.complete)
  }
  func testPCMConversionRejectsErrorsInvalidLengthsAndPrematureEnd() {
    let cases:[(Bool,PCMConversionStatus,UInt32,UInt32)] = [
      (true,.error,0,2048),(true,.unknown,0,2048),(true,.inputRanDry,2,1),
      (true,.inputRanDry,0,0),(true,.haveData,0,2048),(true,.haveData,2049,2048),
      (true,.endOfStream,2,2048),(false,.endOfStream,0,2048)]
    for (draining,status,frames,capacity) in cases {
      var value=PCMConversionProgress(draining:draining)
      XCTAssertThrowsError(try value.observe(status,frames:frames,capacity:capacity,inputSupplied:true))
      XCTAssertFalse(value.complete); XCTAssertTrue(value.failed)
      XCTAssertThrowsError(try value.observe(.endOfStream,frames:0,capacity:2048,inputSupplied:true))
      XCTAssertFalse(value.complete)
    }
  }
  func testPCMOutputCapacityValidatesRateEmptyInputAndOverflow() throws {
    XCTAssertEqual(try PCMConversionProgress.outputCapacity(inputFrames:1024,sampleRate:44100),500)
    XCTAssertEqual(try PCMConversionProgress.outputCapacity(inputFrames:1024,sampleRate:48000),470)
    XCTAssertEqual(try PCMConversionProgress.outputCapacity(inputFrames:3200,sampleRate:16000),3328)
    for rate in [0.0,-1.0,Double.infinity,-Double.infinity,Double.nan,Double.leastNonzeroMagnitude] {
      XCTAssertThrowsError(try PCMConversionProgress.outputCapacity(inputFrames:1024,sampleRate:rate))
    }
    XCTAssertThrowsError(try PCMConversionProgress.outputCapacity(inputFrames:0,sampleRate:48000))
    XCTAssertThrowsError(try PCMConversionProgress.outputCapacity(inputFrames:UInt32.max,sampleRate:1))
  }
  func testPCMQueueKeepsExactOrderTailAndFailedAppendContents() throws {
    let expected=Data((0..<(3200*6+126)).map { UInt8($0 % 251) })
    var queue=PCMQueue(seconds:1); try queue.append(expected)
    let count=queue.count
    XCTAssertThrowsError(try queue.append(Data(repeating:99,count:32002)))
    XCTAssertThrowsError(try queue.append(Data([1,2,3])))
    XCTAssertEqual(queue.count,count)
    var emitted=Data()
    for _ in 0..<6 {
      let frame=try XCTUnwrap(queue.next(final:false)); XCTAssertEqual(frame.count,3200); emitted.append(frame)
    }
    XCTAssertEqual(queue.count,126); XCTAssertNil(queue.next(final:false))
    let tail=try XCTUnwrap(queue.next(final:true)); XCTAssertEqual(tail.count,126); emitted.append(tail)
    XCTAssertEqual(emitted,expected); XCTAssertTrue(queue.isEmpty); XCTAssertNil(queue.next(final:true))
  }
  func testPCMConversionFailureCannotFinishOrCommitLateFinal() throws {
    let id=VoiceIdentity(generation:12)
    var reducer=VoiceEventReducer(identity:id,settings:VoiceSettings())
    _ = try reducer.receive(packet("task-started",task:id.task))
    _ = try reducer.receive(packet("result-generated",task:id.task,payload:result(id:1,text:"retained draft",final:true)))
    reducer.release(at:4)
    var conversion=PCMConversionProgress(draining:true)
    XCTAssertThrowsError(try conversion.observe(.error,frames:0,capacity:2048,inputSupplied:false))
    reducer.fail() // Actual StreamingSession uses the same failure decision.
    XCTAssertFalse(reducer.sendFinish(queueEmpty:true))
    XCTAssertEqual(try reducer.receive(packet("task-finished",task:id.task)),.ignoredTerminal)
    XCTAssertEqual(reducer.state.phase,.failed); XCTAssertEqual(reducer.transcript.preview,"retained draft")
    XCTAssertFalse(reducer.attemptCommit(validated:true)); XCTAssertFalse(reducer.state.capturePermitted)
  }
  func testGUIHoldMouseReleaseIsOwnedAndExactlyOnce() {
    var cycle=GUITestHoldCycle()
    guard case .start(let id)=cycle.press(.mouse) else { return XCTFail("No mouse gesture") }
    XCTAssertEqual(cycle.press(.mouse),.none)
    XCTAssertEqual(cycle.activeID,id)
    XCTAssertEqual(cycle.release(.mouse),.release(id))
    XCTAssertEqual(cycle.release(.mouse),.none); XCTAssertEqual(cycle.cancel(),.none)
    XCTAssertNil(cycle.activeID); XCTAssertTrue(cycle.held.isEmpty)
    XCTAssertFalse(cycle.needsReleaseObservation)
  }
  func testGUIHoldSpaceRepeatsDoNotStartOrStopAnotherGesture() {
    var cycle=GUITestHoldCycle()
    guard case .start(let id)=cycle.press(.space) else { return XCTFail("No keyboard gesture") }
    for _ in 0..<100 { XCTAssertEqual(cycle.press(.space,repeated:true),.none) }
    XCTAssertEqual(cycle.release(.mouse),.none); XCTAssertEqual(cycle.activeID,id)
    XCTAssertEqual(cycle.release(.space),.release(id))
    XCTAssertEqual(cycle.release(.space),.none)
    guard case .start(let next)=cycle.press(.space) else { return XCTFail("Not rearmed") }
    XCTAssertNotEqual(id,next)
  }
  func testGUIHoldMixedSourceCannotStealOwnerOrRearmWhileHeld() {
    var cycle=GUITestHoldCycle()
    guard case .start(let id)=cycle.press(.space) else { return XCTFail("No owner") }
    XCTAssertEqual(cycle.press(.mouse),.none)
    XCTAssertEqual(cycle.release(.mouse),.none); XCTAssertEqual(cycle.activeID,id)
    XCTAssertEqual(cycle.press(.mouse),.none)
    XCTAssertEqual(cycle.release(.space),.release(id))
    XCTAssertEqual(cycle.press(.mouse),.none)
    XCTAssertEqual(cycle.release(.mouse),.none)
    guard case .start=cycle.press(.mouse) else { return XCTFail("Full release did not rearm") }
  }
  func testGUIHoldCancellationWaitsForRealReleaseAndLateUpsAreHarmless() {
    var cycle=GUITestHoldCycle()
    guard case .start(let id)=cycle.press(.space) else { return XCTFail("No owner") }
    XCTAssertEqual(cycle.cancel(),.cancel(id)); XCTAssertEqual(cycle.cancel(),.none)
    XCTAssertNil(cycle.activeID); XCTAssertEqual(cycle.held,[.space])
    XCTAssertTrue(cycle.needsReleaseObservation)
    XCTAssertEqual(cycle.press(.space,repeated:true),.none)
    XCTAssertEqual(cycle.press(.space),.none)
    XCTAssertEqual(cycle.release(.space),.none)
    XCTAssertFalse(cycle.needsReleaseObservation)
    guard case .start=cycle.press(.space) else { return XCTFail("Full release did not rearm") }
  }
  func testGUIRejectedControlReleaseCannotStopAcceptedTestOwner() {
    var owner=GUITestHoldOwner(); let accepted=UUID(), rejected=UUID()
    XCTAssertTrue(owner.begin(accepted)); XCTAssertFalse(owner.begin(rejected))
    XCTAssertFalse(owner.finish(rejected)); XCTAssertTrue(owner.owns(accepted))
    XCTAssertEqual(owner.id,accepted)
    XCTAssertTrue(owner.finish(accepted)); XCTAssertFalse(owner.finish(accepted))
    XCTAssertTrue(owner.begin(rejected)); XCTAssertFalse(owner.finish(accepted))
    XCTAssertTrue(owner.owns(rejected))
  }
  func testGUIOldAudioCallbacksLoseOwnershipAfterCancelOrNewGesture() {
    var owner=GUITestHoldOwner(); let old=UUID(), next=UUID()
    XCTAssertTrue(owner.begin(old)); owner.cancelAll()
    XCTAssertFalse(owner.owns(old)); XCTAssertFalse(owner.finish(old))
    XCTAssertTrue(owner.begin(next)); XCTAssertFalse(owner.owns(old))
    XCTAssertFalse(owner.begin(old)); XCTAssertFalse(owner.finish(old))
    XCTAssertTrue(owner.owns(next)); XCTAssertTrue(owner.finish(next))
  }
  func testOtherModifierChangeRevokesVoiceButRetainsOwnedRelease() {
    for other:UInt16 in [54,55,56,58,59,60,62,57] {
      var keys=PhysicalKeys(); let binding=TriggerBinding(codes:[61])
      XCTAssertEqual(keys.event(code:61,down:true,repeated:false,binding:binding,canStart:true),.start)
      var state=VoiceState(identity:VoiceIdentity(generation:1),settings:VoiceSettings())
      _ = keys.event(code:other,down:true,repeated:false,binding:binding,canStart:true)
      let invalidates=VoiceKeyInterruptionPolicy.shouldInvalidate(code:other,kind:.modifierChange,
        liveVoice:true,ownedCycle:keys.ownsRelease,binding:binding,finalizing:false)
      XCTAssertTrue(invalidates,"An unrelated modifier is real keyboard activity, not a trigger release")
      if invalidates { state.invalidateTarget(at:2); keys.cancel() }
      XCTAssertFalse(state.capturePermitted); XCTAssertFalse(state.targetValid)
      XCTAssertEqual(keys.ownsRelease,[61])
      XCTAssertEqual(keys.event(code:61,down:true,repeated:true,binding:binding,canStart:true),.none)
      _ = keys.event(code:other,down:false,repeated:false,binding:binding,canStart:true)
      _ = keys.event(code:61,down:false,repeated:false,binding:binding,canStart:true)
      state.started(); XCTAssertTrue(state.sendFinish(queueEmpty:true)); state.finished(complete:true)
      XCTAssertEqual(state.phase,.review); XCTAssertFalse(state.attemptCommit(validated:true))
      XCTAssertEqual(keys.event(code:61,down:true,repeated:false,binding:binding,canStart:true),.start)
    }
  }
  func testOwnedTriggerAndBusyFinalizingKeyboardDoNotInvalidate() {
    let binding=TriggerBinding(codes:[59,61]); let frozen:Set<UInt16>=[59,61]
    for kind:VoiceKeyboardEventKind in [.keyDown,.keyUp,.modifierChange] {
      for code:UInt16 in [59,61] {
        XCTAssertFalse(VoiceKeyInterruptionPolicy.shouldInvalidate(code:code,kind:kind,
          liveVoice:true,ownedCycle:frozen,binding:TriggerBinding(codes:[64]),finalizing:false))
        XCTAssertFalse(VoiceKeyInterruptionPolicy.shouldInvalidate(code:code,kind:kind,
          liveVoice:true,ownedCycle:[],binding:binding,finalizing:true))
      }
    }
    XCTAssertTrue(VoiceKeyInterruptionPolicy.shouldInvalidate(code:55,kind:.modifierChange,
      liveVoice:true,ownedCycle:[],binding:binding,finalizing:true))
  }
  func testKeyboardInterruptionOnlyAppliesToLiveUnownedActivity() {
    for kind:VoiceKeyboardEventKind in [.keyDown,.keyUp,.modifierChange] {
      XCTAssertFalse(VoiceKeyInterruptionPolicy.shouldInvalidate(code:0,kind:kind,
        liveVoice:false,ownedCycle:[],binding:nil,finalizing:false))
    }
    XCTAssertFalse(VoiceKeyInterruptionPolicy.shouldInvalidate(code:0,kind:.keyUp,
      liveVoice:true,ownedCycle:[],binding:nil,finalizing:false))
    XCTAssertTrue(VoiceKeyInterruptionPolicy.shouldInvalidate(code:0,kind:.keyDown,
      liveVoice:true,ownedCycle:[],binding:nil,finalizing:false))
    XCTAssertTrue(VoiceKeyInterruptionPolicy.shouldInvalidate(code:55,kind:.modifierChange,
      liveVoice:true,ownedCycle:[],binding:nil,finalizing:false))
  }
  private func nativeLetterReport(_ name: String = "default") throws -> Data {
    let url = try XCTUnwrap(Bundle.module.url(forResource:"native-letter-probe-"+name,withExtension:"json"))
    return try Data(contentsOf:url)
  }
  func testNativeLetterProbeActualReportRequiresAllCasesAndCorrectScope() throws {
    let report = try LetterProbeReport.decode(nativeLetterReport())
    let summary = try report.validatedSummary(expectedKeys:"abcdefghi",expectedHide:true)
    XCTAssertTrue(summary.contains("14 项通过")); XCTAssertTrue(summary.contains("不是"))
    XCTAssertEqual(report.passed,14); XCTAssertEqual(report.failed,0)
    XCTAssertEqual(Set(report.tests.map(\.name)),LetterProbeReport.requiredNames)
    XCTAssertFalse(report.macOSUITested); XCTAssertFalse(report.userDictionaryUsed)
    XCTAssertTrue(report.isolationVerified)
    XCTAssertEqual(report.networkCalls,0)
  }
  func testNativeLetterProbeRejectsIncompleteDuplicateWrongConfigurationAndScope() throws {
    let original = try JSONSerialization.jsonObject(with:nativeLetterReport()) as! [String:Any]
    func verify(_ value:[String:Any]) {
      XCTAssertThrowsError(try LetterProbeReport.decode(JSONSerialization.data(withJSONObject:value)).validatedSummary(expectedKeys:"abcdefghi",expectedHide:true))
    }
    let invalid:[(String,Any)] = [("status","FAIL"),("keys","asdfghjkl"),("hide",false),
      ("format",2),("kind","mock"),("macOS_UI_tested",true),("network_calls",1),
      ("user_dictionary_used",true),("isolation_verified",false),("isolation_verified",1),("passed",13),("failed",1),("skipped",1),("version",""),
      ("hide",1),("fatal","deployment failed")]
    for (key,value) in invalid {
      var changed=original; changed[key]=value; verify(changed)
    }
    var tests=original["tests"] as! [[String:Any]]
    tests.removeLast(); var changed=original; changed["tests"]=tests; verify(changed)
    tests=original["tests"] as! [[String:Any]]; tests[1]=tests[0]; changed["tests"]=tests; verify(changed)
    tests=original["tests"] as! [[String:Any]]; tests[0]["status"]="FAIL"; changed["tests"]=tests; verify(changed)
    XCTAssertThrowsError(try LetterProbeReport.decode(Data()))
    XCTAssertThrowsError(try LetterProbeReport.decode(Data(repeating:32,count:256*1024+1)))
  }
  func testNativeLetterProbeSingleItemNotApplicableIsExplicitNotSkippedFailure() throws {
    let report = try LetterProbeReport.decode(nativeLetterReport("single"))
    let summary = try report.validatedSummary(expectedKeys:"a",expectedHide:true)
    XCTAssertEqual(report.passed,13); XCTAssertEqual(report.skipped,1)
    XCTAssertTrue(summary.contains("不适用"))
    XCTAssertEqual(report.tests.filter{$0.status=="N/A"}.map(\.name),["last_page_missing_item"])
    var bad=try JSONSerialization.jsonObject(with:nativeLetterReport("single")) as! [String:Any]
    var tests=bad["tests"] as! [[String:Any]]; tests[0]["status"]="N/A"; bad["tests"]=tests
    XCTAssertThrowsError(try LetterProbeReport.decode(JSONSerialization.data(withJSONObject:bad)).validatedSummary(expectedKeys:"a",expectedHide:true))
  }
  func testSingleModifierAndRepeats() throws {
    var keys = PhysicalKeys(); let binding = TriggerBinding(codes:[61]); try binding.validate()
    XCTAssertEqual(keys.event(code:61,down:true,repeated:false,binding:binding,canStart:true),.start)
    for _ in 0..<100 { XCTAssertEqual(keys.event(code:61,down:true,repeated:true,binding:binding,canStart:true),.none) }
    XCTAssertEqual(keys.event(code:61,down:false,repeated:false,binding:binding,canStart:true),.stop)
    XCTAssertEqual(keys.event(code:61,down:true,repeated:false,binding:binding,canStart:true),.start)
    _ = keys.event(code:61,down:false,repeated:false,binding:binding,canStart:true)
    XCTAssertEqual(keys.event(code:61,down:true,repeated:false,binding:binding,canStart:true),.start)
  }
  func testTypingWithoutOrdinaryKeyUpsDoesNotBlockVoiceHold() {
    var keys=PhysicalKeys();let binding=TriggerBinding(codes:[58])
    // IMK may deliver ordinary keyDown without keyUp. Typing before recording
    // must not leave printable keys/Space/Return stuck in the hotkey cycle.
    for code:UInt16 in [0,14,49,36,51] {
      XCTAssertEqual(keys.event(code:code,down:true,repeated:false,binding:binding,canStart:false),.none)
    }
    XCTAssertTrue(keys.held.isEmpty)
    XCTAssertEqual(keys.event(code:58,down:true,repeated:false,binding:binding,canStart:true),.start)
    XCTAssertEqual(keys.event(code:58,down:false,repeated:false,binding:binding,canStart:true),.stop)
  }
  func testIdleDeactivateReactivateDoesNotPermanentlyLatchVoice() {
    var keys=PhysicalKeys();let binding=TriggerBinding(codes:[58])
    for _ in 0..<20 {
      keys.lostLifecycle(); keys.reconcileAfterActivation(pressed:[])
      XCTAssertEqual(keys.event(code:58,down:true,repeated:false,binding:binding,canStart:true),.start)
      XCTAssertEqual(keys.event(code:58,down:false,repeated:false,binding:binding,canStart:true),.stop)
    }
  }
  func testIdleLifecycleStillWaitsForModifierPressedOutsideApp() {
    var keys=PhysicalKeys();let binding=TriggerBinding(codes:[58])
    keys.lostLifecycle();keys.reconcileAfterActivation(pressed:[58])
    XCTAssertEqual(keys.event(code:58,down:true,repeated:false,binding:binding,canStart:true),.none)
    _ = keys.event(code:58,down:false,repeated:false,binding:binding,canStart:true)
    XCTAssertEqual(keys.event(code:58,down:true,repeated:false,binding:binding,canStart:true),.start)
  }
  func testActivationIgnoresOrdinaryKeysButWaitsForRealHeldModifier() {
    var keys=PhysicalKeys();let binding=TriggerBinding(codes:[58])
    keys.reconcileAfterActivation(pressed:[0,49])
    XCTAssertEqual(keys.event(code:58,down:true,repeated:false,binding:binding,canStart:true),.start)
    _ = keys.event(code:58,down:false,repeated:false,binding:binding,canStart:true)
    keys.reconcileAfterActivation(pressed:[0,58])
    XCTAssertEqual(keys.event(code:58,down:true,repeated:false,binding:binding,canStart:true),.none)
    _ = keys.event(code:58,down:false,repeated:false,binding:binding,canStart:true)
    XCTAssertEqual(keys.event(code:58,down:true,repeated:false,binding:binding,canStart:true),.start)
  }
  func testExtraSupportedModifierStillRejectsUnconfiguredChord() {
    var keys=PhysicalKeys();let binding=TriggerBinding(codes:[58])
    _ = keys.event(code:56,down:true,repeated:false,binding:binding,canStart:true)
    XCTAssertEqual(keys.event(code:58,down:true,repeated:false,binding:binding,canStart:true),.none)
    _ = keys.event(code:58,down:false,repeated:false,binding:binding,canStart:true)
    _ = keys.event(code:56,down:false,repeated:false,binding:binding,canStart:true)
    XCTAssertEqual(keys.event(code:58,down:true,repeated:false,binding:binding,canStart:true),.start)
  }
  func testCombinationAllReleasedAndBindingChange() {
    var keys = PhysicalKeys(); let old = TriggerBinding(codes:[59,61]); let new = TriggerBinding(codes:[64])
    XCTAssertEqual(keys.event(code:59,down:true,repeated:false,binding:old,canStart:true),.none)
    XCTAssertEqual(keys.event(code:61,down:true,repeated:false,binding:old,canStart:true),.start)
    XCTAssertEqual(keys.event(code:61,down:false,repeated:false,binding:new,canStart:true),.stop)
    XCTAssertEqual(keys.event(code:64,down:true,repeated:false,binding:new,canStart:true),.none)
    _ = keys.event(code:59,down:false,repeated:false,binding:new,canStart:true)
    _ = keys.event(code:64,down:false,repeated:false,binding:new,canStart:true)
    XCTAssertEqual(keys.event(code:64,down:true,repeated:false,binding:new,canStart:true),.start)
  }
  func testCancelCannotRearmHeldKey() {
    var keys = PhysicalKeys(); let binding = TriggerBinding(codes:[61])
    _ = keys.event(code:61,down:true,repeated:false,binding:binding,canStart:true); keys.cancel()
    XCTAssertEqual(keys.event(code:61,down:true,repeated:true,binding:binding,canStart:true),.none)
    _ = keys.event(code:61,down:false,repeated:false,binding:binding,canStart:true)
    XCTAssertEqual(keys.event(code:61,down:true,repeated:false,binding:binding,canStart:true),.start)
  }
  func testTwoSidesNeverUseAggregateFlags() {
    var keys = PhysicalKeys(); let binding = TriggerBinding(codes:[61])
    _ = keys.event(code:61,down:true,repeated:false,binding:binding,canStart:true)
    XCTAssertEqual(keys.event(code:58,down:true,repeated:false,binding:binding,canStart:true),.none)
    XCTAssertEqual(keys.event(code:58,down:false,repeated:false,binding:binding,canStart:true),.none)
    XCTAssertEqual(keys.event(code:61,down:false,repeated:false,binding:binding,canStart:true),.stop)
  }
  func testLetterRepeatGuardDoesNotDisableOrdinaryRepeats() {
    var guarder = LetterRepeatGuard(); guarder.accepted(code:49)
    XCTAssertEqual(guarder.ownedCodes,Set<UInt16>([49]))
    XCTAssertTrue(guarder.consumeRepeat(code:49,isRepeat:true))
    XCTAssertFalse(guarder.consumeRepeat(code:0,isRepeat:true))
    guarder.released(code:49); XCTAssertFalse(guarder.consumeRepeat(code:49,isRepeat:true))
    XCTAssertTrue(guarder.ownedCodes.isEmpty)
  }
  func testUnsafeBindingsRejected() {
    for code:UInt16 in [0,49,36,51,53,57,63,90] { XCTAssertThrowsError(try TriggerBinding(codes:[code]).validate()) }
  }
  func testPageSizeAndKeysMustMatch() {
    var profile = LetterProfile(); profile.pageSize = 3
    XCTAssertThrowsError(try profile.validate()); profile.keys = "asd"; XCTAssertNoThrow(try profile.validate())
    profile.keys = "aaa"; XCTAssertThrowsError(try profile.validate())
  }
  func testExactEndpointAndNoHostInjection() throws {
    var value = VoiceSettings(); value.workspace = "ws-test"; value.region = .beijing
    XCTAssertEqual(try value.endpoint().absoluteString,"wss://ws-test.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference")
    for bad in ["https://evil.example", "ws.test", "foo/bar", "foo@evil", ""] { value.workspace = bad; XCTAssertThrowsError(try value.endpoint()) }
  }
  func testConnectionProbeChecksEndpointAuthenticationButNotModelPermission() {
    let results:[ConnectionProbeResult] = [.webSocketOpened,.timedOut,.failed(httpStatus:401),.failed(httpStatus:429),.failed(httpStatus:nil),.closedBeforeHandshake]
    for result in results {
      XCTAssertEqual(result.authenticationVerified,result == .webSocketOpened)
      XCTAssertFalse(result.modelVerified)
    }
    XCTAssertTrue(ConnectionProbeResult.webSocketOpened.transportEstablished)
    XCTAssertFalse(ConnectionProbeResult.closedBeforeHandshake.transportEstablished)
    XCTAssertTrue(ConnectionProbeResult.failed(httpStatus:401).message.contains("401"))
    XCTAssertTrue(ConnectionProbeResult.failed(httpStatus:401).message.contains("API Key 鉴权失败"))
    XCTAssertTrue(ConnectionProbeResult.failed(httpStatus:403).message.contains("拒绝访问"))
  }
  func testAudioStartupAndNormalStopNotificationsDoNotAbortRecording() {
    XCTAssertFalse(AudioRouteChangePolicy.shouldStop(accepting:true,stopRequested:false,engineRunning:true,deviceChanged:false,formatChanged:false))
    XCTAssertFalse(AudioRouteChangePolicy.shouldStop(accepting:false,stopRequested:true,engineRunning:false,deviceChanged:false,formatChanged:false))
    XCTAssertFalse(AudioRouteChangePolicy.shouldStop(accepting:true,stopRequested:true,engineRunning:false,deviceChanged:true,formatChanged:true))
  }
  func testRealAudioRouteAndFormatLossStillStopAdmission() {
    for (running,device,format) in [(false,false,false),(true,true,false),(true,false,true)] {
      XCTAssertTrue(AudioRouteChangePolicy.shouldStop(accepting:true,stopRequested:false,engineRunning:running,deviceChanged:device,formatChanged:format))
    }
  }
  func testCredentialValidationRejectsUnsafeHeaderBytesWithoutEcho() throws {
    for key in ["fixture-token",String(repeating:"x",count:4096),"A.b_+/-~=Z"] {
      XCTAssertNoThrow(try VoiceCredential.validate(key))
    }
    for bad in ["",String(repeating:"x",count:4097),"has space","trailing\n","cr\r","tab\t","nul\u{0}","esc\u{1b}","delete\u{7f}","非ASCII"] {
      XCTAssertThrowsError(try VoiceCredential.validate(bad)) { error in
        if !bad.isEmpty { XCTAssertFalse(error.localizedDescription.contains(bad)) }
      }
    }
  }
  func testConnectionOnboardingDoesNotRequireRecordingBinding() throws {
    var value = VoiceSettings(); value.workspace = "ws-test"; value.region = .beijing; value.enabled = true
    XCTAssertNil(value.binding); XCTAssertNil(value.credentialReference)
    XCTAssertEqual(try value.validatedConnectionEndpoint().absoluteString,"wss://ws-test.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference")
    for seconds in [0,61] { value.connectSeconds = seconds; XCTAssertThrowsError(try value.validatedConnectionEndpoint()) }
    value.connectSeconds = 10; value.workspace = "other.invalid"
    XCTAssertThrowsError(try value.validatedConnectionEndpoint())
  }
  private func result(id:Int,text:String,final:Bool,heartbeat:Bool=false) -> [String:Any] {
    ["output":["sentence":["sentence_id":id,"text":text,"sentence_end":final,"heartbeat":heartbeat]]]
  }
  func testRevisionFinalDedupAndHeartbeat() throws {
    var acc = TranscriptAccumulator()
    try acc.result(result(id:1,text:"hel",final:false)); try acc.result(result(id:1,text:"hello",final:false))
    try acc.result(result(id:1,text:"hello!",final:true)); try acc.result(result(id:1,text:"hello!",final:true))
    try acc.result(result(id:0,text:"fake",final:false,heartbeat:true))
    XCTAssertEqual(acc.preview,"hello!"); XCTAssertTrue(acc.isComplete)
    try acc.result(result(id:2,text:" world",final:false)); XCTAssertFalse(acc.isComplete)
  }
  func testControlCharactersNeverAutomatic() throws {
    for text in ["send\n", "run\r", "a\tb", "\u{1b}"] {
      var acc = TranscriptAccumulator(); try acc.result(result(id:1,text:text,final:true))
      XCTAssertFalse(acc.permitsAutomaticInsertion); XCTAssertEqual(acc.preview,text)
    }
  }
  func testCumulativeUsageIsSnapshotNotAddition() throws {
    var acc = TranscriptAccumulator(); var r = result(id:1,text:"hello",final:true)
    r["usage"] = ["input_tokens":12]; try acc.result(r); try acc.result(r)
    XCTAssertEqual(acc.usage?["input_tokens"],12)
  }
  func testWrongTaskAndOversizedEventsRejected() throws {
    let id = UUID(); let wrong = try JSONSerialization.data(withJSONObject:["header":["event":"task-started","task_id":UUID().uuidString],"payload":[:]])
    XCTAssertThrowsError(try QwenProtocol.event(wrong,task:id))
    XCTAssertThrowsError(try QwenProtocol.event(Data(repeating:32,count:262145),task:id))
    let run = try JSONSerialization.jsonObject(with:QwenProtocol.run(task:id)) as! [String:Any]
    XCTAssertEqual((run["payload"] as! [String:Any])["model"] as? String,VoiceModel.streaming.rawValue)
  }
  func testLegacyVoiceModelMigrationPreservesConfiguration() throws {
    let data=Data(#"{"enabled":true,"binding":{"codes":[58]},"region":"cn-beijing","workspace":"ws-fixture","credentialReference":"existing-key-reference","deviceUID":"saved-usb","maximumSeconds":60,"previewTransparency":0.45,"previewAtCaret":true}"#.utf8)
    let value=try JSONDecoder().decode(VoiceSettings.self,from:data)
    try value.validate()
    XCTAssertEqual(value.model,.streaming); XCTAssertFalse(value.nativePolish)
    XCTAssertEqual(value.binding?.codes,[58]); XCTAssertEqual(value.deviceUID,"saved-usb")
    XCTAssertEqual(value.credentialReference,"existing-key-reference"); XCTAssertEqual(value.maximumSeconds,60)
    XCTAssertEqual(value.previewTransparency,0.45); XCTAssertTrue(value.previewAtCaret)
  }
  func testFirstSchemaConfigurationAppliesDuringFirstTypedComposition() {
    var boundary=LetterSettingsBoundary(), profile=LetterProfile(); profile.enabled=true
    let first=boundary.offer(schema:"rime_ice",profile:profile,revision:21,composing:true)
    XCTAssertEqual(first?.profile?.hideCandidates,true)
    XCTAssertEqual(first?.profile?.enabled,true)
  }
  func testNewSchemaDoesNotInheritUnknownSchemaDeferredSettings() {
    var boundary=LetterSettingsBoundary(), profile=LetterProfile(); profile.enabled=true
    _ = boundary.offer(schema:"",profile:nil,revision:21,composing:false)
    XCTAssertEqual(boundary.offer(schema:"rime_ice",profile:profile,revision:21,composing:true)?.schema,"rime_ice")
  }
  func testMessageModelAndPolishPersistWithSharedCredentials() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store=SettingsStore(url:directory.appendingPathComponent("settings.json"))
    var settings=Settings(); settings.voice.region = .beijing; settings.voice.workspace="ws-fixture"
    settings.voice.credentialReference="same-key-reference"; settings.voice.deviceUID="same-usb"
    let original=try store.save(settings); let endpoint=try original.voice.endpoint()
    settings=original; settings.voice.model = .message; settings.voice.nativePolish=true
    let saved=try store.save(settings); let loaded=try store.load()
    XCTAssertEqual(saved,loaded); XCTAssertEqual(loaded.revision,original.revision+1)
    XCTAssertEqual(loaded.voice.model,.message); XCTAssertTrue(loaded.voice.nativePolish)
    XCTAssertEqual(try loaded.voice.endpoint(),endpoint)
    XCTAssertEqual(loaded.voice.credentialReference,original.voice.credentialReference)
    XCTAssertEqual(loaded.voice.deviceUID,original.voice.deviceUID)
    settings=loaded; settings.voice.nativePolish=false
    _ = try store.save(settings); XCTAssertFalse(try store.load().voice.nativePolish)
  }
  func testUnknownVoiceModelAndInvalidPolishAreRejected() {
    XCTAssertThrowsError(try JSONDecoder().decode(VoiceSettings.self,from:Data(#"{"model":"unapproved-model"}"#.utf8)))
    XCTAssertThrowsError(try JSONDecoder().decode(VoiceSettings.self,from:Data(#"{"model":"qwen-audio-3.1-asr-flash-message","nativePolish":"true"}"#.utf8)))
  }
  func testMessageRunTaskSendsNativePolishAndStreamingPartials() throws {
    let id=UUID()
    for enabled in [false,true] {
      var settings=VoiceSettings(); settings.model = .message; settings.nativePolish=enabled
      settings.credentialReference="private-reference-never-uploaded"; settings.workspace="ws-fixture"
      let data=try QwenProtocol.run(task:id,settings:settings)
      let run=try JSONSerialization.jsonObject(with:data) as! [String:Any]
      let header=run["header"] as! [String:Any], payload=run["payload"] as! [String:Any]
      let parameters=payload["parameters"] as! [String:Any]
      XCTAssertEqual(header["task_id"] as? String,id.uuidString.lowercased())
      XCTAssertEqual(header["streaming"] as? String,"duplex")
      XCTAssertEqual(payload["model"] as? String,VoiceModel.message.rawValue)
      XCTAssertEqual(parameters["disfluency_removal_enabled"] as? Bool,enabled)
      XCTAssertEqual(parameters["intermediate_result_enabled"] as? Bool,true)
      XCTAssertEqual(parameters["format"] as? String,"pcm"); XCTAssertEqual(parameters["sample_rate"] as? Int,16000)
      XCTAssertTrue((payload["input"] as! [String:Any]).isEmpty)
      XCTAssertFalse(String(decoding:data,as:UTF8.self).contains("private-reference"))
    }
  }
  func testStreamingModelNeverSendsMessageOnlyOptions() throws {
    var settings=VoiceSettings(); settings.nativePolish=true
    let run=try JSONSerialization.jsonObject(with:QwenProtocol.run(task:UUID(),settings:settings)) as! [String:Any]
    let payload=run["payload"] as! [String:Any], parameters=payload["parameters"] as! [String:Any]
    XCTAssertEqual(payload["model"] as? String,VoiceModel.streaming.rawValue)
    XCTAssertEqual(Set(parameters.keys),Set(["format","sample_rate"]))
    XCTAssertFalse(settings.model.supportsNativePolish)
  }
  func testMessageOfficialEventsReplacePartialsAndCommitFinalOnce() throws {
    var settings=VoiceSettings(); settings.model = .message; settings.nativePolish=true
    let id=VoiceIdentity(generation:201); var reducer=VoiceEventReducer(identity:id,settings:settings)
    _ = try reducer.receive(packet("task-started",task:id.task))
    _ = try reducer.receive(packet("result-generated",task:id.task,payload:result(id:1,text:"",final:false)))
    _ = try reducer.receive(packet("result-generated",task:id.task,payload:result(id:1,text:"嗯明天",final:false)))
    XCTAssertEqual(reducer.transcript.preview,"嗯明天"); XCTAssertFalse(reducer.transcript.isComplete)
    let final=try packet("result-generated",task:id.task,payload:result(id:1,text:"明天开会。",final:true))
    _ = try reducer.receive(final); _ = try reducer.receive(final)
    XCTAssertEqual(reducer.transcript.preview,"明天开会。")
    reducer.release(at:10); XCTAssertTrue(reducer.sendFinish(queueEmpty:true))
    _ = try reducer.receive(packet("task-finished",task:id.task))
    XCTAssertEqual(reducer.state.phase,.ready)
    XCTAssertTrue(reducer.attemptCommit(validated:true)); XCTAssertFalse(reducer.attemptCommit(validated:true))
  }
  func testReleaseBeforeTaskStartFinishExactlyOnce() {
    var state = VoiceState(identity:VoiceIdentity(generation:1),settings:VoiceSettings())
    state.release(at:5); XCTAssertFalse(state.capturePermitted); XCTAssertFalse(state.sendFinish(queueEmpty:true))
    state.started(); XCTAssertEqual(state.phase,.finalizing)
    XCTAssertFalse(state.sendFinish(queueEmpty:false)); XCTAssertTrue(state.sendFinish(queueEmpty:true))
    XCTAssertFalse(state.sendFinish(queueEmpty:true)); state.finished(complete:true)
    XCTAssertTrue(state.attemptCommit(validated:true)); XCTAssertFalse(state.attemptCommit(validated:true))
  }
  func testEarlyFinishAndTargetInvalidBecomeReview() {
    var state = VoiceState(identity:VoiceIdentity(generation:1),settings:VoiceSettings())
    state.started(); state.finished(complete:true); XCTAssertEqual(state.phase,.review)
    var other = VoiceState(identity:VoiceIdentity(generation:2),settings:VoiceSettings())
    other.started(); other.invalidateTarget(at:8); _ = other.sendFinish(queueEmpty:true)
    other.finished(complete:true); XCTAssertEqual(other.phase,.review)
    XCTAssertFalse(other.attemptCommit(validated:true))
  }
  func testPCMQueueLimitsChunksAndTail() throws {
    var queue = PCMQueue(seconds:1)
    try queue.append(Data(repeating:0,count:3198)); XCTAssertNil(queue.next(final:false))
    try queue.append(Data(repeating:0,count:2)); XCTAssertEqual(queue.next(final:false)?.count,3200)
    try queue.append(Data(repeating:0,count:100)); XCTAssertEqual(queue.next(final:true)?.count,100)
    XCTAssertThrowsError(try queue.append(Data(repeating:0,count:32002)))
    XCTAssertThrowsError(try queue.append(Data(repeating:0,count:3)))
  }
  func testAtomicSettingsVersionAndRevision() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store = SettingsStore(url:directory.appendingPathComponent("settings.json"))
    let old = Settings(); let saved = try store.save(old); XCTAssertEqual(saved.revision,1)
    XCTAssertThrowsError(try store.save(old)); XCTAssertEqual(try store.load(),saved)
    var unsupported = saved; unsupported.version = 999
    XCTAssertThrowsError(try store.save(unsupported)); XCTAssertEqual(try store.load(),saved)
  }
  func testBusyPressCannotRestartWhenPreviousFinishes() {
    let binding = TriggerBinding(codes:[61]); var keys = PhysicalKeys()
    _ = keys.event(code:61,down:true,repeated:false,binding:binding,canStart:false)
    keys.rejectBusyCycle(binding:binding)
    keys.cancel() // previous task now terminates; busy cycle is still held
    XCTAssertEqual(keys.event(code:61,down:true,repeated:true,binding:binding,canStart:true),.none)
    _ = keys.event(code:61,down:false,repeated:false,binding:binding,canStart:true)
    XCTAssertEqual(keys.event(code:61,down:true,repeated:false,binding:binding,canStart:true),.start)
  }
  func testPhysicalReleaseDeadlineSurvivesIPCQueueDelay() throws {
    let id = VoiceIdentity(generation:7)
    let value = VoiceRelease(identity:id,uptime:5)
    XCTAssertNoThrow(try value.validate(receivedAt:8))
    var state = VoiceState(identity:id,settings:VoiceSettings()); state.release(at:value.uptime)
    state.release(at:8); XCTAssertEqual(state.releasedAt,5)
    XCTAssertThrowsError(try VoiceRelease(identity:id,uptime:.infinity).validate(receivedAt:8))
    XCTAssertThrowsError(try VoiceRelease(identity:id,uptime:9).validate(receivedAt:8))
  }
  func testCorruptSettingsReadOnlyFallbackAndExplicitRecovery() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store = SettingsStore(url:directory.appendingPathComponent("settings.json"))
    var saved = try store.save(Settings()); var profile = LetterProfile(); profile.enabled = true
    saved.letters["pinyin"] = profile; saved = try store.save(saved)
    saved = try store.save(saved) // backup now contains the enabled letter profile
    let bad = Data(repeating:0x7b,count:4 * 1024 * 1024); try bad.write(to:store.url) // Invalid primary exceeds the load budget.
    XCTAssertThrowsError(try store.load())
    let fallback = try XCTUnwrap(store.lastValidReadOnly())
    XCTAssertEqual(fallback.letters["pinyin"],profile); XCTAssertFalse(fallback.voice.enabled)
    XCTAssertEqual(try Data(contentsOf:store.url),bad) // fallback has no side effects
    XCTAssertThrowsError(try store.save(fallback))
    XCTAssertThrowsError(try store.restoreLastValid(expectedRevision:999))
    let restored = try store.restoreLastValid(expectedRevision:fallback.revision)
    XCTAssertEqual(try store.load(),restored); XCTAssertFalse(restored.voice.enabled)
    let backup = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
      .first(where:{$0.pathExtension == "invalid"})
    XCTAssertEqual(try Data(contentsOf:XCTUnwrap(backup)),bad)
  }
  func testTwoFilePatchTransactionAndInterruptedRecovery() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let first = directory.appendingPathComponent("schema.custom.yaml")
    let second = directory.appendingPathComponent("owned")
    try Data("old".utf8).write(to:first)
    try FilePairTransaction.apply(directory:directory,journalName:"journal",first:("schema.custom.yaml",Data("new".utf8)),second:("owned",Data("proof".utf8)))
    XCTAssertEqual(try Data(contentsOf:first),Data("new".utf8))
    XCTAssertEqual(try Data(contentsOf:second),Data("proof".utf8))
    func journal() throws -> Data {
      try JSONSerialization.data(withJSONObject:["version":1,"changes":[
        ["name":"schema.custom.yaml","before":Data("new".utf8).base64EncodedString(),"after":Data("next".utf8).base64EncodedString()],
        ["name":"owned","before":Data("proof".utf8).base64EncodedString(),"after":Data("nextproof".utf8).base64EncodedString()]]])
    }
    let log = directory.appendingPathComponent("journal")
    try journal().write(to:log); try Data("next".utf8).write(to:first) // crash after first rename
    try FilePairTransaction.recover(directory:directory,journalName:"journal",ownedNames:["schema.custom.yaml","owned"])
    XCTAssertEqual(try Data(contentsOf:second),Data("nextproof".utf8)); XCTAssertFalse(FileManager.default.fileExists(atPath:log.path))
    try journal().write(to:log); try Data("user edit".utf8).write(to:first)
    XCTAssertThrowsError(try FilePairTransaction.recover(directory:directory,journalName:"journal",ownedNames:["schema.custom.yaml","owned"]))
    XCTAssertEqual(try Data(contentsOf:first),Data("user edit".utf8))
    XCTAssertThrowsError(try FilePairTransaction.apply(directory:directory,journalName:"../bad",first:("a",nil),second:("b",nil)))
  }
  func testOversizedDecodedRecoveryPayloadNeverWritesEitherFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let first = directory.appendingPathComponent("schema.custom.yaml")
    let second = directory.appendingPathComponent("owned")
    let journal = directory.appendingPathComponent("journal")
    let before = Data("user patch".utf8), proof = Data("user proof".utf8)
    try before.write(to:first); try proof.write(to:second)
    // The JSON log fits the 12 MiB transport budget, but a decoded file image
    // exceeds its 2 MiB budget. Recovery must preflight before any rename.
    let large = Data(repeating:0x61,count:3 * 1024 * 1024)
    let data = try JSONSerialization.data(withJSONObject:["version":1,"changes":[
      ["name":"schema.custom.yaml","before":before.base64EncodedString(),"after":large.base64EncodedString()],
      ["name":"owned","before":proof.base64EncodedString(),"after":Data("new proof".utf8).base64EncodedString()]]])
    try data.write(to:journal)
    XCTAssertThrowsError(try FilePairTransaction.recover(directory:directory,journalName:"journal",ownedNames:["schema.custom.yaml","owned"]))
    XCTAssertEqual(try Data(contentsOf:first),before)
    XCTAssertEqual(try Data(contentsOf:second),proof)
    XCTAssertEqual(try Data(contentsOf:journal),data)
  }
  func testReferenceAppearanceAndOldProfileMigration() throws {
    let profile = LetterProfile()
    XCTAssertEqual(profile.keys,"asdfghjkl"); XCTAssertEqual(profile.appearance.layout,.stacked)
    XCTAssertEqual(profile.appearance.fontPoint,24); XCTAssertEqual(profile.appearance.labelFontPoint,16)
    XCTAssertEqual(profile.appearance.backgroundRGB,"#FFFFFF"); XCTAssertEqual(profile.appearance.highlightedRGB,"#FF0000")
    let old = Data("{\"enabled\":true,\"keys\":\"asdfghjkl\",\"pageSize\":9,\"hideCandidates\":true}".utf8)
    var migrated = try JSONDecoder().decode(LetterProfile.self,from:old)
    XCTAssertEqual(migrated.keys,"asdfghjkl"); XCTAssertEqual(migrated.appearance,profile.appearance)
    migrated.appearance.layout = .linear; migrated.appearance.fontPoint = 32
    let reopened = try JSONDecoder().decode(LetterProfile.self,from:JSONEncoder().encode(migrated))
    XCTAssertEqual(reopened,migrated); XCTAssertNoThrow(try reopened.validate())
    migrated.appearance.fontPoint = 100; XCTAssertThrowsError(try migrated.validate())
    migrated.appearance.fontPoint = 24; migrated.appearance.backgroundRGB = "not a color"; XCTAssertThrowsError(try migrated.validate())
  }
  func testDefaultAppearancePreservesPreviouslySavedCustomStyle() throws {
    let fresh = LetterProfile()
    XCTAssertTrue(fresh.useDefaultAppearance)
    var custom = fresh; custom.useDefaultAppearance = false; custom.appearance.fontPoint = 32
    var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(custom)) as? [String:Any])
    legacy.removeValue(forKey:"useDefaultAppearance")
    let decoded = try JSONDecoder().decode(LetterProfile.self,from:JSONSerialization.data(withJSONObject:legacy))
    XCTAssertFalse(decoded.useDefaultAppearance); XCTAssertEqual(decoded.appearance.fontPoint,32)
    let reopened = try JSONDecoder().decode(LetterProfile.self,from:JSONEncoder().encode(fresh))
    XCTAssertTrue(reopened.useDefaultAppearance)
  }
  func testDefaultAppearanceSwitchWaitsForCurrentComposition() {
    var boundary = LetterSettingsBoundary(), old = LetterProfile()
    old.enabled = true; old.useDefaultAppearance = false
    XCTAssertNotNil(boundary.offer(schema:"pinyin",profile:old,revision:1,composing:false))
    var inherited = old; inherited.useDefaultAppearance = true
    XCTAssertNil(boundary.offer(schema:"pinyin",profile:inherited,revision:2,composing:true))
    XCTAssertNil(boundary.flush(composing:true))
    XCTAssertEqual(boundary.flush(composing:false)?.profile?.useDefaultAppearance,true)
  }
  private func packet(_ event:String, task:UUID, payload:[String:Any]=[:]) throws -> Data {
    try JSONSerialization.data(withJSONObject:["header":["event":event,"task_id":task.uuidString],"payload":payload])
  }
  func testActualEventReducerHoldsAllFinalsUntilWholeTaskEnds() throws {
    let id = VoiceIdentity(generation:1); var reducer = VoiceEventReducer(identity:id,settings:VoiceSettings())
    XCTAssertEqual(try reducer.receive(packet("task-started",task:id.task)),.received)
    for payload in [result(id:1,text:"你",final:false),result(id:1,text:"你好 ",final:true),result(id:2,text:"世界",final:true)] {
      XCTAssertEqual(try reducer.receive(packet("result-generated",task:id.task,payload:payload)),.received)
      XCTAssertEqual(reducer.state.phase,.recording); XCTAssertFalse(reducer.attemptCommit(validated:true))
    }
    XCTAssertEqual(reducer.transcript.preview,"你好 世界")
    reducer.release(at:5); XCTAssertFalse(reducer.state.capturePermitted)
    XCTAssertFalse(reducer.sendFinish(queueEmpty:false)); XCTAssertTrue(reducer.sendFinish(queueEmpty:true))
    XCTAssertFalse(reducer.sendFinish(queueEmpty:true))
    let finish = try packet("task-finished",task:id.task,payload:["usage":["duration":4,"input_tokens":12]])
    XCTAssertEqual(try reducer.receive(finish),.taskFinished); XCTAssertEqual(reducer.state.phase,.ready)
    XCTAssertEqual(try reducer.receive(finish),.ignoredTerminal)
    XCTAssertEqual(reducer.transcript.usage,["duration":4,"input_tokens":12])
    XCTAssertTrue(reducer.attemptCommit(validated:true)); XCTAssertFalse(reducer.attemptCommit(validated:true))
  }
  func testActualEventReducerReleaseBeforeStartCannotRearmCapture() throws {
    let id = VoiceIdentity(generation:2); var reducer = VoiceEventReducer(identity:id,settings:VoiceSettings())
    reducer.release(at:3)
    let started = try packet("task-started",task:id.task)
    for _ in 0..<3 { XCTAssertEqual(try reducer.receive(started),.received) }
    XCTAssertEqual(reducer.state.phase,.finalizing); XCTAssertFalse(reducer.state.capturePermitted)
    XCTAssertEqual(reducer.state.releasedAt,3)
    XCTAssertEqual(try reducer.receive(packet("result-generated",task:id.task,payload:result(id:1,text:"短语",final:true))),.received)
    XCTAssertTrue(reducer.sendFinish(queueEmpty:true))
    XCTAssertEqual(try reducer.receive(packet("task-finished",task:id.task)),.taskFinished)
    XCTAssertEqual(reducer.state.phase,.ready)
  }
  func testActualEventReducerRejectsPrematureWrongTaskAndMalformedPackets() throws {
    let id = VoiceIdentity(generation:3)
    let badPackets = [try packet("result-generated",task:id.task,payload:result(id:1,text:"bad",final:true)),
                      try packet("task-finished",task:id.task),try packet("task-started",task:UUID()),
                      try packet("unknown-event",task:id.task),Data("{not-json}".utf8)]
    for bad in badPackets {
      var reducer = VoiceEventReducer(identity:id,settings:VoiceSettings())
      XCTAssertThrowsError(try reducer.receive(bad)); XCTAssertEqual(reducer.state.phase,.failed)
      XCTAssertFalse(reducer.state.capturePermitted); XCTAssertFalse(reducer.attemptCommit(validated:true))
      XCTAssertEqual(try reducer.receive(packet("task-started",task:id.task)),.ignoredTerminal)
    }
  }
  func testActualEventReducerIncompleteControlOrEarlyEndBecomeReview() throws {
    let id = VoiceIdentity(generation:4)
    for (text,final) in [("partial",false),("",true),("   ",true),("send\n",true)] {
      var reducer = VoiceEventReducer(identity:id,settings:VoiceSettings())
      _ = try reducer.receive(packet("task-started",task:id.task))
      _ = try reducer.receive(packet("result-generated",task:id.task,payload:result(id:1,text:text,final:final)))
      reducer.release(at:6); XCTAssertTrue(reducer.sendFinish(queueEmpty:true))
      XCTAssertEqual(try reducer.receive(packet("task-finished",task:id.task)),.taskFinished)
      XCTAssertEqual(reducer.state.phase,.review); XCTAssertEqual(reducer.transcript.preview,text)
      XCTAssertFalse(reducer.attemptCommit(validated:true))
    }
    var early = VoiceEventReducer(identity:id,settings:VoiceSettings())
    _ = try early.receive(packet("task-started",task:id.task))
    _ = try early.receive(packet("result-generated",task:id.task,payload:result(id:1,text:"final before release",final:true)))
    _ = try early.receive(packet("task-finished",task:id.task))
    XCTAssertEqual(early.state.phase,.review); XCTAssertFalse(early.state.capturePermitted)
  }
  func testActualEventReducerFailureCancellationAndTargetChangeNeverCommitLate() throws {
    let id = VoiceIdentity(generation:5)
    for cause in 0..<3 {
      var reducer = VoiceEventReducer(identity:id,settings:VoiceSettings())
      _ = try reducer.receive(packet("task-started",task:id.task))
      _ = try reducer.receive(packet("result-generated",task:id.task,payload:result(id:1,text:"draft",final:false)))
      if cause == 0 {
        XCTAssertEqual(try reducer.receive(packet("task-failed",task:id.task)),.taskFailed)
      } else if cause == 1 { reducer.cancel() }
      else {
        reducer.invalidateTarget(at:7)
        _ = try reducer.receive(packet("result-generated",task:id.task,payload:result(id:1,text:"final draft",final:true)))
        XCTAssertTrue(reducer.sendFinish(queueEmpty:true))
        _ = try reducer.receive(packet("task-finished",task:id.task))
        XCTAssertEqual(reducer.state.phase,.review)
      }
      let draft = reducer.transcript.preview
      XCTAssertEqual(try reducer.receive(packet("result-generated",task:id.task,payload:result(id:1,text:"late",final:true))),.ignoredTerminal)
      XCTAssertEqual(reducer.transcript.preview,draft); XCTAssertFalse(reducer.attemptCommit(validated:true))
      XCTAssertFalse(reducer.state.capturePermitted)
    }
  }
  func testActualEventReducerHeartbeatDuplicatesAndContradictoryFinal() throws {
    let id = VoiceIdentity(generation:6); var reducer = VoiceEventReducer(identity:id,settings:VoiceSettings())
    _ = try reducer.receive(packet("task-started",task:id.task))
    _ = try reducer.receive(packet("result-generated",task:id.task,payload:result(id:0,text:"ignore",final:false,heartbeat:true)))
    let final = try packet("result-generated",task:id.task,payload:result(id:1,text:"first",final:true))
    _ = try reducer.receive(final); _ = try reducer.receive(final)
    XCTAssertEqual(reducer.transcript.preview,"first")
    XCTAssertThrowsError(try reducer.receive(packet("result-generated",task:id.task,payload:result(id:1,text:"contradiction",final:true))))
    XCTAssertEqual(reducer.transcript.preview,"first"); XCTAssertEqual(reducer.state.phase,.failed)
    XCTAssertFalse(reducer.transcript.permitsAutomaticInsertion)
    XCTAssertEqual(try reducer.receive(packet("task-finished",task:id.task)),.ignoredTerminal)
    XCTAssertFalse(reducer.attemptCommit(validated:true))
  }
  func testConflictingFinalIsStickyAndPreservesOriginalDraft() throws {
    var acc = TranscriptAccumulator()
    try acc.result(result(id:1,text:"first",final:true))
    try acc.result(result(id:1,text:"first",final:true))
    XCTAssertTrue(acc.permitsAutomaticInsertion)
    XCTAssertThrowsError(try acc.result(result(id:1,text:"contradiction",final:true)))
    XCTAssertEqual(acc.preview,"first"); XCTAssertFalse(acc.protocolValid)
    XCTAssertFalse(acc.permitsAutomaticInsertion)
    try acc.result(result(id:2,text:" second",final:true))
    XCTAssertFalse(acc.permitsAutomaticInsertion) // Later valid packets cannot erase an earlier fault.
  }
  func testMissingSentenceCannotPretendCompleteAndOutOfOrderCanFillGap() throws {
    var acc = TranscriptAccumulator()
    try acc.result(result(id:3,text:"third",final:true)); XCTAssertFalse(acc.isComplete)
    try acc.result(result(id:1,text:"first ",final:true)); XCTAssertFalse(acc.isComplete)
    try acc.result(result(id:2,text:"second ",final:true))
    XCTAssertTrue(acc.isComplete); XCTAssertEqual(acc.preview,"first second third")
    try acc.result(result(id:1,text:"stale interim",final:false))
    XCTAssertEqual(acc.preview,"first second third")
    for blank in ["","   "] {
      var empty = TranscriptAccumulator(); try empty.result(result(id:1,text:blank,final:true))
      XCTAssertFalse(empty.permitsAutomaticInsertion)
    }
  }
  func testBooleanAndIntegerJSONFieldsCannotBeConfused() throws {
    for sentence:[String:Any] in [
      ["sentence_id":true,"text":"bad","sentence_end":true],
      ["sentence_id":1.5,"text":"bad","sentence_end":true],
      ["sentence_id":1025,"text":"bad","sentence_end":true],
      ["sentence_id":1,"text":"bad","sentence_end":1],
      ["heartbeat":1]] {
      // Go through real JSONSerialization NSNumber bridging, not only native Swift values.
      let encoded = try JSONSerialization.data(withJSONObject:["output":["sentence":sentence]])
      let payload = try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
      var acc = TranscriptAccumulator(); XCTAssertThrowsError(try acc.result(payload))
      XCTAssertFalse(acc.protocolValid); XCTAssertFalse(acc.permitsAutomaticInsertion)
    }
  }
  func testValidJSONBooleansAndSmallIntegersRemainDistinct() throws {
    for id in [1, 2] {
      let encoded = try JSONSerialization.data(withJSONObject:result(id:id,text:"valid",final:true))
      let payload = try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
      var acc = TranscriptAccumulator(); XCTAssertNoThrow(try acc.result(payload))
      XCTAssertEqual(acc.sentences[id],RecognitionSentence(text:"valid",final:true))
    }
    var acc = TranscriptAccumulator()
    // Byte-sized numeric 0/1 must never become a boolean just because of its
    // Objective-C encoding; both JSON-origin and native bridged values matter.
    acc.recordUsage(["usage":["input_tokens":NSNumber(value:Int8(1)),"output_tokens":NSNumber(value:Int8(0)),"duration":false]])
    XCTAssertEqual(acc.usage,["input_tokens":1,"output_tokens":0])
    var interim = TranscriptAccumulator()
    try interim.result(result(id:1,text:"interim",final:false)); XCTAssertFalse(interim.isComplete)
    try interim.result(result(id:0,text:"heartbeat",final:false,heartbeat:true))
    XCTAssertEqual(interim.preview,"interim")
  }
  func testOversizedRevisionDoesNotMutateAcceptedDraft() throws {
    var acc = TranscriptAccumulator(); let piece = String(repeating:"x",count:65536)
    try acc.result(result(id:1,text:piece,final:true)); try acc.result(result(id:2,text:piece,final:true))
    XCTAssertThrowsError(try acc.result(result(id:3,text:"overflow",final:true)))
    XCTAssertEqual(acc.preview.utf8.count,131072); XCTAssertNil(acc.sentences[3])
    XCTAssertFalse(acc.permitsAutomaticInsertion)
  }
  func testPayloadMustBeAnObjectAndUsageDoesNotAcceptBooleans() throws {
    let task = UUID()
    let packet = try JSONSerialization.data(withJSONObject:["header":["event":"task-started","task_id":task.uuidString],"payload":[]])
    XCTAssertThrowsError(try QwenProtocol.event(packet,task:task))
    var acc = TranscriptAccumulator()
    acc.recordUsage(["usage":["duration":Double.infinity,"input_tokens":true,"output_tokens":-1,"total_tokens":12,"nested":999]])
    XCTAssertEqual(acc.usage,["total_tokens":12])
  }
  func testPreviewPreferenceOldSettingsMigrationAndRoundTrip() throws {
    var value = VoiceSettings(); value.workspace = "ws-test"; value.maximumSeconds = 30; value.showPreview = false
    var object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any]
    object.removeValue(forKey:"showPreview")
    let old = try JSONDecoder().decode(VoiceSettings.self,from:JSONSerialization.data(withJSONObject:object))
    XCTAssertTrue(old.showPreview); XCTAssertEqual(old.workspace,"ws-test"); XCTAssertEqual(old.maximumSeconds,30)
    XCTAssertEqual(try JSONDecoder().decode(VoiceSettings.self,from:JSONEncoder().encode(value)),value)
  }
  private var patchProcessors:[String] { ["ascii_composer","recognizer","key_binder","speller","punctuator","selector","navigator","express_editor"] }
  private var enabledPatch:LetterProfile { var p = LetterProfile(); p.enabled = true; return p }
  func testManagedPatchSmallInsertionAndExactRestore() throws {
    let source = "# 原注释\npatch: # custom\n  menu/page_size: 5 # 原页大小\n  translator/dictionary: user_dict\n"
    let plan = try ManagedLetterPatch.plan(schema:"pinyin",existing:source,ownership:nil,profile:enabledPatch,processors:patchProcessors)
    let text = try XCTUnwrap(plan.yaml)
    XCTAssertTrue(text.contains("@before 0")); XCTAssertTrue(text.contains("translator/dictionary: user_dict"))
    XCTAssertEqual(plan.expectedProcessors,[ManagedLetterPatch.module]+patchProcessors)
    var disabled = enabledPatch; disabled.enabled = false
    let restored = try ManagedLetterPatch.plan(schema:"pinyin",existing:text,ownership:plan.ownership,profile:disabled,processors:[])
    XCTAssertEqual(restored.yaml,source); XCTAssertNil(restored.ownership)
    var changed = enabledPatch; changed.keys = "qwertyuio"
    let again = try ManagedLetterPatch.plan(schema:"pinyin",existing:text,ownership:plan.ownership,profile:changed,processors:try XCTUnwrap(plan.expectedProcessors))
    XCTAssertEqual(try ManagedLetterPatch.plan(schema:"pinyin",existing:again.yaml,ownership:again.ownership,profile:disabled,processors:[]).yaml,source)
  }
  func testManagedPatchLegacyFlowListNeedsExplicitConsentAndPreservesAllOthers() throws {
    let old = "lua_processor@*space_select_gate"
    let pipeline = [patchProcessors[0],old]+Array(patchProcessors.dropFirst())
    let source = "patch:\n  engine/processors: [ascii_composer, lua_processor@*space_select_gate, recognizer, key_binder, speller, punctuator, selector, navigator, express_editor] # legacy\n  menu/page_size: 5\n  translator/dictionary: custom_words\n"
    XCTAssertThrowsError(try ManagedLetterPatch.plan(schema:"pinyin",existing:source,ownership:nil,profile:enabledPatch,processors:pipeline))
    let plan = try ManagedLetterPatch.plan(schema:"pinyin",existing:source,ownership:nil,profile:enabledPatch,processors:pipeline,replaceLegacy:true)
    XCTAssertEqual(plan.expectedProcessors,[ManagedLetterPatch.module]+patchProcessors)
    XCTAssertTrue(plan.replacedLegacy); XCTAssertFalse(try XCTUnwrap(plan.yaml).contains(old))
    var disabled = enabledPatch; disabled.enabled = false
    XCTAssertEqual(try ManagedLetterPatch.plan(schema:"pinyin",existing:plan.yaml,ownership:plan.ownership,profile:disabled,processors:[]).yaml,source)
  }
  func testManagedPatchLaterUnrelatedEditsSurviveAndOwnedEditsRefuse() throws {
    let source = "patch:\n  menu/page_size: 5\n  translator/dictionary: old_words\n"
    let plan = try ManagedLetterPatch.plan(schema:"pinyin",existing:source,ownership:nil,profile:enabledPatch,processors:patchProcessors)
    let text = try XCTUnwrap(plan.yaml)
    var disabled = enabledPatch; disabled.enabled = false
    let edited = text.replacingOccurrences(of:"old_words",with:"new_words")+"# later unrelated comment\n"
    let restored = try ManagedLetterPatch.plan(schema:"pinyin",existing:edited,ownership:plan.ownership,profile:disabled,processors:[])
    XCTAssertTrue(try XCTUnwrap(restored.yaml).contains("new_words")); XCTAssertTrue(try XCTUnwrap(restored.yaml).contains("# later unrelated comment"))
    XCTAssertTrue(try XCTUnwrap(restored.yaml).contains("menu/page_size: 5")); XCTAssertFalse(try XCTUnwrap(restored.yaml).contains(ManagedLetterPatch.begin))
    XCTAssertThrowsError(try ManagedLetterPatch.plan(schema:"pinyin",existing:text.replacingOccurrences(of:"asdfghjkl",with:"qwertyuio"),ownership:plan.ownership,profile:disabled,processors:[]))
    XCTAssertThrowsError(try ManagedLetterPatch.plan(schema:"pinyin",existing:text+"  menu/page_size: 7\n",ownership:plan.ownership,profile:disabled,processors:[]))
    var proof = try JSONSerialization.jsonObject(with:try XCTUnwrap(plan.ownership)) as! [String:Any]
    proof["original"] = source.replacingOccurrences(of:"old_words",with:"forged_words")
    let forged = try JSONSerialization.data(withJSONObject:proof)
    XCTAssertThrowsError(try ManagedLetterPatch.plan(schema:"pinyin",existing:text,ownership:forged,profile:disabled,processors:[]))
    let commentOnly = try ManagedLetterPatch.plan(schema:"pinyin",existing:"# initially no patch\n",ownership:nil,profile:enabledPatch,processors:patchProcessors)
    let laterRoot = try XCTUnwrap(commentOnly.yaml)+"unrelated_root: true\n"
    let rootRestored = try ManagedLetterPatch.plan(schema:"pinyin",existing:laterRoot,ownership:commentOnly.ownership,profile:disabled,processors:[])
    XCTAssertTrue(try XCTUnwrap(rootRestored.yaml).contains("unrelated_root: true"))
    XCTAssertFalse(try XCTUnwrap(rootRestored.yaml).contains("patch:"))
  }
  func testManagedPatchMissingFileWrongIdentityAndUnsupportedShapesRefuse() throws {
    let plan = try ManagedLetterPatch.plan(schema:"pinyin",existing:nil,ownership:nil,profile:enabledPatch,processors:patchProcessors)
    XCTAssertThrowsError(try ManagedLetterPatch.plan(schema:"pinyin",existing:nil,ownership:plan.ownership,profile:enabledPatch,processors:patchProcessors))
    XCTAssertThrowsError(try ManagedLetterPatch.plan(schema:"other",existing:plan.yaml,ownership:plan.ownership,profile:enabledPatch,processors:patchProcessors))
    for source in ["patch: {menu/page_size: 5}\n","patch:\n  menu: {page_size: 5}\n","patch:\n  <<: *alias\n","patch:\n  menu/page_size: 5\n  menu/page_size: 7\n"] {
      XCTAssertThrowsError(try ManagedLetterPatch.plan(schema:"pinyin",existing:source,ownership:nil,profile:enabledPatch,processors:patchProcessors))
    }
    XCTAssertThrowsError(try ManagedLetterPatch.plan(schema:"pinyin",existing:"patch:\n  custom: true\n",ownership:nil,profile:enabledPatch,processors:patchProcessors,parsedKeys:["different"]))
  }
  func testManagedPatchCRLFIndentAndUnknownGate() throws {
    let source = "patch:\r\n    engine/processors: [ascii_composer, selector]\r\n    translator/dictionary: words\r\n"
    let plan = try ManagedLetterPatch.plan(schema:"pinyin",existing:source,ownership:nil,profile:enabledPatch,processors:["ascii_composer","selector"])
    XCTAssertTrue(try XCTUnwrap(plan.yaml).contains("    letter_selection/keys"))
    XCTAssertFalse(try XCTUnwrap(plan.yaml).replacingOccurrences(of:"\r\n",with:"").contains("\n"))
    var disabled = enabledPatch; disabled.enabled = false
    XCTAssertEqual(try ManagedLetterPatch.plan(schema:"pinyin",existing:plan.yaml,ownership:plan.ownership,profile:disabled,processors:[]).yaml,source)
    XCTAssertThrowsError(try ManagedLetterPatch.plan(schema:"pinyin",existing:"patch:\r\n  other: true\n",ownership:nil,profile:enabledPatch,processors:patchProcessors))
    XCTAssertThrowsError(try ManagedLetterPatch.plan(schema:"pinyin",existing:"patch:\n",ownership:nil,profile:enabledPatch,processors:["lua_processor@*space_select_gate_v2"],replaceLegacy:true))
  }
  func testManagedPatchReapplyDoesNotDuplicateAndDetectsPipelineChange() throws {
    let first = try ManagedLetterPatch.plan(schema:"pinyin",existing:"patch:\n",ownership:nil,profile:enabledPatch,processors:patchProcessors)
    var changed = enabledPatch; changed.keys = "qwertyuio"
    let second = try ManagedLetterPatch.plan(schema:"pinyin",existing:first.yaml,ownership:first.ownership,profile:changed,processors:try XCTUnwrap(first.expectedProcessors))
    let text = try XCTUnwrap(second.yaml)
    XCTAssertEqual(text.components(separatedBy:ManagedLetterPatch.module).count-1,1)
    XCTAssertTrue(text.contains("qwertyuio"))
    XCTAssertThrowsError(try ManagedLetterPatch.plan(schema:"pinyin",existing:first.yaml,ownership:first.ownership,profile:changed,processors:["new_component"]+patchProcessors))
  }
  func testManagedPatchVersionOneAdoptionDoesNotReinstallOldBlockOnDisable() throws {
    let block = "  # BEGIN SquirrelEnhanced owned patch v1\n  \"engine/processors/@before 0\": \"lua_processor@*letter_selection\"\n  letter_selection/enabled: true\n  letter_selection/keys: \"asdfghjkl\"\n  letter_selection/hide_candidates: true\n  menu/page_size: 9\n  # END SquirrelEnhanced owned patch v1"
    let source = "patch:\n"+block+"\n  translator/dictionary: words\n"
    let plan = try ManagedLetterPatch.plan(schema:"pinyin",existing:source,ownership:Data(block.utf8),profile:enabledPatch,processors:[ManagedLetterPatch.module]+patchProcessors)
    var disabled = enabledPatch; disabled.enabled = false
    let restored = try ManagedLetterPatch.plan(schema:"pinyin",existing:plan.yaml,ownership:plan.ownership,profile:disabled,processors:[])
    XCTAssertFalse(try XCTUnwrap(restored.yaml).contains("owned patch")); XCTAssertTrue(try XCTUnwrap(restored.yaml).contains("translator/dictionary: words"))
  }
  func testManagedPatchSharedGoldenRecipes() throws {
    struct Recipe:Decodable {
      var name:String; var source:String; var expected:String
      var processorsBefore:[String]; var processorsAfter:[String]; var replaceLegacy:Bool
    }
    let url = try XCTUnwrap(Bundle.module.url(forResource:"native-patch-recipes",withExtension:"json"))
    let recipes = try JSONDecoder().decode([Recipe].self,from:Data(contentsOf:url))
    XCTAssertEqual(recipes.count,3)
    var explicitFixtureProfile=enabledPatch; explicitFixtureProfile.keys="abcdefghi"
    for recipe in recipes {
      let result = try ManagedLetterPatch.plan(schema:"pinyin",existing:recipe.source,ownership:nil,
        profile:explicitFixtureProfile,processors:recipe.processorsBefore,replaceLegacy:recipe.replaceLegacy)
      XCTAssertEqual(result.yaml,recipe.expected,recipe.name); XCTAssertEqual(result.expectedProcessors,recipe.processorsAfter,recipe.name)
    }
  }
}
