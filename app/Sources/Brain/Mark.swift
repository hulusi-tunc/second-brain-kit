import AppKit
import SwiftUI

struct BrainMark: View {
  var size: CGFloat = 16
  var live = false
  var color: Color = pink
  private let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: !live || reduce)) { ctx in
      let t = ctx.date.timeIntervalSinceReferenceDate
      Canvas { c, sz in
        let s = sz.width / 80   // the figure's box is 80 wide, from 10 to 90
        let cols = [1, 3, 2, 1]
        for (i, n) in cols.enumerated() {
          // live: each column 0.86 to 1 in size and 0.55 to 1 in strength, a beat apart
          let beat = live && !reduce ? (sin(t * 5.7 - Double(i) * 0.9) + 1) / 2 : 1
          let scale = 0.86 + 0.14 * beat
          var col = c
          col.opacity = 0.55 + 0.45 * beat
          for k in 0..<n {
            let cx = 50 + (Double(i) - 1.5) * 21
            let cy = 50 + (Double(k) - Double(n - 1) / 2) * 15.6
            let w = 15.2 * scale
            let r = CGRect(x: (cx - w / 2 - 10) * s, y: (cy - w / 2 - 10) * s, width: w * s, height: w * s)
            col.fill(Path(roundedRect: r, cornerRadius: 5.3 * scale * s, style: .continuous), with: .color(color))
          }
        }
      }
    }
    .frame(width: size, height: size)
    .accessibilityLabel("Brain")
  }
}
