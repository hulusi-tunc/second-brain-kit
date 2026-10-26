import AppKit
import SwiftUI


enum DragPhase { case began, moved, ended, click }

/// A patch that moves its window: a press that travels more than 3 points is a drag, otherwise a
/// click. The open hand shows over it, the closed hand while dragging.
struct DragArea: NSViewRepresentable {
  let on: (DragPhase) -> Void
  func makeNSView(context: Context) -> DragView { let v = DragView(); v.on = on; return v }
  func updateNSView(_ v: DragView, context: Context) { v.on = on }

  final class DragView: NSView {
    var on: ((DragPhase) -> Void)?
    private var start: NSPoint?
    private var moved = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      trackingAreas.forEach(removeTrackingArea)
      // active always: the panel is never the key window of an active app, cursor rects would not fire
      addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { if start == nil { NSCursor.openHand.set() } }
    override func mouseExited(with e: NSEvent) { if start == nil { NSCursor.arrow.set() } }
    override func mouseDown(with e: NSEvent) { start = NSEvent.mouseLocation; moved = false; Log.write("drag patch: pressed at \(NSEvent.mouseLocation)") }
    override func mouseDragged(with e: NSEvent) {
      guard let s = start else { return }
      let p = NSEvent.mouseLocation
      if !moved, hypot(p.x - s.x, p.y - s.y) < 3 { return }
      if !moved { moved = true; NSCursor.closedHand.set(); on?(.began) }
      on?(.moved)
    }
    override func mouseUp(with e: NSEvent) {
      if moved { NSCursor.openHand.set(); on?(.ended) } else { on?(.click) }
      start = nil
      moved = false
    }
  }
}

// MARK: the tucked panel

final class PuckModel: ObservableObject {
  @Published var unread = false
  @Published var shown = false
}

/// The panel tucked at the edge: a small circle of the panel's smoke glass with the brain mark,
/// a pink dot while an answer waits. Hover lifts it a little; a click opens the panel where it was.
struct PuckView: View {
  @ObservedObject var m: PuckModel
  let drag: (DragPhase) -> Void
  @State private var hover = false
  var body: some View {
    ZStack(alignment: .topTrailing) {
      BrainMark(size: 18)
        .frame(width: Puck.size, height: Puck.size)
        .glassEffect(Tune.shared.glass, in: .circle)
      if m.unread {
        Circle().fill(S.brand).frame(width: 9, height: 9).offset(x: -2, y: 2)
          .transition(.scale(scale: 0.4).combined(with: .opacity))
      }
    }
    .overlay(DragArea(on: drag))
    .scaleEffect(m.shown ? (hover ? 1.08 : 1) : 0.6)
    .opacity(m.shown ? 1 : 0)
    .animation(Motion.slide, value: m.shown)
    .animation(Motion.slide, value: hover)
    .animation(Motion.slide, value: m.unread)
    .onHover { hover = $0 }
    .help("Brain: click to open, drag along the edge")
    .padding(Puck.room)
  }
}

@MainActor
final class Puck {
  enum Side { case left, right }
  static let size: CGFloat = 46
  /// room around the circle for its shadow and the hover lift
  static let room: CGFloat = 14
  let model = PuckModel()
  private var win: NSPanel?
  var onOpen: (() -> Void)?
  var isShown: Bool { model.shown }
  /// where the circle is, in screen points
  private(set) var circle = NSRect.zero

  /// The circle's place on a side of a screen, at a height, kept on the screen.
  static func circle(on s: NSScreen, side: Side, centerY: CGFloat) -> NSRect {
    let v = s.visibleFrame
    let y = min(max(centerY - size / 2, v.minY + 10), v.maxY - size - 10)
    let x = side == .left ? v.minX + 10 : v.maxX - size - 10
    return NSRect(x: x, y: y, width: size, height: size)
  }

  func show(_ c: NSRect, appearance: NSAppearance?) {
    circle = c
    if win == nil {
      let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      p.isOpaque = false
      p.backgroundColor = .clear
      p.hasShadow = false
      p.level = .floating
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
      p.hidesOnDeactivate = false
      p.contentView = NSHostingView(rootView: PuckView(m: model, drag: { [weak self] in self?.drag($0) }))
      win = p
    }
    win?.appearance = appearance
    win?.setFrame(c.insetBy(dx: -Puck.room, dy: -Puck.room), display: true)
    win?.orderFrontRegardless()
    DispatchQueue.main.async { self.model.shown = true }
  }

  func hide() {
    guard model.shown else { return }
    model.shown = false
    model.unread = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
      guard let self, !self.model.shown else { return }
      self.win?.orderOut(nil)
    }
  }

  // dragged along the edge: it follows, then settles on the nearer side at that height
  private var offset = CGPoint.zero
  private func drag(_ phase: DragPhase) {
    guard let w = win else { return }
    let at = NSEvent.mouseLocation
    switch phase {
    case .click:
      onOpen?()
    case .began:
      offset = CGPoint(x: at.x - w.frame.minX, y: at.y - w.frame.minY)
    case .moved:
      w.setFrameOrigin(NSPoint(x: at.x - offset.x, y: at.y - offset.y))
    case .ended:
      guard let s = NSScreen.screens.first(where: { $0.frame.contains(at) }) ?? NSScreen.main else { return }
      let mid = w.frame.midX
      let c = Puck.circle(on: s, side: mid < s.visibleFrame.midX ? .left : .right, centerY: w.frame.midY)
      circle = c
      let to = c.insetBy(dx: -Puck.room, dy: -Puck.room)
      if Motion.reduce { w.setFrame(to, display: true); return }
      NSAnimationContext.runAnimationGroup { ctx in
        ctx.duration = 0.32
        ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.25, 0.5, 1)   // lands with a small overshoot
        w.animator().setFrame(to, display: true)
      }
    }
  }
}
