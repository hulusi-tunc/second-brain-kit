import Foundation

/// Every dictation, kept in the brain's private layer (never in git): one JSON line each in
/// private/voice/history.jsonl, and the audio as a WAV for 7 days, so a bad transcript can be run
/// again.
enum History {
  static var root: URL { Config.repo.appendingPathComponent("private/voice") }
  private static let keepDays = 7

  struct Entry: Encodable {
    let at: String
    let app: String
    let bundle: String
    let seconds: Double
    let latencyMs: Int
    let language: String
    let raw: String
    let text: String?
    let mic: String
    let peak: Float
  }

  static func add(_ e: Entry, samples: [Float]) {
    DispatchQueue.global(qos: .utility).async {
      let fm = FileManager.default
      try? fm.createDirectory(at: root.appendingPathComponent("audio"), withIntermediateDirectories: true)
      let enc = JSONEncoder()
      enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      guard var line = try? enc.encode(e) else { return }
      line.append(0x0A)
      let file = root.appendingPathComponent("history.jsonl")
      if let h = try? FileHandle(forWritingTo: file) {
        h.seekToEndOfFile(); h.write(line); try? h.close()
      } else {
        try? line.write(to: file)
      }
      let stamp = e.at.replacingOccurrences(of: ":", with: "")
      try? wav(samples).write(to: root.appendingPathComponent("audio/\(stamp).wav"))
    }
  }

  /// Audio older than 7 days goes, dictations and calls alike; the text stays.
  static func sweep() {
    DispatchQueue.global(qos: .background).async {
      let cutoff = Date().addingTimeInterval(-Double(keepDays) * 86_400)
      let fm = FileManager.default
      var files = (try? fm.contentsOfDirectory(at: root.appendingPathComponent("audio"), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
      let meetings = ["meetings"].flatMap { (try? fm.contentsOfDirectory(at: root.appendingPathComponent($0), includingPropertiesForKeys: nil)) ?? [] }
      for m in meetings { files += (try? fm.contentsOfDirectory(at: m, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] }
      for f in files where ["wav", "caf"].contains(f.pathExtension) {
        let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        if d < cutoff { try? FileManager.default.removeItem(at: f) }
      }
    }
  }

  /// 16 kHz mono 16-bit PCM
  static func wav(_ s: [Float]) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    let bytes = UInt32(s.count * 2)
    d.append("RIFF".data(using: .ascii)!); u32(36 + bytes); d.append("WAVE".data(using: .ascii)!)
    d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
    d.append("data".data(using: .ascii)!); u32(bytes)
    for v in s { u16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32_767))) }
    return d
  }
}
