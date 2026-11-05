import Testing
@testable import LocoCore

@Suite struct SearchTests {
  private func rank(_ f: Search.Fields, _ q: String) -> Int? { Search.match(f, words: Search.words(q))?.rank }

  @Test func wordsCanComeInAnyOrderAndCaseDoesNotMatter() {
    let f = Search.Fields(name: "widget-kit", project: "Widgets")
    #expect(rank(f, "KIT widget") != nil)
    #expect(rank(f, "widget kit") == 0)
    #expect(rank(f, "widget kit nope") == nil)
  }

  @Test func nothingTypedMatchesNothing() {
    #expect(Search.words("   ").isEmpty)
    #expect(Search.match(Search.Fields(name: "x"), words: []) == nil)
  }

  @Test func aPortMatchesFromItsStart() {
    let f = Search.Fields(name: "acme-a", ports: [8841])
    #expect(rank(f, "8841") == 0)
    #expect(rank(f, "88") == 1)
    #expect(rank(f, "841") == nil)
  }

  @Test func theNameComesBeforeTheProjectTitleAndFolder() {
    let name = rank(Search.Fields(name: "acme-a"), "acme")!
    let inside = rank(Search.Fields(name: "my-acme"), "acme")!
    let project = rank(Search.Fields(name: "v1", project: "Acme"), "acme")!
    let title = rank(Search.Fields(name: "v1", title: "Acme Hospitals"), "acme")!
    let folder = rank(Search.Fields(name: "v1", folder: "~/Documents/acme"), "acme")!
    #expect([name, inside, project, title, folder] == [0, 1, 2, 3, 4])
  }

  @Test func aTitleOnlyMatchShowsTheTitle() {
    let f = Search.Fields(name: "v1", project: "Decks", title: "Safety review — Acme Hospitals")
    #expect(Search.match(f, words: ["acme"])?.showsTitle == true)
    #expect(Search.match(f, words: ["v1"])?.showsTitle == false)
    #expect(Search.match(f, words: ["decks"])?.showsTitle == false)
    // The name matches one word and the title the other: the title says why it's here.
    #expect(Search.match(f, words: ["v1", "acme"])?.showsTitle == true)
  }

  @Test func aFolderOrCommandMatchDoesNotShowTheTitle() {
    let f = Search.Fields(name: "v1", folder: "~/Documents/northwind", command: "python3 -m http.server", title: "Product sizes")
    #expect(Search.match(f, words: ["northwind"])?.showsTitle == false)
    #expect(rank(f, "http.server") == 4)
  }

  @Test func accentsAreIgnored() {
    #expect(rank(Search.Fields(name: "café-demo"), "cafe") == 0)
  }
}
