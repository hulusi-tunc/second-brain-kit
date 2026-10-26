import AppKit
import CoreText
import SwiftUI

enum S {
  private static func c(_ l: NSColor, _ d: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? d : l })
  }
  private static func rgb(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
  }
  static var look = UserDefaults.standard.string(forKey: "panelLook") ?? "cc"
  static var onGlass: Bool { look == "glass" || look == "smoke" || look == "cc" }
  struct Inks { let ink1, ink2, ink3, sheet, card, line, lineFaint, fillHover, fillQuiet, fillSelected, fillPressed, track: Color }
  private static let o = Inks(
    ink1: c(rgb(0x171717), rgb(0xededed)), ink2: c(rgb(0x666666), rgb(0xa1a1a1)), ink3: c(rgb(0xa9a9a9), rgb(0x6b6b6b)),
    sheet: c(rgb(0xffffff), rgb(0x1c1c1c)), card: c(rgb(0xffffff), rgb(0x1a1a1a)),
    line: c(rgb(0x000000, 0.085), rgb(0xffffff, 0.08)), lineFaint: c(rgb(0x000000, 0.075), rgb(0xffffff, 0.06)),
    fillHover: c(rgb(0x171717, 0.035), rgb(0xededed, 0.05)), fillQuiet: c(rgb(0x171717, 0.05), rgb(0xededed, 0.07)),
    fillSelected: c(rgb(0x171717, 0.07), rgb(0xededed, 0.10)), fillPressed: c(rgb(0x171717, 0.11), rgb(0xededed, 0.14)),
    track: c(rgb(0x171717, 0.20), rgb(0xededed, 0.20)))
  /// on glass the inks let the glass through, as Apple's vibrant labels do
  private static let g = Inks(
    ink1: c(rgb(0x000000, 0.86), rgb(0xffffff, 0.94)), ink2: c(rgb(0x000000, 0.56), rgb(0xffffff, 0.62)), ink3: c(rgb(0x000000, 0.32), rgb(0xffffff, 0.36)),
    sheet: .clear, card: c(rgb(0x000000, 0.035), rgb(0xffffff, 0.06)),
    line: c(rgb(0x000000, 0.09), rgb(0xffffff, 0.10)), lineFaint: c(rgb(0x000000, 0.07), rgb(0xffffff, 0.08)),
    fillHover: c(rgb(0x000000, 0.04), rgb(0xffffff, 0.06)), fillQuiet: c(rgb(0x000000, 0.055), rgb(0xffffff, 0.08)),
    fillSelected: c(rgb(0x000000, 0.08), rgb(0xffffff, 0.12)), fillPressed: c(rgb(0x000000, 0.12), rgb(0xffffff, 0.16)),
    track: c(rgb(0x000000, 0.18), rgb(0xffffff, 0.22)))
  private static var k: Inks { onGlass ? g : o }
  static var cc: Bool { look == "cc" && Tune.shared.adaptiveText }
  private static func st(_ fixed: Color, _ live: AnyShapeStyle) -> AnyShapeStyle { cc ? live : AnyShapeStyle(fixed) }
  static var ink1: AnyShapeStyle { st(k.ink1, AnyShapeStyle(.primary)) }
  static var ink2: AnyShapeStyle { st(k.ink2, AnyShapeStyle(.secondary)) }
  static var ink3: AnyShapeStyle { st(k.ink3, AnyShapeStyle(.tertiary)) }
  static var sheet: AnyShapeStyle { st(k.sheet, AnyShapeStyle(Color.clear)) }
  static var card: AnyShapeStyle { st(k.card, AnyShapeStyle(.quinary)) }
  static var line: AnyShapeStyle { st(k.line, AnyShapeStyle(.quaternary)) }
  static var lineFaint: AnyShapeStyle { st(k.lineFaint, AnyShapeStyle(.quinary)) }
  static var fillHover: AnyShapeStyle { st(k.fillHover, AnyShapeStyle(.quinary)) }
  static var fillQuiet: AnyShapeStyle { st(k.fillQuiet, AnyShapeStyle(.quinary)) }
  static var fillSelected: AnyShapeStyle { st(k.fillSelected, AnyShapeStyle(.quaternary)) }
  static var fillPressed: AnyShapeStyle { st(k.fillPressed, AnyShapeStyle(.tertiary)) }
  static var track: AnyShapeStyle { st(k.track, AnyShapeStyle(.tertiary)) }
  static let clear = AnyShapeStyle(Color.clear)
  static let solidSheet = c(rgb(0xffffff), rgb(0x1c1c1c))
  static let ok = c(rgb(0x16a34a), rgb(0x4ade80))
  static let brand = Color(nsColor: rgb(0xff8fc7))

  static func registerFont() {
    guard let url = Bundle.main.url(forResource: "Geist-Variable", withExtension: "ttf") else { return }
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
  }
  static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    let t = Tune.shared, z = size * t.textScale
    return t.font != "sf" && NSFont(name: "Geist", size: z) != nil ? .custom("Geist", size: z).weight(weight) : .system(size: z, weight: weight)
  }
  static var body: Font { font(13) }
  static var meta: Font { font(12) }
  static var title: Font { font(15, .semibold) }
  static var answer: Font { font(17, .semibold) }
}

enum Motion {
  static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
  /// on-screen movement: the tab plate, sizes, the frame's height
  static var slide: Animation { reduce ? .easeOut(duration: 0.15) : .spring(duration: 0.34, bounce: 0.14) }
  /// entering: a strong ease-out
  static var enter: Animation { reduce ? .easeOut(duration: 0.15) : .timingCurve(0.23, 1, 0.32, 1, duration: 0.32) }
  /// hover and press: quick
  static let hover = Animation.easeOut(duration: 0.12)
  /// how far things travel when they come in
  static var travel: CGFloat { reduce ? 0 : 1 }
}

/// Enters with opacity, a small rise and a little blur, after a delay (for staggered lists).
struct Rise: ViewModifier {
  var delay = 0.0
  var y: CGFloat = 6
  @State private var shown = false
  func body(content: Content) -> some View {
    content
      .opacity(shown ? 1 : 0)
      .offset(y: shown ? 0 : y * Motion.travel)
      .blur(radius: shown || Motion.reduce ? 0 : 2)
      .onAppear { withAnimation(Motion.enter.delay(Motion.reduce ? 0 : delay)) { shown = true } }
  }
}

/// Opacity with a little blur both ways, plus a small slide in from the side it comes from.
struct BlurFade: ViewModifier {
  let on: Bool
  var x: CGFloat = 0
  func body(content: Content) -> some View {
    content.opacity(on ? 0 : 1).blur(radius: on && !Motion.reduce ? 3 : 0).offset(x: on ? x * Motion.travel : 0)
  }
}
extension AnyTransition {
  static func tabSwitch(_ dir: CGFloat) -> AnyTransition {
    .asymmetric(insertion: .modifier(active: BlurFade(on: true, x: 18 * dir), identity: BlurFade(on: false)),
                removal: .identity)
  }
}

struct STabs<T: Hashable>: View {
  let items: [(T, String)]
  @Binding var selected: T
  var pill = false
  @Namespace private var ns
  @State private var hover: T?
  var body: some View {
    HStack(spacing: 2) {
      ForEach(items, id: \.0) { value, label in
        let on = value == selected
        Button { withAnimation(Motion.slide) { selected = value } } label: {
          ZStack {
            // the medium weight's width, kept, so a tab never changes size when chosen
            Text(label).font(S.font(13, .medium)).hidden()
            Text(label).font(S.font(13, on ? .medium : .regular)).foregroundStyle(on ? S.ink1 : S.ink2)
          }
          .padding(.horizontal, pill ? 12 : 10).frame(height: 28)
          .background {
            if on {
              if Motion.reduce { plate.fill(S.fillSelected) } else { plate.fill(S.fillSelected).matchedGeometryEffect(id: "plate", in: ns) }
            } else if hover == value {
              plate.fill(S.fillHover).transition(.opacity)
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(SPress())
        .onHover { h in withAnimation(Motion.hover) { hover = h ? value : (hover == value ? nil : hover) } }
      }
    }
    .animation(Motion.slide, value: selected)
    .fixedSize()
  }
  private var plate: AnyShape { pill ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous)) }
}

struct SIconButton: View {
  let symbol: String
  let help: String
  var on = false
  /// inside a pill: a circle, concentric with the capsule's ends
  var round = false
  let action: () -> Void
  @State private var hover = false
  var body: some View {
    Button { withAnimation(Motion.slide) { action() } } label: {
      Image(systemName: symbol).font(.system(size: 13, weight: .regular)).foregroundStyle(on ? S.ink1 : S.ink2)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 28, height: 28)
        .background(plate.fill(on ? S.fillSelected : hover ? S.fillHover : S.clear))
        .contentShape(Rectangle())
    }
    .buttonStyle(SPress()).help(help)
    .onHover { h in withAnimation(Motion.hover) { hover = h } }
  }
  private var plate: AnyShape { round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6, style: .continuous)) }
}

/// Pressed: a little smaller, as the library's press scale.
struct SPress: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1).animation(.easeOut(duration: 0.08), value: configuration.isPressed)
  }
}

struct SButton: View {
  let label: String
  var brand = false
  let action: () -> Void
  @State private var hover = false
  var body: some View {
    Button(action: action) {
      Text(label).font(S.font(13, .medium)).foregroundStyle(brand ? AnyShapeStyle(Color.black) : S.ink1)
        .padding(.horizontal, 10).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(brand ? AnyShapeStyle(S.brand) : hover ? S.fillSelected : S.fillQuiet))
    }
    .buttonStyle(SPress()).onHover { hover = $0 }
  }
}

struct SMark: View {
  let state: String
  var body: some View {
    ZStack {
      switch state {
      case "needs":
        Circle().fill(S.brand).frame(width: 7.2, height: 7.2)
      case "progress":
        Circle().strokeBorder(S.ink3, lineWidth: 1.5).frame(width: 12, height: 12)
        Circle().trim(from: 0, to: 0.5).fill(S.ink2).frame(width: 6, height: 6).rotationEffect(.degrees(-90))
      case "done":
        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(S.ok)
      case "idle":
        Circle().fill(S.ink3).frame(width: 4, height: 4)
      default:
        Circle().strokeBorder(S.ink3, lineWidth: 1.5).frame(width: 12, height: 12)
      }
    }
    .frame(width: 16, height: 16)
  }
  static func of(_ s: String) -> String {
    switch s { case "overdue": return "needs"; case "due": return "progress"; case "done": return "done"; case "info", "": return "idle"; default: return "backlog" }
  }
}

struct SSecHead: View {
  let label: String
  var count: Int? = nil
  var body: some View {
    HStack(spacing: 8) {
      Text(label).font(S.font(12, .medium)).foregroundStyle(S.ink2)
      if let count { Text("\(count)").font(S.meta).monospacedDigit().foregroundStyle(S.ink2) }
    }
    .padding(.top, 14).padding(.bottom, 4)
  }
}

struct SRow: View {
  var lead: AnyView
  let title: String
  var sub = ""
  var meta = ""
  var strong = false
  let action: () -> Void
  @State private var hover = false
  var body: some View {
    Button(action: action) {
      HStack(alignment: .top, spacing: 8) {
        lead.frame(width: 16, height: 20)
        VStack(alignment: .leading, spacing: 0) {
          Text(title).font(S.body).foregroundStyle(S.ink1).lineLimit(2).fixedSize(horizontal: false, vertical: true)
          if !sub.isEmpty { Text(sub).font(S.meta).foregroundStyle(S.ink2).lineLimit(1) }
        }
        Spacer(minLength: 8)
        if !meta.isEmpty {
          Text(meta).font(S.font(12, strong ? .medium : .regular)).monospacedDigit().foregroundStyle(strong ? S.ink1 : S.ink2).padding(.top, 2)
        }
      }
      .padding(.horizontal, 8).padding(.vertical, 6).frame(minHeight: 44, alignment: .top)
      .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? S.fillHover : S.clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(SPress()).padding(.horizontal, -8)
    .onHover { h in withAnimation(Motion.hover) { hover = h } }
  }
}

struct SSwitch: View {
  @Binding var on: Bool
  var body: some View {
    Button { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { on.toggle() } } label: {
      ZStack(alignment: on ? .trailing : .leading) {
        Capsule().fill(on ? S.ink1 : S.track).frame(width: 34, height: 20)
        // the library's knob: white, a half-point ring and a small drop (--elevation-knob)
        Circle().fill(Color.white).frame(width: 16, height: 16)
          .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
          .shadow(color: .black.opacity(0.3), radius: 1, y: 1).padding(2)
      }
    }
    .buttonStyle(.plain)
  }
}

struct SKeys: View {
  let keys: [String]
  /// at the end of a pill: pill caps, concentric with it
  var pill = false
  var body: some View {
    HStack(spacing: 2) {
      ForEach(keys, id: \.self) { k in
        Text(k).font(S.font(12, .medium)).foregroundStyle(S.ink2).padding(.horizontal, pill ? 6 : 4).frame(minWidth: 20, minHeight: 20)
          .background((pill ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: 4, style: .continuous))).fill(S.fillQuiet))
      }
    }
  }
}

struct STag: View {
  let text: String
  var badge: String? = nil
  var tint: Color = .gray
  var body: some View {
    HStack(spacing: 4) {
      if let badge {
        Text(badge).font(S.font(8, .semibold)).foregroundStyle(.white).frame(width: 14, height: 14).background(Circle().fill(tint))
      }
      Text(text).font(S.font(12, .medium)).foregroundStyle(S.ink2).lineLimit(1)
    }
    .padding(.leading, badge == nil ? 8 : 3).padding(.trailing, 8).frame(height: 20)
    .background(Capsule().fill(S.fillQuiet))
  }
}
