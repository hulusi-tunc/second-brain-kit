import Foundation

/// Every state of the brain in the notch, as one card that changes in place. The question stays
/// where it is from the moment you let go; the brain says what it is reading while it reads; the
/// answer takes the shape the brain gives it: a fact, a list, a summary, none.
enum BrainCards {
  static let width: CGFloat = 500

  /// Keys down. With text selected it says so, so you know a command is coming, not a question.
  static func listening(selection: String?) -> Card {
    if let sel = selection {
      let words = sel.split(whereSeparator: { $0.isWhitespace }).count
      return Card(mark: .live, left: "Command", right: words == 1 ? "1 word" : "\(words) words",
                  lines: [.quote(String(sel.prefix(160))), .listening("Say what to do with it")],
                  hint: "Let go when you are done", width: width)
    }
    return Card(mark: .live, left: "Ask the brain", right: "",
                lines: [.listening("Listening")],
                hint: "People, projects, what you owe, what was said", width: width)
  }

  /// Keys up, the words being written down (about half a second).
  static func writing(selection: Bool) -> Card {
    Card(mark: .wave, left: selection ? "Command" : "Ask the brain", right: "",
         lines: [.listening("Writing it down")], width: width)
  }

  static func thinking(_ q: String, steps: [String], since: Date) -> Card {
    let shown = Array(steps.suffix(3))
    let lines: [Card.Line] = [.question(q)] + shown.enumerated().map { i, s in .step(s, i == shown.count - 1) }
    // one loading mark only, on the step being read
    return Card(mark: .none, left: "Ask the brain", right: "", lines: lines, hint: "esc cancels", width: width, since: since)
  }

  /// The brain's lines (KIND, HEAD, NOTE, ROW, NONE) as a card of the right shape.
  static func answer(_ q: String, out: String, seconds: Int) -> Card {
    let all = out.split(separator: "\n").map(String.init)
    func value(_ key: String) -> String? {
      all.first { $0.hasPrefix(key + ":") }.map { String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) }
    }
    let kind = value("KIND")?.lowercased() ?? (all.contains { $0.hasPrefix("ROW:") } ? "list" : "none")
    let head = value("HEAD") ?? ""
    let rows: [Card.Row] = all.filter { $0.hasPrefix("ROW:") }.map { l in
      let f = Brain.fields(l) + Array(repeating: "", count: 5)
      return Card.Row(text: f[0], when: f[1], state: f[2].lowercased(), source: f[3], file: f[4].isEmpty ? "commitments.md" : f[4])
    }
    let close = [Card.Button(id: "close", label: "Close"), Card.Button(id: "brain", label: "Open in Brain", primary: true)]
    switch kind {
    case "none":
      return Card(left: "Ask the brain", right: "nothing found",
                  lines: [.heard(q), .headline("Not in the brain"), .note(value("NONE") ?? "Nothing matched.")],
                  buttons: close, hint: "Try again with a name or a project", width: width)
    case "error":
      return Card(left: "Ask the brain", right: "",
                  lines: [.heard(q), .headline("The brain did not answer"), .note(head.isEmpty ? "Try again in a moment." : head)],
                  buttons: close, width: width)
    default:
      guard !head.isEmpty || !rows.isEmpty else {
        return Card(left: "Ask the brain", right: "",
                    lines: [.heard(q), .headline("The brain did not answer"), .note("Nothing came back. Try again in a moment.")],
                    buttons: close, width: width)
      }
      var lines: [Card.Line] = [.heard(q)]
      if !head.isEmpty { lines.append(kind == "fact" ? .headline(head) : .question(head)) }
      if kind == "summary", let note = value("NOTE"), !note.isEmpty { lines.append(.note(note)) }
      if !rows.isEmpty {
        if kind != "list" { lines.append(.sep) }
        lines += rows.prefix(5).map { .status($0) }
      }
      let more = rows.count > 5 ? "\(rows.count - 5) more in the ledger. " : ""
      return Card(mark: .pink, left: "Ask the brain", right: "in \(seconds) s", lines: lines, buttons: close,
                  hint: more + (rows.isEmpty ? "esc closes" : "Click a row to open it"), width: width)
    }
  }

  /// Before a call, in the notch: when you last met, what is owed either way, what to ask; the page
  /// and Dismiss.
  static func prep(_ title: String, at: Date, raw: String, ready: Bool) -> Card {
    let mins = max(0, Int(at.timeIntervalSinceNow / 60))
    var lines: [Card.Line] = []
    var page = ""
    if !ready { lines.append(.dim("Reading what is open with them…")) }
    for l in raw.split(separator: "\n").map(String.init) {
      let f = Brain.fields(l) + ["", ""]
      if l.hasPrefix("HEAD:") { lines.append(.head(f[0], f[1])) }
      else if l.hasPrefix("OWE:") { lines.append(.item(f[0], f[1])) }
      else if l.hasPrefix("ASK:") { lines.append(.ask(f[0])) }
      else if l.hasPrefix("PAGE:"), f[0] != "NONE" { page = f[0] }
    }
    if ready && lines.isEmpty { lines.append(.dim("Nothing open with them in the brain.")) }
    var buttons = [Card.Button(id: "dismiss", label: "Dismiss")]
    if !page.isEmpty { buttons.append(Card.Button(id: "page:" + page, label: "Open page", primary: true)) }
    return Card(mark: .cal, left: title, right: mins == 0 ? "now" : "in \(mins) min", lines: lines, buttons: buttons, width: width)
  }

  /// A call being recorded, in the notch: the time running and a way to stop.
  static func live(_ title: String, since: Date) -> Card {
    Card(mark: .live, left: title, right: "since \(IslandView.hhmm(since))",
         lines: [.dim("Recording. The notes land in your brain when the call ends.")],
         buttons: [Card.Button(id: "stop-call", label: "Stop recording")], width: width, since: since)
  }

  static func rewriting(_ instruction: String, since: Date) -> Card {
    Card(mark: .none, left: "Command", right: "", lines: [.said(instruction), .step("Rewriting your text", true)],
         hint: "esc cancels", width: width, since: since)
  }

  static func rewrite(_ instruction: String, old: String, new: String) -> Card {
    let pieces = Diff.pieces(from: old, to: new)
    let changes = pieces.filter { $0.kind == .added }.count
    return Card(mark: .wand, left: "Command",
                right: pieces.count == 1 ? "rewritten" : (changes == 1 ? "1 change" : "\(changes) changes"),
                lines: [.said(instruction), .sep, .diff(pieces)],
                buttons: [.init(id: "close", label: "Keep"), .init(id: "replace", label: "Replace", primary: true)],
                hint: "Tap ⌘⌥ to replace, esc keeps yours", width: width)
  }

  static func unclear(_ instruction: String) -> Card {
    Card(mark: .wand, left: "Command", right: "not understood",
         lines: [.said(instruction), .sep, .text("That is not something to do with the text. Yours is unchanged."),
                 .dim("Try: make it shorter, translate to Spanish, fix the grammar.")],
         buttons: [.init(id: "close", label: "Close")], width: width)
  }
}
