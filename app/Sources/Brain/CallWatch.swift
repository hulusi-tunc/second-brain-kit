import AppKit
import CoreAudio
import Foundation

@MainActor
final class CallWatch {
  struct Call: Equatable {
    let bundle: String
    let app: String
    /// set when Apple's helper holds the mic for it (the iPhone as the mic)
    var via = ""
  }

  /// bundle id prefixes; helpers like com.google.Chrome.helper match their app
  static let callApps: [(String, String)] = [
    ("com.google.Chrome", "Google Meet"), ("company.thebrowser.dia", "Google Meet"), ("com.brave.Browser", "Google Meet"),
    ("company.thebrowser.Browser", "Google Meet"), ("com.apple.Safari", "Google Meet"),
    ("com.tinyspeck.slackmacgap", "Slack huddle"), ("us.zoom.xos", "Zoom"), ("com.microsoft.teams2", "Teams"),
    ("com.apple.FaceTime", "FaceTime"), ("net.whatsapp.WhatsApp", "WhatsApp call"), ("ru.keepcoder.Telegram", "Telegram call"),
    ("com.hnc.Discord", "Discord"),
  ]

  var onStart: ((Call) -> Void)?
  var onEnd: (() -> Void)?
  private var timer: Timer?
  private var seenSince: Date?
  private var lastSeen: Date?
  private(set) var current: Call?

  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  private var ignore: String?
  private var lastLog = Date.distantPast

  private func tick() {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let holding = CallWatch.callsHoldingMic()
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(holding, at: Date()) } }
    }
  }

  private func handle(_ holding: [Call], at now: Date) {
    if let ig = ignore, !holding.contains(where: { $0.bundle == ig }) { ignore = nil }
    if let cur = current {
      if holding.contains(where: { $0.bundle == cur.bundle }) {
        lastSeen = now
        if now.timeIntervalSince(lastLog) > 300 { lastLog = now; Log.write("call: \(cur.app) still holds the mic") }
      } else if let last = lastSeen, now.timeIntervalSince(last) >= 20 {
        Log.write("call: \(cur.app) let go of the mic 20 s ago, ending; others holding: \(holding.map(\.bundle))")
        current = nil
        onEnd?()
      }
      return
    }
    if let call = holding.first(where: { $0.bundle != ignore }) {
      if seenSince == nil { seenSince = now }
      if now.timeIntervalSince(seenSince!) >= 4 {
        current = call
        lastSeen = now
        Log.write("call: \(call.app) (\(call.bundle))\(call.via.isEmpty ? "" : " through \(call.via)") took the mic, recording")
        onStart?(call)
      }
    } else {
      seenSince = nil
    }
  }

  func stopByHand() {
    guard let cur = current else { return }
    Log.write("call: stopped by hand, \(cur.app)")
    ignore = cur.bundle
    current = nil
    seenSince = nil
    onEnd?()
  }

  static let relays = ["com.apple.cmio.ContinuityCaptureAgent", "com.apple.avconferenced"]

  private struct Proc { let pid: pid_t; let bundle: String; let input: Bool; let output: Bool }
  private static func procs() -> [Proc] {
    processObjects().map { id in
      var pidValue: pid_t = 0
      var size = UInt32(MemoryLayout<pid_t>.size)
      var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      AudioObjectGetPropertyData(id, &a, 0, nil, &size, &pidValue)
      return Proc(pid: pidValue, bundle: bundleID(id), input: uint(id, kAudioProcessPropertyIsRunningInput) != 0,
                  output: uint(id, kAudioProcessPropertyIsRunningOutput) != 0)
    }
  }

  /// Every call app in a call right now: taking the mic itself, or playing sound while one of
  /// Apple's helpers takes the mic for it.
  static func callsHoldingMic() -> [Call] {
    var out: [Call] = []
    let me = ProcessInfo.processInfo.processIdentifier
    let all = procs().filter { $0.pid != me }
    func add(_ bundle: String, via: String) {
      if let hit = callApps.first(where: { bundle.hasPrefix($0.0) }), !out.contains(where: { $0.bundle == hit.0 }) {
        out.append(Call(bundle: hit.0, app: hit.1, via: via))
      }
    }
    for p in all where p.input { add(p.bundle, via: "") }
    if let relay = all.first(where: { p in p.input && relays.contains(where: { p.bundle.hasPrefix($0) }) }) {
      let via = relay.bundle.contains("Continuity") ? "the iPhone's mic" : "FaceTime's audio"
      for p in all where p.output { add(p.bundle, via: via) }
    }
    return out
  }

  static func anyHoldingMic() -> [String] {
    var out: [String] = []
    let me = ProcessInfo.processInfo.processIdentifier
    for id in processObjects() {
      guard uint(id, kAudioProcessPropertyIsRunningInput) != 0 else { continue }
      var pidValue: pid_t = 0
      var size = UInt32(MemoryLayout<pid_t>.size)
      var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      AudioObjectGetPropertyData(id, &a, 0, nil, &size, &pidValue)
      let bundle = bundleID(id)
      if pidValue == me || bundle == Config.bundleID { continue }
      if !out.contains(bundle) { out.append(bundle.isEmpty ? "pid \(pidValue)" : bundle) }
    }
    return out
  }

  /// Every process CoreAudio knows: pid, bundle id, input running, output running.
  static func allAudioProcesses() -> [String] {
    processObjects().map { id in
      var pidValue: pid_t = 0
      var size = UInt32(MemoryLayout<pid_t>.size)
      var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      AudioObjectGetPropertyData(id, &a, 0, nil, &size, &pidValue)
      return "\(pidValue)\t\(bundleID(id))\tin \(uint(id, kAudioProcessPropertyIsRunningInput))\tout \(uint(id, kAudioProcessPropertyIsRunningOutput))"
    }
  }

  /// The first call app taking microphone input right now, if any.
  static func callHoldingMic() -> Call? { callsHoldingMic().first }


  nonisolated static func processObjects() -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
  }

  private static func uint(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0
    var s = UInt32(MemoryLayout<UInt32>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v)
    return v
  }

  private static func bundleID(_ id: AudioObjectID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &s, &cf) == noErr else { return "" }
    return (cf?.takeRetainedValue() as String?) ?? ""
  }
}
