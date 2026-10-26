import AppKit

/// The brain from anywhere on the Mac:
///
///   brain:// links, for a Shortcut, Raycast, a Spotlight shortcut or a link in a note
///     brain://ask?q=what do I owe Sam       asks, the answer opens in the notch
///     brain://save?text=call Sam back       a note into raw/, like `brain "..."` in a terminal
///     brain://home                          Brain Home, the dial, in its own window
///     brain://page?path=wiki/sam.md         a page from the repo, read in Brain Home
///     brain://done?id=c1234567              a ledger row done, as `brain done c1234567` in a terminal
///     brain://ledger?v=keep&ids=c1,c2       Brain Home's review: done, keep, drop, or due with a date
///     brain://settings                      settings, in the notch
///
///   Services, in every app's right-click menu and the app menu (System Settings can give them keys)
///     Ask Brain       the selected text is the question
///     Save to Brain   the selected text becomes a note in raw/
@MainActor
final class Everywhere: NSObject {
  var onAsk: ((String) -> Void)?
  var onOpen: (() -> Void)?
  /// a short word in the notch after something was saved
  var onSaved: (() -> Void)?
  var onSettings: (() -> Void)?
  var onHome: (() -> Void)?
  var onPage: ((String) -> Void)?
  var onDone: (() -> Void)?

  func handle(_ url: URL) {
    guard url.scheme?.lowercased() == "brain" else { return }
    let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func item(_ names: String...) -> String? { q.first { names.contains($0.name) }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) }
    let host = (url.host ?? "").lowercased()
    Log.write("everywhere: \(host)")
    switch host {
    case "ask":
      if let text = item("q", "question", "text"), !text.isEmpty { onAsk?(text) } else { onOpen?() }
    case "home", "map":
      onHome?()
    case "page":
      if let path = item("path"), !path.isEmpty, !path.contains("..") { onPage?(path) }
    case "done":
      guard let id = item("id"), id.range(of: "^c[0-9a-f]{7}$", options: .regularExpression) != nil else { return }
      Everywhere.ledger("done", [id]); onDone?()
    case "ledger":
      let ids = (item("ids") ?? "").split(separator: ",").map(String.init)
        .filter { $0.range(of: "^c[0-9a-f]{7}$", options: .regularExpression) != nil }
      guard let v = item("v"), ["done", "keep", "drop", "due"].contains(v), !ids.isEmpty else { return }
      // "due" moves rows to a new date (the sweep's "still on"); the date must be a plain day
      let date = item("date").flatMap { $0.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil ? $0 : nil }
      if v == "due" && date == nil { return }
      Everywhere.ledger(v, ids, date: date)
      if v == "done" { onDone?() }
    case "save", "note":
      if let text = item("text", "q", "note"), !text.isEmpty { Everywhere.save(text, from: "a link"); onSaved?() }
    case "settings":
      onSettings?()
    default:
      onOpen?()
    }
  }

  // MARK: Services (the right-click menu in any app)

  @objc func askBrain(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
    guard let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
    Log.write("everywhere: Ask Brain from the Services menu, \(text.count) chars")
    onAsk?(String(text.prefix(2000)))
  }

  @objc func saveToBrain(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
    guard let text = pboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
    let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "an app"
    Everywhere.save(text, from: app)
    Log.write("everywhere: Save to Brain from \(app), \(text.count) chars")
    onSaved?()
  }

  /// Ledger rows changed from Brain Home: written to data/inbox.jsonl, then applied to commitments.md
  /// by tools/apply_inbox.py once things go quiet for a moment, so ten quick clicks are one commit.
  private static var flush: DispatchWorkItem?
  private static var pending = 0
  static func ledger(_ v: String, _ ids: [String], date: String? = nil) {
    let repo = Config.repo
    let at = ISO8601DateFormatter().string(from: Date())
    let extra = date.map { ",\"date\":\"\($0)\"" } ?? ""
    let lines = ids.map { "{\"t\":\"\(v)\",\"id\":\"\($0)\",\"at\":\"\(at)\",\"via\":\"Brain Home\"\(extra)}\n" }.joined()
    let inbox = repo.appendingPathComponent("data/inbox.jsonl")
    try? FileManager.default.createDirectory(at: inbox.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: inbox) { h.seekToEndOfFile(); h.write(Data(lines.utf8)); try? h.close() }
    else { try? lines.write(to: inbox, atomically: true, encoding: .utf8) }
    pending += ids.count
    flush?.cancel()
    let work = DispatchWorkItem {
      let n = pending; pending = 0
      let p = Process()
      p.executableURL = URL(fileURLWithPath: "/bin/bash")
      p.currentDirectoryURL = repo
      p.arguments = ["-c", "python3 tools/apply_inbox.py && git add commitments.md data/inbox.jsonl && git commit -q -m 'ledger: \(n) row\(n == 1 ? "" : "s") from Brain Home' -- commitments.md data/inbox.jsonl"]
      try? p.run()
    }
    flush = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
  }

  /// A note into raw/<today>.md under the time, the same file and shape as `brain "..."` in a
  /// terminal, so the nightly translate files it with the rest.
  static func save(_ text: String, from: String) {
    let raw = Config.repo.appendingPathComponent("raw")
    let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd"
    let t = DateFormatter(); t.dateFormat = "HH:mm"
    let file = raw.appendingPathComponent("\(d.string(from: Date())).md")
    var out = ""
    if !FileManager.default.fileExists(atPath: file.path) { out += "# \(d.string(from: Date()))\n\n" }
    out += "## \(t.string(from: Date())) (from \(from))\n\n\(text)\n\n"
    if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(Data(out.utf8)); try? h.close() }
    else { try? out.write(to: file, atomically: true, encoding: .utf8) }
  }
}
