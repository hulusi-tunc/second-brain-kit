import AppKit

/// The two shortcuts, changeable in Settings. Each is a modifier key on its own, so nothing you
/// type ever collides:
///   Talk           hold it, speak, let go
///   Ask the brain  hold it with Talk: a question, or with text selected, what to do with it
/// Kept in UserDefaults as the key code; Keys reads them on every event, so a change applies at once.
enum Shortcut: String, CaseIterable {
  case talk, ask

  var title: String {
    switch self { case .talk: "Talk"; case .ask: "Ask the brain" }
  }
  var how: String {
    switch self { case .talk: "hold"; case .ask: "hold with Talk" }
  }
  private var fallback: Int {
    switch self { case .talk: 61; case .ask: 54 }
  }
  var code: Int {
    get { UserDefaults.standard.object(forKey: "key." + rawValue) as? Int ?? fallback }
    nonmutating set { UserDefaults.standard.set(newValue, forKey: "key." + rawValue) }
  }
  var key: ModKey? { ModKey.all.first { $0.code == code } }
  /// "right ⌥", or "none"
  var label: String { key?.short ?? "none" }
  /// just the symbol, "⌥", for the notch where "right" and "left" do not fit
  var glyph: String { key.map { String($0.short.split(separator: " ").last ?? "") } ?? "" }

  /// Talk and Ask never share a key: Ask is held together with Talk.
  func allowed(_ k: ModKey) -> Bool {
    switch self {
    case .talk: return k.code != Shortcut.ask.code
    case .ask: return k.code != Shortcut.talk.code
    }
  }
  var canBeNone: Bool { false }
}

/// A modifier key, told apart left from right by the device bits in the event's flags.
struct ModKey: Hashable {
  let code: Int
  let name: String
  let short: String
  let mask: UInt

  static let all: [ModKey] = [
    ModKey(code: 61, name: "Right Option", short: "right ⌥", mask: 0x40),
    ModKey(code: 58, name: "Left Option", short: "left ⌥", mask: 0x20),
    ModKey(code: 54, name: "Right Command", short: "right ⌘", mask: 0x10),
    ModKey(code: 55, name: "Left Command", short: "left ⌘", mask: 0x08),
    ModKey(code: 62, name: "Right Control", short: "right ⌃", mask: 0x2000),
    ModKey(code: 59, name: "Left Control", short: "left ⌃", mask: 0x01),
    ModKey(code: 60, name: "Right Shift", short: "right ⇧", mask: 0x04),
    ModKey(code: 56, name: "Left Shift", short: "left ⇧", mask: 0x02),
    ModKey(code: 63, name: "fn (Globe)", short: "fn", mask: 0x800000),
  ]
  func isDown(_ e: NSEvent) -> Bool { e.modifierFlags.rawValue & mask != 0 }
}

/// Talk held, Ask held with it. Ask can come first or join while talking. Any other key while Talk
/// is held means you are typing a shortcut, so the take is dropped.
final class Keys {
  enum Mode { case talk, brain }
  /// Settings is listening for a new key: nothing pressed then is a take
  static var paused = false

  var onDown: ((Mode) -> Void)?
  var onBrain: (() -> Void)?
  var onUp: ((_ cancelled: Bool, _ mode: Mode) -> Void)?
  var onEscape: (() -> Void)?
  private var held = false
  private var cancelled = false
  private var mode = Mode.talk
  private var monitors: [Any] = []

  func start() {
    let flags: (NSEvent) -> Void = { [weak self] e in self?.flagsChanged(e) }
    let keys: (NSEvent) -> Void = { [weak self] e in
      if Keys.paused { return }
      if e.keyCode == 53 { self?.onEscape?() }
      if self?.held == true, self?.cancelled == false { self?.cancelled = true; Log.write("take cancelled: key \(e.keyCode) pressed while talking") }
    }
    if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
    if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
    if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
  }

  private func flagsChanged(_ e: NSEvent) {
    // a take ends when its key is up, whatever else happened in between
    if held, let t = Shortcut.talk.key, !t.isDown(e) {
      held = false
      onUp?(cancelled || Keys.paused, mode)
      return
    }
    if Keys.paused { return }
    let code = Int(e.keyCode)
    guard let k = ModKey.all.first(where: { $0.code == code }) else { return }
    let talk = Shortcut.talk.key, ask = Shortcut.ask.key
    if let ask, code == ask.code {
      if held, ask.isDown(e), mode == .talk { mode = .brain; onBrain?() }
      return
    }
    guard let talk, code == talk.code else {
      // another modifier joined in: a shortcut, not dictation
      if held, k.isDown(e) { cancelled = true; Log.write("take cancelled: \(k.name) joined") }
      return
    }
    let down = talk.isDown(e)
    if down, !held {
      held = true
      cancelled = false
      mode = ask.map { $0.isDown(e) } == true ? .brain : .talk
      onDown?(mode)
    } else if !down, held {
      held = false
      onUp?(cancelled, mode)
    }
  }

  /// "right ⌥" for the hints in the notch and the menu
  static var talkLabel: String { Shortcut.talk.label }
  static var askLabel: String { "\(Shortcut.ask.label) and \(Shortcut.talk.label)" }
}
