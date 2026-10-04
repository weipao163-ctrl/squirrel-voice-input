import Foundation
import AVFoundation
import EnhancementCore

@main enum NativeAudioProbe {
  static func main() throws {
    let output=AVAudioFormat(commonFormat:.pcmFormatInt16,sampleRate:16000,channels:1,interleaved:true)!
    var rows:[[String:Any]]=[]
    for rate in [16000.0,44100.0,48000.0] {
      for channels:AVAudioChannelCount in [1,2] {
        for interleaved in [false,true] {
          for chunk in [1024,Int(rate)] {
            let source=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:rate,channels:channels,interleaved:interleaved)!
            var pcm=Data(), errors:[String]=[]
            let converter=try PCMBufferConverter(source:source,output:output,
              pcm:{ data,_ in pcm.append(data) },failure:{errors.append($0)})
            var offset=0, good=true
            while offset<Int(rate) && good {
              let count=min(chunk,Int(rate)-offset)
              let buffer=AVAudioPCMBuffer(pcmFormat:source,frameCapacity:AVAudioFrameCount(count))!
              buffer.frameLength=AVAudioFrameCount(count)
              for channel in 0..<Int(channels) {
                let samples=buffer.floatChannelData![interleaved ? 0 : channel]
                for frame in 0..<count {
                  samples[interleaved ? frame*Int(channels)+channel : frame]=Float(0.1*sin(2*Double.pi*440*Double(offset+frame)/rate))
                }
              }
              good=converter.convert(buffer); offset+=count
            }
            if good { good=converter.convert(nil) }
            let samples=pcm.withUnsafeBytes { raw in
              Array(raw.bindMemory(to:Int16.self)).map { Double(Int16(littleEndian:$0))/32768 }
            }
            let rms=samples.isEmpty ? 0 : sqrt(samples.reduce(0){$0+$1*$1}/Double(samples.count))
            let crossings=zip(samples,samples.dropFirst()).filter { $0<0 && $1>=0 }.count
            good = good && errors.isEmpty && (15000...17000).contains(samples.count) &&
              (0.02...0.20).contains(rms) && (390...490).contains(crossings)
            rows.append(["rate":rate,"channels":channels,"interleaved":interleaved,"chunk":chunk,
                         "outputFrames":samples.count,"rms":rms,"positiveCrossings":crossings,
                         "status":good ? "PASS" : "FAIL","errors":errors])
          }
        }
      }
    }
    let report:[String:Any]=["layer":"real AVAudioConverter on synthetic 440 Hz signals; same production converter",
      "microphone_used":false,"cloud_calls":0,"cases":rows,
      "status":rows.allSatisfy { $0["status"] as? String == "PASS" } ? "PASS" : "FAIL"]
    let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
    FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
    if report["status"] as? String != "PASS" { exit(1) }
  }
}
