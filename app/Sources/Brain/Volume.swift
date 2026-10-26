import CoreAudio
import AudioToolbox
import Foundation

enum Volume {
  private static let lock = NSLock()
  private static var saved: Float32?
  private static var device = AudioObjectID(kAudioObjectUnknown)
  private static var gen = 0
  private static let key = "volumeBeforeTalk"

  static func quiet() { go(down: true) }
  static func back() { go(down: false) }

  static func recover() {
    guard let v = UserDefaults.standard.object(forKey: key) as? Float else { return }
    let dev = defaultOutput()
    if let now = get(dev), now < Float32(v) * 0.5 { set(dev, Float32(v)) }
    UserDefaults.standard.removeObject(forKey: key)
  }

  private static func go(down: Bool) {
    lock.lock()
    gen += 1
    let g = gen
    if down && saved == nil {
      device = defaultOutput()
      if let v = get(device), v > 0.01 { saved = v; UserDefaults.standard.set(Float(v), forKey: key) }
    }
    let dev = device, target = down ? saved.map { $0 * 0.15 } : saved
    lock.unlock()
    guard let target else { return }
    DispatchQueue.global(qos: .userInteractive).async {
      let from = get(dev) ?? (down ? target : 0)
      let ms = down ? 120.0 : 900.0
      let steps = max(1, Int(ms / 15))
      for i in 1...steps {
        lock.lock(); let current = gen; lock.unlock()
        if current != g { return }   // a newer take or release took over
        let t = Double(i) / Double(steps)
        // down: straight and quick; up: slow at first, so the music swells in rather than jumps
        let e = down ? t : t * t
        set(dev, from + (target - from) * Float32(e))
        usleep(15_000)
      }
      if !down {
        lock.lock()
        if gen == g { saved = nil; UserDefaults.standard.removeObject(forKey: key) }
        lock.unlock()
      }
    }
  }

  static func defaultOutput() -> AudioObjectID {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var dev = AudioObjectID(kAudioObjectUnknown)
    var s = UInt32(MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &dev)
    return dev
  }

  private static var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                          mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

  static func get(_ dev: AudioObjectID) -> Float32? {
    guard dev != kAudioObjectUnknown else { return nil }
    var a = address
    var v: Float32 = 0
    var s = UInt32(MemoryLayout<Float32>.size)
    return AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &v) == noErr ? v : nil
  }

  static func set(_ dev: AudioObjectID, _ v: Float32) {
    var a = address
    var x = max(0, min(1, v))
    AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &x)
  }
}
