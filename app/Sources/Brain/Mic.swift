import AVFoundation
import CoreAudio
import AudioToolbox
import Foundation

final class Mic {
  private var engine = AVAudioEngine()
  private let q = DispatchQueue(label: "brain.mic", qos: .userInteractive)
  /// macOS audio has not answered an open for 3 s (the notch says so) / for 8 s (Brain starts again)
  var onSlow: (() -> Void)?
  var onStuck: (() -> Void)?
  private var opening = 0
  private var configToken: NSObjectProtocol?
  private var restartsInTake = 0
  /// the device notices come in bursts; one settle timer for the whole burst
  private var settle: DispatchWorkItem?
  /// buffers since the last open, to notice a mic that opens but sends nothing
  private var buffersSinceOpen = 0
  private var converter: AVAudioConverter?
  private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
  private let lock = NSLock()
  private var samples: [Float] = []
  private(set) var peakLevel: Float = 0
  /// the loudest single sample of the take, 1.0 is clipping
  private(set) var peakSample: Float = 0
  /// set when the mic in use went away during a take
  private(set) var lostDuringTake = false
  /// 0..1, about 30 times a second, on the main thread
  var onLevel: ((Float) -> Void)?
  /// every raw buffer, on the audio thread (Apple's engine streams from these)
  var onBuffer: ((AVAudioPCMBuffer) -> Void)?
  private(set) var deviceName = ""

  var alwaysWarm = false
  private let warmSeconds: TimeInterval = 120
  private let prerollSeconds = 0.6
  private var running = false
  private var recording = false
  private var ring: [Float] = []              // the last prerollSeconds at 16 kHz
  private var rawRing: [AVAudioPCMBuffer] = [] // the same moment as raw buffers, for Apple's stream
  private var coolDown: DispatchWorkItem?

  static func requestAccess(_ done: @escaping (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: done(true)
    case .notDetermined: AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    default: done(false)
    }
  }

  /// Starts a take at once; the mic opens behind, `done` comes on the main thread when it has.
  func start(done: @escaping (Error?) -> Void) {
    coolDown?.cancel()
    lock.lock()
    samples = ring
    peakLevel = 0
    peakSample = 0
    lostDuringTake = false
    restartsInTake = 0
    reopens = 0
    let pre = rawRing
    recording = true
    lock.unlock()
    for b in pre { onBuffer?(b) }
    opening += 1
    let mine = opening, t0 = Date()
    q.async { [weak self] in
      guard let self else { return }
      var failed: Error?
      if !self.running { do { try self.open() } catch { failed = error } }
      let ms = Int(Date().timeIntervalSince(t0) * 1000)
      DispatchQueue.main.async {
        if self.opening == mine { self.opening += 1 }
        if failed == nil { Log.write("mic started: \(self.deviceName)\(ms > 400 ? ", slow to open, \(ms) ms" : "")") }
        done(failed)
      }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
      guard let self, self.opening == mine else { return }
      Log.write("mic: macOS audio has not answered for 3 s")
      self.onSlow?()
      DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
        guard let self, self.opening == mine else { return }
        Log.write("mic: macOS audio stuck for 8 s, starting Brain again")
        self.onStuck?()
      }
    }
    watchForSilence()
  }

  private var reopens = 0
  private func watchForSilence(last: Int = -1, quietFor: Double = 0) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self else { return }
      self.lock.lock(); let n = self.buffersSinceOpen; let rec = self.recording; self.lock.unlock()
      guard rec else { return }
      let still = n == last ? quietFor + 0.3 : 0
      if still >= 0.6, self.reopens < 3 {
        self.reopens += 1
        let def = self.reopens >= 2, n = self.reopens
        self.q.async {
          guard self.settle == nil else { return }
          self.useDefault = def
          Log.write("mic: nothing from \(self.deviceName) for 0.6 s, a fresh engine\(def ? " on macOS's default mic" : "") (\(n))")
          self.close()
          do { try self.open() } catch { Log.write("mic: reopen failed: \(error)") }
        }
        self.watchForSilence()
        return
      }
      self.watchForSilence(last: n, quietFor: still)
    }
  }
  /// set by the watch: open on whatever macOS has as the input, not our pick
  private var useDefault = false

  private func open() throws {
    engine = AVAudioEngine()
    lock.lock(); buffersSinceOpen = 0; lock.unlock()
    let input = engine.inputNode
    if !useDefault, let pick = Mic.bestInput(), let au = input.audioUnit {
      var id = pick.id
      AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
      deviceName = pick.name
    } else {
      deviceName = AVCaptureDevice.default(for: .audio)?.localizedName ?? ""
    }
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw NSError(domain: "Mic", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(deviceName) gave no audio format"])
    }
    converter = Mic.converter(from: format, to: target)
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      self?.take(buffer)
    }
    lock.lock(); ring.removeAll(); rawRing.removeAll(); lock.unlock()
    engine.prepare()
    try engine.start()
    running = true
    configToken = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
      self?.q.async { self?.devicesChanged() }
    }
  }

  private func devicesChanged() {
    guard recording else {
      Log.write("mic: the audio devices changed, closing")
      close()
      // kept warm: open again once things settle, or warm silently stops being warm
      if alwaysWarm {
        q.asyncAfter(deadline: .now() + 1) { [weak self] in
          guard let self, self.alwaysWarm, !self.running else { return }
          self.useDefault = false
          do { try self.open(); Log.write("mic: warm again on \(self.deviceName)") } catch { Log.write("mic: warm reopen failed: \(error)") }
        }
      }
      return
    }
    lock.lock(); let before = buffersSinceOpen; lock.unlock()
    // stopped already: start the same engine again now, every 0.1 s of waiting is a lost word
    if !engine.isRunning, restartsInTake < 3, restartSame() {
      restartsInTake += 1
      Log.write("mic: the audio devices changed in a take, started again at once (\(restartsInTake))")
      return
    }
    settle?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.settle = nil
      guard let self, self.recording else { return }
      self.lock.lock(); let now = self.buffersSinceOpen; self.lock.unlock()
      if self.engine.isRunning && now > before {
        Log.write("mic: the audio devices changed in a take, sound still coming, kept"); return
      }
      self.restartsInTake += 1
      guard self.restartsInTake <= 3 else {
        Log.write("mic: the audio devices keep changing, giving up this take"); self.lostDuringTake = true; return
      }
      if self.restartSame() {
        Log.write("mic: the audio devices changed in a take, same engine started again (\(self.restartsInTake))")
      } else {
        Log.write("mic: restart failed, a fresh engine (\(self.restartsInTake))")
        self.close()
        do { try self.open() } catch { Log.write("mic: reopen failed: \(error)"); self.lostDuringTake = true }
      }
    }
    settle = work
    q.asyncAfter(deadline: .now() + 0.25, execute: work)
  }

  /// the same engine, its tap put back for the format the device has now
  private func restartSame() -> Bool {
    let input = engine.inputNode, format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { return false }
    converter = Mic.converter(from: format, to: target)
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] b, _ in self?.take(b) }
    engine.prepare()
    do { try engine.start(); return true } catch { return false }
  }

  private func close() {
    settle?.cancel(); settle = nil
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    running = false
    // the block observer is removed by its token (removing `self` never removed it, so they piled up)
    if let t = configToken { NotificationCenter.default.removeObserver(t); configToken = nil }
  }

  /// Opens the mic now (Keep mic warm switched on), so even the first take has its pre-roll.
  func warmUp() { q.async { if !self.running { try? self.open() } } }

  /// Stops and hands back everything heard, at 16 kHz.
  func stop() -> [Float] {
    useDefault = false
    lock.lock()
    recording = false
    let out = samples
    lock.unlock()
    coolDown?.cancel()
    if !alwaysWarm {
      let work = DispatchWorkItem { [weak self] in self?.q.async { self?.close() } }
      coolDown = work
      DispatchQueue.main.asyncAfter(deadline: .now() + warmSeconds, execute: work)
    }
    return out
  }

  /// Keep mic warm switched off: close now if no take is running.
  func coolNow() { q.async { if !self.recording && self.running { self.close() } } }

  static func mono(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
    let chs = Int(b.format.channelCount)
    guard chs > 1, b.format.commonFormat == .pcmFormatFloat32, let data = b.floatChannelData,
          let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: b.format.sampleRate, channels: 1, interleaved: false),
          let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: b.frameLength), let o = out.floatChannelData?[0] else { return b }
    out.frameLength = b.frameLength
    let n = Int(b.frameLength)
    for i in 0..<n {
      var s: Float = 0
      for c in 0..<chs { s += b.format.isInterleaved ? data[0][i * chs + c] : data[c][i] }
      o[i] = max(-1, min(1, s))
    }
    return out
  }

  /// the converter to 16 kHz mono, from the input's own format, or from its added-together mono
  static func converter(from f: AVAudioFormat, to target: AVAudioFormat) -> AVAudioConverter? {
    let src = f.channelCount > 1 && f.commonFormat == .pcmFormatFloat32
      ? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: f.sampleRate, channels: 1, interleaved: false) ?? f : f
    let c = AVAudioConverter(from: src, to: target)
    c?.downmix = true
    return c
  }

  struct Device { let id: AudioDeviceID; let name: String; let rank: Int }

  /// Mics that sent silence twice in a row, skipped for ten minutes.
  static var avoid: [String: Date] = [:]

  /// close now, so the next take opens on the best mic again
  func reset() { q.async { if self.running { self.close() } } }

  static func bestInput() -> Device? { inputs().first }

  /// Every mic, best first: a USB mic, the Mac's own, then the rest, Bluetooth last (phone quality).
  /// `defaults write local.secondbrain.app preferredMic "Name"` puts one mic above all of them.
  static func inputs() -> [Device] {
    var size: UInt32 = 0
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    var all: [Device] = []
    avoid = avoid.filter { Date().timeIntervalSince($0.value) < 600 }
    for id in ids where inputChannels(id) > 0 {
      let name = string(id, kAudioObjectPropertyName) ?? ""
      if avoid[name] != nil { continue }
      let transport = uint(id, kAudioDevicePropertyTransportType)
      let rank: Int
      if let p = UserDefaults.standard.string(forKey: "preferredMic"), !p.isEmpty, name.localizedCaseInsensitiveContains(p) { rank = 0 }
      else if transport == kAudioDeviceTransportTypeUSB { rank = 1 }
      else if transport == kAudioDeviceTransportTypeBuiltIn { rank = 2 }
      else if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE { rank = 9 }
      else { rank = 5 }
      all.append(Device(id: id, name: name, rank: rank))
    }
    return all.sorted { $0.rank < $1.rank }
  }

  private static func inputChannels(_ id: AudioDeviceID) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
  }

  private static func string(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> String? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String
  }

  private static func uint(_ id: AudioDeviceID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
    return v
  }

  private func take(_ raw: AVAudioPCMBuffer) {
    lock.lock(); let rec = recording; buffersSinceOpen += 1; lock.unlock()
    if rec { onBuffer?(raw) }
    let buffer = Mic.mono(raw)
    guard let converter else { return }
    let ratio = target.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
    var fed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if fed { status.pointee = .noDataNow; return nil }
      fed = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, let ch = out.floatChannelData else { return }
    let chunk = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    var sum: Float = 0
    var top: Float = 0
    for s in chunk { sum += s * s; top = max(top, abs(s)) }
    let rms = chunk.isEmpty ? 0 : (sum / Float(chunk.count)).squareRoot()
    lock.lock()
    if recording {
      samples.append(contentsOf: chunk)
      peakLevel = max(peakLevel, rms)
      peakSample = max(peakSample, top)
    }
    ring.append(contentsOf: chunk)
    let keep = Int(prerollSeconds * 16_000)
    if ring.count > keep { ring.removeFirst(ring.count - keep) }
    rawRing.append(buffer)
    var frames = rawRing.reduce(0) { $0 + Double($1.frameLength) / $1.format.sampleRate }
    while frames > prerollSeconds, rawRing.count > 1 { frames -= Double(rawRing.removeFirst().frameLength) / buffer.format.sampleRate }
    lock.unlock()
    guard rec else { return }
    let level = max(0, min(1, (20 * log10(max(rms, 1e-5)) + 60) / 50))
    DispatchQueue.main.async { self.onLevel?(level) }
  }
}
