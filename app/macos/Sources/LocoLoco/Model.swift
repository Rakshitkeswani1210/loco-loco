import AppKit
import LocoCore
import Observation
import ServiceManagement

enum RowGroup: Sendable { case running, stopped }

enum RowAction: String, Sendable {
  case stop, restart, log, force, remove

  var symbol: String {
    switch self {
    case .stop: "stop.fill"
    case .restart: "arrow.clockwise"
    case .log: "doc.text"
    case .force: "xmark.octagon"
    case .remove: "trash"
    }
  }

  /// Point sizes that give the mockup's symbol sizes: 11.5pt tall for restart and log, 9.5pt for stop.
  var symbolSize: CGFloat { self == .stop ? 11.75 : 11 }

  var title: String {
    switch self {
    case .stop: "Stop"
    case .restart: "Restart"
    case .log: "Show log"
    case .force: "Force stop"
    case .remove: "Remove from history"
    }
  }
}

/// The project a row belongs to, drawn as a tinted label.
struct ProjectTag: Equatable {
  /// The folder that names the project. Nil for the Other group.
  let root: String?
  let name: String
  /// An index into `Palette.tags`. Nil draws it grey.
  let tint: Int?
}

/// Running servers from one project, under its label.
struct ProjectGroup: Identifiable, Equatable {
  let tag: ProjectTag
  var rows: [Row]
  var id: String { tag.root == nil ? "\u{0}other" : tag.name }
  /// What hovering the label highlights. Other has none, since it isn't one project.
  var headerID: String? { tag.root.map { "proj:" + $0 } }
}

/// One line in the panel.
struct Row: Identifiable, Equatable {
  enum State: Equatable { case idle, stopping, starting, force, queued }

  /// The history entry's UUID, or `app-<pid>-<start>` for app and macOS servers.
  let id: String
  let group: RowGroup
  let port: UInt16
  let ports: [UInt16]
  let name: String
  let folder: String
  let project: ProjectTag?
  /// Start time while running, stop time once stopped.
  let time: Date
  let failure: String?
  let state: State
  let entryID: UUID?
  let server: Server?
  let logPath: String?

  var hasLog: Bool { logPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }
  var canStop: Bool { group == .running && entryID != nil && server != nil && state == .idle }
  var canRestart: Bool { entryID != nil && state == .idle && (group == .stopped || server != nil) }
  var canRemove: Bool { group == .stopped && entryID != nil && state == .idle }

  /// The buttons that take the place of the time on hover.
  var actions: [RowAction] {
    guard entryID != nil, state == .idle else { return [] }
    switch group {
    case .running: return server == nil ? [] : [.stop]
    case .stopped: return failure != nil && hasLog ? [.log, .restart] : [.restart]
    }
  }

  var url: URL { URL(string: "http://localhost:\(port)")! }

  var accessibilityLabel: String {
    let status: String
    switch state {
    case .stopping: status = "stopping"
    case .force: status = "not stopping, force stop available"
    case .starting: status = "starting"
    case .queued: status = "queued"
    case .idle:
      if let failure { status = "didn't start: \(failure)" }
      else if group == .running { status = "running since \(TimeText.short(time))" }
      else { status = "stopped \(TimeText.short(time))" }
    }
    let project = project.map { ", \($0.name)" } ?? ""
    return "\(name)\(project), port \(port), \(status)"
  }
}

/// Two or more stopped servers from one project, as one line that opens to list them.
struct ProjectLine: Identifiable, Equatable {
  let tag: ProjectTag
  let count: Int
  /// When the latest one stopped.
  let time: Date
  let open: Bool
  /// Shown while open: the latest few, unless its More was chosen.
  let rows: [Row]
  var root: String { tag.root ?? "" }
  var id: String { "line:" + root }
  var moreID: String { "more:" + root }
  var hidden: Int { open ? count - rows.count : 0 }
}

/// A line in Stopped: a server on its own, or a project's line.
enum StoppedItem: Identifiable, Equatable {
  case row(Row)
  case line(ProjectLine)

  var id: String {
    switch self {
    case .row(let r): r.id
    case .line(let l): l.id
    }
  }
}

struct Rows: Equatable {
  static let more = "more"

  /// Newest first. When grouped, in group order.
  var running: [Row] = []
  /// Set when Group by project is on and some server has a project.
  var groups: [ProjectGroup]?
  /// Stopped, grouped by project, newest first. The 5 latest unless More was chosen.
  var stoppedItems: [StoppedItem] = []
  /// Every stopped row on show: servers on their own and the ones in open lines.
  var stopped: [Row] = []
  /// Every stopped server, including the ones under More.
  var stoppedTotal = 0
  /// How many Stopped lines aren't shown until More, and the servers in them.
  var hiddenItems = 0
  var hiddenServers = 0

  var hasMore: Bool { hiddenItems > 0 }
  /// Top to bottom, as the arrow keys move.
  var order: [String] {
    var ids = running.map(\.id)
    for item in stoppedItems {
      switch item {
      case .row(let r): ids.append(r.id)
      case .line(let l):
        ids.append(l.id)
        ids += l.rows.map(\.id)
        if l.hidden > 0 { ids.append(l.moreID) }
      }
    }
    return ids + (hasMore ? [Rows.more] : [])
  }
  /// Rows under the Stopped header, for the panel's height.
  var stoppedLines: Int {
    stoppedItems.reduce(0) { n, item in
      if case .line(let l) = item { return n + 1 + l.rows.count + (l.hidden > 0 ? 1 : 0) }
      return n + 1
    }
  }

  func line(_ id: String?) -> ProjectLine? {
    for case .line(let l) in stoppedItems where l.id == id { return l }
    return nil
  }

  func row(_ id: String?) -> Row? {
    guard let id else { return nil }
    return running.first { $0.id == id } ?? stopped.first { $0.id == id }
  }
}

/// What the panel asks the controller to do.
enum Command {
  case primary(String)
  case action(String, RowAction)
  case menu(String, CGPoint?)
  case more
  case settings
  case close
}

enum Appearance: String, CaseIterable {
  case system, light, dark

  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

@MainActor @Observable
final class Model {
  enum Busy {
    case stopping(procs: [ProcRef], since: Date, thenStart: Bool)
    case starting(pid: pid_t, since: Date)
  }

  /// A restart that starts what a server needs first, one at a time, each once the one before listens.
  struct Chain {
    /// Still to come up, in order. The server asked for is last.
    var ids: [UUID]
    /// The ones this chain started. One that's no longer starting and isn't up didn't make it.
    var started: Set<UUID> = []
    let since: Date
  }

  // MARK: Settings

  private(set) var showCount: Bool
  private(set) var showAll: Bool
  private(set) var historyLimit: Int
  private(set) var groupByProject: Bool
  /// Project names you chose, by project folder.
  private(set) var projectNames: [String: String]
  /// Label colours by project name, given out in the order projects first appear.
  private(set) var projectTints: [String: Int]
  /// Opens the panel in the middle of the screen from any app. Nil when turned off.
  private(set) var shortcut: Shortcut?
  private(set) var appearance: Appearance
  /// The panel shows what's behind it through glass instead of a solid surface.
  private(set) var transparent: Bool
  /// Read from macOS, which the user can change in System Settings too.
  private(set) var launchAtLogin = false
  /// A card with a snapshot of the page beside the panel, on hover.
  private(set) var showPreviews: Bool

  // MARK: Servers and history

  private(set) var servers: [Server] = []
  private(set) var history: History
  private(set) var links: [ProcRef: UUID] = [:]
  private(set) var busy: [UUID: Busy] = [:]
  private(set) var forced: Set<UUID> = []
  /// Restarts waiting on the servers they need, needs first.
  private(set) var chains: [Chain] = []
  var expanded = false
  /// Stopped project lines opened or closed by hand, by project folder, until the panel closes.
  /// A line whose newest server didn't start opens by itself, so this flips it.
  var toggledProjects: Set<String> = []
  /// Project lines whose More was chosen: they list every stopped server.
  var fullProjects: Set<String> = []
  var scrolls = false
  /// Set only by the test hooks, to show just these ports in screenshots. Scanning and history are unaffected.
  var onlyPorts: Set<UInt16>?

  // MARK: Pointer and keyboard

  var highlight: String? {
    didSet { if highlight != oldValue { updatePreview() } }
  }
  /// The row whose preview card shows beside the panel.
  var preview: String?
  /// The button under the pointer: `btn:<row>:<action>` or `menu`.
  var hot: String?
  /// The row whose context menu is open. It stays highlighted and hides its buttons.
  var menuRow: String? {
    didSet { if menuRow != nil { preview = nil } }
  }
  var moreMenuOpen = false {
    didSet { if moreMenuOpen { preview = nil } }
  }

  @ObservationIgnored var frames: [String: CGRect] = [:]
  @ObservationIgnored var pointer: CGPoint?
  /// A different row slid under a still pointer. Hover and clicks wait until the pointer moves.
  @ObservationIgnored var staleUnderPointer = false
  @ObservationIgnored var keyboardDriven = false
  @ObservationIgnored var perform: (Command) -> Void = { _ in }
  @ObservationIgnored var onFrames: (() -> Void)?

  @ObservationIgnored var isOpen = false {
    didSet {
      guard isOpen != oldValue else { return }
      if isOpen { scanNow() } else { schedule() }
    }
  }

  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var previewTimer: Timer?
  @ObservationIgnored let snapshotter = Snapshotter()
  /// When each running server was first linked: process start on the first scan, else when it came up. Snapshots follow it.
  @ObservationIgnored private var cameUp: [UUID: Date] = [:]
  /// Entries whose saved command was checked for a served folder this session.
  @ObservationIgnored private var namesChecked: Set<UUID> = []
  @ObservationIgnored private var spawned: [pid_t: UUID] = [:]
  @ObservationIgnored private let watcher = ChildWatcher()
  @ObservationIgnored private var scanning = false
  @ObservationIgnored private var rescan = false
  @ObservationIgnored private var firstScan = true
  @ObservationIgnored private var lastSave = Date.distantPast
  @ObservationIgnored private let home = NSHomeDirectory()
  /// Where project labels are worked out from. Test builds can point it at fixtures outside the real home folder.
  @ObservationIgnored private let projectHome: String = {
    #if TEST_HOOKS
    if let h = ProcessInfo.processInfo.environment["LOCO_PROJECT_HOME"] { return h }
    #endif
    return NSHomeDirectory()
  }()
  /// The history file. Test builds can point it at a copy, so checks leave the real one alone.
  @ObservationIgnored private let historyURL: URL = {
    #if TEST_HOOKS
    if let h = ProcessInfo.processInfo.environment["LOCO_HISTORY"] { return URL(fileURLWithPath: h) }
    #endif
    return History.defaultURL
  }()
  /// Project folders found this session, by server folder. Nil when a folder has none.
  @ObservationIgnored private var rootCache: [String: String?] = [:]

  init() {
    let d = UserDefaults.standard
    d.register(defaults: [
      "showCount": true, "showAll": false, "historyLimit": 20, "groupByProject": false, "shortcut": Shortcut.standard.storage,
      "appearance": Appearance.system.rawValue, "transparent": false, "showPreviews": true,
    ])
    showCount = d.bool(forKey: "showCount")
    showAll = d.bool(forKey: "showAll")
    historyLimit = d.integer(forKey: "historyLimit")
    groupByProject = d.bool(forKey: "groupByProject")
    projectNames = d.dictionary(forKey: "projectNames") as? [String: String] ?? [:]
    projectTints = d.dictionary(forKey: "projectTints") as? [String: Int] ?? [:]
    shortcut = Shortcut(storage: d.string(forKey: "shortcut") ?? "")
    appearance = Appearance(rawValue: d.string(forKey: "appearance") ?? "") ?? .system
    transparent = d.bool(forKey: "transparent")
    showPreviews = d.bool(forKey: "showPreviews")
    history = History(entries: [], limit: d.integer(forKey: "historyLimit"))
    history = History(entries: History.load(from: historyURL), limit: historyLimit)
  }

  // MARK: Rows

  var rows: Rows {
    var out = Rows()
    var shown = Set<UUID>()
    let only = onlyPorts
    for s in servers where only?.contains(s.port) ?? true {
      if s.isDevServer, let id = links[s.root], let e = history[id] {
        shown.insert(id)
        out.running.append(Row(
          id: id.uuidString, group: .running, port: s.port, ports: s.ports, name: e.name, folder: e.projectDir,
          project: tag(e.projectRoot), time: e.startedAt, failure: nil, state: state(id), entryID: id, server: s, logPath: e.logPath))
      } else if showAll, !s.isDevServer {
        out.running.append(Row(
          id: "app-\(s.root.pid)-\(s.root.startMicros)", group: .running, port: s.port, ports: s.ports, name: s.name,
          folder: s.projectDir, project: nil, time: s.startedAt, failure: nil, state: .idle, entryID: nil, server: s, logPath: nil))
      }
    }
    // Starting, not listening yet: shown in Running with a spinner.
    for (id, b) in busy where !shown.contains(id) {
      guard case let .starting(_, since) = b, let e = history[id], only?.contains(e.port) ?? true else { continue }
      out.running.append(Row(
        id: id.uuidString, group: .running, port: e.port, ports: e.ports, name: e.name, folder: e.projectDir,
        project: tag(e.projectRoot), time: since, failure: nil, state: .starting, entryID: id, server: nil, logPath: e.logPath))
      shown.insert(id)
    }
    // Waiting for a server it needs: in Running, in the order they'll start.
    for c in chains {
      for (i, id) in c.ids.enumerated() where !shown.contains(id) {
        guard let e = history[id], only?.contains(e.port) ?? true else { continue }
        shown.insert(id)
        out.running.append(Row(
          id: id.uuidString, group: .running, port: e.port, ports: e.ports, name: e.name, folder: e.projectDir,
          project: tag(e.projectRoot), time: c.since - Double(i) / 1000, failure: nil, state: .queued, entryID: id, server: nil, logPath: e.logPath))
      }
    }
    out.running.sort { ($1.time, $0.port, $0.id) < ($0.time, $1.port, $1.id) }
    if groupByProject { group(&out) }

    let stopped = history.stopped.filter { !shown.contains($0.id) && busy[$0.id] == nil && (only?.contains($0.port) ?? true) }
    out.stoppedTotal = stopped.count
    func row(_ e: HistoryEntry) -> Row {
      Row(id: e.id.uuidString, group: .stopped, port: e.port, ports: e.ports, name: e.name, folder: e.projectDir,
          project: tag(e.projectRoot), time: e.stoppedAt ?? e.lastSeenAt, failure: e.failure, state: .idle, entryID: e.id, server: nil, logPath: e.logPath)
    }
    // One line per project with two or more, where its newest one would be. A server with no project stays a row.
    var byProject: [String: [HistoryEntry]] = [:]
    for e in stopped { if let root = e.projectRoot { byProject[root, default: []].append(e) } }
    var items: [StoppedItem] = []
    var placed = Set<String>()
    for e in stopped {
      guard let root = e.projectRoot, let members = byProject[root], members.count > 1 else { items.append(.row(row(e))); continue }
      guard placed.insert(root).inserted, let tag = tag(root) else { continue }
      let open = (members[0].failure != nil) != toggledProjects.contains(root)
      // A More that would hide a single server takes that server's height, so show it instead.
      let limit = fullProjects.contains(root) || members.count <= Metrics.shownStopped + 1 ? members.count : Metrics.shownStopped
      items.append(.line(ProjectLine(
        tag: tag, count: members.count, time: members[0].stoppedAt ?? members[0].lastSeenAt, open: open,
        rows: open ? members.prefix(limit).map(row) : [])))
    }
    let limit = expanded || items.count <= Metrics.shownStopped + 1 ? items.count : Metrics.shownStopped
    out.stoppedItems = Array(items.prefix(limit))
    out.hiddenItems = items.count - limit
    out.hiddenServers = items.dropFirst(limit).reduce(0) { n, item in
      if case .line(let l) = item { return n + l.count }
      return n + 1
    }
    for item in out.stoppedItems {
      switch item {
      case .row(let r): out.stopped.append(r)
      case .line(let l): out.stopped += l.rows
      }
    }
    return out
  }

  /// Running rows by project, the project with the newest server first. Servers with no project go last, under Other.
  private func group(_ out: inout Rows) {
    var groups: [ProjectGroup] = []
    var other: [Row] = []
    for r in out.running {
      guard let p = r.project else { other.append(r); continue }
      if let i = groups.firstIndex(where: { $0.tag.name == p.name }) { groups[i].rows.append(r) }
      else { groups.append(ProjectGroup(tag: p, rows: [r])) }
    }
    guard !groups.isEmpty else { return }
    if !other.isEmpty { groups.append(ProjectGroup(tag: ProjectTag(root: nil, name: "Other", tint: nil), rows: other)) }
    out.groups = groups
    out.running = groups.flatMap(\.rows)
  }

  // MARK: Projects

  func projectName(_ root: String) -> String { projectNames[root] ?? Naming.projectName(root) }

  private func tag(_ root: String?) -> ProjectTag? {
    guard let root else { return nil }
    let name = projectName(root)
    // Before a colour is given out, a stable one from the name.
    let tint = projectTints[name] ?? name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % Palette.tags.count
    return ProjectTag(root: root, name: name, tint: tint)
  }

  /// Finds the project of entries that don't have one yet, such as ones saved before labels existed.
  private func fillProjectRoots() -> Bool {
    var changed = false
    for e in history.entries where e.projectRoot == nil {
      let root: String?
      if let cached = rootCache[e.projectDir] { root = cached } else {
        root = Naming.projectRoot(dir: e.projectDir, home: projectHome)
        rootCache[e.projectDir] = root
      }
      guard let root else { continue }
      history[e.id]?.projectRoot = root
      changed = true
    }
    return changed
  }

  /// Gives each new project the colour fewest projects have, oldest project first.
  private func assignTints() {
    var names: [String] = []
    for e in history.entries.sorted(by: { $0.startedAt < $1.startedAt }) {
      if let root = e.projectRoot, case let n = projectName(root), !names.contains(n) { names.append(n) }
    }
    let missing = names.filter { projectTints[$0] == nil }
    guard !missing.isEmpty else { return }
    var used = Array(repeating: 0, count: Palette.tags.count)
    for n in names { if let t = projectTints[n] { used[t % used.count] += 1 } }
    var tints = projectTints
    for n in missing {
      let t = used.indices.min { used[$0] < used[$1] }!
      tints[n] = t
      used[t] += 1
    }
    projectTints = tints
    UserDefaults.standard.set(tints, forKey: "projectTints")
  }

  /// Names every server in the project's folder. An empty name, or the folder's own, goes back to the folder's.
  /// Two folders given one name share a group, and a new name keeps the old one's colour.
  func renameProject(root: String, to newName: String) {
    let old = projectName(root)
    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    projectNames[root] = name.isEmpty || name == Naming.projectName(root) ? nil : name
    UserDefaults.standard.set(projectNames, forKey: "projectNames")
    let new = projectName(root)
    if new != old, projectTints[new] == nil, let t = projectTints[old] {
      projectTints[new] = t
      UserDefaults.standard.set(projectTints, forKey: "projectTints")
    }
  }

  private func state(_ id: UUID) -> Row.State {
    switch busy[id] {
    case .stopping?: forced.contains(id) ? .force : .stopping
    case .starting?: .starting
    case nil: .idle
    }
  }

  var stoppable: [UUID] { rows.running.filter(\.canStop).compactMap(\.entryID) }

  /// Opens or closes a project's line in Stopped.
  func toggleProject(_ root: String) {
    if toggledProjects.contains(root) { toggledProjects.remove(root) } else { toggledProjects.insert(root) }
  }

  /// Stops every running server in a project.
  func stopProject(_ root: String) {
    for r in rows.running where r.project?.root == root && r.canStop { if let id = r.entryID { stop(id) } }
  }

  /// Stopped servers in a project, newest first.
  func stoppedInProject(_ root: String) -> [UUID] {
    history.stopped.filter { $0.projectRoot == root && busy[$0.id] == nil && !queued.contains($0.id) }.map(\.id)
  }

  /// Restarts every stopped server in a project, each after the ones it needs.
  func restartProject(_ root: String) {
    for id in stoppedInProject(root).reversed() { startWithNeeds(id) }
  }

  // MARK: Needs

  /// What a server needs, as the panel shows it: port, name if known, and whether something listens there.
  struct Need: Equatable, Identifiable {
    let port: UInt16
    let name: String?
    let running: Bool
    var id: UInt16 { port }
  }

  /// What it calls itself, for the Needs menu.
  func directNeeds(of id: UUID) -> [Need] {
    guard let e = history[id] else { return [] }
    return e.neededPorts.map { p in Need(port: p, name: entry(forPort: p, near: e)?.name, running: listening(p)) }
  }

  /// Everything down the chain: what it needs, then what those need, each once.
  func needs(of id: UUID) -> [Need] {
    guard let first = history[id] else { return [] }
    var out: [Need] = []
    var seen = Set(first.ports)
    var queue: [(port: UInt16, near: HistoryEntry)] = first.neededPorts.map { ($0, first) }
    while !queue.isEmpty {
      let (p, near) = queue.removeFirst()
      guard seen.insert(p).inserted else { continue }
      let e = entry(forPort: p, near: near)
      out.append(Need(port: p, name: e?.name, running: listening(p)))
      if let e { queue += e.neededPorts.map { ($0, e) } }
    }
    return out
  }

  /// The servers that need this one, running first.
  func neededBy(_ id: UUID) -> [Need] {
    guard let e = history[id] else { return [] }
    var seen = Set<UInt16>()
    let users = history.entries
      .filter { $0.id != id && $0.neededPorts.contains(e.port) }
      .sorted { ($0.isRunning ? 0 : 1, $1.lastSeenAt) < ($1.isRunning ? 0 : 1, $0.lastSeenAt) }
    return users.compactMap { u in seen.insert(u.port).inserted ? Need(port: u.port, name: u.name, running: u.isRunning) : nil }
  }

  /// The stopped servers a restart would start first, as ports.
  func stoppedNeeds(of id: UUID) -> [UInt16] {
    needOrder(id).dropLast().compactMap { history[$0]?.port }
  }

  /// The help tag on a button: what Restart will start with it, or how many a project's button acts on.
  func buttonTip(_ button: String) -> String {
    guard let colon = button.lastIndex(of: ":"), let action = RowAction(rawValue: String(button[button.index(after: colon)...])) else { return "" }
    let id = String(button.dropFirst(4)[..<colon])
    if id.hasPrefix("proj:") {
      let root = String(id.dropFirst(5))
      let n = rows.running.filter { $0.project?.root == root && $0.canStop }.count
      return "Stop \(n) in \(projectName(root))"
    }
    if id.hasPrefix("line:") {
      let root = String(id.dropFirst(5))
      return "Restart \(stoppedInProject(root).count) in \(projectName(root))"
    }
    guard action == .restart, let row = rows.row(id), row.group == .stopped, let e = row.entryID else { return action.title }
    let first = stoppedNeeds(of: e)
    guard !first.isEmpty else { return action.title }
    let ports = first.map(String.init)
    let list = ports.count == 1 ? ports[0] : ports.dropLast().joined(separator: ", ") + " and " + ports.last!
    return "Restart with \(list)"
  }

  /// What VoiceOver adds to a row: the page's title and what it needs.
  func accessibilityDetail(_ row: Row) -> String {
    guard let e = row.entryID.flatMap({ history[$0] }) else { return "" }
    var parts: [String] = []
    if let t = e.title { parts.append(t) }
    let needs = e.neededPorts.map(String.init)
    if !needs.isEmpty { parts.append("needs " + needs.joined(separator: ", ")) }
    return parts.joined(separator: ", ")
  }

  /// Ticks or unticks a port in a server's Needs menu.
  func toggleNeed(_ id: UUID, port: UInt16) {
    guard var e = history[id] else { return }
    var added = Set(e.needsAdded ?? []), removed = Set(e.needsRemoved ?? [])
    if e.neededPorts.contains(port) {
      if added.contains(port) { added.remove(port) } else { removed.insert(port) }
    } else {
      if removed.contains(port) { removed.remove(port) } else { added.insert(port) }
    }
    e.needsAdded = added.isEmpty ? nil : added.sorted()
    e.needsRemoved = removed.isEmpty ? nil : removed.sorted()
    history[id] = e
    save()
  }

  /// Other servers in the same project, one per port, for the Needs menu.
  func projectNeighbours(of id: UUID) -> [Need] {
    guard let e = history[id], let root = e.projectRoot else { return [] }
    var seen = Set(e.ports)
    return history.entries
      .filter { $0.projectRoot == root && $0.id != id }
      .sorted { $0.lastSeenAt > $1.lastSeenAt }
      .compactMap { n in seen.insert(n.port).inserted ? Need(port: n.port, name: n.name, running: listening(n.port)) : nil }
      .sorted { $0.port < $1.port }
  }

  private func listening(_ port: UInt16) -> Bool { servers.contains { $0.ports.contains(port) } }

  /// The server that answers on a port: the one running there, else one from the same project, else the newest.
  private func entry(forPort port: UInt16, near e: HistoryEntry) -> HistoryEntry? {
    let linked = linkedIDs
    let all = history.entries.filter { $0.id != e.id && $0.ports.contains(port) }
    if let r = all.first(where: { linked.contains($0.id) }) { return r }
    return all.max { a, b in
      (a.projectRoot == e.projectRoot ? 1 : 0, a.lastSeenAt) < (b.projectRoot == e.projectRoot ? 1 : 0, b.lastSeenAt)
    }
  }

  /// Needs first, depth first, then the server itself. Ones already listening are left out; a loop is cut where it closes.
  private func needOrder(_ id: UUID) -> [UUID] {
    var out: [UUID] = []
    var seen = Set<UUID>()
    func visit(_ id: UUID) {
      guard seen.insert(id).inserted, let e = history[id] else { return }
      for p in e.neededPorts where !listening(p) {
        if let n = entry(forPort: p, near: e) { visit(n.id) }
      }
      out.append(id)
    }
    visit(id)
    return out
  }

  private var queued: Set<UUID> { Set(chains.flatMap(\.ids)) }

  // MARK: Settings

  func setShowCount(_ on: Bool) {
    showCount = on
    UserDefaults.standard.set(on, forKey: "showCount")
  }

  func setShowAll(_ on: Bool) {
    showAll = on
    UserDefaults.standard.set(on, forKey: "showAll")
  }

  func setGroupByProject(_ on: Bool) {
    groupByProject = on
    UserDefaults.standard.set(on, forKey: "groupByProject")
  }

  /// Saves an empty string for none, so the ⌃⌥L default doesn't come back.
  func setShortcut(_ s: Shortcut?) {
    shortcut = s
    UserDefaults.standard.set(s?.storage ?? "", forKey: "shortcut")
  }

  func setAppearance(_ a: Appearance) {
    appearance = a
    UserDefaults.standard.set(a.rawValue, forKey: "appearance")
  }

  func setTransparent(_ on: Bool) {
    transparent = on
    UserDefaults.standard.set(on, forKey: "transparent")
  }

  func setShowPreviews(_ on: Bool) {
    showPreviews = on
    UserDefaults.standard.set(on, forKey: "showPreviews")
    if on { queueSnapshots() } else { preview = nil }
  }

  func refreshLaunchAtLogin() {
    let on = SMAppService.mainApp.status == .enabled
    if launchAtLogin != on { launchAtLogin = on }
  }

  func setLaunchAtLogin(_ on: Bool) throws {
    defer { refreshLaunchAtLogin() }
    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
  }

  func setHistoryLimit(_ n: Int) {
    historyLimit = n
    UserDefaults.standard.set(n, forKey: "historyLimit")
    history.limit = n
    history.prune(keeping: Set(busy.keys))
    save()
  }

  func clearHistory() {
    history.clearStopped(keeping: Set(busy.keys).union(queued))
    expanded = false
    save()
    Snapshotter.clean(keeping: Set(history.entries.map(\.id)))
  }

  /// Forgets one stopped server, so it can't be restarted from here. Its log stays, as with Clear history.
  /// From the keyboard, the highlight moves to the stopped row that takes its place, never to a running one.
  func remove(_ id: UUID) {
    let before = rows.stopped.map(\.id)
    guard busy[id] == nil, history.removeStopped(id) else { return }
    Snapshotter.clean(keeping: Set(history.entries.map(\.id)))
    if history.stopped.isEmpty { expanded = false }
    if keyboardDriven, highlight == id.uuidString {
      let after = rows.stopped.map(\.id)
      let i = before.firstIndex(of: id.uuidString) ?? 0
      highlight = after.isEmpty ? nil : after[min(i, after.count - 1)]
    }
    save()
  }

  // MARK: Scanning

  func begin() {
    Snapshotter.clean(keeping: Set(history.entries.map(\.id)))
    scanNow()
  }

  func scanNow() {
    timer?.invalidate()
    timer = nil
    guard !scanning else { rescan = true; return }
    scanning = true
    let home = self.home
    Task.detached(priority: .userInitiated) { [weak self] in
      let found = Scanner.scan(home: home)
      await self?.finish(found)
    }
  }

  private func finish(_ found: [Server]) {
    scanning = false
    apply(found)
    if rescan {
      rescan = false
      scanNow()
    } else {
      schedule()
    }
  }

  /// Quick while something is stopping or starting, every 2 seconds while the panel is open, else every 10.
  private func schedule() {
    timer?.invalidate()
    guard !scanning else { return }
    let interval: TimeInterval = !busy.isEmpty || !chains.isEmpty ? 0.3 : isOpen ? 2 : 10
    let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.scanNow() }
    }
    t.tolerance = interval / 10
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  private func apply(_ found: [Server]) {
    let now = Date()
    let result = history.reconcile(found, spawned: spawned, now: now, firstScan: firstScan, keeping: Set(busy.keys).union(queued))
    if servers != found { servers = found }
    if links != result.links { links = result.links }
    var changed = result.changed
    if renameServedFolders() { changed = true }
    if fillProjectRoots() { changed = true }
    if fillNeeds() { changed = true }
    assignTints()
    let up = Set(result.links.values)
    for id in up where cameUp[id] == nil { cameUp[id] = firstScan ? history[id]?.startedAt ?? now : now }
    for id in cameUp.keys where !up.contains(id) { cameUp[id] = nil }
    firstScan = false

    let linked = Set(result.links.values)
    for (id, b) in busy {
      switch b {
      case let .stopping(_, since, thenStart):
        if !linked.contains(id) {
          busy[id] = nil
          forced.remove(id)
          if thenStart { startWithNeeds(id) }
        } else if !forced.contains(id), now.timeIntervalSince(since) >= 5 {
          forced.insert(id)
        }
      case let .starting(pid, since):
        if linked.contains(id) {
          busy[id] = nil
          changed = true
        } else if now.timeIntervalSince(since) >= 60 {
          // The shell leads its own process group, so this reaches everything it started.
          killpg(pid, SIGTERM)
          fail(id, "Timed out")
        }
      }
    }
    advanceChains()
    queueSnapshots()
    if changed || (!result.links.isEmpty && now.timeIntervalSince(lastSave) > 60) { save() }
  }

  /// Names a static server after the folder it serves, for entries saved before names followed it (see `Naming.servedFolder`).
  private func renameServedFolders() -> Bool {
    var changed = false
    for e in history.entries where !namesChecked.contains(e.id) {
      namesChecked.insert(e.id)
      guard let served = Naming.servedFolder(command: e.command, cwd: e.commandDir), served.hasPrefix(projectHome + "/") else { continue }
      let dir = Naming.project(cwd: served, home: projectHome).dir
      guard dir != e.projectDir else { continue }
      history[e.id]?.projectDir = dir
      history[e.id]?.name = Naming.baseName(dir)
      history[e.id]?.projectRoot = nil
      changed = true
    }
    return changed
  }

  /// Looks for what each server needs, once per command.
  private func fillNeeds() -> Bool {
    var changed = false
    for e in history.entries where e.needs == nil {
      history[e.id]?.needs = Needs.ports(command: e.command, dirs: [e.commandDir, e.projectDir], own: e.ports, home: home)
      changed = true
    }
    return changed
  }

  // MARK: Snapshots

  /// Takes a snapshot 5 seconds after a server comes up, and again on opening the panel when it's an hour old.
  private func queueSnapshots() {
    guard showPreviews else { return }
    let now = Date()
    for (id, up) in cameUp {
      guard busy[id] == nil, let e = history[id], !snapshotter.isBusy(id) else { continue }
      let taken = e.snapshotAt ?? .distantPast
      let fresh = taken < up && now.timeIntervalSince(up) >= 5
      let stale = isOpen && now.timeIntervalSince(taken) > 3600
      guard fresh || stale else { continue }
      snapshotter.take(id, port: e.port, done: saveSnapshot(id))
    }
    // A stopped static server that never had one: read from its folder, nothing to start.
    for e in history.stopped where e.snapshotAt == nil && !snapshotter.isBusy(e.id) {
      guard let folder = Naming.staticFolder(command: e.command, cwd: e.commandDir),
            FileManager.default.fileExists(atPath: folder + "/index.html") else { continue }
      snapshotter.take(e.id, port: e.port, folder: folder, done: saveSnapshot(e.id))
    }
  }

  private func saveSnapshot(_ id: UUID) -> @MainActor (Snapshotter.Result?) -> Void {
    { [weak self] result in
      guard let self, var e = self.history[id] else { return }
      // Tried, even when it failed, so a broken page isn't loaded again on every scan.
      if let result {
        e.title = result.title
        e.snapshotPath = result.path
      }
      e.snapshotAt = Date()
      self.history[id] = e
      self.save()
    }
  }

  // MARK: Preview

  /// Hover: the card opens after half a second on a row, and follows at once while it's open.
  /// From the keyboard it opens with Space and follows the arrow keys.
  private func updatePreview() {
    previewTimer?.invalidate()
    previewTimer = nil
    guard showPreviews, let h = highlight, canPreview(h), menuRow == nil, !moreMenuOpen else {
      if preview != nil { preview = nil }
      return
    }
    if preview != nil { preview = h; return }
    guard !keyboardDriven else { return }
    let t = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.highlight == h, self.menuRow == nil, !self.moreMenuOpen else { return }
        self.preview = h
      }
    }
    RunLoop.main.add(t, forMode: .common)
    previewTimer = t
  }

  func togglePreview() {
    if preview != nil { preview = nil }
    else if showPreviews, let h = highlight, canPreview(h) { preview = h }
  }

  private func canPreview(_ id: String) -> Bool { rows.row(id)?.entryID != nil }

  func save() {
    try? history.save(to: historyURL)
    lastSave = Date()
  }

  // MARK: Stop and start

  func restart(_ row: Row) {
    guard let id = row.entryID, row.canRestart else { return }
    if row.group == .running { stop(id, thenStart: true) } else { startWithNeeds(id) }
  }

  /// Starts what the server needs first, one at a time, then the server.
  func startWithNeeds(_ id: UUID) {
    guard busy[id] == nil, !queued.contains(id) else { return }
    let order = needOrder(id)
    guard order.count > 1 else { start(id); return }
    chains.append(Chain(ids: order, since: Date()))
    advanceChains()
    scanNow()
  }

  /// Moves each chain on: drops servers that are up, waits for one starting, starts the next.
  /// When one it started didn't come up, the rest fail with "Needs <port>".
  private func advanceChains() {
    guard !chains.isEmpty else { return }
    let up = linkedIDs
    var kept: [Chain] = []
    next: for var c in chains {
      while let head = c.ids.first {
        if up.contains(head) || (c.ids.count > 1 && history[head].map({ listening($0.port) }) == true) {
          c.ids.removeFirst()
        } else if busy[head] != nil {
          kept.append(c)
          continue next
        } else if c.started.contains(head) {
          let port = history[head]?.port ?? 0
          for id in c.ids.dropFirst() where busy[id] == nil && !up.contains(id) { fail(id, "Needs \(port)") }
          continue next
        } else {
          c.started.insert(head)
          start(head)
        }
      }
    }
    if kept.count != chains.count || zip(kept, chains).contains(where: { $0.ids != $1.ids || $0.started != $1.started }) { chains = kept }
  }

  func stop(_ id: UUID, thenStart: Bool = false) {
    guard busy[id] == nil, linkedIDs.contains(id), let root = history[id]?.root else { return }
    let procs = Scanner.tree(of: root)
    guard !procs.isEmpty else { scanNow(); return }
    Launcher.signal(procs, SIGTERM)
    busy[id] = .stopping(procs: procs, since: Date(), thenStart: thenStart)
    scanNow()
  }

  func stopAll() {
    for id in stoppable { stop(id) }
  }

  func forceStop(_ id: UUID) {
    guard case let .stopping(procs, _, thenStart)? = busy[id] else { return }
    var all = Set(Launcher.alive(procs))
    if let root = history[id]?.root { all.formUnion(Scanner.tree(of: root)) }
    Launcher.signal(Array(all), SIGKILL)
    forced.remove(id)
    busy[id] = .stopping(procs: Array(all), since: Date(), thenStart: thenStart)
    scanNow()
  }

  func start(_ id: UUID) {
    guard busy[id] == nil, var e = history[id] else { return }
    let dir: String
    if isFolder(e.commandDir) { dir = e.commandDir }
    else if isFolder(e.projectDir) { dir = e.projectDir }
    else { fail(id, "Folder not found"); return }
    if let p = e.ports.first(where: Launcher.portInUse) { fail(id, "Port \(p) in use"); return }

    let log = Launcher.logURL(name: e.name)
    do {
      let pid = try Launcher.spawn(command: e.command, dir: dir, path: e.path, log: log)
      e.logPath = log.path
      e.failure = nil
      // Newest of the stopped entries until it links, so pruning can't drop it.
      e.stoppedAt = Date()
      history[id] = e
      spawned[pid] = id
      busy[id] = .starting(pid: pid, since: Date())
      watcher.watch(pid) { [weak self] status in self?.childExited(pid, status) }
      save()
      scanNow()
    } catch {
      fail(id, "Couldn't start")
    }
  }

  private func childExited(_ pid: pid_t, _ status: Int32) {
    guard let id = spawned.removeValue(forKey: pid) else { return }
    if case .starting? = busy[id] { fail(id, Launcher.describe(waitStatus: status)) }
    scanNow()
  }

  /// Moves the entry to the top of Stopped with the reason in red.
  private func fail(_ id: UUID, _ reason: String) {
    busy[id] = nil
    guard var e = history[id] else { return }
    e.failure = reason
    e.stoppedAt = Date()
    history[id] = e
    save()
  }

  private var linkedIDs: Set<UUID> { Set(links.values) }

  private func isFolder(_ path: String) -> Bool {
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
  }

  // MARK: Pointer and keyboard

  struct Target: Equatable {
    var row: String?
    var hot: String?
  }

  func target(at p: CGPoint) -> Target {
    if let clip = frames["clip"], !clip.contains(p) { return Target() }
    var t = Target()
    for (id, r) in frames where r.contains(p) {
      if id == "menu" || id.hasPrefix("btn:") { t.hot = id }
      else if id.hasPrefix("row:") { t.row = String(id.dropFirst(4)) }
    }
    return t
  }

  /// The pointer really moved. Hover follows it again.
  func pointerMoved(to p: CGPoint?) {
    pointer = p
    staleUnderPointer = false
    keyboardDriven = false
    hover()
  }

  func hover() {
    guard !staleUnderPointer, !keyboardDriven, menuRow == nil else { return }
    let t = pointer.map(target(at:)) ?? Target()
    if highlight != t.row { highlight = t.row }
    if hot != t.hot { hot = t.hot }
  }

  func framesChanged(_ f: [String: CGRect]) {
    guard f != frames else { return }
    frames = f
    onFrames?()
    guard let p = pointer, !keyboardDriven, !staleUnderPointer, menuRow == nil else { return }
    let t = target(at: p)
    if t.row != highlight {
      staleUnderPointer = true
      highlight = nil
      hot = nil
    } else if t.hot != hot {
      hot = t.hot
    }
  }

  func moveHighlight(_ delta: Int) {
    let order = rows.order
    guard !order.isEmpty else { return }
    keyboardDriven = true
    hot = nil
    if let h = highlight, let i = order.firstIndex(of: h) {
      highlight = order[max(0, min(order.count - 1, i + delta))]
    } else {
      highlight = delta > 0 ? order.first : order.last
    }
  }

  /// Back to a closed panel's state.
  func resetPointer() {
    highlight = nil
    hot = nil
    menuRow = nil
    moreMenuOpen = false
    pointer = nil
    staleUnderPointer = false
    keyboardDriven = false
    expanded = false
    toggledProjects = []
    fullProjects = []
    preview = nil
  }
}
