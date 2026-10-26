import AppKit
import Combine
import SwiftUI

/// The glass look's knobs: every value the panel reads, in one place. Saved values, if any, are read
/// at launch from ~/Library/Application Support/Brain/glass-tuning.json.
final class Tune: ObservableObject {
  /// the default look: smoke with one glass frame, unless other values were saved
  nonisolated(unsafe) static let shared: Tune = { let t = Tune(); t.preset("smoke"); t.load(); return t }()
  static let file = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Brain/glass-tuning.json")

  @Published var layout = "tiles"       // tiles: Control Center's modules; slab: one frame
  @Published var frame = "glass"        // the one frame: glass, or a solid sheet 
  @Published var style = "regular"      // regular or clear (Apple: clear only over rich media)
  @Published var tint = "none"          // none, black, white, pink
  @Published var tintAmount = 0.3       // how strong the tint is, 0 to 0.8
  @Published var dim = 0.0              // a dark layer under the glass (Apple: 35% under clear glass)
  @Published var interactive = true     // the glass answers a press
  @Published var radius = 22.0
  @Published var gap = 10.0
  @Published var pad = 14.0
  @Published var width = 380.0
  @Published var shadow = 0.0           // an extra drop under each tile; the glass has its own
  @Published var adaptiveText = true    // Apple's styles: text goes light or dark with the glass
  @Published var scheme = "auto"        // auto, light, dark
  @Published var font = "geist"         // geist or sf
  @Published var textScale = 1.0
  @Published var onColor = "white"      // the round toggle when on: white, ink, pink

  /// what changes the panel rebuilds on
  var key: String { "\(layout)\(frame)\(style)\(tint)\(tintAmount)\(dim)\(interactive)\(radius)\(gap)\(pad)\(width)\(shadow)\(adaptiveText)\(scheme)\(font)\(textScale)\(onColor)" }

  var tintColor: Color? {
    switch tint {
    case "black": return .black.opacity(tintAmount)
    case "white": return .white.opacity(tintAmount)
    case "pink": return S.brand.opacity(tintAmount)
    default: return nil
    }
  }

  var glass: Glass {
    var g: Glass = style == "clear" ? .clear : .regular
    if let c = tintColor { g = g.tint(c) }
    return g.interactive(interactive)
  }

  var onFill: Color {
    switch onColor { case "ink": return Color(white: 0.09); case "pink": return S.brand; default: return .white }
  }
  var onGlyph: Color { onColor == "ink" ? .white : .black }

  // MARK: presets and saving

  func preset(_ name: String) {
    let d = Tune()
    layout = d.layout; frame = d.frame; style = d.style; tint = d.tint; tintAmount = d.tintAmount; dim = d.dim; interactive = d.interactive
    radius = d.radius; gap = d.gap; pad = d.pad; width = d.width; shadow = d.shadow; adaptiveText = d.adaptiveText
    scheme = d.scheme; font = d.font; textScale = d.textScale; onColor = d.onColor
    switch name {
    case "smoke": tint = "black"; tintAmount = 0.42; scheme = "dark"; layout = "slab"; radius = 20; pad = 16
    case "smoke-solid": tint = "black"; tintAmount = 0.42; scheme = "dark"; layout = "slab"; radius = 20; pad = 16; frame = "solid"
    case "smoke-tiles": tint = "black"; tintAmount = 0.42; scheme = "dark"
    case "clear": style = "clear"; dim = 0.2
    case "slab": layout = "slab"; radius = 18; adaptiveText = false
    default: break   // apple: Control Center as Apple builds it
    }
  }

  var values: [String: Any] {
    ["layout": layout, "frame": frame, "style": style, "tint": tint, "tintAmount": r(tintAmount), "dim": r(dim), "interactive": interactive,
     "radius": r(radius), "gap": r(gap), "pad": r(pad), "width": r(width), "shadow": r(shadow), "adaptiveText": adaptiveText,
     "scheme": scheme, "font": font, "textScale": r(textScale), "onColor": onColor]
  }
  private func r(_ x: Double) -> Double { (x * 100).rounded() / 100 }

  func save() -> Bool {
    var v = values
    v["savedAt"] = ISO8601DateFormatter().string(from: Date())
    guard let data = try? JSONSerialization.data(withJSONObject: v, options: [.prettyPrinted, .sortedKeys]) else { return false }
    try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    return (try? data.write(to: Self.file)) != nil
  }

  /// saved values, if any (the app starts from them)
  func load() {
    guard let data = try? Data(contentsOf: Self.file), let v = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    layout = v["layout"] as? String ?? layout; frame = v["frame"] as? String ?? frame; style = v["style"] as? String ?? style; tint = v["tint"] as? String ?? tint
    tintAmount = v["tintAmount"] as? Double ?? tintAmount; dim = v["dim"] as? Double ?? dim
    interactive = v["interactive"] as? Bool ?? interactive; radius = v["radius"] as? Double ?? radius
    gap = v["gap"] as? Double ?? gap; pad = v["pad"] as? Double ?? pad; width = v["width"] as? Double ?? width
    shadow = v["shadow"] as? Double ?? shadow; adaptiveText = v["adaptiveText"] as? Bool ?? adaptiveText
    scheme = v["scheme"] as? String ?? scheme; font = v["font"] as? String ?? font
    textScale = v["textScale"] as? Double ?? textScale; onColor = v["onColor"] as? String ?? onColor
  }
}
