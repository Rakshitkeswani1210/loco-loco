import Foundation

/// The keys that open Loco Loco from any app: a virtual key code and its modifiers.
public struct Shortcut: Equatable, Sendable {
  public struct Modifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option = Modifiers(rawValue: 1 << 1)
    public static let shift = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)
    public static let all: Modifiers = [.control, .option, .shift, .command]

    /// In the order macOS menus show them: ⌃⌥⇧⌘.
    public var symbols: String {
      (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
  }

  public var keyCode: UInt16
  public var modifiers: Modifiers

  public init(keyCode: UInt16, modifiers: Modifiers) {
    self.keyCode = keyCode
    self.modifiers = modifiers.intersection(.all)
  }

  /// ⌃⌥L: L for Loco, and few apps take ⌃⌥ with a letter.
  public static let standard = Shortcut(keyCode: 37, modifiers: [.control, .option])

  /// Needs ⌃, ⌥ or ⌘, so it never fires while you type. A function key may stand alone.
  public var isValid: Bool {
    !modifiers.isDisjoint(with: [.control, .option, .command]) || Self.functionKeys.contains(keyCode)
  }

  /// How it's saved in the defaults: "37:3". Anything that doesn't read back as a valid shortcut means none.
  public var storage: String { "\(keyCode):\(modifiers.rawValue)" }

  public init?(storage: String) {
    let parts = storage.split(separator: ":")
    guard parts.count == 2, let key = UInt16(parts[0]), let mods = UInt32(parts[1]) else { return nil }
    self.init(keyCode: key, modifiers: Modifiers(rawValue: mods))
    guard isValid else { return nil }
  }

  /// "⌃⌥L". `character` is what the key types on the current layout, for keys whose name depends on it.
  public func display(character: String?) -> String {
    modifiers.symbols + (Self.keyNames[keyCode] ?? character?.uppercased() ?? "Key \(keyCode)")
  }

  /// F1 to F20.
  public static let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]

  /// Keys named the same on every keyboard layout.
  public static let keyNames: [UInt16: String] = {
    var names: [UInt16: String] = [
      49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
      123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]
    for (i, code) in functionKeys.enumerated() { names[code] = "F\(i + 1)" }
    return names
  }()
}
