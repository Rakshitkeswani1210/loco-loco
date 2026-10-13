import Darwin
import Foundation

public struct ProcRef: Sendable, Hashable, Codable {
  public let pid: Int32
  public let startMicros: UInt64
  public init(pid: Int32, startMicros: UInt64) { self.pid = pid; self.startMicros = startMicros }
}

/// One running server: every process under one launch, with the ports they listen on.
public struct Server: Sendable, Identifiable, Hashable {
  public var id: ProcRef { root }
  /// The top of the launch chain, below the shell, agent or app that started it.
  public let root: ProcRef
  public let startedAt: Date
  /// Sorted, unique. The row shows the first.
  public let ports: [UInt16]
  public var port: UInt16 { ports.first ?? 0 }
  public let name: String
  public let projectDir: String
  public let command: String
  public let commandDir: String
  public let path: String?
  /// Runs from a folder inside the home folder and wasn't started by an app.
  public let isDevServer: Bool
  /// The root and everything under it. Stop signals all of them.
  public let processes: [ProcRef]
  public let executable: String?
}

public enum Scanner {
  /// Reads the process table once. Takes about 10–30 ms with 600 processes.
  public static func scan(home: String = NSHomeDirectory()) -> [Server] {
    let me = getuid(), myPID = getpid()
    var table: [pid_t: ProcInfo] = [:]
    var children: [pid_t: [pid_t]] = [:]
    for pid in Proc.allPIDs() {
      guard let info = Proc.info(pid), info.uid == me else { continue }
      table[pid] = info
      children[info.ppid, default: []].append(pid)
    }

    var argsCache: [pid_t: Proc.Args] = [:]
    func args(_ pid: pid_t) -> Proc.Args {
      if let a = argsCache[pid] { return a }
      let a = Proc.args(pid) ?? Proc.Args(argv: [], env: [:])
      argsCache[pid] = a
      return a
    }
    var exeCache: [pid_t: String] = [:]
    func exe(_ pid: pid_t) -> String {
      if let e = exeCache[pid] { return e }
      let e = Proc.executablePath(pid) ?? ""
      exeCache[pid] = e
      return e
    }

    enum Stop { case launchd, us, foreign, app, host, shell, supervisor }
    func boundary(_ pid: pid_t) -> Stop? {
      if pid <= 1 { return .launchd }
      if pid == myPID { return .us }
      guard let info = table[pid] else { return .foreign }
      if Naming.isAppExecutable(exe(pid)) { return .app }
      let argv = args(pid).argv
      if Naming.isHost(names: [exe(pid), argv.first ?? "", info.name]) { return .host }
      if Naming.isInteractiveShell(argv) { return .shell }
      if Naming.isSupervisor(argv) { return .supervisor }
      return nil
    }

    // Listening processes, grouped by the root of their launch chain.
    struct Group { var ports: Set<UInt16>; var listener: pid_t; var chain: [pid_t]; var stop: Stop }
    var groups: [pid_t: Group] = [:]
    for (pid, _) in table where pid != myPID {
      let ports = Proc.listeningPorts(pid)
      guard let lowest = ports.min() else { continue }
      // Walk up from the listener to the shell, agent, app or launchd that started it.
      var chain = [pid]
      var stop = Stop.launchd
      while chain.count < 64, let parent = table[chain.last!]?.ppid {
        if let b = boundary(parent) { stop = b; break }
        chain.append(parent)
      }
      let root = chain.last!
      if var g = groups[root] {
        // The listener on the lowest port names the server.
        if lowest < g.ports.min()! { g.listener = pid; g.chain = chain }
        g.ports.formUnion(ports)
        groups[root] = g
      } else {
        groups[root] = Group(ports: ports, listener: pid, chain: chain, stop: stop)
      }
    }

    let homePrefix = home + "/"
    var servers: [Server] = []
    for (root, g) in groups {
      guard let rootInfo = table[root] else { continue }
      let listenerCwd = Proc.cwd(g.listener) ?? "/"
      let listenerExe = exe(g.listener)
      // Dev servers run from your files or a temp folder. Apps and macOS run from / or ~/Library.
      let devPlace = (listenerCwd.hasPrefix(homePrefix) && !listenerCwd.hasPrefix(homePrefix + "Library/"))
        || listenerCwd.hasPrefix("/private/tmp/") || listenerCwd.hasPrefix("/private/var/folders/")
      // An app's terminal or task runner starts servers through a shell. Anything else an app starts is its own.
      let rootArgv = args(root).argv
      let appOwned = g.stop == .app && Naming.shellScript(rootArgv) == nil && !Naming.isShell(rootArgv)
      let isDev = devPlace && !appOwned && !Naming.isAppExecutable(listenerExe)

      // Name and folder
      var name: String
      var projectDir = listenerCwd
      if isDev {
        let project = Naming.project(cwd: listenerCwd, home: home)
        projectDir = project.dir
        if let uv = g.chain.lazy.compactMap({ Naming.uvRunName(args($0).argv) }).first {
          name = uv
        } else if project.isProject {
          name = Naming.baseName(project.dir)
        } else if let script = Naming.scriptName(args(g.listener).argv, cwd: listenerCwd, home: home) {
          name = script
          projectDir = listenerCwd
        } else {
          name = Naming.baseName(project.dir)
        }
      } else {
        name = Naming.appName(listenerExe) ?? table[g.listener]?.name ?? rootInfo.name
        if let r = listenerExe.range(of: ".app/") { projectDir = String(listenerExe[..<r.lowerBound]) + ".app" }
      }

      // The command that brings it back: the launching shell's one-line script, else the top process's own argv.
      var command = "", commandDir = Proc.cwd(root) ?? listenerCwd
      let rootArgs = args(root)
      if let script = Naming.shellScript(rootArgs.argv), Naming.isRerunnable(script: script) {
        command = script.trimmingCharacters(in: .whitespacesAndNewlines)
      } else {
        let top = g.chain.reversed().first { Naming.shellScript(args($0).argv) == nil } ?? g.listener
        command = Naming.commandLine(args(top).argv)
        commandDir = Proc.cwd(top) ?? commandDir
      }
      let path = rootArgs.env["PATH"] ?? args(g.listener).env["PATH"]

      // The root and all its descendants.
      var procs: [ProcRef] = []
      var queue = [root]
      while let p = queue.popLast() {
        guard p != myPID, let info = table[p] else { continue }
        procs.append(ProcRef(pid: p, startMicros: info.startMicros))
        queue.append(contentsOf: children[p] ?? [])
      }

      servers.append(Server(
        root: ProcRef(pid: root, startMicros: rootInfo.startMicros),
        startedAt: rootInfo.startDate,
        ports: g.ports.sorted(),
        name: name, projectDir: projectDir,
        command: command, commandDir: commandDir, path: path,
        isDevServer: isDev, processes: procs, executable: listenerExe.isEmpty ? nil : listenerExe))
    }
    return servers.sorted { ($0.port, $0.root.pid) < ($1.port, $1.root.pid) }
  }

  /// The root and everything under it now, including children started since the last scan.
  public static func tree(of root: ProcRef) -> [ProcRef] {
    guard Proc.isAlive(root.pid, startMicros: root.startMicros) else { return [] }
    let me = getuid(), myPID = getpid()
    var children: [pid_t: [ProcInfo]] = [:]
    for pid in Proc.allPIDs() {
      if let info = Proc.info(pid), info.uid == me { children[info.ppid, default: []].append(info) }
    }
    var out = [root]
    var queue = [root.pid]
    while let p = queue.popLast() {
      for c in children[p] ?? [] where c.pid != myPID {
        out.append(ProcRef(pid: c.pid, startMicros: c.startMicros))
        queue.append(c.pid)
      }
    }
    return out
  }
}
