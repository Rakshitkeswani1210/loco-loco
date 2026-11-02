import Foundation
import Testing
@testable import LocoCore

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

private func proc(_ pid: Int32) -> ProcRef { ProcRef(pid: pid, startMicros: UInt64(pid) * 1000) }

private func server(
  root: Int32, children: [Int32] = [], port: UInt16, command: String, dir: String = "/Users/me/site", project: String = "/Users/me/site"
) -> Server {
  Server(
    root: proc(root), startedAt: t0, ports: [port], name: "site", projectDir: project, command: command, commandDir: dir,
    path: nil, isDevServer: true, processes: [proc(root)] + children.map(proc), executable: nil)
}

@Suite struct ReconcileTests {
  @Test func keepsTheEntryWhenTheRootShellExitsFirst() throws {
    var h = History()
    let shell = server(root: 10, children: [11, 12], port: 4193, command: "cd /Users/me/site && npx vite preview")
    let first = h.reconcile([shell], now: t0).links
    let id = try #require(first[proc(10)])

    // The shell is gone; npx (11) is now the top of the chain, with a different command line.
    let orphan = server(root: 11, children: [12], port: 4193, command: "npx vite preview")
    let links = h.reconcile([orphan], now: t0 + 2).links
    #expect(links[proc(11)] == id)
    #expect(h.entries.count == 1)
    #expect(h.entries[0].command == "cd /Users/me/site && npx vite preview")
    #expect(h.entries[0].isRunning)
  }

  @Test func sameProjectAndPortWithANewCommandReusesTheEntry() {
    var h = History()
    h.reconcile([server(root: 20, port: 8094, command: "npx -y http-server -p 8094")], now: t0)
    h.reconcile([], now: t0 + 10)
    #expect(h.stopped.count == 1)

    h.reconcile([server(root: 30, port: 8094, command: "node http-server -p 8094 -s")], now: t0 + 20)
    #expect(h.entries.count == 1)
    #expect(h.stopped.isEmpty)
    #expect(h.entries[0].command == "node http-server -p 8094 -s")
  }

  @Test func sameCommandOnAnotherPortReusesTheEntry() {
    var h = History()
    h.reconcile([server(root: 40, port: 5173, command: "npm run dev")], now: t0)
    h.reconcile([], now: t0 + 10)
    h.reconcile([server(root: 41, port: 5174, command: "npm run dev")], now: t0 + 20)
    #expect(h.entries.count == 1)
    #expect(h.entries[0].port == 5174)
  }

  @Test func pruneDropsStoppedCopiesOfRunningAndOlderServers() {
    let a = HistoryEntry(server: server(root: 50, port: 8094, command: "a"), now: t0)
    var b = HistoryEntry(server: server(root: 51, port: 8094, command: "b"), now: t0)
    b.stoppedAt = t0 + 5
    var c = HistoryEntry(server: server(root: 52, port: 4193, command: "c", project: "/Users/me/q"), now: t0)
    c.stoppedAt = t0 + 1
    var d = HistoryEntry(server: server(root: 53, port: 4193, command: "d", project: "/Users/me/q"), now: t0)
    d.stoppedAt = t0 + 2
    var h = History(entries: [a, b, c, d])
    let removed = h.prune()
    #expect(removed)
    #expect(Set(h.entries.map(\.id)) == [a.id, d.id])
  }

  @Test func pruneKeepsEntriesBeingStarted() {
    let running = HistoryEntry(server: server(root: 60, port: 8094, command: "a"), now: t0)
    var starting = HistoryEntry(server: server(root: 61, port: 8094, command: "b"), now: t0)
    starting.stoppedAt = t0 + 5
    var h = History(entries: [running, starting])
    let removed = h.prune(keeping: [starting.id])
    #expect(!removed)
    #expect(h.entries.count == 2)
  }

  @Test func removeStoppedRemovesOnlyThatStoppedEntry() {
    let running = HistoryEntry(server: server(root: 80, port: 8094, command: "a"), now: t0)
    var keep = HistoryEntry(server: server(root: 81, port: 4193, command: "b"), now: t0)
    keep.stoppedAt = t0 + 1
    var gone = HistoryEntry(server: server(root: 82, port: 5173, command: "c"), now: t0)
    gone.stoppedAt = t0 + 2
    var h = History(entries: [running, keep, gone])

    let removed = h.removeStopped(gone.id)
    #expect(removed)
    #expect(Set(h.entries.map(\.id)) == [running.id, keep.id])
    let removedRunning = h.removeStopped(running.id)
    #expect(!removedRunning)
    let removedAgain = h.removeStopped(gone.id)
    #expect(!removedAgain)
    #expect(h.entries.count == 2)
  }

  @Test func pruneKeepsTheNewestUpToTheLimit() {
    var entries: [HistoryEntry] = []
    for i in 0..<5 {
      var e = HistoryEntry(server: server(root: 70 + Int32(i), port: 3000 + UInt16(i), command: "s\(i)"), now: t0)
      e.stoppedAt = t0 + Double(i)
      entries.append(e)
    }
    var h = History(entries: entries, limit: 3)
    h.prune()
    #expect(h.stopped.map(\.port) == [3004, 3003, 3002])
  }

  @Test func historyFilesWithoutProcsStillLoad() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("loco-test-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    var e = HistoryEntry(server: server(root: 80, port: 3000, command: "x"), now: t0)
    e.procs = nil
    try History(entries: [e]).save(to: url)
    #expect(try String(contentsOf: url, encoding: .utf8).contains("procs") == false)
    #expect(History.load(from: url).count == 1)
  }

  @Test func theProjectFolderIsSavedAndOptional() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("loco-test-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    var e = HistoryEntry(server: server(root: 81, port: 3001, command: "x"), now: t0)
    #expect(e.projectRoot == nil)
    e.projectRoot = "/Users/me/Documents/Acme "
    var h = History(entries: [e])
    try h.save(to: url)
    #expect(History.load(from: url).first?.projectRoot == "/Users/me/Documents/Acme ")
    // Files saved before project labels have no projectRoot key.
    h[e.id]?.projectRoot = nil
    try h.save(to: url)
    #expect(try String(contentsOf: url, encoding: .utf8).contains("projectRoot") == false)
    #expect(History.load(from: url).first?.projectRoot == nil)
  }

  @Test func pruneKeepsWhatAKeptServerNeedsPastTheLimit() {
    var app = HistoryEntry(server: server(root: 90, port: 3102, command: "app"), now: t0)
    app.stoppedAt = t0 + 3
    app.needs = [8002]
    var api = HistoryEntry(server: server(root: 91, port: 8002, command: "api"), now: t0)
    api.stoppedAt = t0 + 1
    api.needs = [8090]
    var mock = HistoryEntry(server: server(root: 92, port: 8090, command: "mock"), now: t0)
    mock.stoppedAt = t0
    var deck = HistoryEntry(server: server(root: 93, port: 8947, command: "deck"), now: t0)
    deck.stoppedAt = t0 + 2
    var h = History(entries: [app, api, mock, deck], limit: 2)
    h.prune()
    #expect(Set(h.stopped.map(\.port)) == [3102, 8947, 8002, 8090])
  }

  @Test func neededPortsFollowTheTicks() {
    var e = HistoryEntry(server: server(root: 94, port: 3102, command: "app"), now: t0)
    e.needs = [8002, 3102, 7777]
    e.needsRemoved = [7777]
    e.needsAdded = [8090]
    #expect(e.neededPorts == [8002, 8090])
  }

  @Test func aNewCommandForgetsTheNeedsFoundInTheOldOne() {
    var h = History()
    h.reconcile([server(root: 95, port: 3102, command: "API=http://127.0.0.1:8002 next dev")], now: t0)
    h[h.entries[0].id]?.needs = [8002]
    h.reconcile([], now: t0 + 1)
    h.reconcile([server(root: 96, port: 3102, command: "API=http://127.0.0.1:8003 next dev")], now: t0 + 2)
    #expect(h.entries.count == 1)
    #expect(h.entries[0].needs == nil)
  }
}
