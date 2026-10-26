import AppKit
import WebKit

/// Brain Home: the dial of your brain in a window of its own; a solid base, glass panels. The page is
/// home/index.html in the brain repo, its data (home/data.js) made fresh by home/collect.py each time
/// the window opens. brain:// links from it go straight to the app (done, still on, drop, ask), web
/// links open in the browser. Opening Brain again (Spotlight, Finder) or brain://home shows it; the
/// Dock icon is there only while it is open.
final class BrainHome: NSObject, WKNavigationDelegate, NSWindowDelegate, WKScriptMessageHandler {
  var onLink: ((URL) -> Void)?
  /// a question asked in Brain Home: the answer streams back into the page, not the notch
  var onAsk: ((_ q: String, _ earlier: String, _ line: @escaping (String) -> Void, _ done: @escaping (String) -> Void) -> Void)?
  var onStop: (() -> Void)?
  private var window: NSWindow?
  private var web: WKWebView?
  private var collecting: Process?
  private var root: URL { Config.repo }
  private var dir: URL { root.appendingPathComponent("home") }

  /// carried in when it opens: an answer from the notch, or the ask field focused
  private var pendingJS: String?
  func show(seed: (q: String, out: String)? = nil, focusAsk: Bool = false, page: String? = nil) {
    if let page, let data = try? JSONSerialization.data(withJSONObject: [page]), let json = String(data: data, encoding: .utf8) {
      pendingJS = "window.brainPage && window.brainPage(\(json)[0])"
    } else if let seed, let data = try? JSONSerialization.data(withJSONObject: [seed.q, seed.out]), let json = String(data: data, encoding: .utf8) {
      pendingJS = "window.brainSeed && window.brainSeed(...\(json))"
    } else if focusAsk { pendingJS = "window.brainFocus && window.brainFocus()" }
    NSApp.setActivationPolicy(.regular)
    installMenu()
    if let w = window {
      w.makeKeyAndOrderFront(nil); NSApp.activate(); refresh(); return
    }
    let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let size = NSSize(width: min(1500, vis.width * 0.92), height: min(960, vis.height * 0.92))
    let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                     styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                     backing: .buffered, defer: false)
    w.title = "Brain"
    w.titleVisibility = .hidden
    w.titlebarAppearsTransparent = true
    w.isOpaque = true
    w.backgroundColor = .windowBackgroundColor
    w.minSize = NSSize(width: 1000, height: 640)
    w.isReleasedWhenClosed = false
    w.delegate = self
    w.center()
    w.setFrameAutosaveName("BrainHome")

    // the window is solid, the page paints its own soft backdrop and only its floating panels are glass
    let holder = NSView()
    let cfg = WKWebViewConfiguration()
    cfg.userContentController.add(self, name: "brain")
    // pages open inside Brain: the page reads the repo's text through this
    cfg.setURLSchemeHandler(RepoFiles(root: root), forURLScheme: "brainfile")
    let v = WKWebView(frame: .zero, configuration: cfg)
    v.navigationDelegate = self
    v.setValue(false, forKey: "drawsBackground")
    v.translatesAutoresizingMaskIntoConstraints = false
    holder.addSubview(v)
    // a strip along the top to move the window by, the traffic lights stay where they are
    let drag = DragStrip()
    drag.translatesAutoresizingMaskIntoConstraints = false
    holder.addSubview(drag)
    NSLayoutConstraint.activate([
      v.leadingAnchor.constraint(equalTo: holder.leadingAnchor), v.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
      v.topAnchor.constraint(equalTo: holder.topAnchor), v.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
      drag.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 80), drag.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
      drag.topAnchor.constraint(equalTo: holder.topAnchor), drag.heightAnchor.constraint(equalToConstant: 30),
    ])
    w.contentView = holder
    window = w; web = v
    load()
    w.makeKeyAndOrderFront(nil)
    NSApp.activate()
    refresh()
    Log.write("brain home: open")
  }

  private func load() {
    var c = URLComponents(url: dir.appendingPathComponent("index.html"), resolvingAgainstBaseURL: false)!
    c.queryItems = [URLQueryItem(name: "native", value: "1")]
    web?.loadFileURL(c.url!, allowingReadAccessTo: dir)
  }

  /// the map's data, read again from the repo; the page reloads when it is ready
  private func refresh() {
    guard collecting == nil else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["python3", dir.appendingPathComponent("collect.py").path]
    p.currentDirectoryURL = root
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
    p.environment = env
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    p.terminationHandler = { [weak self] proc in
      DispatchQueue.main.async {
        self?.collecting = nil
        if proc.terminationStatus == 0 { self?.web?.reload() }
        Log.write("brain home: data refreshed, exit \(proc.terminationStatus)")
      }
    }
    collecting = p
    do { try p.run() } catch { collecting = nil }
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let js = pendingJS else { return }
    // the page reloads once its data is fresh; carry it over after that reload when one is coming
    if collecting == nil { pendingJS = nil }
    webView.evaluateJavaScript(js)
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = action.request.url else { return decisionHandler(.cancel) }
    switch url.scheme?.lowercased() {
    case "file", "about":
      decisionHandler(.allow)
    case "brain":
      onLink?(url); decisionHandler(.cancel)
    case "obsidian":
      // an old obsidian:// link: read it here instead
      let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value ?? ""
      let rel = path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path
      if let data = try? JSONSerialization.data(withJSONObject: [rel]), let json = String(data: data, encoding: .utf8) {
        webView.evaluateJavaScript("window.brainPage && window.brainPage(\(json)[0])")
      }
      decisionHandler(.cancel)
    default:
      NSWorkspace.shared.open(url); decisionHandler(.cancel)
    }
  }

  /// the page asks: {type: "ask", q, earlier} or {type: "stop"}
  func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
    if type == "stop" { onStop?(); return }
    guard type == "ask", let q = m["q"] as? String, !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
    Log.write("brain home: ask, \(q.count) chars")
    onAsk?(q, m["earlier"] as? String ?? "", { [weak self] line in self?.send("brainLine", line) }, { [weak self] out in self?.send("brainDone", out) })
  }

  private func send(_ fn: String, _ text: String) {
    guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed]), let json = String(data: data, encoding: .utf8) else { return }
    DispatchQueue.main.async { self.web?.evaluateJavaScript("window.\(fn) && window.\(fn)(\(json)[0])") }
  }

  func windowWillClose(_ notification: Notification) {
    // back to the notch only: no Dock icon, no menu bar of its own
    NSApp.setActivationPolicy(.accessory)
    Log.write("brain home: closed")
  }

  /// the menus a window needs: copy and paste in the ask field, Command W, minimise
  private func installMenu() {
    guard NSApp.mainMenu?.items.first?.submenu?.title != "Brain" else { return }
    let main = NSMenu()
    let appItem = NSMenuItem(); let appMenu = NSMenu(title: "Brain")
    appMenu.addItem(withTitle: "Close Brain Home", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide Brain", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appItem.submenu = appMenu; main.addItem(appItem)
    let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
    edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    edit.addItem(.separator())
    edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = edit; main.addItem(editItem)
    let winItem = NSMenuItem(); let win = NSMenu(title: "Window")
    win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    winItem.submenu = win; main.addItem(winItem)
    NSApp.mainMenu = main
  }
}

/// the top strip of Brain Home: dragging it moves the window, a double click zooms it
private final class DragStrip: NSView {
  override var mouseDownCanMoveWindow: Bool { true }
  override func mouseDown(with event: NSEvent) {
    if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
  }
}


/// brainfile://read/<path in the repo>: the repo's text files, read only, for Brain Home's page reader.
/// Only text, only inside the repo, never private/.
final class RepoFiles: NSObject, WKURLSchemeHandler {
  let root: URL
  init(root: URL) { self.root = root.standardizedFileURL }
  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let url = task.request.url else { return }
    let rel = (url.path.removingPercentEncoding ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let file = root.appendingPathComponent(rel).standardizedFileURL
    let ok = file.path.hasPrefix(root.path + "/") && !rel.hasPrefix("private/") && !rel.contains("/.")
      && ["md", "txt", "json", "csv"].contains(file.pathExtension.lowercased())
    guard ok, let data = try? Data(contentsOf: file) else {
      task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: ["Access-Control-Allow-Origin": "*"])!)
      task.didFinish(); return
    }
    task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "text/plain; charset=utf-8", "Access-Control-Allow-Origin": "*"])!)
    task.didReceive(data); task.didFinish()
  }
  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
