import Darwin
import Foundation

/// Stops and starts servers. Signals go to exact processes (pid and start time), never to a pid that was reused.
public enum Launcher {
  /// Signals every process that is still the one we saw. Returns the ones that were signalled.
  @discardableResult
  public static func signal(_ procs: [ProcRef], _ sig: Int32) -> [ProcRef] {
    let me = getpid()
    return procs.filter { $0.pid > 1 && $0.pid != me && Proc.isAlive($0.pid, startMicros: $0.startMicros) && kill($0.pid, sig) == 0 }
  }

  public static func alive(_ procs: [ProcRef]) -> [ProcRef] {
    procs.filter { Proc.isAlive($0.pid, startMicros: $0.startMicros) }
  }

  /// True when something accepts connections on the port, over IPv4 or IPv6 loopback.
  /// Catches listeners Loco Loco can't inspect, like other users' processes.
  public static func portInUse(_ port: UInt16) -> Bool {
    accepts(port, v6: false) || accepts(port, v6: true)
  }

  private static func accepts(_ port: UInt16, v6: Bool) -> Bool {
    let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var rc: Int32
    if v6 {
      var a = sockaddr_in6()
      a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      a.sin6_family = sa_family_t(AF_INET6)
      a.sin6_port = port.bigEndian
      a.sin6_addr = in6addr_loopback
      rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
    } else {
      var a = sockaddr_in()
      a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      a.sin_family = sa_family_t(AF_INET)
      a.sin_port = port.bigEndian
      a.sin_addr.s_addr = UInt32(0x7f00_0001).bigEndian
      rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    }
    if rc == 0 { return true }
    guard errno == EINPROGRESS else { return false }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, 300) == 1 else { return false }
    var err: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
    return err == 0
  }

  public static var logFolder: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Loco Loco")
  }

  public static func logURL(name: String) -> URL {
    let safe = name.map { "/:\\".contains($0) ? "-" : $0 }
    return logFolder.appendingPathComponent(String(safe) + ".log")
  }

  public enum SpawnError: Error { case failed(Int32) }

  /// Runs `command` with zsh in a new session, from `dir`, with output appended to `log`.
  /// The server outlives Loco Loco. Watch the pid with `ChildWatcher` to reap it.
  public static func spawn(command: String, dir: String, path: String?, log: URL) throws -> pid_t {
    try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    let stamp = Date().formatted(.dateTime.year().month().day().hour().minute().second())
    let header = "\n[Loco Loco] \(stamp) in \(dir)\n$ \(command)\n\n"
    if let h = FileHandle(forWritingAtPath: log.path) ?? {
      FileManager.default.createFile(atPath: log.path, contents: nil)
      return FileHandle(forWritingAtPath: log.path)
    }() {
      h.seekToEndOfFile()
      h.write(Data(header.utf8))
      try? h.close()
    }

    var actions = posix_spawn_file_actions_t(nil as OpaquePointer?)
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    // The non-_np name is only in the macOS 26 SDK (Swift 6.2 and later), so older toolchains still build.
    #if compiler(>=6.2)
    if #available(macOS 26, *) {
      posix_spawn_file_actions_addchdir(&actions, dir)
    } else {
      posix_spawn_file_actions_addchdir_np(&actions, dir)
    }
    #else
    posix_spawn_file_actions_addchdir_np(&actions, dir)
    #endif

    var attr = posix_spawnattr_t(nil as OpaquePointer?)
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    var all = sigset_t(), none = sigset_t()
    sigfillset(&all)
    sigemptyset(&none)
    posix_spawnattr_setsigdefault(&attr, &all)
    posix_spawnattr_setsigmask(&attr, &none)

    // The PATH the server first ran with. Without it, a login shell finds Homebrew and friends.
    let argv = path == nil ? ["/bin/zsh", "-l", "-c", command] : ["/bin/zsh", "-c", command]
    let env = ProcessInfo.processInfo.environment
    var envp = ["PATH=" + (path ?? "/usr/bin:/bin:/usr/sbin:/sbin"), "SHELL=/bin/zsh", "LANG=" + (env["LANG"] ?? "en_US.UTF-8")]
    for k in ["HOME", "USER", "LOGNAME", "TMPDIR"] { if let v = env[k] { envp.append("\(k)=\(v)") } }
    // Python holds back stdout written to a file, which would leave the log empty while the server runs.
    envp.append("PYTHONUNBUFFERED=1")

    var pid: pid_t = 0
    let rc = withCStrings(argv) { a in withCStrings(envp) { e in posix_spawn(&pid, "/bin/zsh", &actions, &attr, a, e) } }
    guard rc == 0 else { throw SpawnError.failed(rc) }
    return pid
  }

  private static func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var ptrs: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    ptrs.append(nil)
    defer { ptrs.forEach { free($0) } }
    return ptrs.withUnsafeBufferPointer { body($0.baseAddress!) }
  }

  /// "Exited with code 1" or "Stopped by signal 9" from a wait status.
  public static func describe(waitStatus status: Int32) -> String {
    let sig = status & 0x7f
    return sig == 0 ? "Exited with code \((status >> 8) & 0xff)" : "Stopped by signal \(sig)"
  }
}

/// Reaps processes Loco Loco started and reports how they ended.
@MainActor
public final class ChildWatcher {
  private var sources: [pid_t: DispatchSourceProcess] = [:]

  public init() {}

  public func watch(_ pid: pid_t, exited: @escaping @MainActor (Int32) -> Void) {
    let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
    let reap: @MainActor () -> Void = { [weak self] in
      guard let self, let s = self.sources.removeValue(forKey: pid) else { return }
      s.cancel()
      var status: Int32 = 0
      while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
      exited(status)
    }
    source.setEventHandler { MainActor.assumeIsolated { reap() } }
    sources[pid] = source
    source.resume()
    // A child that exited before the source was set up never fires it.
    var info = siginfo_t()
    if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid { reap() }
  }
}
