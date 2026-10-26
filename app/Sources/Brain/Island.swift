import AppKit
import SwiftUI

@MainActor
final class IslandModel: ObservableObject {
  enum Phase: Equatable {
    case hidden
    case listening
    case writing
    case pasted(String)
    case nothing
    case note(String, String)   // left, right: setup and error lines
    case recording(String, Date)
    case saved(String)
    case ask
    case prep(String, Date)      // who, and when the call starts: "Sam in 5 min"
    case card(Card)
    case thinking(Date)
    case ready(String)           // an answer waits: a pink dot and its first words
    case folded(Bool)            // the brain mark beside the notch; true: unread
    case quick(Bool)
  }
  @Published var phase: Phase = .hidden
  var onButton: ((String) -> Void)?
  /// what the quick island shows as on (a warm mic), set before it opens
  /// the island is opening out of the hidden notch: that one move gets the slower, bouncier spring
  @Published var fromHidden = false
  @Published var quickWarm = false
  @Published var quickPage = ""
  var onQuick: ((String) -> Void)?
  @Published var levels: [CGFloat] = Array(repeating: 0.15, count: 7)
  @Published var elapsed: Int = 0
  /// the island's drawn size, so its window can take clicks exactly there while a card is open
  var size: CGSize = .zero

  var meterFrom = Date.distantPast
  func push(level: Float) {
    if Date() < meterFrom { return }
    levels.removeFirst()
    levels.append(CGFloat(max(0.15, level)))
  }
}

/// What the open island shows: its two wings, then lines, then at most one main button.
struct Card: Equatable {
  enum Mark: Equatable { case none, wave, live, dots, wand, cal, ok, pink }
  struct Row: Equatable {
    var text: String, when: String, state: String, source: String, file: String
  }
  /// A rewrite shown as changes: kept words plain, removed struck and dim, added bright.
  struct Piece: Equatable { enum Kind: Equatable { case same, added, removed }; let text: String; let kind: Kind }
  enum Line: Equatable {
    case heard(String)            // the question as heard, small, with a mic
    case question(String)         // the question while the brain works on it, the card's title
    case listening(String)
    case quote(String)            // the selected text a command will work on
    case step(String, Bool)       // what the brain is reading; true while it is the current one
    case headline(String)         // the answer itself (a fact), or what a list is
    case note(String)             // a sentence or two of context
    case status(Row)
    case diff([Piece])
    case said(String)             // "You said" and the instruction
    case head(String, String)     // a title and a short fact on the right
    case row(String, String)      // an answer and where it came from
    case item(String, String)     // an open item and who owes it
    case ask(String)              // a question to ask on the call
    case text(String)
    case dim(String)
    case sep
  }
  struct Button: Equatable { let id: String; let label: String; var primary = false }
  var mark: Mark = .none
  var left: String
  var right: String
  var lines: [Line]
  var buttons: [Button] = []
  /// a small grey line left of the buttons: how to close, what a click does
  var hint: String? = nil
  var width: CGFloat = 480
  /// while set, the right wing counts the seconds since then
  var since: Date? = nil
}

let pink = Color(red: 1, green: 0.561, blue: 0.78)

struct IslandShape: Shape {
  var body: CGFloat     // width of the black body
  var fillet: CGFloat = 8
  var radius: CGFloat
  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(body, radius) }
    set { body = newValue.first; radius = newValue.second }
  }
  func path(in r: CGRect) -> Path {
    let w = body, f = fillet, h = r.height, x0 = (r.width - w) / 2 - f
    var p = Path()
    p.move(to: CGPoint(x: x0, y: 0))
    p.addQuadCurve(to: CGPoint(x: x0 + f, y: f), control: CGPoint(x: x0 + f, y: 0))
    p.addLine(to: CGPoint(x: x0 + f, y: h - radius))
    p.addQuadCurve(to: CGPoint(x: x0 + f + radius, y: h), control: CGPoint(x: x0 + f, y: h))
    p.addLine(to: CGPoint(x: x0 + f + w - radius, y: h))
    p.addQuadCurve(to: CGPoint(x: x0 + f + w, y: h - radius), control: CGPoint(x: x0 + f + w, y: h))
    p.addLine(to: CGPoint(x: x0 + f + w, y: f))
    p.addQuadCurve(to: CGPoint(x: x0 + 2 * f + w, y: 0), control: CGPoint(x: x0 + f + w, y: 0))
    p.closeSubpath()
    return p
  }
}

struct IslandView: View {
  @ObservedObject var model: IslandModel
  let notchWidth: CGFloat
  let height: CGFloat
  let wing: CGFloat
  let pill: Bool
  let reduceMotion: Bool

  private let dim = Color.white.opacity(0.6)
  private let ok = Color(red: 0.29, green: 0.87, blue: 0.5)

  private var card: Card? { if case .card(let c) = model.phase { return c }; return nil }
  private var quick: Bool? { if case .quick(let e) = model.phase { return e }; return nil }

  /// the folded mark keeps to a small wing beside the cutout
  private var compact: Bool {
    switch model.phase { case .folded: return true; default: return false }
  }

  var body: some View {
    let open = model.phase != .hidden
    let ww = compact ? 30 : wing
    let w = quick != nil ? max(420, notchWidth + 2 * wing) : card.map { max($0.width, notchWidth + 2 * wing) } ?? (open ? notchWidth + 2 * ww : notchWidth)
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        // each wing is exactly `wing` wide, its words 14 in from the outer edge, never over the cutout
        HStack(spacing: 7) { left }.frame(width: ww - 14, alignment: .leading).padding(.leading, 14)
        if !pill { Spacer().frame(width: notchWidth) }
        HStack(spacing: 7) { right }.frame(width: ww - 14, alignment: .trailing).padding(.trailing, 14)
      }
      .frame(width: w, height: height)
      if let expanded = quick {
        QuickBody(model: model, expanded: expanded)
          .frame(width: w - 28)
          .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 14)
          .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.2).delay(reduceMotion ? 0 : 0.14)), removal: .opacity.animation(.easeOut(duration: 0.1))))
      }
      if let card {
        CardBody(card: card, onButton: { model.onButton?($0) })
          .frame(width: w - 32, alignment: .leading)
          .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 14)
          .transition(.opacity)
      }
    }
    // nothing is ever drawn outside the black: while it grows or folds, the words are cut to its shape
    .mask(alignment: .top) {
      Group {
        if pill { RoundedRectangle(cornerRadius: card == nil && quick == nil ? height / 2 : 22) }
        else { IslandShape(body: w, radius: quick != nil ? 26 : card == nil ? (open ? 14 : 10) : 18) }
      }
    }
    .opacity(open ? 1 : 0)
    .background(alignment: .top) {
      Group {
        if pill {
          RoundedRectangle(cornerRadius: card == nil && quick == nil ? height / 2 : 22).fill(Color.black)
        } else {
          IslandShape(body: w, radius: quick != nil ? 26 : card == nil ? (open ? 14 : 10) : 18).fill(Color.black)
        }
      }
      .opacity(pill && !open ? 0 : 1)
    }
    .background(GeometryReader { g in Color.clear.preference(key: SizeKey.self, value: g.size) })
    .onPreferenceChange(SizeKey.self) { model.size = $0 }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .animation(reduceMotion ? .easeOut(duration: 0.15) : model.fromHidden ? .spring(response: 0.62, dampingFraction: 0.66) : .spring(response: 0.54, dampingFraction: 0.86), value: model.phase)
    .font(.system(size: 12, weight: .regular))
    .foregroundStyle(.white)
  }

  @ViewBuilder private var left: some View {
    switch model.phase {
    case .listening, .ask: Wave(levels: model.levels, live: !reduceMotion)
    case .writing: Wave(levels: model.levels, live: false).opacity(0.5); Text("Writing")
    case .pasted(let app): Circle().fill(ok).frame(width: 7, height: 7); Text("Pasted in \(app)").lineLimit(1)
    case .nothing: Text("Nothing heard").foregroundStyle(dim)
    case .note(let l, _): Text(l).lineLimit(1)
    case .recording(let title, _): RecDot(); Text(title).lineLimit(1)
    case .saved(let t): Circle().fill(ok).frame(width: 7, height: 7); Text(t).lineLimit(1)
    case .prep(let who, let at):
      TimelineView(.periodic(from: .now, by: 15)) { ctx in
        let m = max(0, Int((at.timeIntervalSince(ctx.date) / 60).rounded(.up)))
        Text(m > 0 ? "\(who) in \(m) min" : "\(who) now").lineLimit(1)
      }
    case .card(let c): mark(c.mark); Text(c.left).lineLimit(1)
    case .thinking: BrainMark(size: 13, live: true, color: .white); Text("Thinking")
    case .ready(let head): Circle().fill(pink).frame(width: 7, height: 7); Text(head).lineLimit(1)
    case .folded: BrainMark(size: 12).transition(.scale(scale: 0.6).combined(with: .opacity))
    case .quick: BrainMark(size: 13, color: .white); Text("Brain").font(.system(size: 13, weight: .semibold))
    case .hidden: EmptyView()
    }
  }

  @ViewBuilder private var right: some View {
    switch model.phase {
    case .listening: Text("Listening"); Key(Shortcut.talk.glyph)
    case .ask: Text("Ask the brain"); Key(Shortcut.talk.glyph + Shortcut.ask.glyph)
    case .writing: Text("under 1 s").foregroundStyle(dim)
    case .pasted: EmptyView()
    case .nothing: EmptyView()
    case .note(_, let r): Text(r).foregroundStyle(dim).lineLimit(1)
    case .recording(_, let since):
      TimelineView(.periodic(from: since, by: 1)) { ctx in
        Text(Self.clock(ctx.date.timeIntervalSince(since))).monospacedDigit().foregroundStyle(dim)
      }
    case .saved: EmptyView()
    case .prep(_, let at):
      Image(systemName: "calendar").font(.system(size: 11)).foregroundStyle(dim)
      Text(Self.hhmm(at)).monospacedDigit().foregroundStyle(dim)
    case .card(let c):
      if let since = c.since {
        TimelineView(.periodic(from: since, by: 1)) { ctx in
          Text("\(max(0, Int(ctx.date.timeIntervalSince(since)))) s").monospacedDigit().foregroundStyle(dim)
        }
      } else {
        Text(c.right).foregroundStyle(dim).lineLimit(1)
      }
    case .folded(let unread):
      if unread { Circle().fill(pink).frame(width: 6, height: 6).transition(.scale(scale: 0.4).combined(with: .opacity)) }
    case .thinking(let since):
      TimelineView(.periodic(from: since, by: 1)) { ctx in
        Text("\(Int(ctx.date.timeIntervalSince(since))) s").monospacedDigit().foregroundStyle(dim)
      }
    case .ready: Text("open").foregroundStyle(dim)
    case .quick: Text(IslandView.hhmm(Date())).foregroundStyle(dim).monospacedDigit()
    case .hidden: EmptyView()
    }
  }

  @ViewBuilder private func mark(_ m: Card.Mark) -> some View {
    switch m {
    case .none: EmptyView()
    case .wave: Wave(levels: model.levels, live: false).opacity(0.6)
    case .live: Wave(levels: model.levels, live: !reduceMotion)
    case .dots: Dots(still: reduceMotion)
    case .wand: Image(systemName: "wand.and.stars").font(.system(size: 11))
    case .cal: Image(systemName: "calendar").font(.system(size: 11))
    case .ok: Circle().fill(ok).frame(width: 7, height: 7)
    case .pink: Circle().fill(pink).frame(width: 7, height: 7)
    }
  }

  static func clock(_ s: TimeInterval) -> String {
    let t = Int(s)
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
  }

  static func hhmm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }
}

struct SizeKey: PreferenceKey {
  static let defaultValue: CGSize = .zero
  static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct QuickBody: View {
  @ObservedObject var model: IslandModel
  let expanded: Bool
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        tile("last", "text.bubble", "Last answer", "hold \(Shortcut.talk.glyph) + \(Shortcut.ask.glyph) to ask")
        tile("home", "circle.hexagongrid", "Brain Home", "the map, today, review")
        Button { model.onQuick?("more") } label: {
          Image(systemName: expanded ? "chevron.up" : "slider.horizontal.3").font(.system(size: 15, weight: .medium))
            .foregroundStyle(expanded ? Color.black : Color.white)
            .frame(width: 52, height: 52)
            .background(RoundedRectangle(cornerRadius: 12).fill(expanded ? Color.white : Color.white.opacity(0.12)))
            .overlay(alignment: .topTrailing) {
              if !expanded && model.quickWarm { Circle().fill(Color.green).frame(width: 7, height: 7).padding(7) }
            }
            .contentTransition(.symbolEffect(.replace))
            .contentShape(Rectangle())
        }
        .buttonStyle(QuickPress())
        .accessibilityLabel(expanded ? "Less" : "More")
      }
      if expanded && model.quickPage == "settings" {
        NotchSettings(back: { model.onQuick?("back") })
          .padding(.top, 12)
          .transition(.opacity)
      } else if expanded {
        VStack(spacing: 0) {
          toggle("warm", "mic", "Warm the mic", "No wait when you talk, the orange dot stays", model.quickWarm)
          pill("settings", "gearshape", "All settings")
          .padding(.top, 10)
        }
        .padding(.top, 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }
  private func tile(_ id: String, _ symbol: String, _ title: String, _ sub: String) -> some View {
    Button { model.onQuick?(id) } label: {
      HStack(spacing: 10) {
        Image(systemName: symbol).font(.system(size: 14, weight: .medium))
          .frame(width: 30, height: 30)
          .background(Circle().fill(Color.white.opacity(0.14)))
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.system(size: 13, weight: .semibold))
          Text(sub).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.5)).lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 11)
      .frame(maxWidth: .infinity).frame(height: 52)
      .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
      .contentShape(Rectangle())
    }
    .buttonStyle(QuickPress())
  }
  private func toggle(_ id: String, _ symbol: String, _ title: String, _ sub: String, _ on: Bool) -> some View {
    Button { model.onQuick?(id) } label: {
      HStack(spacing: 11) {
        Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 30, height: 30)
          .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.12)))
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.system(size: 13, weight: .medium))
          Text(sub).font(.system(size: 11)).foregroundStyle(Color.white.opacity(0.5)).lineLimit(1)
        }
        Spacer(minLength: 8)
        Capsule().fill(on ? Color.green : Color.white.opacity(0.2)).frame(width: 34, height: 20)
          .overlay(alignment: on ? .trailing : .leading) { Circle().fill(Color.white).padding(2) }
          .animation(.spring(response: 0.3, dampingFraction: 0.8), value: on)
      }
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(QuickPress())
  }
  private func pill(_ id: String, _ symbol: String, _ title: String) -> some View {
    Button { model.onQuick?(id) } label: {
      HStack(spacing: 6) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)); Text(title).font(.system(size: 12.5, weight: .medium)) }
        .frame(maxWidth: .infinity).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.12)))
    }
    .buttonStyle(QuickPress())
  }
}

struct NotchSettings: View {
  let back: () -> Void
  @AppStorage("recordCalls") private var recordCalls = true
  @AppStorage("musicMode") private var music = "down"
  @StateObject private var rec = KeyRecorder()
  private let dim = Color.white.opacity(0.5)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      head("Calls")
      flip("record.circle", "Record calls", "Your mic and the call, two tracks", $recordCalls)
      flip("speaker.wave.1", "Music down while you talk", "Back up when you let go", Binding(get: { music == "down" }, set: { music = $0 ? "down" : "leave" }))
      head("Shortcuts").padding(.top, 8)
      ForEach(Shortcut.allCases, id: \.self) { s in keyRow(s) }
      Text(rec.listening != nil ? "Press the key you want, Esc keeps it" : rec.swapped.isEmpty ? "Click a key to change it" : rec.swapped)
        .font(.system(size: 11)).foregroundStyle(dim).padding(.top, 6)
      Button(action: { rec.stop(); back() }) {
        HStack(spacing: 6) { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)); Text("Back").font(.system(size: 12.5, weight: .medium)) }
          .frame(maxWidth: .infinity).frame(height: 32)
          .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.12)))
      }
      .buttonStyle(QuickPress()).padding(.top, 10)
    }
    .foregroundStyle(Color.white)
    .onDisappear { if rec.listening != nil { rec.stop() } }
  }

  private func head(_ t: String) -> some View {
    Text(t.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(dim).padding(.bottom, 2)
  }

  private func flip(_ symbol: String, _ title: String, _ sub: String, _ on: Binding<Bool>) -> some View {
    Button { on.wrappedValue.toggle() } label: {
      HStack(spacing: 11) {
        Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26)
          .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
        VStack(alignment: .leading, spacing: 1) {
          Text(title).font(.system(size: 13, weight: .medium))
          Text(sub).font(.system(size: 11)).foregroundStyle(dim).lineLimit(1)
        }
        Spacer(minLength: 8)
        Capsule().fill(on.wrappedValue ? Color.green : Color.white.opacity(0.2)).frame(width: 34, height: 20)
          .overlay(alignment: on.wrappedValue ? .trailing : .leading) { Circle().fill(Color.white).padding(2) }
          .animation(.spring(response: 0.3, dampingFraction: 0.8), value: on.wrappedValue)
      }
      .padding(.vertical, 5).contentShape(Rectangle())
    }
    .buttonStyle(QuickPress())
  }

  private func keyRow(_ s: Shortcut) -> some View {
    let listening = rec.listening == s
    return HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 1) {
        Text(s.title).font(.system(size: 13, weight: .medium))
        Text(listening && !rec.note.isEmpty ? rec.note : s.how).font(.system(size: 11))
          .foregroundStyle(listening && !rec.note.isEmpty ? Color.white : dim).lineLimit(1)
      }
      Spacer(minLength: 8)
      if s.canBeNone, s.code != -1, !listening {
        Button { rec.set(s, -1) } label: {
          Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(dim).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Remove the \(s.title) shortcut")
      }
      Button { listening ? rec.stop() : rec.start(s) } label: {
        Text(listening ? "Press a key" : s.label)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(listening ? Color.black : Color.white)
          .padding(.horizontal, 10).frame(minWidth: 64).frame(height: 26)
          .background(RoundedRectangle(cornerRadius: 8).fill(listening ? Color.white : Color.white.opacity(0.14)))
      }
      .buttonStyle(QuickPress())
      .accessibilityLabel(listening ? "Listening for a key for \(s.title)" : "\(s.title), \(s.label). Click to change")
    }
    .padding(.vertical, 5)
  }
}

/// a press you can feel: a small dip
struct QuickPress: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1).animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

struct CardBody: View {
  let card: Card
  let onButton: (String) -> Void
  private let dim = Color.white.opacity(0.6)

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in row(line) }
      if !card.buttons.isEmpty || card.hint != nil {
        HStack(spacing: 6) {
          if let hint = card.hint { Text(hint).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.45)).lineLimit(1) }
          Spacer(minLength: 8)
          ForEach(card.buttons, id: \.id) { b in
            Button(action: { onButton(b.id) }) {
              Text(b.label).font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(b.primary ? Color.black : Color.white)
                .padding(.horizontal, 12).frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(b.primary ? pink : Color.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.top, 10)
      }
    }
    .font(.system(size: 13))
  }

  private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

  @ViewBuilder private func row(_ line: Card.Line) -> some View {
    switch line {
    case .question(let t):
      Text(t).font(.system(size: 15, weight: .semibold)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        .padding(.top, 2).padding(.bottom, 8)
    case .listening(let t):
      Shimmer(text: t, size: 15, still: reduceMotion).padding(.top, 2).padding(.bottom, 8)
    case .quote(let t):
      HStack(alignment: .top, spacing: 8) {
        Rectangle().fill(Color.white.opacity(0.25)).frame(width: 2)
        Text(t).font(.system(size: 12.5)).foregroundStyle(dim).lineLimit(2)
      }
      .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
    case .step(let t, let active):
      HStack(spacing: 8) {
        if active { Dots(still: reduceMotion, size: 3).frame(width: 14) }
        else { Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.white.opacity(0.4)).frame(width: 14) }
        if active { Shimmer(text: t, size: 12.5, still: reduceMotion) }
        else { Text(t).font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.45)).lineLimit(1) }
      }
      .padding(.vertical, 3)
    case .headline(let t):
      Text(t).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true).padding(.top, 4).padding(.bottom, 4)
    case .note(let t):
      Text(t).foregroundStyle(Color.white.opacity(0.82)).fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
    case .status(let r):
      Button(action: { onButton("open:" + r.file) }) {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
          Circle().fill(StatusMark.color(r.state)).frame(width: 6, height: 6).frame(width: 16, alignment: .leading)
            .opacity(r.state == "info" ? 0 : 1)
          VStack(alignment: .leading, spacing: 1) {
            Text(r.text).fixedSize(horizontal: false, vertical: true)
            if !r.source.isEmpty { Text(r.source).font(.system(size: 12)).foregroundStyle(dim).lineLimit(1) }
          }
          Spacer(minLength: 12)
          Text(StatusMark.when(r)).font(.system(size: 12, weight: r.state == "overdue" ? .semibold : .regular))
            .foregroundStyle(r.state == "overdue" ? Color.white : dim).lineLimit(1)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    case .diff(let pieces):
      Text(Diff.attributed(pieces)).fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
    case .heard(let t):
      HStack(spacing: 7) { Image(systemName: "mic").font(.system(size: 11)); Text(t).lineLimit(2) }
        .foregroundStyle(dim).padding(.vertical, 5)
    case .said(let t):
      HStack(spacing: 7) { Text("You said").foregroundStyle(dim); Text(t).fontWeight(.semibold).lineLimit(2) }.padding(.vertical, 5)
    case .head(let t, let r):
      HStack { Text(t).fontWeight(.semibold).lineLimit(1); Spacer(); Text(r).font(.system(size: 12)).foregroundStyle(dim) }.padding(.vertical, 5)
    case .row(let t, let src):
      VStack(alignment: .leading, spacing: 2) {
        Text(t).fixedSize(horizontal: false, vertical: true)
        if !src.isEmpty { Text(src).font(.system(size: 12)).foregroundStyle(dim).lineLimit(1) }
      }
      .padding(.vertical, 5)
    case .item(let t, let who):
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(t).fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 8)
        Text(who).font(.system(size: 12)).foregroundStyle(dim).lineLimit(1)
      }
      .padding(.vertical, 4)
    case .ask(let t):
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(dim)
        Text(t).fixedSize(horizontal: false, vertical: true)
      }
      .padding(.vertical, 4)
    case .text(let t): Text(t).fixedSize(horizontal: false, vertical: true).padding(.vertical, 4)
    case .dim(let t): Text(t).font(.system(size: 12)).foregroundStyle(dim).fixedSize(horizontal: false, vertical: true).padding(.vertical, 3)
    case .sep: Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1).padding(.vertical, 6)
    }
  }
}

/// Text that a light passes over while the brain works; plain dim text under reduced motion.
struct Shimmer: View {
  let text: String
  var size: CGFloat = 13
  var still = false
  var body: some View {
    let base = Text(text).font(.system(size: size, weight: size >= 15 ? .regular : .regular)).lineLimit(2)
    if still {
      base.foregroundStyle(Color.white.opacity(0.55))
    } else {
      // the light moves, the text does not: the gradient slides under a mask of the text itself
      TimelineView(.animation) { ctx in
        let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
        base.foregroundStyle(Color.white.opacity(0.42))
          .overlay(
            GeometryReader { g in
              LinearGradient(colors: [.clear, .white.opacity(0.95), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: 80)
                .offset(x: CGFloat(t) * (g.size.width + 80) - 80)
            }
            .mask(base)
          )
      }
    }
  }
}

/// Three dots that breathe in turn: the brain is working. Still under reduced motion.
struct Dots: View {
  var still = false
  var size: CGFloat = 4
  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: still)) { ctx in
      let t = ctx.date.timeIntervalSinceReferenceDate
      HStack(spacing: size * 0.8) {
        ForEach(0..<3, id: \.self) { i in
          Circle().fill(Color.white).frame(width: size, height: size)
            .opacity(still ? 0.6 : 0.3 + 0.7 * max(0, sin((t * 4) - Double(i) * 0.7)))
        }
      }
    }
  }
}

enum StatusMark {
  static func color(_ state: String) -> Color {
    switch state {
    case "overdue": return pink
    case "done": return Color(red: 0.29, green: 0.87, blue: 0.5)
    case "due": return Color.white
    default: return Color.white.opacity(0.3)
    }
  }
  static func when(_ r: Card.Row) -> String {
    if r.state == "overdue" { return r.when.isEmpty ? "overdue" : "overdue, \(r.when)" }
    if r.state == "done" { return r.when.isEmpty ? "done" : "done \(r.when)" }
    return r.when
  }
}

enum Diff {
  static func pieces(from old: String, to new: String) -> [Card.Piece] {
    let a = old.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    let b = new.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard a.count < 400, b.count < 400 else { return [.init(text: new, kind: .same)] }
    var l = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in stride(from: a.count - 1, through: 0, by: -1) {
      for j in stride(from: b.count - 1, through: 0, by: -1) {
        l[i][j] = a[i] == b[j] ? l[i + 1][j + 1] + 1 : max(l[i + 1][j], l[i][j + 1])
      }
    }
    var out: [Card.Piece] = []
    var i = 0, j = 0
    func add(_ t: String, _ k: Card.Piece.Kind) {
      if let last = out.last, last.kind == k { out[out.count - 1] = .init(text: last.text + " " + t, kind: k) } else { out.append(.init(text: t, kind: k)) }
    }
    while i < a.count || j < b.count {
      // like track changes: what goes comes first, then what replaces it
      if i < a.count, j < b.count, a[i] == b[j] { add(a[i], .same); i += 1; j += 1 }
      else if i < a.count, j == b.count || l[i + 1][j] >= l[i][j + 1] { add(a[i], .removed); i += 1 }
      else { add(b[j], .added); j += 1 }
    }
    let kept = out.filter { $0.kind == .same }.reduce(0) { $0 + $1.text.split(separator: " ").count }
    return Double(kept) / Double(max(b.count, 1)) < 0.5 ? [.init(text: new, kind: .same)] : out
  }

  static func attributed(_ pieces: [Card.Piece]) -> AttributedString {
    var s = AttributedString()
    for (n, p) in pieces.enumerated() {
      var part = AttributedString((n == 0 ? "" : " ") + p.text)
      switch p.kind {
      case .same: part.foregroundColor = Color.white.opacity(0.85)
      case .added: part.foregroundColor = Color.white; part.font = .system(size: 13, weight: .semibold)
      case .removed: part.foregroundColor = Color.white.opacity(0.35); part.strikethroughStyle = .single
      }
      s += part
    }
    return s
  }
}

/// Red only for recording, pulsing 2.4 s between full and 45%; still under reduced motion.
struct RecDot: View {
  @State private var dim = false
  var body: some View {
    Circle().fill(Color(red: 0.97, green: 0.44, blue: 0.44)).frame(width: 7, height: 7)
      .opacity(dim ? 0.45 : 1)
      .onAppear {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) { dim = true }
      }
  }
}

struct Key: View {
  let k: String
  init(_ k: String) { self.k = k }
  var body: some View {
    Text(k).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
      .padding(.horizontal, 5).frame(height: 18)
      .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
  }
}

struct Wave: View {
  let levels: [CGFloat]
  let live: Bool
  var body: some View {
    HStack(spacing: 2) {
      ForEach(levels.indices, id: \.self) { i in
        RoundedRectangle(cornerRadius: 1).frame(width: 2, height: 4 + levels[i] * 12)
      }
    }
    .frame(height: 16)
    .animation(live ? .easeOut(duration: 0.09) : nil, value: levels)
  }
}

final class IslandHost<V: View>: NSHostingView<V> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The window that holds the island, over the notch of the built-in screen, or the pill on the
/// main screen when there is no notch (an external display). It lets every click through, except
/// while a card is open: then it shrinks to the card and takes clicks there only.
@MainActor
final class IslandPanel {
  let model = IslandModel()
  private var panel: NSPanel?
  private var hideWork: DispatchWorkItem?
  private let wing: CGFloat = 136
  private var top: CGFloat = 0
  private var midX: CGFloat = 0
  private var big = NSRect.zero
  private var wingsRect = NSRect.zero
  private var islandW: CGFloat = 0
  private var islandH: CGFloat = 28
  private var notchRect = NSRect.zero
  /// the notch itself in screen points (on a screen without one, the pill's place)
  private(set) var anchor = NSRect.zero
  var onNotchHover: (() -> Void)?
  var onNotchNear: (() -> Void)?
  private var nearRect = NSRect.zero
  private var monitors: [Any] = []
  private var outsideSince: Date?
  private var insideSince: Date?

  /// hovering the wings while they rest on a prep or a recording
  var onHover: (() -> Void)?
  /// the mouse left a card that hover opened
  var onLeave: (() -> Void)?
  /// a click anywhere outside an open card
  var onOutsideClick: (() -> Void)?
  /// set while a card was opened by hover, so leaving closes it
  var hoverCard = false

  func setUp() {
    let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640), styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    p.ignoresMouseEvents = true
    panel = p
    place()
    watchMouse()
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.place() }
    }
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.place() }
    }
  }

  private var placedOn = ""
  /// a fixed screen instead of the pointer's (the demos)
  var onScreen: NSScreen?
  private var lastPlace = Date.distantPast
  func place(on chosen: NSScreen? = nil) {
    guard let p = panel else { return }
    lastPlace = Date()
    let at = NSEvent.mouseLocation
    let screen = onScreen ?? chosen ?? NSScreen.screens.first { NSMouseInRect(at, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    let notched: NSScreen? = screen.safeAreaInsets.top > 0 ? screen : nil
    placedOn = "\(screen.frame)"
    let f = screen.frame
    var notchW: CGFloat = 0
    var h: CGFloat = 28
    if let s = notched, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
      notchW = f.width - l.width - r.width
      h = s.safeAreaInsets.top
    }
    let pill = notched == nil
    let width = max(560, (pill ? 2 * wing : notchW + 2 * wing) + 40)
    let height = h + 600
    top = pill ? f.maxY - 4 : f.maxY
    midX = f.midX
    big = NSRect(x: midX - width / 2, y: top - height, width: width, height: height)
    let ww = pill ? 2 * wing : notchW + 2 * wing
    islandW = ww
    islandH = h
    let nw = pill ? 120 : notchW
    anchor = NSRect(x: midX - nw / 2, y: top - h, width: nw, height: h)
    notchRect = NSRect(x: midX - nw / 2, y: top - h - 4, width: nw, height: h + 4)
    wingsRect = NSRect(x: midX - ww / 2, y: top - h - 4, width: ww, height: h + 4)
    // close to the notch: a little wider than it and a little below, the way the menu bar is reached
    nearRect = NSRect(x: midX - nw / 2 - 70, y: top - h - 30, width: nw + 140, height: h + 30)
    let host = IslandHost(rootView: IslandView(
      model: model, notchWidth: notchW, height: h, wing: wing, pill: pill,
      reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
    // the window's size is ours to set; SwiftUI must not grow it from its left edge
    host.sizingOptions = []
    p.contentView = host
    p.setFrame(big, display: true)
    fit()
    Log.write("island on \(screen.localizedName) at \(big), notch \(notchW) x \(h)")
  }

  private func watchMouse() {
    let moved: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.mouseMoved() } }
    let down: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.mouseDown() } }
    if let m = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: moved) { monitors.append(m) }
    if let m = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { moved($0); return $0 }) { monitors.append(m) }
    if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: down) { monitors.append(m) }
    if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] e in
      Log.write("click on the island at \(NSEvent.mouseLocation), panel ignores: \(self?.panel?.ignoresMouseEvents ?? true)")
      return e
    }) { monitors.append(m) }
  }

  private var isCard: Bool { switch model.phase { case .card, .quick: return true; default: return false } }

  private func mouseMoved() {
    let at = NSEvent.mouseLocation
    if model.phase == .hidden, onScreen == nil, Date().timeIntervalSince(lastPlace) > 0.5,
       let s = NSScreen.screens.first(where: { NSMouseInRect(at, $0.frame, false) }), "\(s.frame)" != placedOn { place(on: s) }
    if isCard { takeClicksUnderPointer() }
    switch model.phase {
    case .hidden:
      // close to the notch for a breath: it grows into the quick island (a pass to the menu bar does not)
      if nearRect.contains(at) {
        if insideSince == nil { insideSince = Date() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.19) { [weak self] in
          guard let self, let t = self.insideSince, Date().timeIntervalSince(t) >= 0.18,
                self.model.phase == .hidden, self.nearRect.contains(NSEvent.mouseLocation) else { return }
          self.insideSince = nil
          if let near = self.onNotchNear { near() } else { self.onNotchHover?() }
        }
      } else { insideSince = nil }
    case .prep, .recording, .ready, .folded:
      // a short dwell, so passing through to the menu bar does not open it
      if wingsRect.contains(at) {
        if insideSince == nil { insideSince = Date() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
          guard let self, let t = self.insideSince, Date().timeIntervalSince(t) >= 0.35,
                self.wingsRect.contains(NSEvent.mouseLocation) else { return }
          self.insideSince = nil
          self.onHover?()
        }
      } else { insideSince = nil }
    case .quick where model.quickPage == "settings":
      break
    case .quick, .card where hoverCard:
      let inside = cardRect.insetBy(dx: -12, dy: -12).contains(at)
      if inside { outsideSince = nil } else if outsideSince == nil { outsideSince = Date() }
      if let t = outsideSince, Date().timeIntervalSince(t) > 0.6 { outsideSince = nil; hoverCard = false; onLeave?() }
    default: break
    }
  }

  private func cardSize(_ c: Card) -> CGSize {
    let w = max(c.width, islandW)
    let body = NSHostingView(rootView: CardBody(card: c, onButton: { _ in })
      .frame(width: w - 32, alignment: .leading)
      .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 14)
      .font(.system(size: 12)).foregroundStyle(.white))
    return CGSize(width: w, height: islandH + body.fittingSize.height)
  }

  private var cardRect = NSRect.zero

  private func mouseDown() {
    if case .folded = model.phase, wingsRect.contains(NSEvent.mouseLocation) { insideSince = nil; onHover?(); return }
    if isCard { Log.write("click outside Brain at \(NSEvent.mouseLocation), card at \(cardRect), panel \(panel?.frame ?? .zero), ignores \(panel?.ignoresMouseEvents ?? true)") }
    if case .quick = model.phase, model.quickPage == "settings", !cardRect.contains(NSEvent.mouseLocation) { onOutsideClick?(); return }
    guard isCard, !hoverCard else { return }
    if !cardRect.contains(NSEvent.mouseLocation) { onOutsideClick?() }
  }

  private func fit() {
    guard let panel else { return }
    if case .card(let c) = model.phase {
      let sz = cardSize(c)
      let w = sz.width + 16, h = sz.height + 4
      cardRect = NSRect(x: midX - w / 2, y: top - h, width: w, height: h)
    } else if case .quick(let e) = model.phase {
      let w = max(420, islandW) + 16
      let body = NSHostingView(rootView: QuickBody(model: model, expanded: e).frame(width: max(420, islandW) - 28).padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 14))
      let h = islandH + body.fittingSize.height + 4
      cardRect = NSRect(x: midX - w / 2, y: top - h, width: w, height: h)
    } else {
      cardRect = .zero
    }
    if panel.frame != big { panel.setFrame(big, display: true) }
    takeClicksUnderPointer()
  }

  private func takeClicksUnderPointer() {
    let over = cardRect.contains(NSEvent.mouseLocation)
    if panel?.ignoresMouseEvents == over { panel?.ignoresMouseEvents = !over }
    if isCard, pointerTimer == nil {
      pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          if self.isCard { self.takeClicksUnderPointer(); self.mouseMoved() } else { self.pointerTimer?.invalidate(); self.pointerTimer = nil }
        }
      }
    }
  }
  private var pointerTimer: Timer?
  private var showCount = 0

  /// Show a phase; `for` hides it again after that many seconds.
  func show(_ phase: IslandModel.Phase, for seconds: Double? = nil) {
    hideWork?.cancel()
    // coming out of hiding: on the screen the pointer is on now
    if model.phase == .hidden, let s = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }),
       "\(s.frame)" != placedOn { place() }
    let wasOff = panel?.isVisible == false
    if wasOff { panel?.orderFrontRegardless() }
    switch phase { case .card, .quick: break; default: hoverCard = false }
    showCount += 1
    let mine = showCount
    let open = { [weak self] in
      // a hide or a newer show in that frame wins
      guard let self, self.showCount == mine else { return }
      self.model.fromHidden = self.model.phase == .hidden
      if self.model.fromHidden { self.model.meterFrom = Date().addingTimeInterval(0.55) }
      self.model.phase = phase
      self.fit()
    }
    if wasOff { DispatchQueue.main.async(execute: open) } else { open() }
    if let seconds {
      let work = DispatchWorkItem { [weak self] in self?.hide() }
      hideWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
  }

  /// While a call records, or a call is about to start, the island rests there instead of hiding.
  var rest: IslandModel.Phase?

  /// The brain mark beside the notch: shown whenever nothing else rests there.
  var folded: IslandModel.Phase?

  func hide() {
    hideWork?.cancel()
    showCount += 1
    hoverCard = false
    if let r = rest ?? folded { show(r); return }
    model.fromHidden = false
    model.phase = .hidden
    fit()
    panel?.ignoresMouseEvents = true
  }
}
