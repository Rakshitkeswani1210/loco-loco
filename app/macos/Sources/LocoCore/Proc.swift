import Darwin
import Foundation

/// One process, as read from libproc.
public struct ProcInfo: Sendable, Hashable {
  public let pid: pid_t
  public let ppid: pid_t
  public let uid: uid_t
  /// Microseconds since 1970. With the pid, this identifies a process even after its pid is reused.
  public let startMicros: UInt64
  public let name: String

  public var startDate: Date { Date(timeIntervalSince1970: Double(startMicros) / 1_000_000) }
}

/// Thin wrappers over libproc and sysctl. Everything here reads only; nothing needs admin rights.
public enum Proc {
  public static func allPIDs() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = pids.withUnsafeMutableBufferPointer {
      proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
    }
    return Array(pids.prefix(max(0, Int(got)))).filter { $0 > 0 }
  }

  public static func info(_ pid: pid_t) -> ProcInfo? {
    var bi = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, size) == size else { return nil }
    let name = withUnsafeBytes(of: bi.pbi_name) { cString($0) }
    let comm = withUnsafeBytes(of: bi.pbi_comm) { cString($0) }
    return ProcInfo(
      pid: pid, ppid: pid_t(bi.pbi_ppid), uid: bi.pbi_uid,
      startMicros: UInt64(bi.pbi_start_tvsec) * 1_000_000 + UInt64(bi.pbi_start_tvusec),
      name: name.isEmpty ? comm : name)
  }

  /// TCP ports this process is listening on, IPv4 and IPv6 together.
  public static func listeningPorts(_ pid: pid_t) -> Set<UInt16> {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return [] }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16)
    let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
    guard used > 0 else { return [] }
    var ports = Set<UInt16>()
    for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
      var si = socket_fdinfo()
      let want = Int32(MemoryLayout<socket_fdinfo>.size)
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, want) == want,
            si.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
      let tcp = si.psi.soi_proto.pri_tcp
      guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
      let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
      if port > 0 { ports.insert(port) }
    }
    return ports
  }

  public static func cwd(_ pid: pid_t) -> String? {
    var vpi = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, size) == size else { return nil }
    let path = withUnsafeBytes(of: vpi.pvi_cdir.vip_path) { cString($0) }
    return path.isEmpty ? nil : path
  }

  /// The executable's path on disk. Unlike argv, a process can't rewrite this.
  public static func executablePath(_ pid: pid_t) -> String? {
    var buf = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    return buf.withUnsafeBytes { cString($0) }
  }

  public struct Args: Sendable {
    public var argv: [String]
    public var env: [String: String]
  }

  /// argv and environment through KERN_PROCARGS2. Readable for your own processes only.
  public static func args(_ pid: pid_t) -> Args? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = MemoryLayout<Int32>.size
    while i < size && buf[i] != 0 { i += 1 }   // executable path
    while i < size && buf[i] == 0 { i += 1 }   // padding
    func next() -> String {
      let start = i
      while i < size && buf[i] != 0 { i += 1 }
      let s = String(decoding: buf[start..<i], as: UTF8.self)
      i += 1
      return s
    }
    var argv: [String] = []
    while argv.count < argc && i < size { argv.append(next()) }
    // A process that rewrote its title (Node's process.title) can leave its argv area padded with NULs.
    while i < size && buf[i] == 0 { i += 1 }
    var env: [String: String] = [:]
    while i < size {
      let s = next()
      if s.isEmpty { break }
      if let eq = s.firstIndex(of: "="), env[String(s[..<eq])] == nil {
        env[String(s[..<eq])] = String(s[s.index(after: eq)...])
      }
    }
    return Args(argv: argv, env: env)
  }

  /// True while the process runs. A zombie (exited, not yet reaped) counts as gone,
  /// and so does a new process that reused the pid.
  public static func isAlive(_ pid: pid_t, startMicros: UInt64? = nil) -> Bool {
    var bi = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bi, size) == size else {
      return kill(pid, 0) == 0 || errno == EPERM
    }
    if bi.pbi_status == 5 { return false }  // SZOMB
    if let startMicros {
      return UInt64(bi.pbi_start_tvsec) * 1_000_000 + UInt64(bi.pbi_start_tvusec) == startMicros
    }
    return true
  }

  private static func cString(_ raw: UnsafeRawBufferPointer) -> String {
    let bytes = raw.bindMemory(to: UInt8.self)
    let end = bytes.firstIndex(of: 0) ?? bytes.count
    return String(decoding: bytes[..<end], as: UTF8.self)
  }
}
