import AppKit

/// The brain from anywhere on the Mac:
///
///   brain:// links, for a Shortcut, Raycast, a Spotlight shortcut or a link in a note
///     brain://ask?q=what do I owe Sam       asks, the answer opens in the notch
///     brain://save?text=call Sam back       a note into raw/, like `brain "..."` in a terminal
///     brain://page?path=wiki/sam.md         a page from the repo, in your .md app
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

  func handle(_ url: URL) {
    guard url.scheme?.lowercased() == "brain" else { return }
    let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    func item(_ names: String...) -> String? { q.first { names.contains($0.name) }?.value?.trimmingCharacters(in: .whitespacesAndNewlines) }
    let host = (url.host ?? "").lowercased()
    Log.write("everywhere: \(host)")
    switch host {
    case "ask":
      if let text = item("q", "question", "text"), !text.isEmpty { onAsk?(text) } else { onOpen?() }
    case "page":
      if let path = item("path"), !path.isEmpty, !path.contains("..") { Brain.open(path) }
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
