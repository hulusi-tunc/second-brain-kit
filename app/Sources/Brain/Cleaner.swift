import Foundation

/// The instant clean-up, rules only, no model: English fillers, a doubled small word,
/// spoken line breaks, and tone per app. Everything here takes under a millisecond. What rules
/// cannot do (a self-correction like "at 3, no, 4") is left for the model pass.
enum Cleaner {
  /// Code tools: a short command loses its full stop ("run the tests", not "Run the tests.")
  static let codeApps: Set<String> = [
    "com.todesktop.230313mzl4w4u92",  // Cursor
    "com.anthropic.claudefordesktop",
    "com.apple.Terminal", "dev.warp.Warp-Stable", "com.googlecode.iterm2",
    "com.microsoft.VSCode", "com.mitchellh.ghostty",
  ]

  private static func re(_ p: String) -> NSRegularExpression {
    try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
  }

  /// Fillers with the comma or space that follows them. Doubled words are only collapsed for small
  /// English words: other languages double words on purpose.
  private static let fillers = re(#"(?<![\p{L}'])(u+m+|u+h+|erm+|uhm+|hmm+|e{3,})(?![\p{L}'])[,.]?\s*"#)
  private static let doubled = re(#"\b(I|a|an|the|is|it|to|and|we|in|of|on|that|this)\s+\1\b"#)
  private static let newParagraph = re(#"[,.]?\s*\b(new paragraph)\b[,.]?\s*"#)
  private static let newLine = re(#"[,.]?\s*\b(new line)\b[,.]?\s*"#)
  private static let bullet = re(#"[,.]?\s*\b(new bullet)\b[,.]?\s*"#)

  /// Self-corrections, by rule (an on-device model was slower and missed more). At a cue, take the
  /// first word of the correction; if it was said shortly before the cue, cut from that earlier word
  /// through the cue ("at 3, no wait, at 4" -> "at 4"); otherwise drop the one word before the cue
  /// ("to Sam, sorry, Alex" -> "to Alex"). Cues only count between commas mid-sentence, so
  /// "Sorry, I'm late" is left alone.
  private static let cue = re(#"(?:,\s*(?:no wait|no,? wait|sorry|I mean|wait)\s*,)\s*"#)

  static func corrections(_ text: String) -> String {
    var s = text
    for _ in 0..<3 {   // a few in one dictation at most
      let ns = s as NSString
      guard let m = cue.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.range.location > 0 else { break }
      let before = ns.substring(to: m.range.location)
      let after = ns.substring(from: m.range.location + m.range.length)
      // the sentence the cue sits in: a cue right after a full stop is a real apology, not a correction
      let sentenceStart = before.range(of: #"[.!?]\s+[^.!?]*$"#, options: .regularExpression).map { before.distance(from: before.startIndex, to: $0.lowerBound) + 2 } ?? 0
      let head = String(before.dropFirst(sentenceStart))
      let headWords = head.split(separator: " ", omittingEmptySubsequences: true)
      guard !headWords.isEmpty, let first = after.split(separator: " ").first else { break }
      let key = first.lowercased().trimmingCharacters(in: .punctuationCharacters)
      var cutAt: String.Index?
      // the earlier word, within the last 6 words before the cue
      let window = headWords.suffix(6)
      if let w = window.last(where: { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) == key }) {
        cutAt = w.startIndex
      } else if let lastWord = headWords.last {
        cutAt = lastWord.startIndex
      }
      guard let cutAt else { break }
      let offset = head.distance(from: head.startIndex, to: cutAt)
      let keep = String(before.prefix(sentenceStart + offset)).replacingOccurrences(of: #" +$"#, with: "", options: .regularExpression)
      s = keep.isEmpty ? after : keep + " " + after
    }
    return s
  }

  static func clean(_ text: String, bundle: String) -> String {
    var s = corrections(text)
    func sub(_ r: NSRegularExpression, _ with: String) {
      s = r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
    }
    sub(fillers, "")
    sub(doubled, "$1")
    sub(newParagraph, "\n\n")
    sub(newLine, "\n")
    sub(bullet, "\n- ")
    // tidy what the removals left: double spaces, a space before punctuation, a lowercase start
    s = s.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: #" +([,.!?;:])"#, with: "$1", options: .regularExpression)
    s = s.replacingOccurrences(of: #"(?m)^[ ,]+"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"[ ,]+$"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"(?m)[ ,]+$"#, with: "", options: .regularExpression)
    s = s.trimmingCharacters(in: .whitespaces)
    // every line, and every bullet, starts with a capital
    var lines = s.components(separatedBy: "\n").map { line -> String in
      let lead = line.hasPrefix("- ") ? "- " : ""
      let body = line.dropFirst(lead.count)
      guard let f = body.first, f.isLowercase else { return line }
      return lead + f.uppercased() + body.dropFirst()
    }
    if lines.isEmpty { lines = [""] }
    s = lines.joined(separator: "\n")
    // a short command in a code tool: no full stop
    if codeApps.contains(bundle), !s.contains("\n"), s.split(separator: " ").count <= 12, s.hasSuffix("."), !s.hasSuffix("...") {
      s.removeLast()
    }
    return s
  }
}
