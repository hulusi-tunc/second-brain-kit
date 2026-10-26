import Foundation

/// A call's two tracks become one note in the brain's raw/ (title, date and length, participants,
/// source, then the transcript), so /translate and the ledger take it like any meeting note. The
/// summary and next steps are added afterwards by bin/brain-call-notes.sh.
enum Notes {
  static var raw: URL { Config.repo.appendingPathComponent("raw") }

  struct Track {
    let who: String
    let offset: Double          // seconds this track started after the meeting started
    let segments: [Whisper.Segment]
  }

  static func clock(_ s: Double) -> String { String(format: "%02d:%02d", Int(s) / 60, Int(s) % 60) }

  /// One transcript, both voices in time order, each line "[mm:ss] Who: text".
  static func transcript(_ tracks: [Track]) -> String {
    var lines: [(Double, String)] = []
    for t in tracks {
      for s in t.segments { lines.append((t.offset + s.start, "[\(clock(t.offset + s.start))] \(t.who): \(s.text)")) }
    }
    return lines.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n")
  }

  static func slug(_ s: String) -> String {
    let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
    let parts = folded.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    return String(parts.joined(separator: "-").prefix(40))
  }

  /// Writes raw/meeting-YYYY-MM-DD-<slug>.md and returns its path.
  @discardableResult
  static func write(title: String, start: Date, minutes: Int, participants: [String], source: String, transcript: String) -> URL? {
    let day = DateFormatter(); day.dateFormat = "yyyy-MM-dd"
    let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH:mm"
    let body = [
      "# \(title)", "",
      "date: \(stamp.string(from: start)), \(minutes) min",
      "participants: \(participants.isEmpty ? "not recorded" : participants.joined(separator: ", "))",
      "source: \(source)", "",
      "## Transcript", "", transcript, "",
    ].joined(separator: "\n")
    var url = raw.appendingPathComponent("meeting-\(day.string(from: start))-\(slug(title)).md")
    var i = 2
    while FileManager.default.fileExists(atPath: url.path) {
      url = raw.appendingPathComponent("meeting-\(day.string(from: start))-\(slug(title))-\(i).md"); i += 1
    }
    do { try body.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
  }
}
