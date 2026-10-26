import AppKit
import Combine

/// The brain's answer, parsed from the lines bin/brain-ask.sh prints (KIND, HEAD, NOTE, ROW, NONE).
struct Answer: Equatable {
  var kind = "list", head = "", note = "", none = ""
  var rows: [Card.Row] = []

  init(_ out: String) {
    let all = out.split(separator: "\n").map(String.init)
    func value(_ key: String) -> String? {
      all.first { $0.hasPrefix(key + ":") }.map { String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) }
    }
    kind = value("KIND")?.lowercased() ?? (all.contains { $0.hasPrefix("ROW:") } ? "list" : "none")
    head = value("HEAD") ?? ""
    note = value("NOTE") ?? ""
    none = value("NONE") ?? ""
    rows = all.filter { $0.hasPrefix("ROW:") }.map { l in
      let f = Brain.fields(l) + Array(repeating: "", count: 5)
      return Card.Row(text: f[0], when: f[1], state: f[2].lowercased(), source: f[3], file: f[4].isEmpty ? "commitments.md" : f[4])
    }
    if head.isEmpty && rows.isEmpty && kind != "none" { kind = "error" }
  }
}

/// One question asked in the notch, kept in private/brain/history.jsonl.
struct HistoryItem: Codable, Identifiable, Equatable {
  var id = UUID()
  var q: String
  var at: Date
  var head: String
  var raw: String
  var seconds: Int
}

/// Every question and its answer's first line, appended as JSON, newest last.
final class AnswerHistory {
  static var file: URL { History.root.deletingLastPathComponent().appendingPathComponent("brain/history.jsonl") }

  func remember(_ item: HistoryItem) {
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    guard var line = try? enc.encode(item) else { return }
    line.append(0x0A)
    let f = Self.file
    try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(line); try? h.close() }
    else { try? line.write(to: f) }
  }
}

/// Settings in the notch: click a shortcut, press the modifier key you want.
final class KeyRecorder: ObservableObject {
  @Published var listening: Shortcut?
  @Published var note = ""
  /// after a swap: what happened to the other shortcut, shown under the list until the next pick
  @Published var swapped = ""
  private var monitors: [Any] = []
  private var timeout: DispatchWorkItem?

  func start(_ s: Shortcut) {
    stop()
    listening = s; note = ""; swapped = ""; Keys.paused = true
    let flags: (NSEvent) -> Void = { [weak self] e in self?.flags(e) }
    let keys: (NSEvent) -> Void = { [weak self] e in
      guard let self else { return }
      if e.keyCode == 53 { self.stop(); return }
      self.note = "Use ⌥ ⌘ ⌃ ⇧ or fn, a key on its own"
    }
    if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
    if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
    if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
    if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keys($0); return nil }) { monitors.append(m) }
    let t = DispatchWorkItem { [weak self] in self?.stop() }
    timeout = t
    DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: t)
  }

  private func flags(_ e: NSEvent) {
    guard let s = listening, let k = ModKey.all.first(where: { $0.code == Int(e.keyCode) }), k.isDown(e) else { return }
    if s.code == k.code || s.allowed(k) {
      set(s, k.code); stop()
    } else {
      let old = s.code
      let owners = Shortcut.allCases.filter { $0 != s && $0.code == k.code }
      let before = Dictionary(uniqueKeysWithValues: Shortcut.allCases.map { ($0, $0.code) })
      owners.forEach { $0.code = -1 }
      var ok = s.allowed(k)
      if ok {
        s.code = k.code
        for o in owners {
          if let ok2 = ModKey.all.first(where: { $0.code == old }), o.allowed(ok2) { o.code = old }
          else if !o.canBeNone { ok = false }
        }
      }
      guard ok else {
        before.forEach { $0.key.code = $0.value }
        note = "\(k.short) is \(owners.first?.title ?? "taken"), pick another"
        return
      }
      set(s, k.code)
      for o in owners { Log.write("shortcut: \(o.rawValue) is now \(o.label) (swapped)") }
      swapped = owners.map { $0.code == -1 ? "\($0.title) is off now" : "\($0.title) moved to \($0.label)" }.joined(separator: ", ")
      stop()
    }
  }

  func set(_ s: Shortcut, _ code: Int) {
    s.code = code
    Log.write("shortcut: \(s.rawValue) is now \(s.label)")
    NotificationCenter.default.post(name: .shortcutsChanged, object: nil)
    objectWillChange.send()
  }

  func stop() {
    timeout?.cancel(); timeout = nil
    monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
    listening = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      if self?.listening == nil { Keys.paused = false }
    }
  }
}

extension Notification.Name { static let shortcutsChanged = Notification.Name("brain.shortcutsChanged") }
