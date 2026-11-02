import AppKit
import LocoCore
import SwiftUI

/// A borderless panel that takes keyboard focus without activating the app, like a menu.
final class PanelWindow: NSPanel {
  init() {
    super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    isFloatingPanel = true
    level = .popUpMenu
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    backgroundColor = .clear
    isOpaque = false
    hasShadow = true
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    animationBehavior = .none
    acceptsMouseMovedEvents = true
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
  private let handler: () -> Void

  init(_ title: String, symbol: String? = nil, key: String = "", enabled: Bool = true, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(fire), keyEquivalent: key)
    target = self
    isEnabled = enabled
    if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
  }

  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  @objc private func fire() { handler() }
}

@MainActor
final class AppController: NSObject, NSWindowDelegate {
  let model: Model
  let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  let panel = PanelWindow()
  private let hosting: NSHostingView<PanelRoot>
  let input: InputView
  let hotKey = HotKey()
  private(set) lazy var settings = SettingsController(model: model, hotKey: hotKey)
  private var monitor: Any?
  private var transparent: Bool
  /// The screen the shortcut opened the panel in the middle of. Nil when it hangs from the menu bar icon.
  private var centeredOn: NSScreen?
  private var closedAt = Date.distantPast
  private(set) var closing = false
  /// The panel's top edge while it's open. In a full-screen space the menu bar hides once the pointer leaves it,
  /// so the panel keeps the place it opened at instead of following the bar off the screen.
  private var pinnedTop: CGFloat?
  /// Keeps the panel open while an alert is up. Test hooks also hold it open.
  var holdOpen = 0
  /// The app that had focus before an alert activated Loco Loco; it gets focus back when the panel closes.
  private var returnFocusTo: NSRunningApplication?

  private static let cursorID = "com.todesktop.230313mzl4w4u92"
  private let awake = Octopus.menuBarImage(asleep: false)
  private let asleep = Octopus.menuBarImage(asleep: true)

  init(model: Model) {
    self.model = model
    hosting = NSHostingView(rootView: PanelRoot(model: model))
    input = InputView(model: model)
    transparent = model.transparent
    super.init()

    hosting.sizingOptions = []
    let container = NSView()
    for v in [hosting, input] as [NSView] {
      v.frame = container.bounds
      v.autoresizingMask = [.width, .height]
      container.addSubview(v)
    }
    input.content = hosting
    panel.contentView = container
    panel.delegate = self

    if let button = statusItem.button {
      button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
      button.target = self
      button.action = #selector(toggle)
      button.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    model.perform = { [weak self] in self?.handle($0) }
    model.onFrames = { [weak self] in self?.input.updateToolTips() }
    hotKey.onPress = { [weak self] in self?.toggleCentered() }
    hotKey.register(model.shortcut)
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyAppearance() }
    }
    applyAppearance()
    update()
    observe()
  }

  // MARK: Changes

  private func observe() {
    withObservationTracking {
      _ = model.rows
      _ = model.showCount
      _ = model.appearance
      _ = model.transparent
    } onChange: { [weak self] in
      Task { @MainActor in self?.update(); self?.observe() }
    }
  }

  private func update() {
    let n = model.rows.running.count
    if let button = statusItem.button {
      let shown = model.showCount && n > 0
      // The octopus sleeps when nothing is running.
      button.image = n == 0 ? asleep : awake
      button.title = shown ? "\(n)" : ""
      button.imagePosition = shown ? .imageLeading : .imageOnly
      button.setAccessibilityLabel(n == 1 ? "Loco Loco, 1 server running" : "Loco Loco, \(n) servers running")
    }
    applyAppearance()
    if transparent != model.transparent {
      transparent = model.transparent
      panel.invalidateShadow()
    }
    if panel.isVisible { layout() }
  }

  /// Light or Dark for the panel, menus, alerts and Settings. The menu bar icon follows the menu bar, not this.
  private func applyAppearance() {
    let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    let name: NSAppearance.Name? = switch model.appearance {
    case .system: nil
    case .light: contrast ? .accessibilityHighContrastAqua : .aqua
    case .dark: contrast ? .accessibilityHighContrastDarkAqua : .darkAqua
    }
    guard NSApp.appearance?.name != name else { return }
    NSApp.appearance = name.flatMap { NSAppearance(named: $0) }
  }

  // MARK: Open and close

  @objc func toggle() {
    if panel.isVisible && !closing { close() }
    else if !closing, Date().timeIntervalSince(closedAt) > 0.3 { open(centeredOn: nil) }
  }

  /// The keyboard shortcut: opens the panel in the middle of the screen with the pointer, or closes it.
  func toggleCentered() {
    if panel.isVisible && !closing { close() }
    else if !closing {
      let mouse = NSEvent.mouseLocation
      open(centeredOn: NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main)
    }
  }

  private func open(centeredOn screen: NSScreen?) {
    centeredOn = screen
    model.resetPointer()
    model.isOpen = true
    pinnedTop = nil
    layout()
    panel.alphaValue = 1
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(input)
    if screen == nil {
      DispatchQueue.main.async { [weak self] in self?.statusItem.button?.highlight(true) }
    }
    monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
      MainActor.assumeIsolated {
        // The clicked app takes focus itself.
        self?.returnFocusTo = nil
        self?.close()
      }
    }
  }

  func close() {
    guard holdOpen == 0, panel.isVisible, !closing else { return }
    closing = true
    closedAt = Date()
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    statusItem.button?.highlight(false)
    model.isOpen = false
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.panel.orderOut(nil)
        self.panel.alphaValue = 1
        self.closing = false
        self.model.resetPointer()
        // Settings keeps focus when it opened from the panel.
        if NSApp.isActive, !self.settings.isVisible {
          if let app = self.returnFocusTo, !app.isTerminated { app.activate() } else { NSApp.deactivate() }
        }
        self.returnFocusTo = nil
      }
    }
  }

  func windowDidResignKey(_ notification: Notification) { close() }

  /// Sizes the panel to its rows, under the status item or in the middle of the screen, and scrolls what doesn't fit.
  private func layout() {
    let rows = model.rows
    var height = Metrics.padding * 2 + Metrics.rowHeight * CGFloat(1 + rows.running.count)
    if rows.running.isEmpty { height += Metrics.emptyHeight }
    if let groups = rows.groups {
      height += Metrics.projectHeader * CGFloat(groups.count) + Metrics.projectGap * CGFloat(groups.count - 1)
    }
    if rows.stoppedTotal > 0 {
      height += Metrics.groupGap + Metrics.rowHeight * CGFloat(1 + rows.stopped.count + (rows.hasMore ? 1 : 0))
    }
    let place: (x: CGFloat, top: CGFloat, maxHeight: CGFloat)
    if let screen = centeredOn {
      place = centered(height, on: screen)
    } else if let below = belowStatusItem() {
      place = below
    } else {
      return
    }
    let scrolls = height > place.maxHeight
    if model.scrolls != scrolls { model.scrolls = scrolls }
    height = min(height, place.maxHeight)

    let m = Metrics.margin
    let frame = NSRect(x: place.x - m, y: place.top - height - m, width: Metrics.width + 2 * m, height: height + 2 * m).integral
    guard panel.frame != frame else { return }
    panel.setFrame(frame, display: true)
    panel.invalidateShadow()
    DispatchQueue.main.async { [weak self] in self?.panel.invalidateShadow() }
  }

  /// Pinned under the status item, down to the bottom of the screen.
  private func belowStatusItem() -> (x: CGFloat, top: CGFloat, maxHeight: CGFloat)? {
    guard let button = statusItem.button, let barWindow = button.window,
          let screen = barWindow.screen ?? NSScreen.main else { return nil }
    // A hidden menu bar sits above the screen, so the top never goes higher than a menu bar's height below it.
    let top = pinnedTop ?? min(barWindow.frame.minY, screen.frame.maxY - NSStatusBar.system.thickness) - Metrics.gapBelowMenuBar
    pinnedTop = top
    let maxHeight = top - screen.visibleFrame.minY - Metrics.gapBelowMenuBar
    let buttonRect = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
    var x = min(buttonRect.minX, screen.frame.maxX - Metrics.screenInset - Metrics.width)
    x = max(x, screen.frame.minX + Metrics.screenInset)
    return (x, top, maxHeight)
  }

  /// In the middle of the screen, clear of the menu bar and Dock. Once open, the top stays put so rows don't jump,
  /// and moves up only when the panel grows past the bottom.
  private func centered(_ height: CGFloat, on screen: NSScreen) -> (x: CGFloat, top: CGFloat, maxHeight: CGFloat) {
    let area = screen.visibleFrame.insetBy(dx: Metrics.screenInset, dy: Metrics.screenInset)
    let fit = min(height, area.height)
    var top = panel.isVisible ? panel.frame.maxY - Metrics.margin : (area.midY + fit / 2).rounded()
    top = min(area.maxY, max(top, area.minY + fit))
    return ((area.midX - Metrics.width / 2).rounded(), top, area.height)
  }

  // MARK: Commands

  private func handle(_ command: Command) {
    switch command {
    case .primary(let id): primary(id)
    case let .action(id, action): perform(action, on: id)
    case let .menu(id, point): showContextMenu(for: id, at: point)
    case .more: showMoreMenu()
    case .settings: openSettings()
    case .close: close()
    }
  }

  /// Click or Return: a running server opens in the browser, a stopped one restarts, More expands.
  private func primary(_ id: String) {
    if id == Rows.more {
      model.expanded = true
      return
    }
    guard let row = model.rows.row(id) else { return }
    switch row.group {
    case .running:
      guard row.server != nil, row.state == .idle else { return }
      open(row.url)
    case .stopped:
      model.restart(row)
    }
  }

  private func perform(_ action: RowAction, on id: String) {
    guard let row = model.rows.row(id) else { return }
    switch action {
    case .stop: if row.canStop, let e = row.entryID { model.stop(e) }
    case .restart: model.restart(row)
    case .force: if let e = row.entryID { model.forceStop(e) }
    case .log: showLog(row)
    case .remove: if row.canRemove, let e = row.entryID { model.remove(e) }
    }
  }

  private func open(_ url: URL) {
    NSWorkspace.shared.open(url)
    close()
  }

  private func showLog(_ row: Row) {
    guard row.hasLog, let path = row.logPath else { return }
    NSWorkspace.shared.open(URL(fileURLWithPath: path))
    close()
  }

  // MARK: Menus

  private func showContextMenu(for id: String, at point: CGPoint?) {
    guard let row = model.rows.row(id) else { return }
    let isDev = row.entryID != nil
    let folder = URL(fileURLWithPath: row.folder)
    let folderExists = FileManager.default.fileExists(atPath: row.folder)
    let menu = NSMenu()
    menu.autoenablesItems = false

    menu.addItem(ActionItem("Open in browser", symbol: "globe", enabled: row.server != nil && row.state == .idle) { [weak self] in
      self?.open(row.url)
    })
    menu.addItem(ActionItem("Copy URL", symbol: "link") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(row.url.absoluteString, forType: .string)
    })
    for port in row.ports.dropFirst() {
      menu.addItem(ActionItem("Open localhost:\(port)", enabled: row.server != nil) { [weak self] in
        self?.open(URL(string: "http://localhost:\(port)")!)
      })
    }
    menu.addItem(.separator())
    menu.addItem(ActionItem("Restart", symbol: "arrow.clockwise", enabled: row.canRestart) { [weak self] in
      self?.model.restart(row)
    })
    menu.addItem(ActionItem("Stop", symbol: "stop.fill", enabled: row.canStop) { [weak self] in
      if let e = row.entryID { self?.model.stop(e) }
    })
    menu.addItem(.separator())
    menu.addItem(ActionItem("Show in Finder", symbol: "folder", enabled: folderExists) { [weak self] in
      NSWorkspace.shared.activateFileViewerSelecting([folder])
      self?.close()
    })
    menu.addItem(ActionItem("Open in Terminal", symbol: "terminal", enabled: isDev && folderExists) { [weak self] in
      self?.openFolder(folder, with: "com.apple.Terminal")
    })
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.cursorID) != nil {
      menu.addItem(ActionItem("Open in Cursor", symbol: "chevron.left.forwardslash.chevron.right", enabled: isDev && folderExists) { [weak self] in
        self?.openFolder(folder, with: Self.cursorID)
      })
    }
    menu.addItem(ActionItem("Show log", symbol: "doc.text", enabled: row.hasLog) { [weak self] in
      self?.showLog(row)
    })
    if let project = row.project, let root = project.root {
      menu.addItem(.separator())
      menu.addItem(ActionItem("Rename project…", symbol: "pencil") { [weak self] in
        self?.renameProject(root: root, name: project.name)
      })
    }
    if row.canRemove, let e = row.entryID {
      menu.addItem(.separator())
      menu.addItem(ActionItem(RowAction.remove.title, symbol: RowAction.remove.symbol) { [weak self] in
        self?.model.remove(e)
      })
    }

    let at: CGPoint
    if let point { at = point }
    else if let r = model.frames["row:" + id] { at = CGPoint(x: r.minX + Metrics.rowInset, y: r.maxY) }
    else { return }
    model.menuRow = id
    model.highlight = id
    model.hot = nil
    menu.popUp(positioning: nil, at: at, in: input)
    model.menuRow = nil
    refreshHover()
  }

  private func openFolder(_ folder: URL, with bundleID: String) {
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
    NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    close()
  }

  private func showMoreMenu() {
    guard let rect = model.frames["menu"] else { return }
    let menu = NSMenu()
    menu.autoenablesItems = false

    menu.addItem(ActionItem("Stop all…", enabled: !model.stoppable.isEmpty) { [weak self] in self?.confirmStopAll() })
    menu.addItem(ActionItem("Clear history…", enabled: model.history.entries.contains { !$0.isRunning }) { [weak self] in
      self?.confirmClearHistory()
    })
    menu.addItem(.separator())
    menu.addItem(ActionItem("Settings…", key: ",") { [weak self] in self?.openSettings() })
    menu.addItem(.separator())
    menu.addItem(ActionItem("Quit Loco Loco", key: "q") { NSApp.terminate(nil) })

    // Right-aligned under the ··· button.
    let onScreen = panel.convertToScreen(input.convert(rect, to: nil))
    let at = NSPoint(x: onScreen.maxX - menu.size.width, y: onScreen.minY - 4)
    model.moreMenuOpen = true
    model.hot = "menu"
    menu.popUp(positioning: nil, at: at, in: nil)
    model.moreMenuOpen = false
    refreshHover()
  }

  private func refreshHover() {
    guard panel.isVisible else { return }
    model.pointer = input.currentPointer()
    model.hover()
  }

  /// Closes the panel and brings up Settings, which gives focus back to the app you were in when it closes.
  func openSettings() {
    var app = returnFocusTo
    if !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication, front != .current { app = front }
    returnFocusTo = nil
    close()
    settings.show(returningFocusTo: app)
  }

  // MARK: Alerts

  private func confirmStopAll() {
    let n = model.stoppable.count
    guard n > 0 else { return }
    let title = n == 1 ? "Stop 1 server?" : "Stop all \(n) servers?"
    if alert(title, info: nil, action: "Stop all") { model.stopAll() }
  }

  private func confirmClearHistory() {
    if alert("Clear history?", info: nil, action: "Clear history") {
      model.clearHistory()
    }
  }

  private func renameProject(root: String, name: String) {
    let field = NSTextField(string: name)
    field.frame = NSRect(x: 0, y: 0, width: 228, height: 22)
    // Folders like "Acme " end in a space, which would read as a double space here.
    let folder = Naming.abbreviate(root, home: NSHomeDirectory()).trimmingCharacters(in: .whitespaces)
    let info = "Every server in \(folder) shows this name."
    if alert("Rename project", info: info, action: "Rename", destructive: false, field: field) {
      model.renameProject(root: root, to: field.stringValue)
    }
  }

  /// Shows an alert above the open panel. Returns true when the action button is chosen.
  private func alert(_ title: String, info: String?, action: String?, destructive: Bool = true, field: NSTextField? = nil) -> Bool {
    let a = NSAlert()
    a.messageText = title
    if let info { a.informativeText = info }
    if let action {
      a.addButton(withTitle: action).hasDestructiveAction = destructive
      a.addButton(withTitle: "Cancel")
    }
    if let field {
      a.accessoryView = field
      a.layout()
      a.window.initialFirstResponder = field
    }
    return runAlert(a) == .alertFirstButtonReturn && action != nil
  }

  /// Runs an alert above the open panel, which stays open behind it, and gives focus back to the panel after.
  private func runAlert(_ a: NSAlert) -> NSApplication.ModalResponse {
    holdOpen += 1
    defer { holdOpen -= 1 }
    panel.level = .floating
    if !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication, front != .current { returnFocusTo = front }
    NSApp.activate()
    let response = a.runModal()
    panel.level = .popUpMenu
    if panel.isVisible { panel.makeKeyAndOrderFront(nil) }
    return response
  }
}
