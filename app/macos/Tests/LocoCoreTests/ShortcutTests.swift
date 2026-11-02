import Testing
@testable import LocoCore

@Suite struct ShortcutTests {
  @Test func theStandardShortcutIsControlOptionL() {
    #expect(Shortcut.standard.display(character: "l") == "⌃⌥L")
    #expect(Shortcut.standard.storage == "37:3")
    #expect(Shortcut.standard.isValid)
  }

  @Test func storageReadsBack() {
    let s = Shortcut(keyCode: 40, modifiers: [.command, .shift, .option])
    #expect(Shortcut(storage: s.storage) == s)
  }

  @Test func emptyOrBrokenStorageMeansNone() {
    #expect(Shortcut(storage: "") == nil)
    #expect(Shortcut(storage: "37") == nil)
    #expect(Shortcut(storage: "x:3") == nil)
  }

  @Test func aShortcutNeedsControlOptionOrCommand() {
    #expect(!Shortcut(keyCode: 37, modifiers: []).isValid)
    #expect(!Shortcut(keyCode: 37, modifiers: [.shift]).isValid)
    #expect(Shortcut(keyCode: 37, modifiers: [.command]).isValid)
    #expect(Shortcut(storage: "37:4") == nil)
  }

  @Test func aFunctionKeyCanStandAlone() {
    let f5 = Shortcut(keyCode: 96, modifiers: [])
    #expect(f5.isValid)
    #expect(f5.display(character: nil) == "F5")
  }

  @Test func modifiersShowInMenuOrder() {
    let s = Shortcut(keyCode: 49, modifiers: [.command, .shift, .control, .option])
    #expect(s.display(character: " ") == "⌃⌥⇧⌘Space")
  }

  @Test func unknownModifierBitsAreDropped() {
    #expect(Shortcut(keyCode: 37, modifiers: Shortcut.Modifiers(rawValue: 0xFF)).modifiers == .all)
  }
}
