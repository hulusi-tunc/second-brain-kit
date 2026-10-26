import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

final class CallRecorder {
  let dir: URL
  let started = Date()
  private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
  private let lock = NSLock()

  // them
  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var agg = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?
  private var themFile: AVAudioFile?
  private var themConv: AVAudioConverter?
  private var themFrames = 0

  // me
  private let engine = AVAudioEngine()
  private var meFile: AVAudioFile?
  private var meConv: AVAudioConverter?
  private var meFrames = 0
  private var observer: NSObjectProtocol?

  /// the call side as it arrives, 16 kHz mono (on the tap thread)
  var onThem: (([Float]) -> Void)?

  init(dir: URL) { self.dir = dir }

  func start() throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let wav: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                              AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
    themFile = try AVAudioFile(forWriting: dir.appendingPathComponent("them.wav"), settings: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
    meFile = try AVAudioFile(forWriting: dir.appendingPathComponent("me.wav"), settings: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
    try startTap()
    try startMic()
    observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
      try? self?.startMic()
    }
  }

  func stop() -> (me: URL, them: URL, seconds: Double) {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    if let procID { AudioDeviceStop(agg, procID); AudioDeviceDestroyIOProcID(agg, procID) }
    if agg != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(agg) }
    if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    lock.lock(); themFile = nil; meFile = nil; lock.unlock()
    return (dir.appendingPathComponent("me.wav"), dir.appendingPathComponent("them.wav"), Date().timeIntervalSince(started))
  }

  private func startTap() throws {
    let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    desc.uuid = UUID()
    desc.muteBehavior = .unmuted
    desc.isPrivate = true
    guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { throw NSError(domain: "brain.tap", code: 1) }
    let outUID = CallRecorder.defaultOutputUID()
    let aggDesc: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Brain call", kAudioAggregateDeviceUIDKey: UUID().uuidString,
      kAudioAggregateDeviceMainSubDeviceKey: outUID, kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
      kAudioAggregateDeviceTapAutoStartKey: true,
      kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
      kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
    ]
    guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg) == noErr else { throw NSError(domain: "brain.tap", code: 2) }
    var a = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription()
    var s = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    AudioObjectGetPropertyData(tapID, &a, 0, nil, &s, &asbd)
    guard let fmt = AVAudioFormat(streamDescription: &asbd) else { throw NSError(domain: "brain.tap", code: 3) }
    themConv = AVAudioConverter(from: fmt, to: target)
    themConv?.downmix = true
    AudioDeviceCreateIOProcIDWithBlock(&procID, agg, DispatchQueue(label: "brain.tap")) { [weak self] _, inData, _, _, _ in
      guard let self, let b = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: inData, deallocator: nil) else { return }
      self.write(b, converter: self.themConv, file: \.themFile, frames: \.themFrames, hook: self.onThem)
    }
    guard AudioDeviceStart(agg, procID) == noErr else { throw NSError(domain: "brain.tap", code: 4) }
  }

  private func startMic() throws {
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    let input = engine.inputNode
    if let pick = Mic.bestInput(), let au = input.audioUnit {
      var id = pick.id
      AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }
    let fmt = input.outputFormat(forBus: 0)
    meConv = AVAudioConverter(from: fmt, to: target)
    meConv?.downmix = true
    input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] b, _ in
      guard let self else { return }
      self.write(b, converter: self.meConv, file: \.meFile, frames: \.meFrames)
    }
    engine.prepare()
    try engine.start()
  }

  /// Converts to 16 kHz mono and appends, padding with silence first if the track fell behind the
  /// wall clock (by more than 0.2 s).
  private func write(_ b: AVAudioPCMBuffer, converter: AVAudioConverter?, file: ReferenceWritableKeyPath<CallRecorder, AVAudioFile?>,
                     frames: ReferenceWritableKeyPath<CallRecorder, Int>, hook: (([Float]) -> Void)? = nil) {
    guard let converter else { return }
    let cap = AVAudioFrameCount(Double(b.frameLength) * 16_000 / b.format.sampleRate) + 64
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
    var fed = false
    converter.convert(to: out, error: nil) { _, st in
      if fed { st.pointee = .noDataNow; return nil }
      fed = true; st.pointee = .haveData; return b
    }
    if let hook, out.frameLength > 0 { hook(Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))) }
    lock.lock(); defer { lock.unlock() }
    guard let f = self[keyPath: file] else { return }
    let due = Int(Date().timeIntervalSince(started) * 16_000) - Int(out.frameLength)
    let behind = due - self[keyPath: frames]
    if behind > 3_200, let gap = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(behind)) {
      gap.frameLength = gap.frameCapacity
      memset(gap.floatChannelData![0], 0, Int(gap.frameLength) * 4)
      try? f.write(from: gap)
      self[keyPath: frames] += Int(gap.frameLength)
    }
    try? f.write(from: out)
    self[keyPath: frames] += Int(out.frameLength)
  }

  static func defaultOutputUID() -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dev = AudioObjectID()
    var s = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &dev)
    var u = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var s2 = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    AudioObjectGetPropertyData(dev, &u, 0, nil, &s2, &cf)
    return (cf?.takeRetainedValue() as String?) ?? ""
  }
}
