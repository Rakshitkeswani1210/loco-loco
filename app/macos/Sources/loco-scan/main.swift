import Darwin
import Foundation
import LocoCore

// Tests Loco Loco's core from the terminal.
//   loco-scan [--all]                 what the panel would list
//   loco-scan stop <port>             stop a server the way the Stop button does
//   loco-scan run <dir> <command>     start a command the way Restart does, and wait for its port
//   loco-scan history <file>          reconcile a scan with a history file, print and save it
//   loco-scan project <dir> ...       the project label each folder gets
var argv = Array(CommandLine.arguments.dropFirst())
let home = NSHomeDirectory()

func list(_ servers: [Server]) {
  let fmt = DateFormatter()
  fmt.dateFormat = "MMM d HH:mm"
  for s in servers {
    let ports = s.ports.map(String.init).joined(separator: ",")
    print("\(ports.padding(toLength: 12, withPad: " ", startingAt: 0)) \(s.name.padding(toLength: 34, withPad: " ", startingAt: 0)) \(fmt.string(from: s.startedAt))  root \(s.root.pid)  procs \(s.processes.count)\(s.isDevServer ? "" : "  [app/system]")")
    print("    folder   \(Naming.abbreviate(s.projectDir, home: home))")
    if s.isDevServer { print("    project  \(Naming.projectRoot(dir: s.projectDir, home: home).map(Naming.projectName) ?? "none")") }
    print("    command  \(s.command.prefix(160))")
    print("    in       \(Naming.abbreviate(s.commandDir, home: home))   PATH \(s.path == nil ? "missing" : "\(s.path!.split(separator: ":").count) entries")")
  }
}

switch argv.first {
case "stop":
  guard argv.count == 2, let port = UInt16(argv[1]) else { print("usage: loco-scan stop <port>"); exit(2) }
  guard let s = Scanner.scan(home: home).first(where: { $0.ports.contains(port) }) else { print("nothing on \(port)"); exit(1) }
  let procs = Scanner.tree(of: s.root)
  print("SIGTERM \(procs.map { String($0.pid) }.joined(separator: " ")) (\(s.name))")
  Launcher.signal(procs, SIGTERM)
  let t0 = Date()
  while !Launcher.alive(procs).isEmpty && Date().timeIntervalSince(t0) < 5 { usleep(100_000) }
  let left = Launcher.alive(procs)
  if left.isEmpty {
    print("stopped in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
  } else {
    print("still alive after 5 s: \(left.map { String($0.pid) }), SIGKILL")
    Launcher.signal(left, SIGKILL)
  }

case "run":
  guard argv.count >= 3 else { print("usage: loco-scan run <dir> <command>"); exit(2) }
  let dir = argv[1], command = argv[2...].joined(separator: " ")
  let log = URL(fileURLWithPath: "/tmp/loco-scan-run.log")
  let pid = try Launcher.spawn(command: command, dir: dir, path: ProcessInfo.processInfo.environment["PATH"], log: log)
  print("spawned \(pid), log \(log.path)")
  let t0 = Date()
  while Date().timeIntervalSince(t0) < 30 {
    var status: Int32 = 0
    if waitpid(pid, &status, WNOHANG) == pid { print(Launcher.describe(waitStatus: status)); exit(1) }
    if let s = Scanner.scan(home: home).first(where: { $0.processes.contains { $0.pid == pid } }) {
      print("listening on \(s.ports) as \(s.name) after \(Int(Date().timeIntervalSince(t0) * 1000)) ms, root \(s.root.pid)")
      list([s])
      exit(0)
    }
    usleep(250_000)
  }
  print("timed out")
  exit(1)

case "history":
  guard argv.count == 2 else { print("usage: loco-scan history <file>"); exit(2) }
  let url = URL(fileURLWithPath: argv[1])
  let existing = History.load(from: url)
  var history = History(entries: existing)
  let servers = Scanner.scan(home: home)
  let r = history.reconcile(servers, firstScan: true)
  try history.save(to: url)
  print("changed \(r.changed), \(r.links.count) linked")
  for e in history.entries.sorted(by: { ($0.isRunning ? 0 : 1, $0.port) < ($1.isRunning ? 0 : 1, $1.port) }) {
    print("\(e.isRunning ? "running" : "stopped") \(e.port) \(e.name) \(e.failure ?? "")")
  }

case "project":
  for dir in argv.dropFirst() {
    let root = Naming.projectRoot(dir: dir, home: home)
    print("\(Naming.abbreviate(dir, home: home))  ->  \(root.map { "\(Naming.projectName($0))  (\(Naming.abbreviate($0, home: home)))" } ?? "none")")
  }

default:
  let all = argv.contains("--all")
  let t0 = Date()
  let servers = Scanner.scan(home: home).filter { all || $0.isDevServer }
  let ms = Int(Date().timeIntervalSince(t0) * 1000)
  list(servers)
  print("\(servers.count) servers in \(ms) ms")
}
