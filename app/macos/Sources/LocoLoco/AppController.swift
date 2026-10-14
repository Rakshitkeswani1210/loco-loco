import AppKit
import LocoCore
import ServiceManagement
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
  private var monitor: Any?
  private var closedAt = Date.distantPast
  private var closing = false
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
    update()
    observe()
  }

  // MARK: Changes

  private func observe() {
    withObservationTracking {
      _ = model.rows
      _ = model.showCount
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
    if panel.isVisible { layout() }
  }

  // MARK: Open and close

  @objc func toggle() {
    if panel.isVisible && !closing { close() }
    else if !closing, Date().timeIntervalSince(closedAt) > 0.3 { open() }
  }

  private func open() {
    model.resetPointer()
    model.isOpen = true
    pinnedTop = nil
    layout()
    panel.alphaValue = 1
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(input)
    DispatchQueue.main.async { [weak self] in self?.statusItem.button?.highlight(true) }
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
        if NSApp.isActive {
          if let app = self.returnFocusTo, !app.isTerminated { app.activate() } else { NSApp.deactivate() }
        }
        self.returnFocusTo = nil
      }
    }
  }

  func windowDidResignKey(_ notification: Notification) { close() }

  /// Pins the panel under the status item and sizes it to its rows, up to the bottom of the screen.
  private func layout() {
    guard let button = statusItem.button, let barWindow = button.window,
          let screen = barWindow.screen ?? NSScreen.main else { return }
    let rows = model.rows
    var height = Metrics.padding * 2 + Metrics.rowHeight * CGFloat(1 + rows.running.count)
    if rows.running.isEmpty { height += Metrics.emptyHeight }
    if let groups = rows.groups {
      height += Metrics.projectHeader * CGFloat(groups.count) + Metrics.projectGap * CGFloat(groups.count - 1)
    }
    if rows.stoppedTotal > 0 {
      height += Metrics.groupGap + Metrics.rowHeight * CGFloat(1 + rows.stopped.count + (rows.hasMore ? 1 : 0))
    }
    // A hidden menu bar sits above the screen, so the top never goes higher than a menu bar's height below it.
    let top = pinnedTop ?? min(barWindow.frame.minY, screen.frame.maxY - NSStatusBar.system.thickness) - Metrics.gapBelowMenuBar
    pinnedTop = top
    let maxHeight = top - screen.visibleFrame.minY - Metrics.gapBelowMenuBar
    let scrolls = height > maxHeight
    if model.scrolls != scrolls { model.scrolls = scrolls }
    height = min(height, maxHeight)

    let buttonRect = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
    var x = min(buttonRect.minX, screen.frame.maxX - Metrics.screenInset - Metrics.width)
    x = max(x, screen.frame.minX + Metrics.screenInset)
    let m = Metrics.margin
    let frame = NSRect(x: x - m, y: top - height - m, width: Metrics.width + 2 * m, height: height + 2 * m).integral
    guard panel.frame != frame else { return }
    panel.setFrame(frame, display: true)
    panel.invalidateShadow()
    DispatchQueue.main.async { [weak self] in self?.panel.invalidateShadow() }
  }

  // MARK: Commands

  private func handle(_ command: Command) {
    switch command {
    case .primary(let id): primary(id)
    case let .action(id, action): perform(action, on: id)
    case let .menu(id, point): showContextMenu(for: id, at: point)
    case .more: showMoreMenu()
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
    menu.addItem(.separator())
    let login = ActionItem("Launch at login") { [weak self] in self?.toggleLogin() }
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    menu.addItem(login)
    let count = ActionItem("Show count in menu bar") { [weak self] in
      guard let self else { return }
      self.model.setShowCount(!self.model.showCount)
    }
    count.state = model.showCount ? .on : .off
    menu.addItem(count)
    let all = ActionItem("Show app and macOS servers") { [weak self] in
      guard let self else { return }
      self.model.setShowAll(!self.model.showAll)
    }
    all.state = model.showAll ? .on : .off
    menu.addItem(all)
    let group = ActionItem("Group by project") { [weak self] in
      guard let self else { return }
      self.model.setGroupByProject(!self.model.groupByProject)
    }
    group.state = model.groupByProject ? .on : .off
    menu.addItem(group)
    menu.addItem(.separator())
    let keep = NSMenuItem(title: "Keep history", action: nil, keyEquivalent: "")
    let limits = NSMenu()
    for n in [10, 20, 50] {
      let item = ActionItem("\(n) servers") { [weak self] in self?.model.setHistoryLimit(n) }
      item.state = model.historyLimit == n ? .on : .off
      limits.addItem(item)
    }
    keep.submenu = limits
    menu.addItem(keep)
    menu.addItem(ActionItem("Clear history…", enabled: model.history.entries.contains { !$0.isRunning }) { [weak self] in
      self?.confirmClearHistory()
    })
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

  private func toggleLogin() {
    let service = SMAppService.mainApp
    do {
      if service.status == .enabled { try service.unregister() } else { try service.register() }
    } catch {
      _ = alert("Couldn't change Launch at login", info: error.localizedDescription, action: nil)
    }
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
    holdOpen += 1
    defer { holdOpen -= 1 }
    panel.level = .floating
    if !NSApp.isActive, let front = NSWorkspace.shared.frontmostApplication, front != .current { returnFocusTo = front }
    NSApp.activate()
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
    let response = a.runModal()
    panel.level = .popUpMenu
    if panel.isVisible { panel.makeKeyAndOrderFront(nil) }
    return action != nil && response == .alertFirstButtonReturn
  }
}
