import Foundation

/// Where the app finds your second brain and what it calls you.
/// scripts/build.sh writes the repo path into Info.plist (BrainRepo); to point the app somewhere else:
///   defaults write local.secondbrain.app repo ~/path/to/your/brain
/// Your name on call notes defaults to your macOS first name:
///   defaults write local.secondbrain.app myName Sam
/// The languages you dictate in, so Whisper never guesses a fourth (empty: any language):
///   defaults write local.secondbrain.app languages -array en de
enum Config {
  static let home = FileManager.default.homeDirectoryForCurrentUser
  static let bundleID = Bundle.main.bundleIdentifier ?? "local.secondbrain.app"

  static var repo: URL {
    if let p = UserDefaults.standard.string(forKey: "repo"), !p.isEmpty {
      return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }
    if let p = Bundle.main.object(forInfoDictionaryKey: "BrainRepo") as? String, !p.isEmpty {
      return URL(fileURLWithPath: p)
    }
    return home.appendingPathComponent("second-brain")
  }

  /// a script in the brain's bin/ folder
  static func script(_ name: String) -> String { repo.appendingPathComponent("bin/\(name)").path }

  static var me: String {
    if let n = UserDefaults.standard.string(forKey: "myName"), !n.isEmpty { return n }
    return NSFullUserName().split(separator: " ").first.map(String.init) ?? "Me"
  }

  /// Whisper models, fetched by scripts/models.sh
  static let models = home.appendingPathComponent(".second-brain/models")
  static let cache = home.appendingPathComponent("Library/Caches/\(bundleID)")

  static var languages: [String] {
    if let a = UserDefaults.standard.stringArray(forKey: "languages") { return a.map { $0.lowercased() } }
    if let s = UserDefaults.standard.string(forKey: "languages") {
      return s.split(whereSeparator: { $0 == "," || $0 == " " }).map { $0.lowercased() }
    }
    return []
  }
}
