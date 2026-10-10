#if TEST_HOOKS
import AppKit

/// Drives the panel from the command line for screenshots and checks. Compiled in only by `scripts/build.sh --test-hooks`.
/// Commands arrive as distributed notifications named `com.rakshit.locoloco.test` whose object is the command,
/// such as `toggle`, `row 8765`, `btn stop`, `click` or `dump /tmp/state.json`.
@MainActor
final class TestHooks {
  private let controller: AppController
  private var observers: [NSObjectProtocol] = []
  private var model: Model { controller.model }
  private var input: InputView { controller.input }
  private var panel: NSPanel { controller.panel }
  private var pointer = CGPoint(x: -100, y: -100)
  /// Open menus close by themselves after this many seconds, so a blocked main thread comes back.
  private var menuSeconds: TimeInterval = 4
  private var alertAnswer: NSApplication.ModalResponse?
  /// The next menu that opens chooses the first item whose title starts with this, after a moment for a screenshot.
  private var pick: String?
  /// Focus, activation and outside clicks, newest last, so a panel that closes by itself can be explained.
  private var events: [String] = []
  private var clickMonitor: Any?

  init(controller: AppController) {
    self.controller = controller
    let center = DistributedNotificationCenter.default()
    observers.append(center.addObserver(forName: .init("com.rakshit.locoloco.test"), object: nil, queue: .main) { [weak self] n in
      let command = n.object as? String ?? ""
      MainActor.assumeIsolated { self?.run(command) }
    })
    observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] n in
      // Posted on the main queue, so the menu never leaves the main thread.
      nonisolated(unsafe) let menu = n.object as? NSMenu
      MainActor.assumeIsolated {
        guard let self, let menu else { return }
        if let pick = self.pick, let index = menu.items.firstIndex(where: { $0.title.hasPrefix(pick) }) {
          self.pick = nil
          self.after(0.8) {
            menu.cancelTrackingWithoutAnimation()
            self.after(0.3) { menu.performActionForItem(at: index) }
          }
          return
        }
        self.after(self.menuSeconds) { menu.cancelTracking() }
      }
    })
    // Answers alerts once they've been up for 2 seconds.
    let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let answer = self.alertAnswer, NSApp.modalWindow != nil else { return }
        self.alertAnswer = nil
        self.after(2) { NSApp.stopModal(withCode: answer) }
      }
    }
    RunLoop.main.add(t, forMode: .common)
    record()
  }

  private func record() {
    let workspace = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
      observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
        let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let text = "\(n.name.rawValue) \(app?.bundleIdentifier ?? app?.localizedName ?? "?") pid \(app?.processIdentifier ?? 0)"
        MainActor.assumeIsolated { self?.note(text) }
      })
    }
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                 NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
        let object = n.object.map { String(describing: type(of: $0)) } ?? "nil"
        let text = "\(n.name.rawValue) \(object)"
        MainActor.assumeIsolated { self?.note(text) }
      })
    }
    clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
      let text = "outside click \(e.type.rawValue)"
      MainActor.assumeIsolated { self?.note(text) }
    }
  }

  private func note(_ text: String) {
    let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(3)))
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    events.append("\(time) \(text) | front \(front) active \(NSApp.isActive) visible \(panel.isVisible) key \(panel.isKeyWindow)")
    if events.count > 60 { events.removeFirst(events.count - 60) }
  }

  private func after(_ seconds: TimeInterval, _ body: @escaping @MainActor () -> Void) {
    let t = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { body() } }
    RunLoop.main.add(t, forMode: .common)
  }

  private func run(_ command: String) {
    let a = command.split(separator: " ").map(String.init)
    switch a.first ?? "" {
    case "toggle": controller.toggle()
    case "move" where a.count == 3: move(to: CGPoint(x: Double(a[1]) ?? 0, y: Double(a[2]) ?? 0))
    case "row" where a.count >= 2: if let r = rowFrame(port: a[1], group: a.count > 2 ? a[2] : nil) { move(to: CGPoint(x: r.midX, y: r.midY)) }
    case "more": if let r = model.frames["row:more"] { move(to: CGPoint(x: r.midX, y: r.midY)) }
    case "btn" where a.count == 2: button(a[1])
    case "menuButton": if let r = model.frames["menu"] { move(to: CGPoint(x: r.midX, y: r.midY)) }
    case "leave": input.mouseExited(with: mouse(.mouseMoved))
    case "click": send(.leftMouseDown); send(.leftMouseUp)
    case "rightClick": send(.rightMouseDown)
    case "key" where a.count >= 2: key(UInt16(a[1]) ?? 0, command: a.contains("cmd"), characters: a.count > 2 && a[2] != "cmd" ? a[2] : "")
    case "menuSeconds" where a.count == 2: menuSeconds = Double(a[1]) ?? 4
    case "alert" where a.count == 2: alertAnswer = a[1] == "first" ? .alertFirstButtonReturn : .alertSecondButtonReturn
    case "pick" where a.count >= 2: pick = a.dropFirst().joined(separator: " ")
    case "only" where a.count >= 2: model.onlyPorts = a[1] == "all" ? nil : Set(a.dropFirst().compactMap { UInt16($0) })
    case "appearance" where a.count == 2:
      NSApp.appearance = a[1] == "dark" ? NSAppearance(named: .darkAqua) : a[1] == "light" ? NSAppearance(named: .aqua) : nil
    case "note": note(a.dropFirst().joined(separator: " "))
    case "dump": dump(a.count > 1 ? a[1] : "/tmp/loco-test.json")
    case "statusShot" where a.count == 2: statusShot(a[1])
    default: NSLog("Loco Loco test: unknown command %@", command)
    }
  }

  /// Renders the status item button as AppKit draws it, for when the menu bar is hidden.
  private func statusShot(_ path: String) {
    guard let button = controller.statusItem.button,
          let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return }
    button.cacheDisplay(in: button.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }

  private func rowFrame(port: String, group: String?) -> CGRect? {
    let rows = model.rows
    let list = group == "stopped" ? rows.stopped : group == "running" ? rows.running : rows.running + rows.stopped
    guard let row = list.first(where: { "\($0.port)" == port }) else { return nil }
    return model.frames["row:" + row.id]
  }

  /// Moves onto the hovered row's button: `stop`, `restart`, `log` or `force`.
  private func button(_ action: String) {
    guard let r = model.frames.first(where: { $0.key.hasPrefix("btn:") && $0.key.hasSuffix(":" + action) })?.value else { return }
    move(to: CGPoint(x: r.midX, y: r.midY))
  }

  private func move(to p: CGPoint) {
    pointer = p
    send(.mouseMoved)
  }

  private func mouse(_ type: NSEvent.EventType) -> NSEvent {
    NSEvent.mouseEvent(
      with: type, location: input.convert(pointer, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
  }

  private func send(_ type: NSEvent.EventType) {
    let e = mouse(type)
    switch type {
    case .mouseMoved: input.mouseMoved(with: e)
    default: panel.sendEvent(e)
    }
  }

  private func key(_ code: UInt16, command: Bool, characters: String) {
    let e = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: command ? .command : [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
      isARepeat: false, keyCode: code)!
    if command, input.performKeyEquivalent(with: e) { return }
    panel.sendEvent(e)
  }

  private func dump(_ path: String) {
    let rows = model.rows
    func json(_ r: Row) -> [String: Any] {
      ["id": r.id, "group": r.group == .running ? "running" : "stopped", "port": Int(r.port), "name": r.name,
       "state": "\(r.state)", "failure": r.failure ?? "", "time": TimeText.short(r.time), "actions": r.actions.map(\.rawValue)]
    }
    let f = panel.frame
    let state: [String: Any] = [
      "visible": panel.isVisible, "key": panel.isKeyWindow, "frame": [f.minX, f.minY, f.width, f.height],
      "statusTitle": controller.statusItem.button?.title ?? "",
      "running": rows.running.map(json), "stopped": rows.stopped.map(json), "stoppedTotal": rows.stoppedTotal,
      "highlight": model.highlight ?? "", "hot": model.hot ?? "", "stale": model.staleUnderPointer,
      "expanded": model.expanded, "scrolls": model.scrolls,
      "frames": model.frames.mapValues { [$0.minX, $0.minY, $0.width, $0.height] },
      "events": events,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: URL(fileURLWithPath: path))
    }
  }
}
#endif
