import AppKit
import Combine
import SwiftUI


struct TraceStep: Identifiable, Equatable {
  let id = UUID()
  var kind: String          // think, search, read, cal, done
  var text: String          // **bold** marks the thing it looked at
  var chips: [Chip] = []
  struct Chip: Equatable, Hashable { var text: String; var kind: String }   // person, meet, proj, ledger, cal, count
}

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

struct LiveLine: Identifiable, Equatable { let id = UUID(); var en: String; var at: Date }

/// One question and its answer, earlier in the conversation.
struct Turn: Identifiable, Equatable {
  let id = UUID()
  let q: String
  let at: Date
  let seconds: Int
  let data: Answer
}

enum NowItem: Equatable {
  case empty
  case thinking(q: String, since: Date, steps: [TraceStep])
  case answer(q: String, at: Date, seconds: Int, steps: [TraceStep], data: Answer)
  case prep(title: String, at: Date, raw: String, ready: Bool)
  case live(title: String, since: Date, lines: [LiveLine])

  /// which state, for animating a change of state (not every new line or step)
  var kind: String {
    switch self {
    case .empty: return "empty"
    case .thinking(let q, _, _): return "thinking \(q)"
    case .answer(let q, let at, _, _, _): return "answer \(q) \(at.timeIntervalSince1970)"
    case .prep(let t, _, _, let ready): return "prep \(t) \(ready)"
    case .live(let t, _, _): return "live \(t)"
    }
  }
}

struct HistoryItem: Codable, Identifiable, Equatable {
  var id = UUID()
  var q: String
  var at: Date
  var head: String
  var raw: String
  var seconds: Int
}

@MainActor
final class PanelModel: ObservableObject {
  enum Tab: String, CaseIterable { case now = "Now", history = "History", settings = "Settings" }
  @Published var tab: Tab = .now {
    didSet { if let a = Tab.allCases.firstIndex(of: oldValue), let b = Tab.allCases.firstIndex(of: tab), a != b { tabDir = b > a ? 1 : -1 } }
  }
  /// which way the last tab change went, so the content comes in from that side
  var tabDir: CGFloat = 1

  @Published var earlier: [Turn] = []
  /// the brain keys are held while the panel is open: the ask field listens, the notch stays quiet
  @Published var listening = false
  /// a follow-up being written down
  @Published var writing = false
  @Published var levels: [CGFloat] = Array(repeating: 0.15, count: 7)
  var onNew: (() -> Void)?
  var onDrag: ((DragPhase) -> Void)?
  func push(level: Float) {
    levels.removeFirst()
    levels.append(CGFloat(max(0.15, level)))
  }
  var hasAnswer: Bool { if case .answer = now { return true }; return false }
  /// the last three turns as text, for the brain to read a follow-up in their light
  var context: String {
    var turns = earlier.suffix(2).map { ($0.q, $0.data) }
    if case .answer(let q, _, _, _, let d) = now { turns.append((q, d)) }
    return turns.suffix(3).map { q, d in
      var t = "Q: \(q)\nA: \(d.kind == "none" ? "nothing found. " + d.none : d.head)"
      if !d.note.isEmpty { t += "\n" + d.note }
      for r in d.rows.prefix(6) { t += "\n- \(r.text)" + (r.when.isEmpty ? "" : " (\(r.when), \(r.state))") }
      return t
    }.joined(separator: "\n\n")
  }
  @Published var now: NowItem = .empty
  @Published var history: [HistoryItem] = []
  @Published var pinned = false
  @Published var traceOpen = false
  @Published var query = ""
  @Published var search = ""
  @Published var warm = false

  var onAsk: ((String) -> Void)?
  var onOpen: ((String) -> Void)?
  var onStopCall: (() -> Void)?
  var onWarm: ((Bool) -> Void)?
  var onClose: (() -> Void)?
  var onFold: (() -> Void)?

  static let historyFile = History.root.deletingLastPathComponent().appendingPathComponent("brain/history.jsonl")

  init() { loadHistory() }

  func loadHistory() {
    guard let text = try? String(contentsOf: Self.historyFile, encoding: .utf8) else { return }
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    history = text.split(separator: "\n").compactMap { try? dec.decode(HistoryItem.self, from: Data($0.utf8)) }.reversed()
  }

  func remember(_ item: HistoryItem) {
    history.insert(item, at: 0)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    guard var line = try? enc.encode(item) else { return }
    line.append(0x0A)
    try? FileManager.default.createDirectory(at: Self.historyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let h = try? FileHandle(forWritingTo: Self.historyFile) { h.seekToEndOfFile(); h.write(line); try? h.close() }
    else { try? line.write(to: Self.historyFile) }
  }
}


struct PanelView: View {
  @ObservedObject var m: PanelModel
  @ObservedObject var tune = Tune.shared
  let maxBody: CGFloat
  /// room around the rim for its shadow: 16 aside and below, 8 on top
  static let margin = CGSize(width: 16, height: 8)

  var body: some View {
    Group {
      switch S.look {
      case "glass", "smoke": glassPanel
      case "float": floatPanel
      case "cc": ccPanel.id(tune.key)
      default: rimPanel
      }
    }
    .padding(.horizontal, PanelView.margin.width).padding(.top, PanelView.margin.height).padding(.bottom, PanelView.margin.width + 10)
    .frame(maxHeight: .infinity, alignment: .top)
    .font(S.body).foregroundStyle(S.ink1)
    .onExitCommand { m.onFold?() }
  }

  private var content: some View {
    Group {
      switch m.tab {
      case .now: NowView(m: m)
      case .history: HistoryView(m: m)
      case .settings: SettingsView(m: m)
      }
    }
    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var scroll: some View {
    ScrollView { content }
      .scrollBounceBehavior(.basedOnSize)
      .scrollIndicators(.never)
      .frame(maxHeight: maxBody)
      .fixedSize(horizontal: false, vertical: true)
  }

  private var stacked: some View {
    VStack(spacing: 0) {
      head
      Rectangle().fill(S.lineFaint).frame(height: 1)
      scroll
      if m.tab != .settings {
        Rectangle().fill(S.lineFaint).frame(height: 1)
        AskField(m: m).padding(12)
      }
    }
  }

  private var rimPanel: some View {
    stacked
      .frame(width: 368)
      .background(S.sheet, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(S.line, lineWidth: 1))
      .padding(6)
      .glassEffect(.regular, in: .rect(cornerRadius: 19))
      .background(RimShadow(radius: 19))
  }

  /// B and C: all glass, Apple's popover and sidebar look; smoke is tinted dark like the notch
  private var glassPanel: some View {
    stacked
      .frame(width: 380)
      .glassEffect(S.look == "smoke" ? .regular.tint(Color.black.opacity(0.42)) : .regular, in: .rect(cornerRadius: 18))
      .background(RimShadow(radius: 18))
  }

  private var floatPanel: some View {
    ScrollView { content.padding(.top, 50).padding(.bottom, m.tab == .settings ? 0 : 52) }
      .scrollBounceBehavior(.basedOnSize)
      .scrollIndicators(.never)
      .frame(maxHeight: maxBody + 102)
      .fixedSize(horizontal: false, vertical: true)
      .overlay(alignment: .top) { floatHead }
      .overlay(alignment: .bottom) {
        if m.tab != .settings { AskField(m: m, capsule: true).padding(10) }
      }
      .frame(width: 380)
      .background(S.sheet, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(S.line, lineWidth: 1))
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .background(RimShadow(radius: 18))
  }

  private var floatHead: some View {
    GlassEffectContainer(spacing: 8) {
      HStack(spacing: 8) {
        HStack(spacing: 2) {
          // the mark is a handle too: it carries the panel off the notch and home again
          BrainMark(size: 15).frame(width: 28, height: 28).overlay(DragArea { m.onDrag?($0) })
          STabs(items: PanelModel.Tab.allCases.map { ($0, $0.rawValue) }, selected: $m.tab, pill: true)
        }
        .padding(4)
        .glassEffect(Tune.shared.glass, in: .capsule)
        Spacer(minLength: 0)
        HStack(spacing: 2) {
          if m.hasAnswer || !m.earlier.isEmpty {
            SIconButton(symbol: "square.and.pencil", help: "New question", round: true) { m.onNew?() }
              .transition(.scale(scale: 0.6).combined(with: .opacity))
          }
          SIconButton(symbol: m.pinned ? "pin.fill" : "pin", help: m.pinned ? "Pinned: stays open" : "Pin", on: m.pinned, round: true) { m.pinned.toggle() }
          SIconButton(symbol: "minus", help: "Minimize", round: true) { m.onFold?() }
          SIconButton(symbol: "xmark", help: "Close", round: true) { m.onClose?() }
        }
        .padding(4)
        .glassEffect(Tune.shared.glass, in: .capsule)
      }
      .background(DragArea { m.onDrag?($0) })
    }
    .padding(8)
  }

  private var ccPanel: some View {
    Group {
      VStack(alignment: .leading, spacing: tune.layout == "slab" ? 10 : tune.gap) {
        floatHead.padding(-8)
        Group {
          if tune.layout == "slab" {
            ScrollViewReader { proxy in
              ScrollView { CCBody(m: m).padding(tune.pad) }
                .scrollBounceBehavior(.basedOnSize).scrollIndicators(.never)
                .onChange(of: m.now.kind) { _, _ in
                  guard !m.earlier.isEmpty else { return }
                  withAnimation(Motion.slide) { proxy.scrollTo("current", anchor: .top) }
                }
            }
            .frame(maxHeight: maxBody).fixedSize(horizontal: false, vertical: true)
              .modifier(OneFrame(t: tune))
          } else {
            ScrollView {
              CCBody(m: m).padding(4)
            }
            .padding(-4)   // room for the glass edges inside the scroll's clip, without moving the tiles
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.never)
            .frame(maxHeight: maxBody)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
        if m.tab != .settings { AskField(m: m, capsule: true).transition(.opacity) }
        Grabber(drag: { m.onDrag?($0) }).frame(maxWidth: .infinity).padding(.top, -4)
      }
    }
    .frame(width: tune.width)
    // on the whole panel, so the frame's height eases with the content, whoever changed it
    .animation(Motion.slide, value: m.tab)
    .animation(Motion.slide, value: m.now.kind)
  }

  private var head: some View {
    HStack(spacing: 6) {
      BrainMark(size: 16)
      Text("Brain").font(S.font(13, .semibold)).fixedSize().padding(.trailing, 2)
      STabs(items: PanelModel.Tab.allCases.map { ($0, $0.rawValue) }, selected: $m.tab)
      Spacer(minLength: 0)
      SIconButton(symbol: m.pinned ? "pin.fill" : "pin", help: m.pinned ? "Pinned: stays open" : "Pin", on: m.pinned) { m.pinned.toggle() }
      SIconButton(symbol: "sidebar.right", help: "Fold to the edge") { m.onFold?() }
      SIconButton(symbol: "xmark", help: "Close") { m.onClose?() }
    }
    .padding(.leading, 12).padding(.trailing, 8).frame(height: 44)
  }
}

struct AskField: View {
  @ObservedObject var m: PanelModel
  var capsule = false
  @FocusState private var focused: Bool
  var body: some View {
    if capsule {
      field.padding(.leading, 14).padding(.trailing, 10).frame(height: 40)
        .glassEffect(Tune.shared.glass, in: .capsule)
    } else {
      field.padding(.leading, 10).padding(.trailing, 6).frame(height: 32)
        .background(S.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(focused ? S.ink3 : S.line, lineWidth: 1))
    }
  }

  private var field: some View {
    HStack(spacing: 8) {
      if m.listening {
        // the keys are held: this is where the follow-up goes, so this is where it listens
        Wave(levels: m.levels, live: !Motion.reduce).foregroundStyle(S.brand)
        Text("Listening").font(S.body).foregroundStyle(S.ink2)
        Spacer(minLength: 0)
      } else if m.writing {
        BrainMark(size: 13, live: true)
        Text("Writing it down").font(S.body).foregroundStyle(S.ink2)
        Spacer(minLength: 0)
      } else {
        Image(systemName: "mic").font(.system(size: 13)).foregroundStyle(S.ink2)
        TextField("", text: $m.query, prompt: Text(m.hasAnswer ? "Ask a follow-up" : "Ask the brain").foregroundStyle(S.ink3))
          .textFieldStyle(.plain).font(S.body).focused($focused)
          .onSubmit { let q = m.query.trimmingCharacters(in: .whitespaces); if !q.isEmpty { m.query = ""; m.onAsk?(q) } }
      }
      SKeys(keys: ["⌘", "⌥"], pill: capsule)
    }
    .animation(Motion.hover, value: m.listening)
    .animation(Motion.hover, value: m.writing)
  }
}

struct RimShadow: View {
  let radius: CGFloat
  var strength = 1.0
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    shape.fill(Color.black)
      .shadow(color: .black.opacity((scheme == .dark ? 0.45 : 0.16) * strength), radius: 14, y: 6)
      .shadow(color: .black.opacity((scheme == .dark ? 0.3 : 0.06) * strength), radius: 1.5, y: 0.5)
      .padding(-0.5)
      .mask {
        Rectangle().padding(-40).overlay(shape.blendMode(.destinationOut)).compositingGroup()
      }
      .allowsHitTesting(false)
  }
}

// MARK: E, Control Center's modules

/// The bar under the panel that moves it: faint at rest, brighter under the pointer, wide enough
/// to find without looking.
struct Grabber: View {
  let drag: (DragPhase) -> Void
  @State private var hover = false
  var body: some View {
    Capsule().fill(Color.white.opacity(hover ? 0.75 : 0.45))
      .padding(1.5)
      .frame(width: hover ? 56 : 44, height: 7)
      .glassEffect(Tune.shared.glass, in: .capsule)
      .frame(width: 110, height: 18)
      .contentShape(Rectangle())
      .overlay(DragArea(on: drag))
      .onHover { h in withAnimation(Motion.hover) { hover = h } }
      .help("Drag to move; near the notch it docks")
  }
}

struct OneFrame: ViewModifier {
  let t: Tune
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: t.radius, style: .continuous)
    if t.frame == "solid" {
      content
        .background(S.solidSheet, in: shape)
        .overlay(shape.strokeBorder(S.line, lineWidth: 1))
        .background(RimShadow(radius: t.radius, strength: max(0.6, t.shadow)))
    } else {
      content
        .background(shape.fill(Color.black.opacity(t.dim)))
        .glassEffect(t.glass, in: .rect(cornerRadius: t.radius))
        .background(RimShadow(radius: t.radius, strength: t.shadow))
    }
  }
}

/// One module: Control Center's corner, regular glass, room inside.
struct CCTile<C: View>: View {
  var padding: CGFloat? = nil
  @ViewBuilder let content: () -> C
  var body: some View {
    let t = Tune.shared
    if t.layout == "slab" {
      // inside the one slab: sections, no glass of their own
      content().frame(maxWidth: .infinity, alignment: .leading)
    } else {
      content()
        .padding(padding.map { $0 * t.pad / 14 } ?? t.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: t.radius, style: .continuous).fill(Color.black.opacity(t.dim)))
        .glassEffect(t.glass, in: .rect(cornerRadius: t.radius))
        .background(RimShadow(radius: t.radius, strength: t.shadow))
    }
  }
}

struct CCBody: View {
  @ObservedObject var m: PanelModel
  var body: some View {
    // one layer per tab: the new one comes in from the side of the tab, the old fades in place
    ZStack(alignment: .topLeading) {
      page.id(m.tab).transition(.tabSwitch(m.tabDir))
    }
  }

  private var page: some View {
    VStack(alignment: .leading, spacing: Tune.shared.layout == "slab" ? 18 : Tune.shared.gap) {
      switch m.tab {
      case .history: CCTile { HistoryView(m: m) }
      case .settings: CCSettings(m: m)
      case .now:
        ForEach(m.earlier) { t in
          EarlierTurn(turn: t, open: { m.onOpen?($0) })
        }
        Group {
        switch m.now {
        case .empty:
          CCTile {
            VStack(alignment: .leading, spacing: 4) {
              Text("Nothing open").font(S.title)
              Text("Hold \(Keys.askLabel) to ask, or type below.").foregroundStyle(S.ink2)
            }
          }
        case .thinking(let q, let since, let steps):
          CCTile {
            VStack(alignment: .leading, spacing: 14) {
              Asked(text: q, when: since)
              Trace(steps: steps, live: true, since: since, seconds: 0, open: true) {}
            }
          }
        case .answer(let q, let at, let secs, let steps, let data):
          CCTile {
            VStack(alignment: .leading, spacing: 12) {
              Asked(text: q, when: at)
              if !steps.isEmpty {
                Trace(steps: steps + [TraceStep(kind: "done", text: "Done")], live: false, since: at, seconds: secs, open: m.traceOpen) { m.traceOpen.toggle() }
              }
              VStack(alignment: .leading, spacing: 4) {
                Text(data.kind == "none" ? "Not in the brain" : data.kind == "error" ? "The brain did not answer" : data.head)
                  .font(S.answer).fixedSize(horizontal: false, vertical: true)
                let note = data.kind == "none" ? data.none : data.note
                if !note.isEmpty { Text(note).foregroundStyle(S.ink2).fixedSize(horizontal: false, vertical: true) }
              }
            }
          }
          ForEach(Array(AnswerView.groups(data.rows).enumerated()), id: \.element.0) { i, g in
            CCTile(padding: 12) {
              RowGroup(label: g.0, rows: g.1, open: { m.onOpen?($0) }).padding(.top, -12)
            }
            .modifier(Rise(delay: 0.06 + Double(i) * 0.05))   // the groups arrive one after another
          }
        case .prep(let title, let at, let raw, let ready):
          CCTile { PrepView(title: title, at: at, raw: raw, ready: ready, open: { m.onOpen?($0) }) }
        case .live(let title, let since, let lines):
          CCTile { LiveView(title: title, since: since, lines: lines, stop: { m.onStopCall?() }) }
        }
        }
        .id("current")   // a new turn scrolls itself to the top
      }
    }
  }
}

/// An earlier turn of the conversation: the question and the answer's line; its items fold away
/// behind a count, so the thread stays short and the newest turn leads.
struct EarlierTurn: View {
  let turn: Turn
  let open: (String) -> Void
  @State private var expanded = false
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      CCTile {
        VStack(alignment: .leading, spacing: 6) {
          Asked(text: turn.q, when: turn.at)
          Text(turn.data.kind == "none" ? "Not in the brain" : turn.data.head)
            .font(S.font(14, .semibold)).foregroundStyle(S.ink1).fixedSize(horizontal: false, vertical: true)
          if !turn.data.rows.isEmpty {
            Button { withAnimation(Motion.slide) { expanded.toggle() } } label: {
              HStack(spacing: 4) {
                Text(expanded ? "Hide" : "\(turn.data.rows.count) item\(turn.data.rows.count == 1 ? "" : "s")")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 180 : 0))
              }
              .font(S.meta).foregroundStyle(S.ink2).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
              ForEach(AnswerView.groups(turn.data.rows), id: \.0) { label, rows in
                RowGroup(label: label, rows: rows, open: open)
              }
              .transition(.opacity)
            }
          }
        }
      }
      if Tune.shared.layout == "slab" {
        Rectangle().fill(S.lineFaint).frame(height: 1).padding(.top, 16)
      }
    }
  }
}

/// Settings as Control Center: a module per switch, the round button white when on.
struct CCSettings: View {
  @ObservedObject var m: PanelModel
  @AppStorage("musicMode") private var music = "down"
  @AppStorage("recordCalls") private var recordCalls = true

  var body: some View {
    let g = Tune.shared.layout == "slab" ? 10 : Tune.shared.gap
    VStack(alignment: .leading, spacing: g) {
      HStack(spacing: g) {
        CCToggle(symbol: "mic.fill", title: "Mic warm", on: Binding(get: { m.warm }, set: { m.onWarm?($0) }))
        CCToggle(symbol: "record.circle", title: "Record calls", on: $recordCalls)
      }
      HStack(spacing: g) {
        CCToggle(symbol: "speaker.wave.1.fill", title: "Music down", on: Binding(get: { music == "down" }, set: { music = $0 ? "down" : "leave" }))
        Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
      }
      CCTile { ShortcutRows() }
    }
  }
}

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

struct ShortcutRows: View {
  @StateObject private var rec = KeyRecorder()
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Shortcut.allCases, id: \.self) { s in
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 1) {
            Text(s.title).font(S.font(13, .medium)).foregroundStyle(S.ink1)
            Text(rec.listening == s && !rec.note.isEmpty ? rec.note : s.how).font(S.meta)
              .foregroundStyle(rec.listening == s && !rec.note.isEmpty ? S.ink1 : S.ink2)
          }
          Spacer(minLength: 8)
          if s.canBeNone, s.code != -1, rec.listening != s {
            Button { rec.set(s, -1) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(S.ink2).frame(width: 20, height: 20) }
              .buttonStyle(.plain).help("No shortcut").accessibilityLabel("Remove the \(s.title) shortcut")
          }
          Button { rec.listening == s ? rec.stop() : rec.start(s) } label: {
            if rec.listening == s {
              Text("Press a key").font(S.font(12, .semibold)).foregroundStyle(S.ink1)
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(S.fillSelected))
                .overlay(Capsule().strokeBorder(S.ink2, lineWidth: 1))
            } else {
              SKeys(keys: [s.label])
            }
          }
          .buttonStyle(.plain)
          .help(rec.listening == s ? "Press the key you want, Esc to keep it" : "Click, then press the key you want")
          .accessibilityLabel(rec.listening == s ? "Listening for a key for \(s.title)" : "\(s.title) shortcut, \(s.label). Click to change")
        }
      }
      Text(rec.listening == nil ? "Click a key to change it." : "Press the key you want. Esc keeps it as it is.")
        .font(S.meta).foregroundStyle(S.ink3)
    }
    .onDisappear { if rec.listening != nil { rec.stop() } }
  }
}

extension Notification.Name { static let shortcutsChanged = Notification.Name("brain.shortcutsChanged") }

/// Control Center's wide module: a round button, the name, its state.
struct CCToggle: View {
  let symbol: String
  let title: String
  @Binding var on: Bool
  var body: some View {
    Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { on.toggle() } } label: {
      let slab = Tune.shared.layout == "slab"
      HStack(spacing: slab ? 8 : 10) {
        Image(systemName: symbol).font(.system(size: 15, weight: .medium))
          .foregroundStyle(on ? AnyShapeStyle(Tune.shared.onGlyph) : S.ink1)
          .frame(width: slab ? 34 : 38, height: slab ? 34 : 38)
          .background(Circle().fill(on ? AnyShapeStyle(Tune.shared.onFill) : S.fillSelected))
          .symbolEffect(.bounce, options: .speed(1.4), value: on)
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(S.font(13, .semibold)).foregroundStyle(S.ink1).lineLimit(1)
          Text(on ? "On" : "Off").font(S.meta).foregroundStyle(S.ink2)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, slab ? 10 : 12).frame(height: slab ? 56 : 64)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .modifier(ToggleSurface())
  }
}

/// a toggle on its own glass among tiles; inside the one frame, a quiet plate (no glass on glass)
struct ToggleSurface: ViewModifier {
  func body(content: Content) -> some View {
    let t = Tune.shared
    if t.layout == "slab" {
      // a pill: the round button sits 11 in, so the plate's ends are concentric with it
      content.background(S.fillQuiet, in: Capsule())
    } else {
      content
        .background(RoundedRectangle(cornerRadius: t.radius, style: .continuous).fill(Color.black.opacity(t.dim)))
        .glassEffect(t.glass, in: .rect(cornerRadius: t.radius))
    }
  }
}

// MARK: Now

struct NowView: View {
  @ObservedObject var m: PanelModel
  var body: some View {
    switch m.now {
    case .empty:
      VStack(alignment: .leading, spacing: 4) {
        Text("Nothing open").font(S.title)
        Text("Hold \(Keys.askLabel) to ask, or type below. Answers, the prep before a call and the live call open here.")
          .foregroundStyle(S.ink2).fixedSize(horizontal: false, vertical: true)
      }
    case .thinking(let q, let since, let steps):
      VStack(alignment: .leading, spacing: 14) {
        Asked(text: q, when: since)
        Trace(steps: steps, live: true, since: since, seconds: 0, open: true) {}
      }
    case .answer(let q, let at, let secs, let steps, let data):
      VStack(alignment: .leading, spacing: 14) {
        Asked(text: q, when: at)
        if !steps.isEmpty {
          Trace(steps: steps + [TraceStep(kind: "done", text: "Done")], live: false, since: at, seconds: secs, open: m.traceOpen) { m.traceOpen.toggle() }
        }
        AnswerView(data: data, open: { m.onOpen?($0) })
      }
    case .prep(let title, let at, let raw, let ready):
      PrepView(title: title, at: at, raw: raw, ready: ready, open: { m.onOpen?($0) })
    case .live(let title, let since, let lines):
      LiveView(title: title, since: since, lines: lines, stop: { m.onStopCall?() })
    }
  }
}

struct Asked: View {
  let text: String
  let when: Date
  var label = "You asked"
  var symbol = "mic"
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 5) {
        Image(systemName: symbol).font(.system(size: 10))
        Text("\(label) · \(IslandView.hhmm(when))")
      }
      .font(S.meta).foregroundStyle(S.ink2)
      Text(text).font(S.font(13, .medium)).fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct Trace: View {
  let steps: [TraceStep]
  let live: Bool
  let since: Date
  let seconds: Int
  let open: Bool
  let toggle: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: toggle) {
        HStack(spacing: 8) {
          BrainMark(size: 14, live: live).frame(width: 16)
          if live {
            TimelineView(.periodic(from: since, by: 1)) { ctx in
              HStack(spacing: 6) {
                Text("Thinking").font(S.font(13, .medium)).foregroundStyle(S.ink1)
                Text("\(Int(ctx.date.timeIntervalSince(since))) s").font(S.meta).monospacedDigit().foregroundStyle(S.ink2)
              }
            }
          } else {
            let n = steps.filter { $0.kind == "read" || $0.kind == "search" }.count
            Text("Read \(n) source\(n == 1 ? "" : "s") in \(seconds) s").font(S.meta).foregroundStyle(S.ink2)
            Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(S.ink3)
          }
        }
        .frame(height: 20).contentShape(Rectangle())
      }
      .buttonStyle(.plain).allowsHitTesting(!live)
      if live || open {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(steps.enumerated()), id: \.element.id) { i, st in
            StepRow(step: st, current: live && i == steps.count - 1, last: i == steps.count - 1)
              .modifier(Rise(delay: live ? 0 : Double(i) * 0.03, y: 4))
          }
        }
        .padding(.top, 8)
        .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.18), value: steps.count)
    .animation(.easeOut(duration: 0.18), value: open)
  }
}

struct StepRow: View {
  let step: TraceStep
  let current: Bool
  let last: Bool
  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      ZStack(alignment: .top) {
        if !last { Rectangle().fill(S.line).frame(width: 1).padding(.top, 18).frame(maxHeight: .infinity) }
        Group {
          if step.kind == "think" {
            Circle().fill(S.ink3).frame(width: 4, height: 4)
          } else {
            Image(systemName: Self.symbol(step.kind)).font(.system(size: 11)).foregroundStyle(step.kind == "done" ? AnyShapeStyle(S.ok) : S.ink2)
          }
        }
        .frame(width: 16, height: 18)
      }
      .frame(width: 16)
      VStack(alignment: .leading, spacing: 6) {
        Text(Self.rich(step.text)).font(S.body).foregroundStyle(step.kind == "think" ? S.ink2 : S.ink1)
          .opacity(current ? 0.6 : 1).fixedSize(horizontal: false, vertical: true)
        if !step.chips.isEmpty { Chips(chips: step.chips) }
      }
      .padding(.bottom, 10)
    }
  }
  static func symbol(_ k: String) -> String {
    switch k { case "search": return "magnifyingglass"; case "read": return "doc.text"; case "cal": return "calendar"; case "done": return "checkmark.circle"; default: return "circle" }
  }
  static func rich(_ s: String) -> AttributedString {
    var a = (try? AttributedString(markdown: s)) ?? AttributedString(s)
    for run in a.runs where run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
      a[run.range].font = S.font(13, .medium)
    }
    return a
  }
}

struct Chips: View {
  let chips: [TraceStep.Chip]
  var body: some View {
    HStack(spacing: 6) {
      ForEach(chips.prefix(3), id: \.self) { c in
        if c.kind == "count" { STag(text: c.text) } else { STag(text: c.text, badge: Self.initials(c), tint: Self.tint(c.kind)) }
      }
      if chips.count > 3 { STag(text: "\(chips.count - 3) more") }
    }
  }
  static func tint(_ k: String) -> Color {
    switch k {
    case "person": return Color(white: 0.45)
    case "meet": return Color(red: 0.18, green: 0.44, blue: 0.37)
    case "proj": return Color(red: 0.31, green: 0.27, blue: 0.9)
    case "cal": return Color(red: 0.9, green: 0.33, blue: 0.1)
    default: return Color(white: 0.12)
    }
  }
  static func initials(_ c: TraceStep.Chip) -> String {
    switch c.kind {
    case "ledger": return "L"
    case "meet": return "M"
    case "cal": return "C"
    default: return c.text.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
  }
}

struct AnswerView: View {
  let data: Answer
  let open: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      switch data.kind {
      case "none":
        Text("Not in the brain").font(S.title)
        Text(data.none.isEmpty ? "Nothing matched." : data.none).foregroundStyle(S.ink2).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
      case "error":
        Text("The brain did not answer").font(S.title)
        Text(data.head.isEmpty ? "Try again in a moment." : data.head).foregroundStyle(S.ink2).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
      default:
        if !data.head.isEmpty { Text(data.head).font(S.answer).fixedSize(horizontal: false, vertical: true) }
        if !data.note.isEmpty { Text(data.note).foregroundStyle(S.ink2).fixedSize(horizontal: false, vertical: true).padding(.top, 4) }
        ForEach(Self.groups(data.rows), id: \.0) { label, rows in
          RowGroup(label: label, rows: rows, open: open)
        }
      }
    }
  }

  /// Groups in a fixed order: overdue, due, open, details, done
  static func groups(_ rows: [Card.Row]) -> [(String, [Card.Row])] {
    let order: [(String, String)] = [("overdue", "Overdue"), ("due", "Due soon"), ("open", "Open"), ("info", "Details"), ("done", "Done")]
    var out: [(String, [Card.Row])] = []
    for (state, label) in order {
      let g = rows.filter { ($0.state.isEmpty ? "info" : $0.state) == state }
      if !g.isEmpty { out.append((label, Array(g.prefix(6)))) }
    }
    return out
  }
}

struct RowGroup: View {
  let label: String
  let rows: [Card.Row]
  let open: (String) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SSecHead(label: label, count: rows.count)
      ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
        SRow(lead: AnyView(SMark(state: SMark.of(r.state))), title: r.text, sub: r.source, meta: r.when, strong: r.state == "overdue") { open(r.file) }
      }
    }
  }
}

// MARK: prep, live call

struct PrepView: View {
  let title: String
  let at: Date
  let raw: String
  let ready: Bool
  let open: (String) -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Asked(text: title, when: at, label: "Next call", symbol: "calendar")
      if !ready {
        HStack(spacing: 8) { BrainMark(size: 14, live: true).frame(width: 16); Text("Reading the brain for this call").foregroundStyle(S.ink2) }
      } else {
        VStack(alignment: .leading, spacing: 0) {
          Text(Brain.lines(raw, "HEAD").first?.0 ?? title).font(S.answer).fixedSize(horizontal: false, vertical: true)
          let owe = Brain.lines(raw, "OWE")
          let mine = owe.filter { $0.1.lowercased().hasPrefix("you") }
          let theirs = owe.filter { !$0.1.lowercased().hasPrefix("you") }
          if !mine.isEmpty { RowGroup(label: "You owe", rows: mine.map { Card.Row(text: $0.0, when: "", state: "open", source: "", file: "commitments.md") }, open: open) }
          if !theirs.isEmpty { RowGroup(label: theirs.first?.1 ?? "They owe", rows: theirs.map { Card.Row(text: $0.0, when: "", state: "open", source: "", file: "commitments.md") }, open: open) }
          let asks = Brain.lines(raw, "ASK")
          if !asks.isEmpty {
            SSecHead(label: "Ask")
            ForEach(Array(asks.enumerated()), id: \.offset) { _, a in
              SRow(lead: AnyView(Image(systemName: "questionmark.bubble").font(.system(size: 11)).foregroundStyle(S.ink2)), title: a.0) {}
            }
          }
          if let page = Brain.lines(raw, "PAGE").first?.0, page.hasSuffix(".md") {
            SButton(label: "Open the page") { open(page) }.padding(.top, 12)
          }
        }
      }
    }
  }
}

struct LiveView: View {
  let title: String
  let since: Date
  let lines: [LiveLine]
  let stop: () -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Circle().fill(Color(red: 0.94, green: 0.27, blue: 0.27)).frame(width: 7, height: 7).frame(width: 16)
        Text(title).font(S.font(13, .medium)).lineLimit(1)
        Spacer()
        TimelineView(.periodic(from: since, by: 1)) { ctx in
          Text(IslandView.clock(ctx.date.timeIntervalSince(since))).font(S.meta).monospacedDigit().foregroundStyle(S.ink2)
        }
      }
      .frame(height: 20)
      if !lines.isEmpty {
        SSecHead(label: "Live", count: lines.count)
        ForEach(lines.suffix(12)) { l in
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(IslandView.hhmm(l.at)).font(S.meta).monospacedDigit().foregroundStyle(S.ink3).frame(width: 34, alignment: .leading)
            Text(l.en).fixedSize(horizontal: false, vertical: true)
          }
          .padding(.vertical, 5)
        }
      }
      SButton(label: "Stop recording", action: stop).padding(.top, 12)
    }
  }
}

// MARK: history, settings

struct HistoryView: View {
  @ObservedObject var m: PanelModel
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(S.ink2)
        TextField("", text: $m.search, prompt: Text("Search what you asked").foregroundStyle(S.ink3)).textFieldStyle(.plain).font(S.body)
      }
      .padding(.horizontal, 10).frame(height: 32)
      .background(S.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(S.line, lineWidth: 1))
      let items = m.history.filter { m.search.isEmpty || $0.q.localizedCaseInsensitiveContains(m.search) || $0.head.localizedCaseInsensitiveContains(m.search) }
      if items.isEmpty {
        Text(m.history.isEmpty ? "Nothing asked yet." : "Nothing matches.").foregroundStyle(S.ink2).padding(.top, 14)
      }
      ForEach(Self.days(items), id: \.0) { day, list in
        SSecHead(label: day, count: list.count)
        ForEach(list) { h in
          SRow(lead: AnyView(Image(systemName: "mic").font(.system(size: 12)).foregroundStyle(S.ink2)), title: h.q,
               sub: h.head.isEmpty ? "No answer" : h.head, meta: IslandView.hhmm(h.at)) {
            m.earlier = []
            m.now = .answer(q: h.q, at: h.at, seconds: h.seconds, steps: [], data: Answer(h.raw))
            m.traceOpen = false
            m.tab = .now
          }
        }
      }
    }
  }
  static func days(_ items: [HistoryItem]) -> [(String, [HistoryItem])] {
    let cal = Calendar.current
    let f = DateFormatter(); f.dateFormat = "EEE d MMM"
    var out: [(String, [HistoryItem])] = []
    for h in items {
      let label = cal.isDateInToday(h.at) ? "Today" : cal.isDateInYesterday(h.at) ? "Yesterday" : f.string(from: h.at)
      if let i = out.firstIndex(where: { $0.0 == label }) { out[i].1.append(h) } else { out.append((label, [h])) }
    }
    return out
  }
}

struct SettingsView: View {
  @ObservedObject var m: PanelModel
  @AppStorage("musicMode") private var music = "down"
  @AppStorage("recordCalls") private var recordCalls = true

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      SSecHead(label: "Voice").padding(.top, -14)
      card {
        row("Mic kept warm", "No wait to start. macOS shows the orange mic.") {
          SSwitch(on: Binding(get: { m.warm }, set: { m.onWarm?($0) }))
        }
        divider
        row("Music down", "To 15% while you talk, back in 0.9 s.") {
          SSwitch(on: Binding(get: { music == "down" }, set: { music = $0 ? "down" : "leave" }))
        }
      }
      SSecHead(label: "Calls")
      card {
        row("Record every call", "Your mic and the call, two tracks.") { SSwitch(on: $recordCalls) }
      }
      SSecHead(label: "Keys")
      card { ShortcutRows().padding(12) }
    }
  }

  private var divider: some View { Rectangle().fill(S.lineFaint).frame(height: 1).padding(.leading, 12) }
  private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
    VStack(spacing: 0) { content() }
      .background(S.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(S.line, lineWidth: 1))
  }
  private func row<C: View>(_ label: String, _ desc: String, @ViewBuilder _ ctl: () -> C) -> some View {
    HStack(alignment: .center, spacing: 16) {
      VStack(alignment: .leading, spacing: 1) {
        Text(label).font(S.font(13, .medium))
        Text(desc).font(S.meta).foregroundStyle(S.ink2).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      ctl()
    }
    .padding(.horizontal, 12).padding(.vertical, 12)
  }
}

// MARK: the windows

final class PanelWindow: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// The panel's window and its folded tab on the screen edge.
@MainActor
final class BrainPanel {
  let model = PanelModel()
  private var win: PanelWindow?
  private var host: NSHostingView<PanelView>?
  private let morph = Morph()
  /// where the notch is (or the pill on a screen without one), so the panel comes out of it
  var anchor: (() -> NSRect?)?
  var onOpened: (() -> Void)?
  var onFolded: (() -> Void)?
  var onClosed: (() -> Void)?
  private var watch: AnyCancellable?
  private var monitors: [Any] = []
  private(set) var isOpen = false
  /// a fixed screen instead of the pointer's (the demo uses it to check one screen's wallpaper)
  var onScreen: NSScreen?
  var freeMove = false { didSet { win?.isMovableByWindowBackground = freeMove } }

  enum Home: String { case notch, float }
  var home: Home = Home(rawValue: UserDefaults.standard.string(forKey: "panelHome") ?? "") ?? .notch {
    didSet { UserDefaults.standard.set(home.rawValue, forKey: "panelHome") }
  }
  /// where it floats, as shares of the screen (its left edge, its top), so it lands in the same
  /// place on every screen
  private var spot: CGPoint? {
    get {
      let d = UserDefaults.standard
      guard d.object(forKey: "panelSpotX") != nil else { return nil }
      return CGPoint(x: d.double(forKey: "panelSpotX"), y: d.double(forKey: "panelSpotTop"))
    }
    set {
      let d = UserDefaults.standard
      if let p = newValue { d.set(p.x, forKey: "panelSpotX"); d.set(p.y, forKey: "panelSpotTop") } else { d.removeObject(forKey: "panelSpotX") }
    }
  }
  /// opened by a rest of the pointer on the notch: it puts itself back when the pointer leaves;
  /// a click inside or a key makes it stay
  private(set) var peek = false
  private var peekTimer: Timer?
  private var peekZone = NSRect.zero
  private var outsideSince: Date?
  /// the notch says "drop here" while the panel is dragged near it
  var onReach: ((Bool) -> Void)?
  /// tucked at the edge while it floats and is minimized
  let puck = Puck()
  var isStashed: Bool { puck.isShown }
  private var dragging = false
  private var dragOffset = CGPoint.zero
  private var reaching = false
  /// how close to the notch the panel's top has to come for the notch to pull it in
  private let magnet: CGFloat = 110
  private var tuneWatch: AnyCancellable?

  /// light or dark from the tuning; auto follows the Mac
  func applyScheme() {
    guard S.look == "cc" else { return }
    let a: NSAppearance? = Tune.shared.scheme == "dark" ? NSAppearance(named: .darkAqua) : Tune.shared.scheme == "light" ? NSAppearance(named: .aqua) : nil
    if win?.appearance != a { win?.appearance = a }
  }

  /// the playground's "move it over" buttons
  func place(_ spot: String) {
    guard let w = win, let s = screen else { return }
    let v = s.visibleFrame
    let x: CGFloat = spot == "left" ? v.minX + 480 : spot == "middle" ? v.midX - w.frame.width / 2 : v.maxX - w.frame.width + PanelView.margin.width - 10
    w.setFrameTopLeftPoint(NSPoint(x: x, y: v.maxY))
  }
  var tabNumber: Int { 0 }
  /// the window's number, so a picture can be taken of the panel alone
  var windowNumber: Int { win?.windowNumber ?? 0 }
  private var screen: NSScreen?

  func setUp() {
    model.onClose = { [weak self] in self?.close() }
    model.onFold = { [weak self] in self?.fold() }
    watch = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refit() } }
    tuneWatch = Tune.shared.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { self?.applyScheme(); self?.refit() }
    }
    model.onDrag = { [weak self] in self?.drag($0) }
    puck.onOpen = { [weak self] in
      guard let self else { return }
      self.open(origin: self.puck.circle)
    }
    if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.isOpen, let w = self.win, self.peek || (self.home == .notch && !self.model.pinned) else { return }
        if !w.frame.contains(NSEvent.mouseLocation) { self.fold() }
      }
    }) { monitors.append(m) }
    if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown], handler: { [weak self] e in
      MainActor.assumeIsolated { if let self, e.window === self.win, self.peek { self.peek = false; Log.write("panel: peek kept") } }
      return e
    }) { monitors.append(m) }
  }

  private func makeWindow(_ s: NSScreen) {
    let maxBody = min(560, s.visibleFrame.height * 0.72)
    let h = NSHostingView(rootView: PanelView(m: model, maxBody: maxBody))
    if S.look == "smoke" { h.appearance = NSAppearance(named: .darkAqua) }   // smoke is dark glass in any mode
    h.sizingOptions = [.intrinsicContentSize]
    let w = PanelWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false   // the panel draws its own, see RimShadow
    w.level = .floating
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    w.isMovableByWindowBackground = freeMove
    w.hidesOnDeactivate = false
    w.contentView = h
    win = w
    host = h
    applyScheme()
  }

  static var retired = true

  /// Opens on the screen the pointer is on, sliding in from the right edge.
  func open(focus: Bool = false, peek: Bool = false, origin: NSRect? = nil) {
    guard !BrainPanel.retired else { Log.write("panel: retired, not opened"); return }
    let s = onScreen ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    if win == nil || screen != s { win?.orderOut(nil); win = nil; makeWindow(s); screen = s }
    guard let w = win else { return }
    let wasOpen = isOpen
    if !wasOpen { self.peek = peek }
    let fromPuck = origin != nil && puck.isShown
    puck.hide()
    let target = frame(on: s)
    if !isOpen, !Motion.reduce, let a = origin ?? anchor?(), s.frame.intersects(a) {
      // out of the notch: a shape grows from it to the panel; the panel shows itself as it lands
      collapsing = false
      w.setFrame(target, display: true)
      w.alphaValue = 0
      w.orderFrontRegardless()
      morph.run(from: a, to: Self.visible(target), radius: fromPuck ? Puck.size / 2 : 10, 20, color: fromPuck ? Morph.smoke : .black, Morph.smoke,
                landAt: 0.55, land: { [weak self, weak w] in
        guard let self, self.isOpen, let w else { return }
        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = 0.12
          ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
          w.animator().alphaValue = 1
        }
      })
    } else if !isOpen {
      let reduce = Motion.reduce
      w.setFrame(reduce ? target : target.offsetBy(dx: 28, dy: 0), display: false)
      w.alphaValue = 0
      w.orderFrontRegardless()
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = reduce ? 0.15 : 0.3
        ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        w.animator().setFrame(target, display: true)
        w.animator().alphaValue = 1
      }
    } else {
      w.setFrame(target, display: true)
      w.orderFrontRegardless()
    }
    isOpen = true
    onOpened?()
    if self.peek && !wasOpen, let a = anchor?() { watchPeek(around: Self.visible(target).union(a)) }
    Log.write("panel: open\(self.peek ? " as a peek" : "") at the \(home == .notch ? "notch" : "spot it was left") on \(s.localizedName) at \(target), content \(host?.fittingSize ?? .zero), visible \(w.isVisible)")
    if focus { w.makeKey() }
  }

  /// Height follows the content; the top stays 10 points under the menu bar.
  private func frame(on s: NSScreen) -> NSRect {
    let size = host?.fittingSize ?? NSSize(width: 412, height: 300)
    let v = s.visibleFrame
    let h = min(size.height, v.height - 10)
    // the rim's right edge 10 in from the screen, its top 8 under the menu bar; the margin is shadow
    let w = (S.look == "cc" ? Tune.shared.width : 380) + 2 * PanelView.margin.width
    if freeMove, let cur = win, isOpen {
      let x = min(cur.frame.maxX, v.maxX + PanelView.margin.width) - w
      return NSRect(x: max(v.minX - PanelView.margin.width, x), y: cur.frame.maxY - h, width: w, height: h)
    }
    if dragging, let cur = win { return NSRect(x: cur.frame.minX, y: cur.frame.maxY - h, width: w, height: h) }
    if home == .float, let p = spot {
      let x = v.minX + p.x * v.width - PanelView.margin.width
      let top = v.maxY - p.y * v.height + PanelView.margin.height
      return clamp(NSRect(x: x, y: top - h, width: w, height: h), in: v)
    }
    return docked(on: s, w: w, h: h)
  }

  /// At home: hanging under the notch, the top 8 under the menu bar (the notch and the pill both
  /// sit in the middle of the screen)
  private func docked(on s: NSScreen, w: CGFloat, h: CGFloat) -> NSRect {
    NSRect(x: s.frame.midX - w / 2, y: s.visibleFrame.maxY - h, width: w, height: h)
  }

  /// Kept on the screen, the shadow's room allowed past the edges.
  private func clamp(_ f: NSRect, in v: NSRect) -> NSRect {
    let m = PanelView.margin.width
    var r = f
    r.origin.x = min(max(r.minX, v.minX - m), v.maxX - r.width + m)
    if r.maxY > v.maxY { r.origin.y = v.maxY - r.height }
    if r.minY < v.minY - m - 10 { r.origin.y = v.minY - m - 10 }
    return r
  }

  // MARK: dragging, the magnet, the peek

  /// Dragged by its head: it follows the pointer; near the notch it is pulled in, harder the
  /// closer it gets, and the notch shows its mark; let go there and it snaps home, elsewhere it
  /// floats where it was let go.
  func drag(_ phase: DragPhase, at point: NSPoint? = nil) {
    guard let w = win, let s = screen, !freeMove else { return }
    let at = point ?? NSEvent.mouseLocation
    let dock = docked(on: s, w: w.frame.width, h: w.frame.height)
    switch phase {
    case .click:
      peek = false
    case .began:
      dragging = true
      peek = false
      shrinkWork?.cancel()
      dragOffset = CGPoint(x: at.x - w.frame.minX, y: at.y - w.frame.minY)
    case .moved:
      var o = CGPoint(x: at.x - dragOffset.x, y: at.y - dragOffset.y)
      let d = hypot(o.x - dock.minX, o.y - dock.minY)
      let near = d < magnet
      if near {
        let pull = pow(1 - d / magnet, 1.6) * 0.7
        o.x += (dock.minX - o.x) * pull
        o.y += (dock.minY - o.y) * pull
      }
      if near != reaching { reaching = near; onReach?(near) }
      w.setFrameOrigin(o)
    case .ended:
      dragging = false
      let d = hypot(w.frame.minX - dock.minX, w.frame.minY - dock.minY)
      if reaching { reaching = false; onReach?(false) }
      if d < magnet {
        home = .notch
        settle(w, to: dock, overshoot: true)
        Log.write("panel: docked at the notch")
      } else {
        home = .float
        let v = s.visibleFrame
        let f = clamp(w.frame, in: v)
        let vis = Self.visible(f)
        spot = CGPoint(x: (vis.minX - v.minX) / v.width, y: (v.maxY - vis.maxY) / v.height)
        if f != w.frame { settle(w, to: f, overshoot: false) }
        Log.write("panel: floats at \(Int(vis.minX)), \(Int(vis.maxY))")
      }
    }
  }

  private func settle(_ w: NSWindow, to f: NSRect, overshoot: Bool) {
    if Motion.reduce { w.setFrame(f, display: true); return }
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = overshoot ? 0.36 : 0.24
      ctx.timingFunction = overshoot ? CAMediaTimingFunction(controlPoints: 0.3, 1.25, 0.5, 1) : CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
      w.animator().setFrame(f, display: true)
    }
  }

  /// A peek puts itself back once the pointer has been away from it and the notch for half a second.
  private func watchPeek(around zone: NSRect) {
    peekZone = zone.insetBy(dx: -16, dy: -16)
    outsideSince = nil
    peekTimer?.invalidate()
    peekTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
      MainActor.assumeIsolated {
        guard let self, self.isOpen, self.peek else { t.invalidate(); return }
        if self.peekZone.contains(NSEvent.mouseLocation) { self.outsideSince = nil; return }
        if self.outsideSince == nil { self.outsideSince = Date() }
        if let t0 = self.outsideSince, Date().timeIntervalSince(t0) > 0.5 { t.invalidate(); self.fold() }
      }
    }
  }

  /// An answer came while it was tucked at the edge: the puck gets the pink dot.
  func markUnread() { if puck.isShown { puck.model.unread = true } }

  /// The window follows the content without cutting it: it grows at once (the content then eases
  /// into the room, the window is clear), and shrinks only after the content has eased down.
  private var shrinkWork: DispatchWorkItem?
  private func refit() {
    guard isOpen, let w = win, let s = screen else { return }
    let f = frame(on: s)
    guard abs(f.height - w.frame.height) > 0.5 || abs(f.width - w.frame.width) > 0.5 else { return }
    shrinkWork?.cancel()
    if f.height >= w.frame.height - 0.5 || abs(f.width - w.frame.width) > 0.5 {
      w.setFrame(f, display: true, animate: false)
    } else {
      let work = DispatchWorkItem { [weak self] in
        guard let self, self.isOpen, let w = self.win, let s = self.screen else { return }
        w.setFrame(self.frame(on: s), display: true, animate: false)
      }
      shrinkWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.reduce ? 0.2 : 0.45), execute: work)
    }
  }

  /// Closed with the x: back into the notch, nothing left there.
  func close() { puck.hide(); collapse(folded: false) }

  func fold() {
    if home == .float, !freeMove { stash() } else { collapse(folded: true) }
  }

  /// Floating and minimized: the panel goes into a small round button at the nearer edge, at the
  /// height of its head.
  private func stash() {
    guard let w = win, isOpen, let s = screen else { return }
    isOpen = false
    peek = false
    shrinkWork?.cancel()
    let from = w.frame
    let vis = Self.visible(from)
    let c = Puck.circle(on: s, side: vis.midX < s.visibleFrame.midX ? .left : .right, centerY: vis.maxY - 40)
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 0.1
      w.animator().alphaValue = 0
    }, completionHandler: { MainActor.assumeIsolated { if !self.isOpen { w.orderOut(nil) } } })
    let app = w.appearance
    if Motion.reduce { puck.show(c, appearance: app); return }
    morph.run(from: vis, to: c, radius: 20, Puck.size / 2, color: Morph.smoke, Morph.smoke, landAt: 0.8, land: { [weak self] in
      self?.puck.show(c, appearance: app)
    })
  }

  /// Hidden completely, at once (the demos end with it).
  func hideAll() { isOpen = false; morph.cancel(); win?.orderOut(nil) }

  private var collapsing = false
  private func collapse(folded: Bool) {
    guard let w = win, isOpen else { return }
    isOpen = false
    shrinkWork?.cancel()
    let from = w.frame
    let done: () -> Void = { [weak self] in
      guard let self else { return }
      if folded { self.onFolded?() } else { self.onClosed?() }
    }
    if !Motion.reduce, let a = anchor?(), screen?.frame.intersects(a) == true {
      // the panel hands over to the shape at once, and the shape goes back into the notch
      collapsing = true
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.1
        w.animator().alphaValue = 0
      }, completionHandler: { MainActor.assumeIsolated { if !self.isOpen { w.orderOut(nil) } } })
      morph.run(from: Self.visible(from), to: a, radius: 20, 10, color: Morph.smoke, .black, landAt: 0.85, land: done)
    } else {
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = Motion.reduce ? 0.12 : 0.18
        ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 1, 1)
        if !Motion.reduce { w.animator().setFrame(from.offsetBy(dx: 16, dy: 0), display: true) }
        w.animator().alphaValue = 0
      }, completionHandler: { MainActor.assumeIsolated { if !self.isOpen { w.orderOut(nil); w.setFrame(from, display: false) } } })
      done()
    }
  }

  /// What the eye sees of the panel's window: without the room kept for its shadow
  static func visible(_ f: NSRect) -> NSRect {
    NSRect(x: f.minX + PanelView.margin.width, y: f.minY + PanelView.margin.width + 10,
           width: f.width - 2 * PanelView.margin.width, height: f.height - PanelView.margin.height - PanelView.margin.width - 10)
  }
}

