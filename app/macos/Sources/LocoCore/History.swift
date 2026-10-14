import Foundation

/// A dev server Loco Loco has seen, running or stopped. Stopped entries are the history.
public struct HistoryEntry: Codable, Sendable, Identifiable, Hashable {
  public var id: UUID
  /// Set when the server is first seen and kept, so a restarted server keeps its row.
  public var name: String
  public var projectDir: String
  /// The folder that names its project label (see `Naming.projectRoot`). Kept, so the label survives a deleted worktree.
  public var projectRoot: String?
  /// What Restart runs, from `commandDir`, with `path` as PATH.
  public var command: String
  public var commandDir: String
  public var path: String?
  public var ports: [UInt16]
  public var startedAt: Date
  /// Nil while the server runs.
  public var stoppedAt: Date?
  public var lastSeenAt: Date
  public var root: ProcRef?
  /// The root and everything under it at the last scan. Finds the server again when its root exits
  /// before the rest, like a `cd … && npm run dev` shell.
  public var procs: [ProcRef]?
  /// Why the last restart failed. Shown in red in place of the time.
  public var failure: String?
  public var logPath: String?

  public var port: UInt16 { ports.first ?? 0 }
  public var isRunning: Bool { stoppedAt == nil }
  var key: String { commandDir + "\u{0}" + command }
  /// The same project on the same port is the same server, whatever command started it.
  var identity: String { projectDir + "\u{0}" + String(port) }

  public init(server s: Server, now: Date) {
    id = UUID()
    name = s.name
    projectDir = s.projectDir
    command = s.command
    commandDir = s.commandDir
    path = s.path
    ports = s.ports
    startedAt = s.startedAt
    lastSeenAt = now
    root = s.root
    procs = s.processes
  }
}

extension Server {
  var key: String { commandDir + "\u{0}" + command }
  var identity: String { projectDir + "\u{0}" + String(port) }
}

public struct History: Sendable {
  public private(set) var entries: [HistoryEntry]
  /// How many stopped servers to keep. Running ones are always kept.
  public var limit: Int

  public init(entries: [HistoryEntry] = [], limit: Int = 20) {
    self.entries = entries
    self.limit = limit
  }

  public subscript(id: UUID) -> HistoryEntry? {
    get { entries.first { $0.id == id } }
    set {
      guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
      if let newValue { entries[i] = newValue } else { entries.remove(at: i) }
    }
  }

  public var stopped: [HistoryEntry] {
    entries.filter { !$0.isRunning }.sorted {
      ($0.stoppedAt!, $1.port) > ($1.stoppedAt!, $0.port)
    }
  }

  /// Removes stopped entries, except `keep`: ones Loco Loco is starting right now.
  public mutating func clearStopped(keeping keep: Set<UUID> = []) {
    entries.removeAll { !$0.isRunning && !keep.contains($0.id) }
  }

  /// Links each scanned dev server to an entry and records the ones that stopped.
  ///
  /// A server matches an entry by its root process (pid and start time), then by a pid Loco Loco
  /// spawned for that entry, then by any process the entry had at the last scan (its root exited first).
  /// After that it matches the same server started again by hand: the same folder and command, or else
  /// the same project and port, which takes the new command.
  /// Running entries with no server have stopped. On the first scan after launch they get the time
  /// they were last seen, because they may have stopped while Loco Loco wasn't running.
  /// - Parameter keeping: entries Loco Loco is starting or stopping. Pruning leaves them alone.
  /// - Returns: the entry for each server root, and whether anything worth saving changed.
  @discardableResult
  public mutating func reconcile(
    _ servers: [Server], spawned: [pid_t: UUID] = [:], now: Date = Date(), firstScan: Bool = false, keeping: Set<UUID> = []
  ) -> (links: [ProcRef: UUID], changed: Bool) {
    var links: [ProcRef: UUID] = [:]
    var matched = Set<UUID>()
    var changed = false
    let dev = servers.filter(\.isDevServer)

    func link(_ s: Server, _ i: Int) {
      var e = entries[i]
      if e.root != s.root { e.root = s.root; e.startedAt = s.startedAt; changed = true }
      if e.stoppedAt != nil { e.stoppedAt = nil; changed = true }
      if e.failure != nil { e.failure = nil; changed = true }
      if e.ports != s.ports { e.ports = s.ports; changed = true }
      if e.path == nil, s.path != nil { e.path = s.path; changed = true }
      e.procs = s.processes
      e.lastSeenAt = now
      entries[i] = e
      matched.insert(e.id)
      links[s.root] = e.id
    }

    // The same process, one Loco Loco started for an entry, or what's left of a running entry's processes.
    var rest: [Server] = []
    for s in dev {
      if let i = entries.firstIndex(where: { $0.root == s.root && !matched.contains($0.id) }) {
        link(s, i)
      } else if let id = s.processes.lazy.compactMap({ spawned[$0.pid] }).first,
                let i = entries.firstIndex(where: { $0.id == id && !matched.contains(id) }) {
        link(s, i)
      } else if let i = entries.firstIndex(where: {
        $0.isRunning && !matched.contains($0.id) && !Set($0.procs ?? []).isDisjoint(with: s.processes)
      }) {
        link(s, i)
      } else {
        rest.append(s)
      }
    }
    // Started again by hand: the most recent entry with the same folder and command, else the same project and port.
    for s in rest {
      let free = entries.indices.filter { !matched.contains(entries[$0].id) }
      let newest: (Int, Int) -> Bool = { entries[$0].lastSeenAt < entries[$1].lastSeenAt }
      if let i = free.filter({ entries[$0].key == s.key }).max(by: newest) {
        link(s, i)
      } else if let i = free.filter({ entries[$0].identity == s.identity }).max(by: newest) {
        entries[i].command = s.command
        entries[i].commandDir = s.commandDir
        entries[i].path = s.path
        link(s, i)
        changed = true
      } else {
        entries.append(HistoryEntry(server: s, now: now))
        link(s, entries.count - 1)
        changed = true
      }
    }

    for i in entries.indices where entries[i].isRunning && !matched.contains(entries[i].id) {
      entries[i].stoppedAt = firstScan ? entries[i].lastSeenAt : now
      changed = true
    }
    if prune(keeping: keeping) { changed = true }
    return (links, changed)
  }

  /// The newest `limit` stopped entries, one per folder and command and one per project and port.
  /// A stopped entry for a server that's running again goes. `keep` is never removed.
  @discardableResult
  public mutating func prune(keeping keep: Set<UUID> = []) -> Bool {
    var kept = Set<UUID>()
    var claimed = Set<String>()
    for e in entries where e.isRunning {
      claimed.insert(e.key)
      claimed.insert(e.identity)
    }
    for e in stopped where keep.contains(e.id) || (!claimed.contains(e.key) && !claimed.contains(e.identity) && kept.count < limit) {
      claimed.insert(e.key)
      claimed.insert(e.identity)
      kept.insert(e.id)
    }
    let before = entries.count
    entries.removeAll { !$0.isRunning && !kept.contains($0.id) && !keep.contains($0.id) }
    return entries.count != before
  }

  // MARK: File

  struct File: Codable {
    var version = 1
    var entries: [HistoryEntry]
  }

  /// Keeps fractions of a second, so servers stopped together still sort the same after a relaunch.
  static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

  public static var defaultURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Loco Loco/history.json")
  }

  public static func load(from url: URL = defaultURL) -> [HistoryEntry] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { try dateStyle.parse($0.singleValueContainer().decode(String.self)) }
    return (try? decoder.decode(File.self, from: data))?.entries ?? []
  }

  public func save(to url: URL = defaultURL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var c = encoder.singleValueContainer()
      try c.encode(History.dateStyle.format(date))
    }
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(File(entries: entries)).write(to: url, options: .atomic)
  }
}
