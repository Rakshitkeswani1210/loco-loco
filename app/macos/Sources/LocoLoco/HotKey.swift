import AppKit
import Carbon.HIToolbox
import LocoCore

/// A system-wide keyboard shortcut. Carbon's hot keys need no Accessibility permission, unlike an event tap.
@MainActor
final class HotKey {
  var onPress: () -> Void = {}
  private var ref: EventHotKeyRef?
  private var handler: EventHandlerRef?

  var isRegistered: Bool { ref != nil }

  init() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, me in
      guard let me else { return OSStatus(eventNotHandledErr) }
      let hotKey = Unmanaged<HotKey>.fromOpaque(me).takeUnretainedValue()
      // Carbon calls this on the main thread.
      MainActor.assumeIsolated { hotKey.onPress() }
      return noErr
    }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
  }

  /// Replaces the current shortcut. Nil turns it off. Returns false when the keys can't be taken, usually because another app has them.
  @discardableResult
  func register(_ shortcut: Shortcut?) -> Bool {
    unregister()
    guard let shortcut else { return true }
    var newRef: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x4C6F_636F), id: 1)  // "Loco"
    let status = RegisterEventHotKey(
      UInt32(shortcut.keyCode), shortcut.carbonModifiers, id, GetApplicationEventTarget(), 0, &newRef)
    guard status == noErr, let newRef else { return false }
    ref = newRef
    return true
  }

  func unregister() {
    if let ref { UnregisterEventHotKey(ref) }
    ref = nil
  }
}

extension Shortcut.Modifiers {
  init(flags: NSEvent.ModifierFlags) {
    var m: Shortcut.Modifiers = []
    if flags.contains(.control) { m.insert(.control) }
    if flags.contains(.option) { m.insert(.option) }
    if flags.contains(.shift) { m.insert(.shift) }
    if flags.contains(.command) { m.insert(.command) }
    self = m
  }

  var flags: NSEvent.ModifierFlags {
    var f: NSEvent.ModifierFlags = []
    if contains(.control) { f.insert(.control) }
    if contains(.option) { f.insert(.option) }
    if contains(.shift) { f.insert(.shift) }
    if contains(.command) { f.insert(.command) }
    return f
  }
}

extension Shortcut {
  /// The keys pressed, when they make a valid shortcut.
  init?(event: NSEvent) {
    self.init(keyCode: event.keyCode, modifiers: Modifiers(flags: event.modifierFlags))
    guard isValid else { return nil }
  }

  /// "⌃⌥L", with the letter from the current keyboard layout.
  var title: String { display(character: Self.character(for: keyCode)) }

  var carbonModifiers: UInt32 {
    var m = 0
    if modifiers.contains(.control) { m |= controlKey }
    if modifiers.contains(.option) { m |= optionKey }
    if modifiers.contains(.shift) { m |= shiftKey }
    if modifiers.contains(.command) { m |= cmdKey }
    return UInt32(m)
  }

  /// True when a shortcut that's turned on in macOS, such as ⌘Space for Spotlight, already uses these keys.
  /// macOS would take them first. Other apps' shortcuts can't be seen.
  var isTakenBySystem: Bool {
    var list: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&list) == noErr, let hotKeys = list?.takeRetainedValue() as? [[String: Any]] else { return false }
    let mask = UInt32(controlKey | optionKey | shiftKey | cmdKey)
    return hotKeys.contains { hotKey in
      guard hotKey[kHISymbolicHotKeyEnabled] as? Bool == true,
            let code = hotKey[kHISymbolicHotKeyCode] as? NSNumber,
            let mods = hotKey[kHISymbolicHotKeyModifiers] as? NSNumber else { return false }
      return code.uint16Value == keyCode && mods.uint32Value & mask == carbonModifiers
    }
  }

  /// For an NSMenuItem's keyEquivalent, so the menu shows the shortcut the way macOS shows any other.
  var menuKey: String? {
    if let special = Self.menuKeys[keyCode], let scalar = UnicodeScalar(special) { return String(Character(scalar)) }
    return Self.character(for: keyCode)?.lowercased()
  }

  private static let menuKeys: [UInt16: Int] = {
    var keys: [UInt16: Int] = [
      49: 0x20, 36: 0x0D, 76: 0x03, 48: 0x09, 51: 0x08, 117: NSDeleteFunctionKey, 53: 0x1B,
      123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey,
      115: NSHomeFunctionKey, 119: NSEndFunctionKey, 116: NSPageUpFunctionKey, 121: NSPageDownFunctionKey,
    ]
    for (i, code) in functionKeys.enumerated() { keys[code] = NSF1FunctionKey + i }
    return keys
  }()

  /// What the key types on the current keyboard layout, without modifiers.
  static func character(for keyCode: UInt16) -> String? {
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    let capacity = 4
    var chars = [UniChar](repeating: 0, count: capacity)
    var length = 0
    var dead: UInt32 = 0
    let status = data.withUnsafeBytes { buffer -> OSStatus in
      guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return OSStatus(paramErr) }
      return UCKeyTranslate(
        layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
        &dead, capacity, &length, &chars)
    }
    guard status == noErr, length > 0 else { return nil }
    let s = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    return s.isEmpty ? nil : s
  }
}

/// Records a shortcut: click it, or press Space when it has focus, then press the keys. Delete turns the shortcut off.
/// Esc, a click elsewhere or leaving the window stops recording without a change.
final class ShortcutField: NSView {
  var shortcut: Shortcut? {
    didSet { refresh() }
  }
  /// New keys, or nil for none. Returns why they can't be used, and recording goes on; nil when they're saved.
  var onRecord: @MainActor (Shortcut?) -> String? = { _ in nil }
  var onRecording: @MainActor (Bool) -> Void = { _ in }
  private(set) var isRecording = false {
    didSet { refresh() }
  }
  /// Modifiers held down before the key, shown while they're pressed.
  private var held: Shortcut.Modifiers = [] {
    didSet { refresh() }
  }
  private var clickMonitor: Any?
  private var resignObserver: NSObjectProtocol?

  init(shortcut: Shortcut?) {
    self.shortcut = shortcut
    super.init(frame: NSRect(origin: .zero, size: Self.size))
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel("Keyboard shortcut")
    setAccessibilityHelp("Press, then press the keys you want. Delete turns it off.")
    refresh()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  static let size = NSSize(width: 132, height: 22)
  override var intrinsicContentSize: NSSize { Self.size }

  var text: String {
    guard isRecording else { return shortcut?.title ?? "None" }
    return held.isEmpty ? "Type shortcut" : held.symbols
  }

  private func refresh() {
    needsDisplay = true
    setAccessibilityValue(text)
  }

  func begin() {
    guard !isRecording else { return }
    isRecording = true
    held = []
    clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
      let number = e.windowNumber
      let point = e.locationInWindow
      MainActor.assumeIsolated {
        guard let self else { return }
        if number != self.window?.windowNumber || !self.bounds.contains(self.convert(point, from: nil)) { self.end() }
      }
      return e
    }
    onRecording(true)
  }

  func end() {
    guard isRecording else { return }
    isRecording = false
    held = []
    if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
    clickMonitor = nil
    onRecording(false)
  }

  private func record(_ s: Shortcut?) {
    if onRecord(s) == nil {
      shortcut = s
      end()
    } else {
      held = []
      NSSound.beep()
    }
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    end()
    if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    resignObserver = nil
    guard let newWindow else { return }
    resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: newWindow, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.end() }
    }
  }

  override var acceptsFirstResponder: Bool { true }
  override var focusRingMaskBounds: NSRect { bounds }

  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
  }

  override func resignFirstResponder() -> Bool {
    end()
    return true
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    begin()
  }

  override func accessibilityPerformPress() -> Bool {
    window?.makeFirstResponder(self)
    begin()
    return true
  }

  override func draw(_ dirtyRect: NSRect) {
    let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
    NSColor.textBackgroundColor.setFill()
    box.fill()
    (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
    box.stroke()
    let dim = isRecording || shortcut == nil
    let s = NSAttributedString(string: text, attributes: [
      .font: NSFont.systemFont(ofSize: 13),
      .foregroundColor: dim ? NSColor.secondaryLabelColor : NSColor.labelColor,
    ])
    let size = s.size()
    s.draw(at: NSPoint(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded()))
  }

  override func keyDown(with e: NSEvent) {
    let bare = Shortcut.Modifiers(flags: e.modifierFlags).isEmpty
    guard isRecording else {
      // Like a button: Space or Return starts recording.
      if bare, [49, 36, 76].contains(e.keyCode) { begin() } else { super.keyDown(with: e) }
      return
    }
    if let s = Shortcut(event: e) {
      record(s)
      return
    }
    guard bare || e.keyCode == 48 else { NSSound.beep(); return }
    switch e.keyCode {
    case 51, 117: record(nil)
    case 53, 36, 76: end()
    case 48:
      end()
      super.keyDown(with: e)  // Tab and ⇧Tab move on.
    default: NSSound.beep()
    }
  }

  /// ⌘ and ⌃ keys come here before keyDown. Take them while recording, so they set the shortcut instead of
  /// closing the window or quitting.
  override func performKeyEquivalent(with e: NSEvent) -> Bool {
    guard isRecording, e.type == .keyDown, window?.firstResponder === self, Shortcut(event: e) != nil else {
      return super.performKeyEquivalent(with: e)
    }
    keyDown(with: e)
    return true
  }

  override func flagsChanged(with e: NSEvent) {
    guard isRecording else { return super.flagsChanged(with: e) }
    held = Shortcut.Modifiers(flags: e.modifierFlags)
  }
}
