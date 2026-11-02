import Foundation

/// Finds the servers a server calls: local URLs in its start command, in the shell script that command runs,
/// and in the .env files of its folders. Kept free of system calls (files come through `read`) so it's easy to check.
public enum Needs {
  static let envFiles = [".env", ".env.local", ".env.development", ".env.development.local"]
  static let shellNames: Set<String> = ["sh", "bash", "zsh", "source", "."]

  /// The ports a server points at, without its own.
  /// - Parameters:
  ///   - command: what Restart runs.
  ///   - dirs: the folder it runs from and its project folder, for scripts with relative paths and .env files.
  ///   - read: a file's text, or nil when there's none.
  public static func ports(
    command: String, dirs: [String], own: [UInt16], home: String,
    read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
  ) -> [UInt16] {
    var texts = [command]
    for script in scripts(in: command, dir: dirs.first ?? home, home: home) {
      if let t = read(script) { texts.append(t) }
    }
    for dir in Set(dirs) {
      for name in envFiles { if let t = read(dir + "/" + name) { texts.append(t) } }
    }
    let found = Set(texts.flatMap(ports(in:))).subtracting(own)
    return found.sorted()
  }

  /// Ports in local URLs in environment variables, skipping the ones that list who may call it.
  public static func ports(env: [String: String], own: Set<UInt16>) -> [UInt16] {
    let text = env.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    return Set(ports(in: text)).subtracting(own).sorted()
  }

  /// Ports in local URLs, skipping variables that list who may call this server (CORS, allowed origins),
  /// since those point back at the servers that need it.
  static func ports(in text: String) -> [UInt16] {
    var t = text
    if let assignment = try? NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*(?:CORS|ORIGIN)[A-Za-z0-9_]*\s*[=:]\s*('[^']*'|"[^"]*"|\[[^\]]*\]|\S+)"#, options: [.caseInsensitive]) {
      t = assignment.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
    }
    guard let url = try? NSRegularExpression(pattern: #"(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):(\d{2,5})\b"#) else { return [] }
    return url.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap { m in
      Range(m.range(at: 1), in: t).flatMap { UInt16(t[$0]) }
    }
  }

  /// Shell scripts the command runs: `bash x.sh`, `sh x`, `source x`, or a path ending in .sh. One level deep.
  static func scripts(in command: String, dir: String, home: String) -> [String] {
    let words = Naming.shellWords(command)
    var out: [String] = []
    for (i, w) in words.enumerated() {
      guard !Naming.shellOperators.contains(w) else { continue }
      let afterShell = i > 0 && shellNames.contains(Naming.baseName(words[i - 1])) && !w.hasPrefix("-")
      guard afterShell || w.hasSuffix(".sh") else { continue }
      var path = w
      if path.hasPrefix("~/") { path = home + path.dropFirst(1) }
      else if path.hasPrefix("$HOME/") { path = home + path.dropFirst(5) }
      if !path.hasPrefix("/") { path = (dir as NSString).appendingPathComponent(path) }
      out.append((path as NSString).standardizingPath)
    }
    return out
  }
}
