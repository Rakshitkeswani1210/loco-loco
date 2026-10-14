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

/// Records a shortcut in an alert: press the keys to set it, Delete for none. Return and Esc still reach the alert's buttons.
final class ShortcutField: NSView {
  private(set) var shortcut: Shortcut? {
    didSet { held = [] }
  }
  var onReturn: () -> Void = {}
  var onEscape: () -> Void = {}
  /// Modifiers held down before the key, shown while they're pressed.
  private var held: Shortcut.Modifiers = [] {
    didSet { refresh() }
  }

  init(shortcut: Shortcut?) {
    self.shortcut = shortcut
    super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
    setAccessibilityElement(true)
    setAccessibilityRole(.textField)
    setAccessibilityLabel("Keyboard shortcut")
    refresh()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  private var text: String { held.isEmpty ? shortcut?.title ?? "None" : held.symbols }

  private func refresh() {
    needsDisplay = true
    setAccessibilityValue(text)
  }

  override var acceptsFirstResponder: Bool { true }
  override var focusRingMaskBounds: NSRect { bounds }

  override func drawFocusRingMask() {
    NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
  }

  override func resignFirstResponder() -> Bool {
    held = []
    return true
  }

  override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

  override func draw(_ dirtyRect: NSRect) {
    let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
    NSColor.textBackgroundColor.setFill()
    box.fill()
    NSColor.separatorColor.setStroke()
    box.stroke()
    let dim = !held.isEmpty || shortcut == nil
    let s = NSAttributedString(string: text, attributes: [
      .font: NSFont.systemFont(ofSize: 13),
      .foregroundColor: dim ? NSColor.secondaryLabelColor : NSColor.labelColor,
    ])
    let size = s.size()
    s.draw(at: NSPoint(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded()))
  }

  override func keyDown(with e: NSEvent) {
    if let s = Shortcut(event: e) {
      shortcut = s
      return
    }
    let bare = Shortcut.Modifiers(flags: e.modifierFlags).isEmpty
    guard bare || e.keyCode == 48 else { NSSound.beep(); return }
    switch e.keyCode {
    case 51, 117: shortcut = nil
    case 53: onEscape()
    case 36, 76: onReturn()
    case 48: super.keyDown(with: e)  // Tab and ⇧Tab move to the buttons.
    default: NSSound.beep()
    }
  }

  /// ⌘ and ⌃ keys come here before keyDown. Take them while recording, so they set the shortcut instead of pressing a button.
  override func performKeyEquivalent(with e: NSEvent) -> Bool {
    guard e.type == .keyDown, window?.firstResponder === self, Shortcut(event: e) != nil else {
      return super.performKeyEquivalent(with: e)
    }
    keyDown(with: e)
    return true
  }

  override func flagsChanged(with e: NSEvent) {
    held = Shortcut.Modifiers(flags: e.modifierFlags)
  }
}
