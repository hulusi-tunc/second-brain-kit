import AppKit
import QuartzCore

@MainActor
final class Morph {
  private var win: NSWindow?
  private var token = 0

  static let smoke = NSColor(white: 0.13, alpha: 0.94)

  /// `a` and `b` in screen points. `land` runs when the shape is about to settle (the panel shows
  /// itself there), `done` once it has; the shape then fades and its window goes.
  func run(from a: NSRect, to b: NSRect, radius ra: CGFloat, _ rb: CGFloat, color ca: NSColor, _ cb: NSColor,
           landAt: Double = 0.62, land: (() -> Void)? = nil, done: (() -> Void)? = nil) {
    cancel()
    token += 1
    let mine = token
    let area = a.union(b).insetBy(dx: -48, dy: -48)
    let w = NSWindow(contentRect: area, styleMask: .borderless, backing: .buffered, defer: false)
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true
    w.isReleasedWhenClosed = false
    // over the panel, under the island: it comes out from under the notch and goes back under it
    w.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    let v = NSView(frame: NSRect(origin: .zero, size: area.size))
    v.wantsLayer = true
    w.contentView = v
    win = w

    func local(_ r: NSRect) -> CGRect { CGRect(x: r.minX - area.minX, y: r.minY - area.minY, width: r.width, height: r.height) }
    let fa = local(a), fb = local(b)
    let l = CALayer()
    l.cornerCurve = .continuous
    l.shadowColor = NSColor.black.cgColor
    l.shadowOpacity = 0.35
    l.shadowRadius = 18
    l.shadowOffset = CGSize(width: 0, height: -8)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    l.bounds = CGRect(origin: .zero, size: fb.size)
    l.position = CGPoint(x: fb.midX, y: fb.midY)
    l.cornerRadius = rb
    l.backgroundColor = cb.cgColor
    v.layer?.addSublayer(l)
    CATransaction.commit()
    w.orderFrontRegardless()

    // Apple's way: a spring, critically damped but for a whisper of overshoot
    func spring(_ key: String, _ from: Any, _ to: Any) -> CASpringAnimation {
      let s = CASpringAnimation(keyPath: key)
      s.fromValue = from
      s.toValue = to
      s.mass = 1
      s.stiffness = 330
      s.damping = 35
      s.duration = s.settlingDuration
      return s
    }
    let pos = spring("position", NSValue(point: CGPoint(x: fa.midX, y: fa.midY)), NSValue(point: CGPoint(x: fb.midX, y: fb.midY)))
    let size = spring("bounds", NSValue(rect: CGRect(origin: .zero, size: fa.size)), NSValue(rect: CGRect(origin: .zero, size: fb.size)))
    let ease = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    let corner = CABasicAnimation(keyPath: "cornerRadius")
    corner.fromValue = ra; corner.toValue = rb; corner.duration = 0.34; corner.timingFunction = ease
    let colour = CABasicAnimation(keyPath: "backgroundColor")
    colour.fromValue = ca.cgColor; colour.toValue = cb.cgColor; colour.duration = 0.3; colour.timingFunction = ease
    l.add(pos, forKey: "position")
    l.add(size, forKey: "bounds")
    l.add(corner, forKey: "cornerRadius")
    l.add(colour, forKey: "backgroundColor")

    let total = max(pos.duration, size.duration)
    DispatchQueue.main.asyncAfter(deadline: .now() + total * landAt) { [weak self] in
      guard let self, self.token == mine else { return }
      land?()
    }
    // the shape hands over as it lands: it fades out while the panel fades in, a quick cross-fade,
    // never a dim panel sitting on it
    DispatchQueue.main.asyncAfter(deadline: .now() + total * landAt + 0.04) { [weak self] in
      guard let self, self.token == mine else { return }
      NSAnimationContext.runAnimationGroup({ ctx in
        ctx.duration = 0.12
        w.animator().alphaValue = 0
      }, completionHandler: { MainActor.assumeIsolated { if self.token == mine { self.cancel() } } })
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + total * 0.8) { [weak self] in
      guard let self, self.token == mine else { return }
      done?()
    }
  }

  func cancel() {
    win?.orderOut(nil)
    win = nil
  }
}
