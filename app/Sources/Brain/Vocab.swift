import Foundation

struct Vocab: Decodable {
  struct Pair: Decodable { let from: String; let to: String }
  struct Snippet: Decodable { let trigger: String; let text: String }
  var prompt: String = ""
  var replacements: [Pair] = []
  var snippets: [Snippet] = []

  /// the hint list as single names, for Apple's engine
  var names: [String] { prompt.trimmingCharacters(in: CharacterSet(charactersIn: ".")).components(separatedBy: ", ").filter { !$0.isEmpty } }

  static let url = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Brain/vocab.json")

  static func load() -> Vocab {
    guard let data = try? Data(contentsOf: url), let v = try? JSONDecoder().decode(Vocab.self, from: data) else { return Vocab() }
    return v
  }

  /// What Whisper says on silence or noise; never paste these alone
  private static let ghosts: Set<String> = [
    "", "you", "thank you", "thanks for watching", "thank you for watching", "bye",
    "soustitres réalisés par la communauté damaraorg", "merci", "merci beaucoup",
  ]

  static func key(_ s: String) -> String {
    s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
      .split(separator: " ").joined(separator: " ")
  }

  /// nil when there is nothing worth pasting
  func apply(_ raw: String) -> String? {
    let k = Vocab.key(raw)
    if Vocab.ghosts.contains(k) { return nil }
    if let s = snippets.first(where: { Vocab.key($0.trigger) == k }) { return s.text }
    var out = raw
    for r in replacements {
      let pattern = "\\b" + NSRegularExpression.escapedPattern(for: r.from) + "\\b"
      out = out.replacingOccurrences(of: pattern, with: r.to, options: [.regularExpression, .caseInsensitive])
    }
    return out
  }
}
