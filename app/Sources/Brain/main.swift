import AppKit
import AVFoundation

/// Whisper large-v3-turbo (about 550 MB), fetched by scripts/models.sh. BRAIN_MODEL overrides it.
let modelPath = ProcessInfo.processInfo.environment["BRAIN_MODEL"]
  ?? Config.models.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin").path

/// What the app is in the middle of (a call it records), as files a separate process can see:
/// `Brain --mic-users` reports them, so an install or a demo can wait for it to finish.
enum Busy {
  static var dir: URL { Config.cache }
  static func set(_ what: String, _ on: Bool) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("busy-" + what.replacingOccurrences(of: " ", with: "-"))
    if on { try? Data(what.utf8).write(to: f) } else { try? FileManager.default.removeItem(at: f) }
  }
  static func now() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("busy-") }
      .compactMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }
  }
  static func clear() { for w in now() { set(w, false) } }
}

@MainActor
final class App: NSObject, NSApplicationDelegate {
  private let island = IslandPanel()
  /// holds the answer history and the mic state; its floating window stays closed, the notch shows everything
  private let panel = BrainPanel()
  /// takes in a row where the mic sent nothing at all
  private var silentTakes = 0
  private let whisper = Whisper()
  private let mic = Mic()
  private let keys = Keys()
  private let calls = CallWatch()
  private var recorder: CallRecorder?
  private var vocab = Vocab.load()
  private var status: NSStatusItem?
  private var ready = false
  private var startedAt = Date()
  private var targetApp = ""
  private var targetBundle = ""
  // the brain in the notch
  private var brainTask: Process?
  private var selection: String?
  private var selectionUnknown = false
  private var rewrite: String?
  private var answerFile = "commitments.md"
  private var prepEvent: Agenda.Event?
  private var prepOut: String?
  private var prepDismissed: Set<String> = []
  private var callEvent: Agenda.Event?
  // the island's resting state: a call, else a call about to start
  private var callPhase: IslandModel.Phase?
  private var prepPhase: IslandModel.Phase?

  /// brain:// links and the Services menu (Everywhere.swift)
  private let everywhere = Everywhere()

  func application(_ application: NSApplication, open urls: [URL]) {
    for u in urls { everywhere.handle(u) }
  }

  func applicationDidFinishLaunching(_ n: Notification) {
    Busy.clear()   // whatever the last run was doing ended with it
    S.registerFont()
    everywhere.onAsk = { [weak self] q in self?.ask(q) }
    everywhere.onOpen = { [weak self] in self?.showQuick(false) }
    everywhere.onSaved = { [weak self] in self?.island.show(.note("Saved to Brain", "in today's notes"), for: 2) }
    everywhere.onSettings = { [weak self] in self?.island.model.quickPage = "settings"; self?.showQuick(true) }
    NSApp.servicesProvider = everywhere
    NSUpdateDynamicServices()
    island.setUp()
    makeMenu()
    History.sweep()
    island.show(.note("Brain", "loading the model"))
    whisper.load(model: modelPath) { [weak self] ok in
      guard let self else { return }
      self.ready = ok
      Log.write("model \(ok ? "ready" : "missing")")
      // only the loading note goes away: a take started meanwhile keeps its island
      if !ok { self.island.show(.note("Brain", "model missing, run scripts/models.sh"), for: 8) } else if case .note = self.island.model.phase { self.island.hide() }
    }
    Mic.requestAccess { [weak self] ok in
      if !ok { self?.island.show(.note("Microphone", "allow in Settings"), for: 8) }
    }
    Log.write("launched Brain \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?"): repo \(Config.repo.path), accessibility \(Paste.trusted(prompt: false)), microphone \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue == 3)")
    if !FileManager.default.fileExists(atPath: Config.repo.appendingPathComponent("raw").path) {
      island.show(.note("No brain found", "set the repo, see the README"), for: 8)
    }
    waitForAccessibility(prompt: true)
    mic.onLevel = { [weak self] l in
      guard let self else { return }
      if self.panel.model.listening { self.panel.model.push(level: l) } else { self.island.model.push(level: l) }
    }
    mic.onSlow = { [weak self] in self?.island.show(.note("Microphone", "macOS audio is not answering"), for: 5) }
    // the audio system is stuck inside a call the app cannot cancel: start again (launchd brings it
    // back in seconds) rather than sit frozen
    mic.onStuck = { exit(1) }
    mic.alwaysWarm = UserDefaults.standard.bool(forKey: "alwaysWarm")
    if mic.alwaysWarm { mic.warmUp() }
    calls.onStart = { [weak self] c in self?.callStarted(c) }
    calls.onEnd = { [weak self] in self?.callEnded() }
    calls.start()
    keys.onDown = { [weak self] m in self?.down(m) }
    keys.onBrain = { [weak self] in self?.brainJoined() }
    keys.onUp = { [weak self] c, m in self?.up(cancelled: c, mode: m) }
    keys.onEscape = { [weak self] in self?.escape() }
    island.model.onButton = { [weak self] id in self?.button(id) }
    island.onHover = { [weak self] in self?.hovered() }
    // the notch itself grows under the pointer
    island.onNotchHover = { [weak self] in guard let self, self.island.model.phase == .hidden else { return }; self.showQuick(false) }
    island.onNotchNear = { [weak self] in guard let self, !self.panel.isOpen else { return }; self.showQuick(false) }
    island.model.onQuick = { [weak self] id in self?.quick(id) }
    panel.setUp()
    panel.anchor = { [weak self] in
      guard let self else { return nil }
      if self.island.model.phase == .hidden { self.island.place() }
      return self.island.anchor
    }
    panel.onOpened = { [weak self] in self?.foldedAway() }
    panel.onFolded = { [weak self] in self?.foldedInto(unread: false) }
    panel.onClosed = { [weak self] in self?.foldedAway() }
    panel.onReach = { [weak self] near in
      guard let self else { return }
      if near { if self.island.model.phase == .hidden { self.island.show(.folded(false)) } }
      else if self.island.folded == nil, case .folded = self.island.model.phase { self.island.hide() }
    }
    panel.model.onNew = { [weak self] in
      guard let self else { return }
      self.brainTask?.terminate(); self.brainTask = nil
      self.panel.model.earlier = []
      self.panel.model.now = .empty
    }
    panel.model.onAsk = { [weak self] q in self?.ask(q) }
    panel.model.onOpen = { f in Brain.open(f) }
    panel.model.onStopCall = { [weak self] in self?.calls.stopByHand() }
    panel.model.onWarm = { [weak self] on in self?.setWarm(on) }
    panel.model.warm = mic.alwaysWarm
    island.onLeave = { [weak self] in self?.island.hide() }
    island.onOutsideClick = { [weak self] in
      guard let self else { return }
      if case .quick = self.island.model.phase { self.island.model.quickPage = ""; self.island.hide(); return }
      self.closeCard()
    }
    Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tickAgenda() } }
    tickAgenda()
    Volume.recover()
    // `Brain --test-command "fix the grammar"`: the command flow on the current selection without
    // the keys or the mic, to test Replace end to end
    DistributedNotificationCenter.default().addObserver(forName: .init(Config.bundleID + ".test-command"), object: nil, queue: .main) { [weak self] n in
      let instruction = (n.object as? String) ?? "fix the grammar"
      MainActor.assumeIsolated {
        guard let self else { return }
        self.selection = nil; self.selectionUnknown = false
        self.readSelection()
        if self.selectionUnknown { Selection.viaCopy { [weak self] t in self?.selection = t; self?.selectionUnknown = false } }
        self.route(instruction, 0)
      }
    }
  }

  /// The app hears the key and presses ⌘V only with Accessibility; ask once, then wait for it.
  private func waitForAccessibility(prompt: Bool) {
    if Paste.trusted(prompt: prompt) {
      keys.start()
      return
    }
    island.show(.note("Accessibility", "allow Brain in Settings"), for: 6)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.waitForAccessibility(prompt: false) }
  }

  /// A quick tap of the brain keys while a rewrite is waiting means Replace: hands stay on the
  /// keyboard and the text box keeps its focus.
  private var tapToReplace = false
  /// the talk keys are down: a late music fade only happens while they still are
  private var keyHeld = false

  private func down(_ mode: Keys.Mode) {
    keyHeld = true
    Log.write("key down: \(mode == .brain ? "brain" : "talk"), ready \(ready), island \(island.model.phase)")
    // right after launch the model may still be loading: the take is recorded anyway and written
    // as soon as the model is in (whenReady)
    if !ready { Log.write("key down while the model loads: recording, writing it when ready") }
    tapToReplace = mode == .brain && rewrite != nil
    if tapToReplace { return }
    rewrite = nil   // a new take: a fix still waiting is dropped, so a later tap cannot paste it
    // the Mac goes quiet while you talk (not during a call: that sound is being recorded); the fade
    // starts once the notch has opened, so the opening never hitches
    if recorder == nil, (UserDefaults.standard.string(forKey: "musicMode") ?? "down") == "down" {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
        guard let self, self.keyHeld else { return }
        Volume.quiet()
      }
    }
    brainTask?.terminate(); brainTask = nil
    selection = nil; selectionUnknown = false
    if mode == .brain { readSelection() }
    let front = NSWorkspace.shared.frontmostApplication
    targetApp = front?.localizedName ?? "the app"
    targetBundle = front?.bundleIdentifier ?? ""
    startedAt = Date()
    followUp = mode == .brain && panel.isOpen && selection == nil
    if followUp {
      panel.model.listening = true
      island.hide()
    } else {
      if mode == .brain, selection != nil, panel.isOpen, panel.home == .notch { panel.fold() }
      island.show(mode == .brain ? (selection != nil ? .card(BrainCards.listening(selection: selection)) : .ask) : .listening)
    }
    // Whisper wakes on the GPU once the opening has played, still long before the keys are let go
    if ready { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.whisper.warmUp() } }
    mic.start { [weak self] error in
      guard let error else { return }
      Log.write("mic could not start: \(error)")
      self?.island.show(.note("Microphone", "could not start"), for: 3)
    }
  }

  private func up(cancelled: Bool, mode: Keys.Mode) {
    keyHeld = false
    if tapToReplace { tapToReplace = false; _ = mic.stop(); if !cancelled { button("replace") }; return }
    let samples = mic.stop()
    let peakNow = mic.peakLevel
    panel.model.listening = false
    Volume.back()
    let seconds = Double(samples.count) / 16_000
    Log.write("key up: \(mode == .brain ? "brain" : "talk"), \(String(format: "%.1f", seconds)) s, peak \(String(format: "%.4f", peakNow)), cancelled \(cancelled)")
    if cancelled || seconds < 0.3 { Log.write("take: \(cancelled ? "cancelled" : "too short")"); island.hide(); return }
    // under about -58 dBFS nothing was said; quiet takes above it are written, and what Whisper
    // invents from near-silence ("Thank you.") is dropped instead of pasted
    if peakNow < 0.0012 {
      Log.write("take: silent (peak under the bar)")
      // a long take with no sound at all is the mic failing: say so, and a mic that does it twice
      // in a row is skipped for ten minutes
      if seconds > 1 {
        silentTakes += 1
        let name = mic.deviceName
        if silentTakes >= 2, !name.isEmpty { Mic.avoid[name] = Date(); mic.reset(); silentTakes = 0; Log.write("mic: \(name) sent silence twice, skipped for 10 min") }
        island.show(.note("The mic sent silence", silentTakes == 0 ? "switched mic, say it again" : "say it again"), for: 3)
      } else { island.show(.nothing, for: 1.5) }
      return
    }
    silentTakes = 0
    let quiet = peakNow < 0.003
    if mode == .brain { whenReady { [weak self] in self?.brainHeard(samples) }; return }
    island.show(.writing)
    let app = targetApp, bundle = targetBundle, micName = mic.deviceName, peak = peakNow
    let coach = coachLine()
    // heard but no words back: once more without the word list before giving up
    let once: (@escaping (Whisper.Result?) -> Void) -> Void = { [weak self] next in
      guard let self else { return }
      self.whisper.transcribe(samples, prompt: self.vocab.prompt) { r in
        if let r, !r.text.trimmingCharacters(in: .whitespaces).isEmpty { next(r); return }
        Log.write("talk: no words on the first pass, trying once more")
        self.whisper.transcribe(samples, prompt: "") { next($0) }
      }
    }
    // a take that is still not written after a while says so; the words still land when it ends
    var finished = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 12 + seconds / 2) { [weak self] in
      guard !finished else { return }
      Log.write("take: slow, still writing after \(Int(12 + seconds / 2)) s")
      self?.island.show(.note("Still writing", "it lands when done"), for: 4)
    }
    whenReady { once { [weak self] r in
      finished = true
      guard let self else { return }
      var text = r.flatMap { self.vocab.apply($0.text) }.map { Cleaner.clean($0, bundle: bundle) }.flatMap { $0.isEmpty ? nil : $0 }
      if quiet, let t = text, Whisper.ghost(t) { Log.write("take: quiet, Whisper made up \"\(t)\", dropped"); text = nil }
      Log.write("talk heard: \(text?.count ?? 0) chars, \(r?.language ?? "?"), \(r?.millis ?? -1) ms, into \(app)")
      if let text {
        self.lastTake = text
        switch Paste.deliver(text) {
        case .pasted:
          Log.write("take: ok, pasted")
          self.island.show(.card(self.takeCard(text, title: "Pasted in \(app)", pasted: true)), for: 10)
        case .held(let why):
          Log.write("take: ok, held in the notch (\(why))")
          self.island.show(.card(self.takeCard(text, title: "Not pasted, \(why)", pasted: false)), for: 20)
        }
      } else if quiet {
        Log.write("take: nothing said"); self.island.show(.nothing, for: 1.5)
      } else {
        Log.write("take: no words"); self.island.show(.note("No words came out", "the audio is kept in History"), for: 3)
      }
      if let coach { DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { self.island.show(.note(coach.0, coach.1), for: 4) } }
      History.add(.init(at: ISO8601DateFormatter().string(from: Date()), app: app, bundle: bundle, seconds: seconds,
                        latencyMs: r?.millis ?? -1, language: r?.language ?? "?", raw: r?.text ?? "", text: text,
                        mic: micName, peak: peak), samples: samples)
    } }
  }

  /// Runs once the model is in: at once normally, or as soon as it finishes loading after a start.
  private func whenReady(_ go: @escaping () -> Void, waited: Double = 0) {
    if ready { go(); return }
    guard waited < 60 else { Log.write("take: the model never loaded"); island.show(.note("Brain", "the model did not load"), for: 5); return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.whenReady(go, waited: waited + 0.25) }
  }

  /// The input coach: one line in the notch, only when something costs accuracy, once per change.
  /// Whispering is fine, so "too quiet" is never said.
  private var lastMic = ""
  private func coachLine() -> (String, String)? {
    defer { lastMic = mic.deviceName }
    if mic.lostDuringTake { return ("Mic lost", "next take: \(Mic.bestInput()?.name ?? "the built-in mic")") }
    if mic.peakSample >= 0.98 { return ("Too loud, clipping", "gain down a little") }
    if !lastMic.isEmpty, lastMic != mic.deviceName { return ("Mic now", mic.deviceName) }
    if mic.deviceName.localizedCaseInsensitiveContains("AirPods") { return ("AirPods mic", "phone quality, a wired mic is clearer") }
    return nil
  }

  // MARK: the brain in the notch. Talk + Ask held: a question, or with text selected, a command.

  private func brainJoined() {
    if selection == nil { readSelection() }
    followUp = panel.isOpen && selection == nil
    if followUp { panel.model.listening = true; island.hide() } else {
      island.show(selection != nil ? .card(BrainCards.listening(selection: selection)) : .ask)
    }
  }

  /// the brain keys went down while the panel was open, with nothing selected: a follow-up
  private var followUp = false

  private func readSelection() {
    switch Selection.read() {
    case .text(let t): selection = t; selectionUnknown = false
    case .none: selection = nil; selectionUnknown = false
    case .unknown: selection = nil; selectionUnknown = true
    }
  }

  private func brainHeard(_ samples: [Float]) {
    if followUp && selection == nil { panel.model.writing = true } else {
      island.show(selection != nil ? .card(BrainCards.writing(selection: true)) : .note("Ask the brain", "writing"))
    }
    // the app would not say what is selected: copy it now, while the words are being written down
    if selection == nil && selectionUnknown {
      Selection.viaCopy { [weak self] t in self?.selection = t; self?.selectionUnknown = false }
    }
    whisper.transcribe(samples, prompt: vocab.prompt) { [weak self] r in
      guard let self else { return }
      let q = r.flatMap { self.vocab.apply($0.text) }.map { Cleaner.clean($0, bundle: "") } ?? ""
      self.panel.model.writing = false
      Log.write("brain heard: \(q.count) chars, \(r?.language ?? "?"), \(r?.millis ?? -1) ms, selection \(self.selection != nil)")
      guard !q.isEmpty else { self.island.show(.nothing, for: 1.5); return }
      if self.voiceSwitch(q) { Log.write("brain: a voice switch"); return }
      // a stray "okay" or "yes" with the keys down is not a question
      let words = q.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
      let filler: Set<String> = ["okay", "ok", "yes", "yeah", "no", "hmm", "um", "uh", "so", "thanks", "thank", "you"]
      if words.count < 2 || words.allSatisfy({ filler.contains($0) }) {
        self.island.show(.note("Ask the brain", "say a question"), for: 1.5); return
      }
      self.route(q, 0)
    }
  }

  /// "stop recording", "mic warm", "mic rest": switches by voice, from any screen, since the menu
  /// bar icon can sit hidden behind the notch.
  private func voiceSwitch(_ q: String) -> Bool {
    let t = q.lowercased().folding(options: .diacriticInsensitive, locale: nil)
      .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    let words = Set(t)
    guard t.count <= 6 else { return false }
    if recorder != nil, words.contains("recording"), !words.isDisjoint(with: ["stop", "end"]) {
      calls.stopByHand(); return true
    }
    if words.contains("mic") || words.contains("microphone") {
      if words.contains("warm") { setWarm(true); island.show(.note("Mic kept warm", "the orange dot stays"), for: 2.5); return true }
      if words.contains("rest") { setWarm(false); island.show(.note("Mic rests", "opens when you talk"), for: 2.5); return true }
    }
    return false
  }

  private func route(_ q: String, _ tries: Int) {
    if selectionUnknown && tries < 20 {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.route(q, tries + 1) }
      return
    }
    Log.write("brain route: \(selection != nil ? "rewrite the selection" : "ask")")
    if let sel = selection { command(q, on: sel) } else { ask(q) }
  }

  /// A question, asked and answered in the notch: what the brain reads, step by step, then the
  /// answer. A question while an answer is open is a follow-up.
  private var lastQA: (q: String, out: String)?
  private func ask(_ q: String) {
    let showing: Bool = { if case .card = island.model.phase { return true }; return false }()
    let context = showing ? (lastQA.map { "Q: \($0.q)\nA: \(Answer($0.out).head)" } ?? "") : ""
    Log.write("ask: started in the notch, follow-up \(!context.isEmpty)")
    let since = Date()
    var steps: [String] = []
    island.hoverCard = false
    island.show(.card(BrainCards.thinking(q, steps: steps, since: since)))
    brainTask = Brain.stream(["ask", q] + (context.isEmpty ? [] : [context]), onLine: { [weak self] line in
      guard let self, self.brainTask != nil, line.hasPrefix("STEP:") else { return }
      let f = Brain.fields(line) + ["", ""]
      steps.append(f[1].replacingOccurrences(of: "**", with: ""))
      self.island.show(.card(BrainCards.thinking(q, steps: steps, since: since)))
    }, done: { [weak self] out in
      guard let self, self.brainTask != nil else { return }
      self.brainTask = nil
      let secs = Int(Date().timeIntervalSince(since).rounded())
      let data = Answer(out)
      self.lastQA = (q, out)
      self.answerFile = App.file(in: data.rows.map { $0.source + " " + $0.file })
      self.panel.model.remember(HistoryItem(q: q, at: since, head: data.kind == "none" ? "Not in the brain" : data.head, raw: out, seconds: secs))
      Log.write("ask: \(steps.count) steps, \(out.split(separator: "\n").count) lines back in \(secs) s")
      self.island.show(.card(BrainCards.answer(q, out: out, seconds: secs)))
    })
  }

  /// The panel folded into the notch: its mark stays there while the panel holds something.
  private func foldedInto(unread: Bool) {
    if case .empty = panel.model.now { foldedAway(); return }
    island.folded = .folded(unread)
    switch island.model.phase {
    case .hidden, .folded: island.show(.folded(unread))
    default: break   // a call rests there; the mark comes back after
    }
  }

  /// Opened or closed: nothing waits in the notch any more.
  private func foldedAway() {
    island.folded = nil
    if case .folded = island.model.phase { island.hide() }
  }

  /// The page an answer came from: the first .md file named in its sources, else the ledger.
  static func file(in sources: [String]) -> String {
    let root = Config.repo.path
    for src in sources {
      for word in src.split(whereSeparator: { " ,;()".contains($0) }) where word.hasSuffix(".md") {
        for dir in ["", "wiki/", "archive/"] where FileManager.default.fileExists(atPath: "\(root)/\(dir)\(word)") { return dir + word }
      }
      for word in src.split(whereSeparator: { " ,;()".contains($0) }) {
        for dir in ["archive/", "wiki/"] where FileManager.default.fileExists(atPath: "\(root)/\(dir)\(word).md") { return "\(dir)\(word).md" }
      }
    }
    return "commitments.md"
  }

  private func command(_ instruction: String, on text: String) {
    if panel.isOpen, panel.home == .notch { panel.fold() }
    island.show(.card(BrainCards.rewriting(instruction, since: Date())))
    brainTask = Brain.run(["rewrite", instruction], input: text) { [weak self] out in
      guard let self else { return }
      self.brainTask = nil
      if out == "ASK" { self.selection = nil; self.ask(instruction); return }
      if out.isEmpty || out.hasPrefix("NOT_AN_INSTRUCTION") {
        self.island.show(.card(BrainCards.unclear(instruction)))
        return
      }
      self.rewrite = out
      self.island.show(.card(BrainCards.rewrite(instruction, old: text, new: out)))
    }
  }

  private func button(_ id: String) {
    Log.write("button \(id), front app \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    switch id {
    case "takeCopy":
      guard let t = lastTake else { island.hide(); return }
      Paste.copy(t)
      Log.write("take: copied by hand, \(t.count) characters")
      island.show(.note("Copied", "⌘V puts it anywhere"), for: 2)
    case "takePaste":
      guard let t = lastTake else { island.hide(); return }
      island.hide()
      // the notch never takes focus: the app and its cursor are still where you clicked
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
        Log.write("take: pasted again into \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        Paste.type(t)
        self?.island.show(.pasted(NSWorkspace.shared.frontmostApplication?.localizedName ?? "the app"), for: 2)
      }
    case "replace":
      guard let text = rewrite else { closeCard(); return }
      rewrite = nil
      island.hide()
      // the app kept focus and the selection, so the paste replaces it; ⌘Z there undoes it
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
        Log.write("replace: pasting \(text.count) characters into \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        Paste.type(text)
        self?.island.show(.note("Replaced", "⌘Z undoes"), for: 3)
      }
    case "obsidian":
      Brain.open(answerFile); closeCard()
    case "dismiss":
      if let e = prepEvent, recorder == nil { prepDismissed.insert(e.id); prepPhase = nil; island.rest = callPhase }
      closeCard()
    case "warm": setWarm(!mic.alwaysWarm); island.hide()
    case "stop-call": island.hide(); calls.stopByHand()
    default:
      if id.hasPrefix("open:") { Brain.open(String(id.dropFirst(5))); closeCard(); return }
      if id.hasPrefix("page:") { Brain.open(String(id.dropFirst(5))); island.hide(); return }
      if id.hasPrefix("url:"), let u = URL(string: String(id.dropFirst(4))) { NSWorkspace.shared.open(u); island.hide(); return }
      closeCard()
    }
  }

  private func updateRest() {
    let r = callPhase ?? prepPhase
    island.rest = r
    switch island.model.phase {
    case .hidden, .prep, .recording, .folded: if let r = r ?? island.folded { island.show(r) } else { island.hide() }
    default: break   // something you are looking at; the rest comes back when it closes
    }
  }

  /// the last dictation, for the card's Copy and Paste again
  private var lastTake: String?

  /// The words stay in the notch for 10 s: Copy puts them on the clipboard, Paste again puts them
  /// wherever the cursor is now (click the right field first).
  private func takeCard(_ text: String, title: String, pasted: Bool) -> Card {
    let short = text.count > 140 ? String(text.prefix(140)) + "…" : text
    return Card(mark: pasted ? .ok : .pink, left: title, right: "",
                lines: [.quote(short)],
                buttons: [Card.Button(id: "takeCopy", label: "Copy", primary: !pasted),
                          Card.Button(id: "takePaste", label: pasted ? "Paste again" : "Paste", primary: false)],
                hint: pasted ? "Wrong place? Click the right field, then Paste again" : "Click where it goes, then Paste")
  }

  private func closeCard() {
    brainTask?.terminate(); brainTask = nil
    rewrite = nil
    island.hide()
  }

  private func escape() {
    if case .card = island.model.phase { closeCard(); return }
    if case .quick = island.model.phase, !Keys.paused { island.model.quickPage = ""; island.hide(); return }
  }

  // MARK: prep before a call: made 10 min ahead, shown 5 min ahead, the card on hover

  private func tickAgenda() {
    let now = Date()
    if let e = Agenda.next(within: 10, now: now), e.id != prepEvent?.id, !prepDismissed.contains(e.id) {
      prepEvent = e
      prepOut = nil
      Brain.run(["prep", e.title, e.names.joined(separator: ", "), IslandView.hhmm(e.start)]) { [weak self] out in
        if self?.prepEvent?.id == e.id { self?.prepOut = out }
      }
    }
    var phase: IslandModel.Phase?
    if recorder == nil, let e = prepEvent, !prepDismissed.contains(e.id),
       now >= e.start.addingTimeInterval(-5 * 60), now <= e.start.addingTimeInterval(5 * 60) {
      phase = .prep(Agenda.who(e), e.start)
    }
    if phase != prepPhase { prepPhase = phase; updateRest() }
  }

  /// The quick island: the notch grown under the pointer, its switches showing what is on now
  private func showQuick(_ expanded: Bool) {
    island.model.quickWarm = panel.model.warm
    island.hoverCard = true
    island.show(.quick(expanded))
  }
  private func quick(_ id: String) {
    let expanded: Bool = { if case .quick(let e) = island.model.phase { return e }; return false }()
    Log.write("quick: \(id)")
    switch id {
    case "folder": island.hide(); NSWorkspace.shared.open(Config.repo)
    case "warm": setWarm(!panel.model.warm); showQuick(expanded)
    case "more": island.model.quickPage = ""; showQuick(!expanded)
    case "back": island.model.quickPage = ""; showQuick(true)
    case "last":
      if let a = lastQA { island.hoverCard = false; island.show(.card(BrainCards.answer(a.q, out: a.out, seconds: 0))) }
      else { island.show(.note("No answer yet", "hold \(Keys.askLabel) and ask"), for: 2.5) }
    case "settings": island.model.quickPage = "settings"; showQuick(true)
    default: break
    }
  }

  /// Hovering the notch opens what it is showing: the last answer, the live call, the prep.
  private func hovered() {
    switch island.model.phase {
    case .ready, .folded: island.folded = nil; if let a = lastQA { island.show(.card(BrainCards.answer(a.q, out: a.out, seconds: 0))) } else { showQuick(false) }
    case .recording: openLive()
    default: openPrep()
    }
  }

  private func openLive() {
    guard let r = recorder else { return }
    island.hoverCard = true
    island.show(.card(BrainCards.live(callEvent?.title ?? callApp, since: r.started)))
  }

  private func openPrep() {
    if recorder != nil, callEvent == nil { openLive(); return }
    guard let e = recorder != nil ? (callEvent ?? prepEvent) : prepEvent else { return }
    island.hoverCard = true
    island.show(.card(BrainCards.prep(e.title, at: e.start, raw: prepOut ?? "", ready: prepOut != nil)))
  }

  func applicationWillTerminate(_ n: Notification) {
    if recorder != nil { callEnded() }
    whisper.close()
  }

  // MARK: calls. Every call that holds the mic is recorded, unless switched off in Settings.

  private var callApp = ""
  private func callStarted(_ c: CallWatch.Call) {
    guard UserDefaults.standard.object(forKey: "recordCalls") as? Bool ?? true else { Log.write("call: \(c.app), not recorded (Settings)"); return }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
    let dir = History.root.appendingPathComponent("meetings/\(f.string(from: Date()))")
    let r = CallRecorder(dir: dir)
    do {
      try r.start()
      recorder = r
      Busy.set("a call", true)
      callApp = c.app
      callEvent = Agenda.current()
      let title = callEvent.map { Agenda.who($0) } ?? c.app
      callPhase = .recording(title, r.started)
      updateRest()
    } catch {
      island.show(.note("Call not recorded", "allow System Audio Recording"), for: 6)
    }
  }

  private func callEnded() {
    guard let r = recorder else { return }
    recorder = nil
    Busy.set("a call", false)
    callPhase = nil
    island.rest = nil
    let (me, themURL, seconds) = r.stop()
    let started = r.started
    // about 12 s for a 15 min track with voice detection; two tracks
    island.show(.note("Writing notes", "about \(Int(seconds / 60 * 1.6) + 5) s"))
    let app = callApp
    let event = callEvent
    callEvent = nil
    if let e = event { prepDismissed.insert(e.id) }
    // the calendar names the call and, when it is one person, the other voice
    let them = event.flatMap { $0.names.count == 1 ? $0.names[0] : nil } ?? "Them"
    let myName = Config.me
    var tracks: [Notes.Track] = []
    func next(_ todo: [(String, URL)]) {
      guard let (who, url) = todo.first else {
        let minutes = Int(seconds / 60)
        let text = Notes.transcript(tracks)
        guard !text.isEmpty, let note = Notes.write(title: event?.title ?? "Call in \(app)", start: started, minutes: minutes,
                                                   participants: [myName] + (event?.names ?? []), source: "Brain, \(app)", transcript: text) else {
          island.show(.note("Nothing said", "no notes saved"), for: 3)
          return
        }
        island.show(.saved("Notes saved"), for: 3)
        // the summary and next steps are written by the brain's script, in the background
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Config.script("brain-call-notes.sh"), note.path]
        try? p.run()
        return
      }
      DispatchQueue.global(qos: .userInitiated).async {
        let samples = readAudio16k(url.path) ?? []
        DispatchQueue.main.async {
          self.whisper.transcribeLong(samples, prompt: self.vocab.prompt) { segs, _ in
            tracks.append(.init(who: who, offset: 0, segments: segs))
            next(Array(todo.dropFirst()))
          }
        }
      }
    }
    next([(myName, me), (them, themURL)])
  }

  private func makeMenu() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Brain")
    item.autosaveName = "Brain"
    let m = NSMenu()
    m.addItem(withTitle: "Brain \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")", action: nil, keyEquivalent: "")
    let talkItem = m.addItem(withTitle: "", action: nil, keyEquivalent: "")
    let askItem = m.addItem(withTitle: "", action: nil, keyEquivalent: "")
    // the shortcuts can change in Settings: the menu says what they are now
    let name = { [weak talkItem, weak askItem] in
      talkItem?.title = "Hold \(Keys.talkLabel) to talk"
      askItem?.title = "Hold \(Keys.askLabel) to ask the brain"
    }
    name()
    NotificationCenter.default.addObserver(forName: .shortcutsChanged, object: nil, queue: .main) { _ in name() }
    m.addItem(.separator())
    let warm = NSMenuItem(title: "Keep mic warm", action: #selector(toggleWarm(_:)), keyEquivalent: "")
    warm.state = UserDefaults.standard.bool(forKey: "alwaysWarm") ? .on : .off
    warmItem = warm
    m.addItem(warm)
    m.addItem(.separator())
    m.addItem(withTitle: "Open your brain", action: #selector(openRepo), keyEquivalent: "")
    m.addItem(withTitle: "Reload words", action: #selector(reloadVocab), keyEquivalent: "")
    m.addItem(withTitle: "Open history", action: #selector(openHistory), keyEquivalent: "")
    m.addItem(.separator())
    // launchd brings the app back right away, so quitting is a restart
    m.addItem(withTitle: "Restart Brain", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
    for i in m.items where i.action != nil && i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
    item.menu = m
    status = item
  }

  /// On: the mic never closes, no wait ever, the orange dot stays. Off: warm for 2 min after a take.
  @objc private func toggleWarm(_ item: NSMenuItem) { setWarm(item.state != .on) }

  private var warmItem: NSMenuItem?
  private func setWarm(_ on: Bool) {
    panel.model.warm = on
    warmItem?.state = on ? .on : .off
    UserDefaults.standard.set(on, forKey: "alwaysWarm")
    mic.alwaysWarm = on
    on ? mic.warmUp() : mic.coolNow()
  }

  @objc private func openRepo() { NSWorkspace.shared.open(Config.repo) }
  @objc private func reloadVocab() { vocab = Vocab.load() }
  @objc private func openHistory() { NSWorkspace.shared.open(History.root) }
}

/// `Brain --files a.wav b.wav ...`: the takes one after another on one engine, the way the app runs all day.
func runFiles(_ paths: [String]) {
  let w = Whisper()
  let vocab = Vocab.load()
  let sem = DispatchSemaphore(value: 0)
  w.load(model: modelPath) { _ in sem.signal() }
  while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  for path in paths {
    guard let samples = readWav16k(path) else { print("cannot read \(path)"); continue }
    var done = false
    w.transcribe(samples, prompt: vocab.prompt) { r in
      print("\(URL(fileURLWithPath: path).lastPathComponent)  \(String(format: "%.1f", Double(samples.count) / 16_000)) s  \(r?.millis ?? -1) ms  \(r?.text.prefix(90) ?? "(nothing)")")
      done = true
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  }
  w.close()
  exit(0)
}

/// `Brain --file x.wav`: transcribe a file with the same engine, twice, print the time, quit.
func runFile(_ path: String) {
  let w = Whisper()
  let vocab = Vocab.load()
  guard let samples = readWav16k(path) else { print("cannot read \(path)"); exit(1) }
  let sem = DispatchSemaphore(value: 0)
  w.load(model: modelPath) { _ in sem.signal() }
  RunLoop.main.run(until: Date().addingTimeInterval(0.1))
  while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  for _ in 0..<2 {
    var done = false
    w.transcribe(samples, prompt: vocab.prompt) { r in
      print("\(r?.millis ?? -1) ms  [\(r?.language ?? "?")]  \(r.flatMap { vocab.apply($0.text) } ?? "(nothing)")")
      done = true
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  }
  w.close()
  exit(0)
}

/// Any audio file (a mic's WAV, a 48 kHz stereo tap CAF) to 16 kHz mono, read in 10 s chunks.
func readAudio16k(_ path: String) -> [Float]? {
  guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
  let src = file.processingFormat
  let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
  guard let conv = AVAudioConverter(from: src, to: target) else { return nil }
  conv.downmix = true
  var out: [Float] = []
  out.reserveCapacity(Int(Double(file.length) * 16_000 / src.sampleRate) + 16_000)
  let chunk = AVAudioFrameCount(src.sampleRate * 10)
  var done = false
  while !done {
    guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: chunk), (try? file.read(into: inBuf, frameCount: chunk)) != nil, inBuf.frameLength > 0 else { break }
    if inBuf.frameLength < chunk { done = true }
    let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16_000 / src.sampleRate) + 64
    guard let o = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { break }
    var fed = false
    _ = conv.convert(to: o, error: nil) { _, st in
      if fed { st.pointee = .noDataNow; return nil }
      fed = true; st.pointee = .haveData; return inBuf
    }
    out.append(contentsOf: UnsafeBufferPointer(start: o.floatChannelData![0], count: Int(o.frameLength)))
  }
  return out
}

/// `Brain --meeting --title T --start "yyyy-MM-dd HH:mm" --out path --track Who:file:offsetSeconds ...`
/// Transcribes each track, merges them by time, writes the note: for recordings made elsewhere.
func runMeeting(_ args: [String]) {
  func val(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
  let tracks: [(String, String, Double)] = args.indices.filter { args[$0] == "--track" && $0 + 1 < args.count }.compactMap {
    let p = args[$0 + 1].split(separator: ":", maxSplits: 2).map(String.init)
    return p.count == 3 ? (p[0], p[1], Double(p[2]) ?? 0) : nil
  }
  let w = Whisper()
  let vocab = Vocab.load()
  var loaded = false
  w.load(model: modelPath) { _ in loaded = true }
  while !loaded { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  var results: [Notes.Track] = []
  var minutes = 0
  for (who, file, offset) in tracks {
    guard let samples = readAudio16k(file) else { print("cannot read \(file)"); continue }
    minutes = max(minutes, Int((offset + Double(samples.count) / 16_000) / 60))
    let t0 = Date()
    var done = false
    w.transcribeLong(samples, prompt: vocab.prompt) { segs, lang in
      print("\(who): \(samples.count / 16_000) s of audio, \(segs.count) segments, \(lang), \(Int(Date().timeIntervalSince(t0))) s to transcribe")
      results.append(.init(who: who, offset: offset, segments: segs))
      done = true
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
  }
  let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
  let start = val("--start").flatMap { f.date(from: $0) } ?? Date()
  let text = Notes.transcript(results)
  let title = val("--title") ?? "Call"
  let header = "# \(title)\n\ndate: \(f.string(from: start)), \(minutes) min\nparticipants: \(tracks.map(\.0).joined(separator: ", "))\nsource: Brain, from files\n\n## Transcript\n\n"
  if let out = val("--out") { try? (header + text + "\n").write(toFile: out, atomically: true, encoding: .utf8); print("wrote \(out)") }
  w.close()
  exit(0)
}

func readWav16k(_ path: String) -> [Float]? {
  guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return nil }
  let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
  guard let conv = AVAudioConverter(from: file.processingFormat, to: target),
        let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
        (try? file.read(into: inBuf)) != nil else { return nil }
  let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16_000 / file.processingFormat.sampleRate) + 64
  guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
  var fed = false
  _ = conv.convert(to: out, error: nil) { _, st in
    if fed { st.pointee = .endOfStream; return nil }
    fed = true; st.pointee = .haveData; return inBuf
  }
  return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--test-command") {
  DistributedNotificationCenter.default().postNotificationName(.init(Config.bundleID + ".test-command"),
    object: i + 1 < args.count ? args[i + 1] : "fix the grammar", userInfo: nil, deliverImmediately: true)
  exit(0)
} else if args.contains("--selection") {
  // `Brain --selection`: what Accessibility says about the selection in the front app
  let app = NSWorkspace.shared.frontmostApplication
  switch Selection.read() {
  case .text(let t): print("\(app?.localizedName ?? "?"): selected \(t.count) characters")
  case .none: print("\(app?.localizedName ?? "?"): answers, nothing selected")
  case .unknown: print("\(app?.localizedName ?? "?"): does not say, the app will copy instead")
  }
  exit(0)
} else if args.contains("--audio-procs") {
  // `Brain --audio-procs`: every process CoreAudio knows, its bundle id and whether it takes input
  MainActor.assumeIsolated {
    for line in CallWatch.allAudioProcesses() { print(line) }
  }
} else if args.contains("--mic-test") {
  // `Brain --mic-test`: a take without the key. The mic opens the way a take does, listens 2 s and
  // prints the device, the buffers and the peak; nothing is kept.
  let m = Mic()
  var buffers = 0
  m.onBuffer = { _ in buffers += 1 }
  m.start { error in if let error { print("mic: could not start: \(error)"); exit(1) } }
  RunLoop.main.run(until: Date().addingTimeInterval(2))
  let n = m.stop().count
  print("mic test: \(m.deviceName), \(buffers) buffers, \(String(format: "%.1f", Double(n) / 16_000)) s heard, peak \(String(format: "%.4f", m.peakSample)), lost \(m.lostDuringTake)")
  exit(n > 8_000 ? 0 : 2)
} else if args.contains("--mic-users") {
  // `Brain --mic-users`: every app taking the microphone now, one per line, or "none"
  MainActor.assumeIsolated {
    let users = CallWatch.anyHoldingMic() + Busy.now().map { "Brain: \($0)" }
    print(users.isEmpty ? "none" : users.joined(separator: "\n"))
  }
} else if args.contains("--agenda") {
  // `Brain --agenda`: the calendar as the app sees it, yesterday to tomorrow
  let f = DateFormatter(); f.dateFormat = "EEE d MMM HH:mm"
  for e in Agenda.events(from: Date().addingTimeInterval(-86_400), to: Date().addingTimeInterval(86_400)) {
    print("\(f.string(from: e.start))  \(e.title)  with \(e.names.joined(separator: ", "))  -> \(Agenda.who(e))")
  }
  print("now: \(Agenda.current().map(\.title) ?? "no event")")
  exit(0)
} else if args.contains("--meeting") {
  runMeeting(args)
} else if let i = args.firstIndex(of: "--clean"), i + 1 < args.count {
  // `Brain --clean "text" [bundle id]`: the clean-up rules alone, for testing
  print(Cleaner.clean(args[i + 1], bundle: i + 2 < args.count ? args[i + 2] : ""))
  exit(0)
} else if let i = args.firstIndex(of: "--files"), i + 1 < args.count {
  runFiles(Array(args[(i + 1)...]))
} else if let i = args.firstIndex(of: "--file"), i + 1 < args.count {
  runFile(args[i + 1])
} else {
  MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }
}
