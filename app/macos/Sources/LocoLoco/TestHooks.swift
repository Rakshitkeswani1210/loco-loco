#if TEST_HOOKS
import AppKit
import Carbon.HIToolbox
import LocoCore

/// Drives the panel from the command line for screenshots and checks. Compiled in only by `scripts/build.sh --test-hooks`.
/// Commands arrive as distributed notifications named `com.rakshit.locoloco.test` whose object is the command,
/// such as `toggle`, `row 8765`, `btn stop`, `click` or `dump /tmp/state.json`. `hold on` ignores outside clicks while you use the Mac.
@MainActor
final class TestHooks: NSObject {
  private let controller: AppController
  private var observers: [NSObjectProtocol] = []
  private var model: Model { controller.model }
  private var input: InputView { controller.input }
  private var panel: NSPanel { controller.panel }
  private var pointer = CGPoint(x: -100, y: -100)
  /// Open menus close by themselves after this many seconds, so a blocked main thread comes back.
  private var menuSeconds: TimeInterval = 4
  private var alertAnswer: NSApplication.ModalResponse?
  /// Typed into the next alert's text field as soon as it opens.
  private var alertText: String?
  /// Commands to run once an alert is up, one every half second, since notifications may wait until it closes.
  private var modalQueue: [String] = []
  private var fieldCalls: [String] = []
  /// The next menu that opens chooses the first item whose title starts with this, after a moment for a screenshot.
  private var pick: String?
  /// Focus, activation and outside clicks, newest last, so a panel that closes by itself can be explained.
  private var events: [String] = []
  private var clickMonitor: Any?
  private var shotTimer: Timer?

  init(controller: AppController) {
    self.controller = controller
    super.init()
    // Delivered even while another app is active, so checks don't need to take focus.
    DistributedNotificationCenter.default().addObserver(
      self, selector: #selector(received(_:)), name: .init("com.rakshit.locoloco.test"), object: nil,
      suspensionBehavior: .deliverImmediately)
    observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] n in
      // Posted on the main queue, so the menu never leaves the main thread.
      nonisolated(unsafe) let menu = n.object as? NSMenu
      MainActor.assumeIsolated {
        guard let self, let menu else { return }
        let keys = menu.items.filter { !$0.keyEquivalent.isEmpty }.map { "\($0.title)=\($0.keyEquivalentModifierMask.rawValue):\($0.keyEquivalent)" }
        self.note("menu keys " + keys.joined(separator: ", "))
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
        guard let self, let window = NSApp.modalWindow else { return }
        if !self.modalQueue.isEmpty {
          self.run(self.modalQueue.removeFirst())
          return
        }
        if let text = self.alertText, let field = Self.textField(in: window.contentView) {
          self.alertText = nil
          field.stringValue = text
        }
        guard let answer = self.alertAnswer else { return }
        self.alertAnswer = nil
        self.after(2) { NSApp.stopModal(withCode: answer) }
      }
    }
    RunLoop.main.add(t, forMode: .common)
    record()
  }

  @objc private func received(_ n: Notification) {
    let command = n.object as? String ?? ""
    MainActor.assumeIsolated { run(command) }
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
    case "shortcut": controller.toggleCentered()
    case "modal" where a.count >= 2: modalQueue.append(a.dropFirst().joined(separator: " "))
    case "modalKey" where a.count >= 2: modalKey(a)
    case "modalFlags": modalFlags(a)
    case "modalShot" where a.count == 2: modalShot(a[1])
    case "offscreen" where a.count == 2: offscreen(a[1])
    case "settings": controller.openSettings()
    case "panelShot" where a.count >= 2: panelShot(a[1], below: a.contains("below"))
    case "autoshot" where a.count == 2: autoShot(a[1])
    case "settingsClose": controller.settings.window?.performClose(nil)
    case "settingsShot" where a.count == 2: settingsShot(a[1])
    case "settingsField": if let field = settingsField() { field.mouseDown(with: mouse(.leftMouseDown)) }
    case "settingsKey" where a.count >= 2: settingsKey(a)
    case "settingsFlags": if let field = settingsField(), let e = flagsEvent(a) { field.flagsChanged(with: e) }
    case "setting" where a.count == 3:
      switch a[1] {
      case "appearance": model.setAppearance(Appearance(rawValue: a[2]) ?? .system)
      case "transparent": model.setTransparent(a[2] == "on")
      default: break
      }
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
    case "type" where a.count >= 1: alertText = a.dropFirst().joined(separator: " ")
    case "hold" where a.count == 2: controller.holdOpen = a[1] == "on" ? 1 : 0
    case "group" where a.count == 2: model.setGroupByProject(a[1] == "on")
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

  private static func textField(in view: NSView?) -> NSTextField? {
    guard let view else { return nil }
    if let field = view as? NSTextField, field.isEditable { return field }
    for sub in view.subviews { if let f = textField(in: sub) { return f } }
    return nil
  }

  /// Renders the status item button as AppKit draws it, for when the menu bar is hidden.
  private func statusShot(_ path: String) {
    guard let button = controller.statusItem.button,
          let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return }
    button.cacheDisplay(in: button.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }

  private func flags(_ a: [String]) -> NSEvent.ModifierFlags {
    var f: NSEvent.ModifierFlags = []
    if a.contains("ctrl") { f.insert(.control) }
    if a.contains("opt") { f.insert(.option) }
    if a.contains("shift") { f.insert(.shift) }
    if a.contains("cmd") { f.insert(.command) }
    return f
  }

  /// `modalKey 37 ctrl opt chars=l`: a key press in the alert, through the app the way a real one arrives.
  private func modalKey(_ a: [String]) {
    guard let window = NSApp.modalWindow else { return }
    let chars = a.first { $0.hasPrefix("chars=") }.map { String($0.dropFirst(6)) } ?? ""
    let e = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags(a), timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
      isARepeat: false, keyCode: UInt16(a[1]) ?? 0)!
    NSApp.sendEvent(e)
  }

  /// `modalFlags ctrl opt`: modifiers held down in the alert, or none.
  private func modalFlags(_ a: [String]) {
    guard let window = NSApp.modalWindow, let e = flagsEvent(a) else { return }
    window.firstResponder?.flagsChanged(with: e)
  }

  private func flagsEvent(_ a: [String]) -> NSEvent? {
    guard let cg = CGEvent(keyboardEventSource: nil, virtualKey: 59, keyDown: true) else { return nil }
    cg.type = .flagsChanged
    cg.flags = CGEventFlags(rawValue: UInt64(flags(a).rawValue))
    return NSEvent(cgEvent: cg)
  }

  private func settingsField() -> ShortcutField? {
    func find(_ v: NSView) -> ShortcutField? {
      if let f = v as? ShortcutField { return f }
      for sub in v.subviews { if let f = find(sub) { return f } }
      return nil
    }
    return controller.settings.window?.contentView.flatMap(find)
  }

  /// `settingsKey 13 cmd chars=w`: a key press in Settings, the way AppKit hands it over, without taking focus.
  private func settingsKey(_ a: [String]) {
    guard let window = controller.settings.window else { return }
    let chars = a.first { $0.hasPrefix("chars=") }.map { String($0.dropFirst(6)) } ?? ""
    let e = NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags(a), timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
      isARepeat: false, keyCode: UInt16(a[1]) ?? 0)!
    if !e.modifierFlags.intersection([.command, .control]).isEmpty, window.performKeyEquivalent(with: e) { return }
    window.firstResponder?.keyDown(with: e)
  }

  /// Renders Settings as AppKit draws it, title bar included. Makes the window without showing it if needed.
  private func settingsShot(_ path: String) {
    let window = controller.settings.makeWindow()
    window.contentView?.layoutSubtreeIfNeeded()
    guard let view = window.contentView?.superview ?? window.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { note("settingsShot: no png \(view.bounds)"); return }
    do { try data.write(to: URL(fileURLWithPath: path)) } catch { note("settingsShot: \(error)") }
  }

  /// Checks the shortcut pieces without showing anything or taking focus: the recorder's keys, which keys macOS
  /// already uses, and that a hot key event reaches the handler.
  private func offscreen(_ path: String) {
    var results: [String: Any] = [:]
    func type(
      _ name: String, from start: Shortcut?, _ code: UInt16, _ flags: NSEvent.ModifierFlags = [], _ chars: String = "",
      recording: Bool = true, reject: Bool = false
    ) {
      let field = ShortcutField(shortcut: start)
      fieldCalls = []
      field.onRecord = { [weak self] s in
        self?.fieldCalls.append("record " + (s?.storage ?? "none"))
        return reject ? "taken" : nil
      }
      field.onRecording = { [weak self] on in self?.fieldCalls.append(on ? "on" : "off") }
      if recording { field.begin() }
      let e = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
        characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
      field.keyDown(with: e)
      results[name] = [field.shortcut?.storage ?? "none", fieldCalls.joined(separator: ","), field.text, field.isRecording]
    }
    type("record", from: .standard, 40, [.control, .option, .shift], "k")
    type("delete", from: .standard, 51, [], "\u{8}")
    type("forwardDelete", from: .standard, 117)
    type("escape", from: .standard, 53, [], "\u{1B}")
    type("return", from: .standard, 36, [], "\r")
    type("enter", from: .standard, 76, [], "\u{3}")
    type("commandDelete", from: .standard, 51, [.command], "\u{8}")
    type("f5", from: nil, 96)
    type("letter", from: .standard, 0, [], "a")
    type("taken", from: .standard, 49, [.command], " ", reject: true)
    type("idleSpace", from: .standard, 49, [], " ", recording: false)
    type("idleReturn", from: .standard, 36, [], "\r", recording: false)
    type("idleKeys", from: .standard, 40, [.control, .option], "k", recording: false)

    for storage in ["49:8", "20:12", "37:3", "46:12"] {
      results["taken " + storage] = Shortcut(storage: storage)?.isTakenBySystem ?? false
    }

    let hotKey = controller.hotKey
    let saved = hotKey.onPress
    var fired = 0
    hotKey.onPress = { fired += 1 }
    var event: EventRef?
    CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, EventAttributes(kEventAttributeNone), &event)
    var id = EventHotKeyID(signature: OSType(0x4C6F_636F), id: 1)
    SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id)
    let status = SendEventToEventTarget(event, GetApplicationEventTarget())
    if let event { ReleaseEvent(event) }
    hotKey.onPress = saved
    results["carbon"] = ["status": Int(status), "fired": fired, "registered": hotKey.isRegistered]

    if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: URL(fileURLWithPath: path))
    }
  }

  /// The panel as the window server shows it, shadow included. An app may capture its own windows without
  /// screen recording permission. `below` adds what's under it, as far as macOS allows.
  private func panelShot(_ path: String, below: Bool, bare: Bool = false) {
    typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { note("no capture"); return }
    let capture = unsafeBitCast(sym, to: Capture.self)
    let f = panel.frame
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    let rect = below ? CGRect(x: f.minX - 30, y: top - f.maxY - 30, width: f.width + 60, height: f.height + 60) : .null
    guard let image = capture(rect, below ? 12 : 8, UInt32(panel.windowNumber), bare ? 1 : 0)?.takeRetainedValue() else { note("capture failed"); return }
    let rep = NSBitmapImageRep(cgImage: image)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }

  /// Captures the panel the next time it opens and takes focus, framed, over what's below, and bare.
  private func autoShot(_ path: String) {
    let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.panel.isVisible, self.panel.isKeyWindow else { return }
        self.shotTimer?.invalidate()
        self.after(0.8) {
          self.panelShot(path, below: false)
          self.panelShot(path.replacingOccurrences(of: ".png", with: "-below.png"), below: true)
          self.panelShot(path.replacingOccurrences(of: ".png", with: "-bare.png"), below: false, bare: true)
          self.note("autoshot done")
        }
      }
    }
    shotTimer = t
    RunLoop.main.add(t, forMode: .common)
  }

  /// Renders the alert as AppKit draws it, since this build can't record the screen.
  private func modalShot(_ path: String) {
    guard let view = NSApp.modalWindow?.contentView?.superview ?? NSApp.modalWindow?.contentView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
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

  private func settingsState() -> [String: Any] {
    guard let w = controller.settings.window else { return ["made": false] }
    let field = settingsField()
    var hit = ""
    if let field, let content = w.contentView {
      let p = content.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), from: field)
      hit = content.hitTest(p).map { String(describing: type(of: $0)) } ?? "nil"
    }
    return [
      "made": true, "visible": w.isVisible, "key": w.isKeyWindow, "frame": [w.frame.minX, w.frame.minY, w.frame.width, w.frame.height],
      "firstResponder": w.firstResponder.map { String(describing: type(of: $0)) } ?? "",
      "field": field?.text ?? "", "recording": field?.isRecording ?? false, "fieldHit": hit,
      "appearance": w.effectiveAppearance.name.rawValue,
    ]
  }

  private func viewClasses(_ view: NSView?) -> [String] {
    guard let view else { return [] }
    return [String(describing: type(of: view))] + view.subviews.flatMap(viewClasses)
  }

  private func dump(_ path: String) {
    let rows = model.rows
    func json(_ r: Row) -> [String: Any] {
      ["id": r.id, "group": r.group == .running ? "running" : "stopped", "port": Int(r.port), "name": r.name,
       "state": "\(r.state)", "failure": r.failure ?? "", "time": TimeText.short(r.time), "actions": r.actions.map(\.rawValue),
       "project": r.project?.name ?? "", "tint": r.project?.tint ?? -1]
    }
    let f = panel.frame
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    let modal = NSApp.modalWindow
    let state: [String: Any] = [
      "visible": panel.isVisible, "key": panel.isKeyWindow, "frame": [f.minX, f.minY, f.width, f.height],
      "statusTitle": controller.statusItem.button?.title ?? "",
      "statusHighlighted": controller.statusItem.button?.isHighlighted ?? false,
      "screen": screen.map { [$0.visibleFrame.minX, $0.visibleFrame.minY, $0.visibleFrame.width, $0.visibleFrame.height] } ?? [],
      "shortcut": UserDefaults.standard.string(forKey: "shortcut") ?? "(default)",
      "shortcutTitle": model.shortcut?.title ?? "", "hotKeyRegistered": controller.hotKey.isRegistered,
      "takenBySystem": model.shortcut?.isTakenBySystem ?? false,
      "modal": modal != nil, "modalKey": modal?.isKeyWindow ?? false, "closing": controller.closing, "holdOpen": controller.holdOpen,
      "active": NSApp.isActive, "alpha": panel.alphaValue,
      "modalFirstResponder": modal?.firstResponder.map { String(describing: type(of: $0)) } ?? "",
      "modalField": (modal?.firstResponder as? NSView)?.accessibilityValue() as? String ?? "",
      "settings": settingsState(),
      "appearance": model.appearance.rawValue, "transparent": model.transparent, "launchAtLogin": model.launchAtLogin,
      "appAppearance": NSApp.appearance?.name.rawValue ?? "nil",
      "panelAppearance": panel.effectiveAppearance.name.rawValue,
      "statusAppearance": controller.statusItem.button?.effectiveAppearance.name.rawValue ?? "",
      "panelViews": viewClasses(panel.contentView),
      "running": rows.running.map(json), "stopped": rows.stopped.map(json), "stoppedTotal": rows.stoppedTotal,
      "groups": (rows.groups ?? []).map { ["name": $0.tag.name, "tint": $0.tag.tint ?? -1, "ports": $0.rows.map { Int($0.port) }] },
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
