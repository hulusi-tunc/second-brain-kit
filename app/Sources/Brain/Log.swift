import Foundation
/// A small trace (clicks on the island, pastes, calls, the mic) in ~/Library/Logs/Brain.log, one file a day, kept two weeks.

enum Log {
  static let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
  static let url = dir.appendingPathComponent("Brain.log")
  private static let keepDays = 14
  private static let lock = NSLock()

  static func write(_ s: String) {
    lock.lock(); defer { lock.unlock() }
    let now = Date()
    rotate(now)
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let line = "\(f.string(from: now)) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? Data(line.utf8).write(to: url) }
  }

  /// Yesterday's lines move to their own file the first time something is written today.
  private static func rotate(_ now: Date) {
    let fm = FileManager.default
    guard let mod = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
          !Calendar.current.isDate(mod, inSameDayAs: now) else { return }
    let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd"
    let old = dir.appendingPathComponent("Brain-\(d.string(from: mod)).log")
    if let data = try? Data(contentsOf: url) {
      if let h = try? FileHandle(forWritingTo: old) { h.seekToEndOfFile(); h.write(data); try? h.close() }
      else { try? data.write(to: old) }
      try? fm.removeItem(at: url)
    }
    let cut = Calendar.current.date(byAdding: .day, value: -keepDays, to: now) ?? now
    for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasPrefix("Brain-") && name.hasSuffix(".log") {
      let day = String(name.dropFirst(6).dropLast(4))
      if let date = d.date(from: day), date < cut { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
    }
  }
}
