import AppKit
import LocoCore
import Observation

enum RowGroup: Sendable { case running, stopped }

enum RowAction: String, Sendable {
  case stop, restart, log, force

  var symbol: String {
    switch self {
    case .stop: "stop.fill"
    case .restart: "arrow.clockwise"
    case .log: "doc.text"
    case .force: "xmark.octagon"
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
}

/// One line in the panel.
struct Row: Identifiable, Equatable {
  enum State: Equatable { case idle, stopping, starting, force }

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
    case .idle:
      if let failure { status = "didn't start: \(failure)" }
      else if group == .running { status = "running since \(TimeText.short(time))" }
      else { status = "stopped \(TimeText.short(time))" }
    }
    let project = project.map { ", \($0.name)" } ?? ""
    return "\(name)\(project), port \(port), \(status)"
  }
}

struct Rows: Equatable {
  static let more = "more"

  /// Newest first. When grouped, in group order.
  var running: [Row] = []
  /// Set when Group by project is on and some server has a project.
  var groups: [ProjectGroup]?
  var stopped: [Row] = []
  /// Every stopped server, including the ones under More.
  var stoppedTotal = 0

  var hasMore: Bool { stopped.count < stoppedTotal }
  /// Top to bottom, as the arrow keys move.
  var order: [String] { running.map(\.id) + stopped.map(\.id) + (hasMore ? [Rows.more] : []) }

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
  case close
}

@MainActor @Observable
final class Model {
  enum Busy {
    case stopping(procs: [ProcRef], since: Date, thenStart: Bool)
    case starting(pid: pid_t, since: Date)
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

  // MARK: Servers and history

  private(set) var servers: [Server] = []
  private(set) var history: History
  private(set) var links: [ProcRef: UUID] = [:]
  private(set) var busy: [UUID: Busy] = [:]
  private(set) var forced: Set<UUID> = []
  var expanded = false
  var scrolls = false
  /// Set only by the test hooks, to show just these ports in screenshots. Scanning and history are unaffected.
  var onlyPorts: Set<UInt16>?

  // MARK: Pointer and keyboard

  var highlight: String?
  /// The button under the pointer: `btn:<row>:<action>` or `menu`.
  var hot: String?
  /// The row whose context menu is open. It stays highlighted and hides its buttons.
  var menuRow: String?
  var moreMenuOpen = false

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
  /// Project folders found this session, by server folder. Nil when a folder has none.
  @ObservationIgnored private var rootCache: [String: String?] = [:]

  init() {
    let d = UserDefaults.standard
    d.register(defaults: ["showCount": true, "showAll": false, "historyLimit": 20, "groupByProject": false])
    showCount = d.bool(forKey: "showCount")
    showAll = d.bool(forKey: "showAll")
    historyLimit = d.integer(forKey: "historyLimit")
    groupByProject = d.bool(forKey: "groupByProject")
    projectNames = d.dictionary(forKey: "projectNames") as? [String: String] ?? [:]
    projectTints = d.dictionary(forKey: "projectTints") as? [String: Int] ?? [:]
    history = History(entries: History.load(), limit: d.integer(forKey: "historyLimit"))
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
    }
    out.running.sort { ($1.time, $0.port, $0.id) < ($0.time, $1.port, $1.id) }
    if groupByProject { group(&out) }

    let stopped = history.stopped.filter { busy[$0.id] == nil && (only?.contains($0.port) ?? true) }
    out.stoppedTotal = stopped.count
    // A More row that would hide a single entry takes that entry's height, so show it instead.
    let limit = expanded || stopped.count <= Metrics.shownStopped + 1 ? stopped.count : Metrics.shownStopped
    for e in stopped.prefix(limit) {
      out.stopped.append(Row(
        id: e.id.uuidString, group: .stopped, port: e.port, ports: e.ports, name: e.name, folder: e.projectDir,
        project: tag(e.projectRoot), time: e.stoppedAt ?? e.lastSeenAt, failure: e.failure, state: .idle, entryID: e.id, server: nil, logPath: e.logPath))
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

  func setHistoryLimit(_ n: Int) {
    historyLimit = n
    UserDefaults.standard.set(n, forKey: "historyLimit")
    history.limit = n
    history.prune(keeping: Set(busy.keys))
    save()
  }

  func clearHistory() {
    history.clearStopped(keeping: Set(busy.keys))
    expanded = false
    save()
  }

  // MARK: Scanning

  func begin() { scanNow() }

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
    let interval: TimeInterval = !busy.isEmpty ? 0.3 : isOpen ? 2 : 10
    let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated { self?.scanNow() }
    }
    t.tolerance = interval / 10
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  private func apply(_ found: [Server]) {
    let now = Date()
    let result = history.reconcile(found, spawned: spawned, now: now, firstScan: firstScan, keeping: Set(busy.keys))
    firstScan = false
    if servers != found { servers = found }
    if links != result.links { links = result.links }
    var changed = result.changed
    if fillProjectRoots() { changed = true }
    assignTints()

    let linked = Set(result.links.values)
    for (id, b) in busy {
      switch b {
      case let .stopping(_, since, thenStart):
        if !linked.contains(id) {
          busy[id] = nil
          forced.remove(id)
          if thenStart { start(id) }
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
    if changed || (!result.links.isEmpty && now.timeIntervalSince(lastSave) > 60) { save() }
  }

  func save() {
    try? history.save()
    lastSave = Date()
  }

  // MARK: Stop and start

  func restart(_ row: Row) {
    guard let id = row.entryID, row.canRestart else { return }
    if row.group == .running { stop(id, thenStart: true) } else { start(id) }
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
  }
}
