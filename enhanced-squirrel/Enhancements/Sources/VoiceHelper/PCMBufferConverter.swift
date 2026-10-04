import AVFoundation
import EnhancementCore

// The same converter is used by production capture and the synthetic native
// signal probe. No engine, permission request, microphone or network here.
final class PCMBufferConverter {
  private let converter: AVAudioConverter
  private let format: AVAudioFormat
  private let onPCM: (Data, Double) -> Void
  private let onFailure: (String) -> Void
  private var conversionFailed = false
  init(source:AVAudioFormat,output:AVAudioFormat,pcm:@escaping(Data,Double)->Void,
       failure:@escaping(String)->Void) throws {
    guard let converter=AVAudioConverter(from:source,to:output) else {
      throw SettingsError.invalid("输入设备格式不可转换为 16 kHz 单声道 PCM。")
    }
    converter.downmix=true; self.converter=converter; format=output
    onPCM=pcm; onFailure=failure
  }
  private func conversionFailure(_ message: String) -> Bool {
    guard !conversionFailed else { return false }
    conversionFailed = true
    onFailure(message); return false
  }
  func convert(_ buffer: AVAudioPCMBuffer?) -> Bool {
    guard !conversionFailed else { return false }
    do {
      let frames = try buffer.map { try PCMConversionProgress.outputCapacity(inputFrames:$0.frameLength,sampleRate:$0.format.sampleRate) } ?? 2048
      var progress = PCMConversionProgress(draining:buffer == nil)
      var supplied = false // Preserved across calls: never offer the same input twice.
      while true {
        guard let output = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:frames) else {
          return conversionFailure("PCM 输出缓冲分配失败；仅保留草稿。")
        }
        var error: NSError?
        let status = converter.convert(to:output,error:&error) { _, inputStatus in
          if let buffer, !supplied { supplied = true; inputStatus.pointee = .haveData; return buffer }
          inputStatus.pointee = buffer == nil ? .endOfStream : .noDataNow; return nil
        }
        let normalized:PCMConversionStatus
        switch status {
        case .haveData: normalized = .haveData
        case .inputRanDry: normalized = .inputRanDry
        case .endOfStream: normalized = .endOfStream
        case .error: normalized = .error
        @unknown default: normalized = .unknown
        }
        let step = try progress.observe(error == nil ? normalized : .error,
            frames:output.frameLength,capacity:frames,inputSupplied:supplied)
        if output.frameLength > 0 {
          guard let samples = output.int16ChannelData?[0] else {
            return conversionFailure("PCM 输出缺少有效样本；仅保留草稿。")
          }
          let count = Int(output.frameLength)
          let sum = (0..<count).reduce(0.0) { $0 + pow(Double(samples[$1]) / 32768.0, 2) }
          onPCM(Data(bytes:samples,count:count*2),sqrt(sum/Double(count)))
        }
        if step == .complete { return true }
      }
    } catch { return conversionFailure(error.localizedDescription) }
  }
}
