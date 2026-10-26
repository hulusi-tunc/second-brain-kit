import AppKit
import ApplicationServices

/// The brain in the notch: the app asks bin/brain-ask.sh in your brain repo, which runs Claude
/// against the repo, read only, and reads lines back. A question takes a few seconds, a rewrite a
/// little less; the prep for a call is made ahead of time, so it is never waited on.
enum Brain {
  static var script: String { Config.script("brain-ask.sh") }

  /// Runs the script off the main thread; `done` gets its output on the main thread. Keep the
  /// process to cancel it.
  @discardableResult
  static func run(_ args: [String], input: String? = nil, done: @escaping (String) -> Void) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script] + args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    let inPipe = Pipe()
    p.standardInput = inPipe
    DispatchQueue.global(qos: .userInitiated).async {
      do { try p.run() } catch { DispatchQueue.main.async { done("") }; return }
      if let input { inPipe.fileHandleForWriting.write(Data(input.utf8)) }
      try? inPipe.fileHandleForWriting.close()
      let data = out.fileHandleForReading.readDataToEndOfFile()
      p.waitUntilExit()
      let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      DispatchQueue.main.async { if p.terminationReason != .uncaughtSignal { done(text) } }
    }
    return p
  }

  /// Like `run`, but every line reaches `onLine` the moment the script prints it (the brain's STEP
  /// lines), and `done` gets the whole output at the end. Both on the main thread.
  @discardableResult
  static func stream(_ args: [String], onLine: @escaping (String) -> Void, done: @escaping (String) -> Void) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [script] + args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    p.standardInput = FileHandle.nullDevice
    let lock = NSLock()
    var buffer = Data(), all = ""
    out.fileHandleForReading.readabilityHandler = { h in
      let d = h.availableData
      guard !d.isEmpty else { return }
      lock.lock()
      buffer.append(d)
      var lines: [String] = []
      while let nl = buffer.firstIndex(of: 0x0A) {
        lines.append(String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self))
        buffer.removeSubrange(buffer.startIndex...nl)
      }
      all += lines.map { $0 + "\n" }.joined()
      lock.unlock()
      if !lines.isEmpty { DispatchQueue.main.async { lines.forEach(onLine) } }
    }
    p.terminationHandler = { proc in
      out.fileHandleForReading.readabilityHandler = nil
      lock.lock()
      let rest = String(decoding: buffer, as: UTF8.self)
      let text = (all + rest).trimmingCharacters(in: .whitespacesAndNewlines)
      lock.unlock()
      DispatchQueue.main.async { if proc.terminationReason != .uncaughtSignal { done(text) } }
    }
    do { try p.run() } catch { DispatchQueue.main.async { done("") } }
    return p
  }

  /// One line's fields after "KEY:", split on "||"
  static func fields(_ line: String) -> [String] {
    guard let c = line.firstIndex(of: ":") else { return [] }
    return line[line.index(after: c)...].components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespaces) }
  }

  /// "KEY: left || right" lines
  static func lines(_ text: String, _ key: String) -> [(String, String)] {
    text.split(separator: "\n").compactMap { l in
      guard l.hasPrefix(key + ":") else { return nil }
      let rest = l.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
      let parts = rest.components(separatedBy: "||").map { $0.trimmingCharacters(in: .whitespaces) }
      return (parts[0], parts.count > 1 ? parts[1] : "")
    }
  }

  /// a page from the repo, read in Brain Home; set in main
  static var onOpen: ((String) -> Void)?
  static func open(_ relative: String) { onOpen?(relative) }
}

/// The text selected in the front app. First through Accessibility (Electron apps such as Slack
/// and Cursor expose it only once asked to, so the app asks). Some apps never answer, so then the
/// app copies the selection itself with ⌘C once your keys are up, and puts your clipboard back.
enum Selection {
  enum Read { case text(String), none, unknown }

  static func read() -> Read {
    guard let app = NSWorkspace.shared.frontmostApplication else { return .unknown }
    let appEl = AXUIElementCreateApplication(app.processIdentifier)
    AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
          let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return .unknown }
    var sel: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextAttribute as CFString, &sel) == .success,
          let s = sel as? String else { return .unknown }
    return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .none : .text(s)
  }

  /// ⌘C into the front app once no modifier is held (so it is not ⌘⌥C), the copy read, your
  /// clipboard restored. nil when nothing was selected (the clipboard did not change).
  static func viaCopy(_ done: @escaping (String?) -> Void) {
    func waitKeysUp(_ tries: Int) {
      let held = NSEvent.modifierFlags.intersection([.command, .option, .control, .shift])
      if !held.isEmpty && tries < 40 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { waitKeysUp(tries + 1) }
        return
      }
      let pb = NSPasteboard.general
      let saved: [(NSPasteboard.PasteboardType, Data)] = (pb.pasteboardItems ?? []).flatMap { item in
        item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
      }
      let before = pb.changeCount
      let src = CGEventSource(stateID: .hidSystemState)
      let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)
      let up = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
      down?.flags = .maskCommand; up?.flags = .maskCommand
      down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
        guard pb.changeCount != before else { done(nil); return }
        let text = pb.string(forType: .string)
        pb.clearContents()
        if !saved.isEmpty {
          let item = NSPasteboardItem()
          for (t, d) in saved { item.setData(d, forType: t) }
          pb.writeObjects([item])
        }
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        done(t.isEmpty ? nil : text)
      }
    }
    waitKeysUp(0)
  }
}
