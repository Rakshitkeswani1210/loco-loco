import AppKit
import UniformTypeIdentifiers
import WebKit

/// Takes a picture of the page a server opens, in an offscreen web view, for the preview card.
/// Two at a time. A page can only read: a script refuses anything but GET and HEAD, so a snapshot never writes data.
@MainActor
final class Snapshotter: NSObject {
  struct Result {
    let title: String?
    /// The address taken when it isn't the root, like an API's "/docs". Nil for the root.
    let path: String?
  }

  static var folder: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Loco Loco/Snapshots")
  }

  static func file(for id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".png") }

  /// Deletes snapshots of servers no longer in history.
  static func clean(keeping ids: Set<UUID>) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in names where name.hasSuffix(".png") {
      guard let id = UUID(uuidString: String(name.dropLast(4))), !ids.contains(id) else { continue }
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
  }

  private struct Job {
    let id: UUID
    let port: UInt16
    let folder: String?
    let done: @MainActor (Result?) -> Void
  }

  private var waiting: [Job] = []
  private var running: [UUID: Capture] = [:]
  private let limit = 2

  func isBusy(_ id: UUID) -> Bool { running[id] != nil || waiting.contains { $0.id == id } }

  /// `done` gets nil when no picture could be taken; the last one stays.
  /// With `folder`, a stopped static server: its index.html is read straight from the folder, with nothing running.
  func take(_ id: UUID, port: UInt16, folder: String? = nil, done: @escaping @MainActor (Result?) -> Void) {
    guard !isBusy(id) else { return }
    waiting.append(Job(id: id, port: port, folder: folder, done: done))
    startNext()
  }

  private func startNext() {
    while running.count < limit, !waiting.isEmpty {
      let job = waiting.removeFirst()
      let capture = Capture(port: job.port, folder: job.folder, file: Self.file(for: job.id))
      running[job.id] = capture
      capture.run { [weak self] result in
        self?.running[job.id] = nil
        job.done(result)
        self?.startNext()
      }
    }
  }
}

/// Serves a built site to the web view. Opened as plain files, a Next.js export loses its styles, because it asks for
/// `/_next/…` from the root.
@MainActor
private final class FolderSite: NSObject, WKURLSchemeHandler {
  static let scheme = "loco-folder"
  private let root: URL

  init(root: URL) { self.root = root }

  func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
    guard let url = task.request.url else { task.didFailWithError(URLError(.badURL)); return }
    var file = root.appendingPathComponent(url.path)
    var isFolder: ObjCBool = false
    if FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), isFolder.boolValue { file.appendPathComponent("index.html") }
    let inside = file.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    guard inside, let data = try? Data(contentsOf: file) else {
      task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!)
      task.didFinish()
      return
    }
    let type = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!)
    task.didReceive(data)
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// One snapshot: finds a page to show, loads it, waits for its requests to settle, saves a 640 × 400 PNG.
@MainActor
private final class Capture: NSObject, WKNavigationDelegate {
  private let port: UInt16
  private let folder: String?
  private let file: URL
  private var window: NSWindow?
  private var web: WKWebView?
  private var finish: ((Snapshotter.Result?) -> Void)?
  private var path: String?
  private var timeout: Timer?

  /// Counts requests in flight, and lets only GET and HEAD through.
  private static let readOnly = """
    (() => {
      const ok = m => !m || /^(GET|HEAD)$/i.test(m);
      window.__locoPending = 0;
      const track = p => { window.__locoPending++; return p.finally(() => window.__locoPending--); };
      const f = window.fetch;
      window.fetch = (input, init) => {
        const m = (init && init.method) || (input && input.method);
        return ok(m) ? track(f(input, init)) : Promise.reject(new TypeError('Loco Loco snapshot: read only'));
      };
      const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, ...rest) {
        if (!ok(m)) throw new Error('Loco Loco snapshot: read only');
        return open.call(this, m, ...rest);
      };
      XMLHttpRequest.prototype.send = function (...a) {
        window.__locoPending++;
        this.addEventListener('loadend', () => window.__locoPending--, { once: true });
        return send.apply(this, a);
      };
      navigator.sendBeacon = () => false;
      HTMLFormElement.prototype.submit = function () {};
      addEventListener('submit', e => e.preventDefault(), true);
    })();
    """

  init(port: UInt16, folder: String?, file: URL) {
    self.port = port
    self.folder = folder
    self.file = file
  }

  func run(_ finish: @escaping (Snapshotter.Result?) -> Void) {
    self.finish = finish
    timeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.end(nil) }
    }
    if let folder {
      load(URL(string: FolderSite.scheme + "://site/index.html")!, site: FolderSite(root: URL(fileURLWithPath: folder, isDirectory: true)))
      return
    }
    Task {
      let root = URL(string: "http://localhost:\(port)/")!
      let kind = await Self.kind(of: root)
      if kind == .page { load(root); return }
      // An API: its docs page when it has one (FastAPI), else no picture.
      let docs = URL(string: "http://localhost:\(port)/docs")!
      if await Self.kind(of: docs) == .page {
        path = "/docs"
        load(docs)
        return
      }
      try? FileManager.default.removeItem(at: file)
      end(kind == .json ? Snapshotter.Result(title: "JSON API", path: nil) : nil)
    }
  }

  private enum Kind { case page, json, other }

  private static func kind(of url: URL) async -> Kind {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
    request.httpMethod = "GET"
    guard let (_, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return .other }
    let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
    if (200..<400).contains(http.statusCode), type.contains("text/html") { return .page }
    return type.contains("json") ? .json : .other
  }

  private func load(_ url: URL, site: FolderSite? = nil) {
    let config = WKWebViewConfiguration()
    if let site { config.setURLSchemeHandler(site, forURLScheme: FolderSite.scheme) }
    config.websiteDataStore = .nonPersistent()
    config.userContentController.addUserScript(WKUserScript(source: Self.readOnly, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    config.mediaTypesRequiringUserActionForPlayback = .all
    let size = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let web = WKWebView(frame: size, configuration: config)
    web.navigationDelegate = self
    // Offscreen and invisible, but in a window, or WebKit doesn't paint.
    let window = NSWindow(contentRect: size.offsetBy(dx: -20000, dy: -20000), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.contentView = web
    window.orderBack(nil)
    self.web = web
    self.window = window
    web.load(URLRequest(url: url))
  }

  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
    action.request.httpMethod.map { ["GET", "HEAD"].contains($0.uppercased()) } ?? true ? .allow : .cancel
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    Task { await settleAndShoot(webView) }
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { end(nil) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { end(nil) }

  /// Waits until no request has been in flight for a second, at least two seconds after load (decks fade in) and at most 10.
  private func settleAndShoot(_ web: WKWebView) async {
    let start = Date()
    var quiet = 0
    try? await Task.sleep(for: .seconds(2))
    while Date().timeIntervalSince(start) < 10, quiet < 2 {
      let pending = (try? await web.evaluateJavaScript("window.__locoPending|0") as? Int) ?? 0
      quiet = pending == 0 ? quiet + 1 : 0
      try? await Task.sleep(for: .milliseconds(500))
    }
    let title = (try? await web.evaluateJavaScript("document.title") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let config = WKSnapshotConfiguration()
    config.snapshotWidth = 640
    guard let image = try? await web.takeSnapshot(configuration: config),
          let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { end(nil); return }
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard (try? png.write(to: file, options: .atomic)) != nil else { end(nil); return }
    end(Snapshotter.Result(title: title?.isEmpty == false ? title : nil, path: path))
  }

  private func end(_ result: Snapshotter.Result?) {
    guard let finish else { return }
    self.finish = nil
    timeout?.invalidate()
    web?.stopLoading()
    web?.navigationDelegate = nil
    window?.orderOut(nil)
    window?.contentView = nil
    web = nil
    window = nil
    finish(result)
  }
}
