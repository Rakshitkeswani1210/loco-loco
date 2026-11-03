import Foundation
import Testing
@testable import LocoCore

/// Shaped like a real `rayfin/.deployments.json`, with the keys Loco Loco must not keep.
private let deployments = Data(#"""
{"deployments":{"my-space":{"fabricItemId":"item-id","itemName":"web-kit","fabricApiUrl":"https://api.example/secret-path",
"fabricWorkspaceId":"w","fabricTenantId":"t","publishableKey":"pk-SECRET",
"hostingUrl":"https://brave-otter-12ab34cd56-eastus.webapp.example.net",
"fabricDeepLink":"https://app.fabric.example/item","deployedAt":"2026-11-03T22:01:01.858Z"},
"old":{"fabricItemId":"x"}},"active":"my-space"}
"""#.utf8)
private let yaml = """
id: web-kit
name: Web Kit
services:
  auth:
    name: nested
    allowedRedirectUris:
      - http://localhost:3600
      - http://127.0.0.1:3600
      - http://localhost:5173
  staticHosting:
    folder: out
"""

@Suite struct HostedTests {
  @Test func readsTheLinkNameDateAndPorts() throws {
    let links = Hosted.links(deployments: deployments, yaml: yaml, folder: "/Users/me/Acme /web-kit")
    let l = try #require(links.first)
    #expect(links.count == 1)
    #expect(l.url.hasPrefix("https://brave-otter"))
    #expect(l.title == "Web Kit")
    #expect(l.deployedAt != nil)
    #expect(l.ports == [3600, 5173])
    #expect(l.buildFolder == "out")
    #expect(l.shortURL == "brave-otter-12ab34cd56…example.net")
  }

  @Test func brokenFilesGiveNoLinks() {
    #expect(Hosted.links(deployments: Data("{".utf8), yaml: "", folder: "/x").isEmpty)
  }

  @Test func noSecretsLandInTheSavedFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("loco-links-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let links = Hosted.links(deployments: deployments, yaml: yaml, folder: "/x")
    try Hosted.save(links, to: url)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("SECRET") && !text.contains("secret-path") && !text.contains("item-id"))
    #expect(Hosted.load(from: url).first?.deployedAt == links.first?.deployedAt)
  }

  @Test func oneLinkPerUrlAndTheNewestDeployWins() {
    var old = HostedLink(url: "https://a", name: "old copy", folder: "/old")
    old.deployedAt = Date(timeIntervalSince1970: 100)
    var new = HostedLink(url: "https://a", name: "new", folder: "/new")
    new.deployedAt = Date(timeIntervalSince1970: 200)
    let merged = Hosted.merge(saved: [], found: [old, new])
    #expect(merged.count == 1)
    #expect(merged[0].name == "new" && merged[0].folder == "/new")
  }

  @Test func aLinkOutlivesItsFolderAndKeepsItsName() {
    var mine = HostedLink(url: "https://a", name: "a")
    mine.customName = "Mine"
    let gone = HostedLink(url: "https://gone", name: "gone")
    let merged = Hosted.merge(saved: [mine, gone], found: [HostedLink(url: "https://a", name: "b")])
    #expect(merged.map(\.title) == ["Mine", "gone"])
  }

  @Test func aNewDeployBringsBackAHiddenLink() {
    var saved = HostedLink(url: "https://a", name: "a")
    saved.hidden = true
    saved.deployedAt = Date(timeIntervalSince1970: 100)
    var same = saved
    same.hidden = nil
    #expect(Hosted.merge(saved: [saved], found: [same])[0].hidden == true)
    same.deployedAt = Date(timeIntervalSince1970: 200)
    #expect(Hosted.merge(saved: [saved], found: [same])[0].hidden == nil)
  }
}
