import Foundation

/// Pure rules for reading a launch chain: what is a shell, what is a boundary, what to call a server,
/// and which command brings it back. Kept free of system calls so they're easy to check.
public enum Naming {
  static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "tcsh", "csh"]
  /// Long-lived hosts that start servers: agent CLIs, multiplexers, remote logins.
  static let hosts: Set<String> = [
    "copilot", "claude", "codex", "cursor-agent", "gemini", "aider", "opencode", "goose", "amp",
    "tmux", "screen", "zellij", "login", "sshd", "mosh-server",
  ]
  /// Build-output and docs folders. A server running in one is named after the folder above.
  static let genericFolders: Set<String> = ["dist", "build", "public", "docs", "out"]
  static let markers = ["package.json", "pyproject.toml"]
  static let scriptExtensions: Set<String> = ["py", "js", "mjs", "cjs", "ts", "mts", "rb", "sh", "php", "pl"]

  public static func baseName(_ path: String) -> String {
    let trimmed = path.hasPrefix("-") ? String(path.dropFirst()) : path
    return (trimmed as NSString).lastPathComponent
  }

  /// The script of `sh -c '<script>'` (also `-lc`, `-ec`, `--norc -c`), or nil.
  public static func shellScript(_ argv: [String]) -> String? {
    guard let first = argv.first, shells.contains(baseName(first)) else { return nil }
    var i = 1
    while i < argv.count {
      let a = argv[i]
      if a == "--" { return nil }
      if a == "-o" || a == "+o" { i += 2; continue }
      if a.hasPrefix("-") && !a.hasPrefix("--") && a.dropFirst().contains("c") {
        return i + 1 < argv.count ? argv[i + 1] : nil
      }
      if a.hasPrefix("-") || a.hasPrefix("+") { i += 1; continue }
      return nil  // `bash script.sh` runs a file, not a -c script
    }
    return nil
  }

  public static func isShell(_ argv: [String]) -> Bool {
    guard let first = argv.first else { return false }
    return shells.contains(baseName(first))
  }

  /// A login shell ("-zsh") or a shell with no script: the prompt a person types into.
  public static func isInteractiveShell(_ argv: [String]) -> Bool {
    guard let first = argv.first else { return false }
    if first.hasPrefix("-"), shells.contains(String(first.dropFirst())) { return true }
    guard shells.contains(baseName(first)), shellScript(argv) == nil else { return false }
    return !argv.dropFirst().contains { !$0.hasPrefix("-") && !$0.hasPrefix("+") }
  }

  /// A shell that only runs the command it was handed ("$@"), like Copilot CLI's detached supervisor.
  public static func isSupervisor(_ argv: [String]) -> Bool {
    shellScript(argv)?.contains("$@") ?? false
  }

  public static func isHost(names: [String]) -> Bool {
    names.contains { hosts.contains(baseName($0)) }
  }

  /// An app's executable. Homebrew's Python also lives in an app bundle, inside a framework, so that doesn't count.
  public static func isAppExecutable(_ path: String) -> Bool {
    path.contains(".app/Contents/") && !path.contains(".framework/")
  }

  /// "Figma" from /Applications/Figma.app/Contents/MacOS/Figma.
  public static func appName(_ path: String) -> String? {
    guard let r = path.range(of: ".app/") else { return nil }
    return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
  }

  /// A script is safe to run again when it is one line with no heredoc. Agents sometimes chain
  /// file edits and checks before the server; those run once, so they fall back to the server's own command.
  public static func isRerunnable(script: String) -> Bool {
    let s = script.trimmingCharacters(in: .whitespacesAndNewlines)
    return !s.isEmpty && !s.contains("\n") && !s.contains("<<")
  }

  /// The name in `uv run [options] <name>`. Nil for `uv run python …`, which says nothing about the project.
  public static func uvRunName(_ argv: [String]) -> String? {
    var args = argv.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    if args.count == 1 { args = args[0].split(separator: " ").map(String.init) }
    guard let u = args.firstIndex(where: { baseName($0) == "uv" }), u + 1 < args.count, args[u + 1] == "run" else { return nil }
    let takesValue: Set<String> = [
      "--project", "--directory", "--with", "--with-editable", "--with-requirements", "--python", "-p",
      "--package", "--extra", "--group", "--only-group", "--no-group", "--env-file", "--index", "--default-index",
    ]
    var i = u + 2
    while i < args.count {
      let a = args[i]
      if a == "--" { i += 1; continue }
      if a.hasPrefix("-") { i += takesValue.contains(a) ? 2 : 1; continue }
      let base = baseName(a)
      if base.hasPrefix("python") { return nil }
      return (base as NSString).pathExtension == "py" ? (base as NSString).deletingPathExtension : base
    }
    return nil
  }

  /// "auth-mock" from `python3 …/auth-mock.py --port 8090`. Skips files inside node_modules.
  /// Nil when the script sits in the folder it runs from (`python3 serve.py` in api-mock): the folder names it better.
  /// Desktop, Documents and Downloads hold loose scripts, so there the script still names it.
  public static func scriptName(_ argv: [String], cwd: String, home: String) -> String? {
    guard let script = argv.dropFirst().first(where: {
      !$0.hasPrefix("-") && !$0.contains("/node_modules/") && scriptExtensions.contains(($0 as NSString).pathExtension.lowercased())
    }) else { return nil }
    let full = script.hasPrefix("/") ? script : (cwd as NSString).appendingPathComponent(script)
    let folder = ((full as NSString).standardizingPath as NSString).deletingLastPathComponent
    let looseFolders = ["Desktop", "Documents", "Downloads"].map { home + "/" + $0 }
    if folder == (cwd as NSString).standardizingPath, !looseFolders.contains(folder) { return nil }
    return (baseName(script) as NSString).deletingPathExtension
  }

  /// The folder a server belongs to, and whether it is a project.
  /// Inside a git repo: the nearest folder with package.json or pyproject.toml, else the repo root.
  /// Outside git: the folder itself, past dist, build, public, docs and out. Never the home folder or above.
  public static func project(cwd: String, home: String,
                             exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
    -> (dir: String, isProject: Bool)
  {
    let homePrefix = home.hasSuffix("/") ? home : home + "/"
    guard cwd.hasPrefix(homePrefix) else { return (cwd, false) }
    var marker: String?
    var dir = cwd
    while dir.hasPrefix(homePrefix) {
      if marker == nil, !genericFolders.contains(baseName(dir)), markers.contains(where: { exists(dir + "/" + $0) }) {
        marker = dir
      }
      if exists(dir + "/.git") { return (marker ?? dir, true) }
      dir = (dir as NSString).deletingLastPathComponent
    }
    var folder = cwd
    while genericFolders.contains(baseName(folder)) {
      let up = (folder as NSString).deletingLastPathComponent
      guard up.hasPrefix(homePrefix) else { break }
      folder = up
    }
    return (folder, markers.contains { exists(folder + "/" + $0) })
  }

  /// Folders that hold projects rather than being one.
  static let containers: Set<String> = [
    "Documents", "Desktop", "Downloads", "Developer", "Projects", "projects", "Code", "code", "src", "dev", "repos", "GitHub", "Sites",
  ]

  public enum GitLink: Equatable, Sendable {
    case repo
    /// A linked worktree or submodule: its `.git` is a file pointing into another repo's `.git` folder.
    case pointer(gitdir: String)
  }

  /// What the `.git` in a folder is, or nil when there is none.
  public static func gitLink(in dir: String) -> GitLink? {
    let path = dir + "/.git"
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return nil }
    guard !isDir.boolValue, let text = try? String(contentsOfFile: path, encoding: .utf8),
          let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return .repo }
    return .pointer(gitdir: line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces))
  }

  /// The folder that names a server's project label, like "~/Documents/Acme " for ~/Documents/Acme /web-lab.
  /// A worktree belongs to its main repo. Then it is the first folder below Documents, Desktop, Downloads or
  /// another folder that holds projects, else the first folder in the home folder.
  /// Nil outside the home folder, in hidden folders and Library, and for loose files in a folder like Documents.
  public static func projectRoot(dir: String, home: String, git: (String) -> GitLink? = gitLink(in:)) -> String? {
    let homePrefix = home.hasSuffix("/") ? home : home + "/"
    var base = dir
    var d = dir
    while d.hasPrefix(homePrefix) {
      if let link = git(d) {
        base = d
        if case let .pointer(gitdir) = link {
          let full = gitdir.hasPrefix("/") ? gitdir : d + "/" + gitdir
          let path = URL(fileURLWithPath: full).standardized.path
          if let r = path.range(of: "/.git/worktrees/") ?? path.range(of: "/.git/modules/"), path[..<r.lowerBound].hasPrefix(homePrefix) {
            base = String(path[..<r.lowerBound])
          }
        }
        break
      }
      d = (d as NSString).deletingLastPathComponent
    }
    guard base.hasPrefix(homePrefix) else { return nil }
    let parts = base.dropFirst(homePrefix.count).split(separator: "/").map(String.init)
    var i = 0
    while i < parts.count, containers.contains(parts[i]) { i += 1 }
    guard i < parts.count, !parts[i].hasPrefix("."), !(i == 0 && parts[0] == "Library") else { return nil }
    return homePrefix + parts[...i].joined(separator: "/")
  }

  /// "Acme" for "~/Documents/Acme ".
  public static func projectName(_ root: String) -> String {
    (root as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A command line that runs argv again from zsh.
  public static func commandLine(_ argv: [String]) -> String {
    var args = argv
    while let last = args.last, last.trimmingCharacters(in: .whitespaces).isEmpty { args.removeLast() }
    guard !args.isEmpty else { return "" }
    // Node tools rewrite their title into argv[0] ("npm exec vite preview --port 4193"). It already reads as a command.
    if args.count == 1, args[0].contains(" "), !FileManager.default.fileExists(atPath: args[0]) {
      let title = args[0].trimmingCharacters(in: .whitespaces)
      // `npm exec` reads flags after the package as its own; npx passes them through.
      return title.hasPrefix("npm exec ") ? "npx " + title.dropFirst("npm exec ".count) : title
    }
    // Homebrew's Python reports its full Cellar path, which changes on every upgrade.
    if args[0].contains("/Python.framework/") { args[0] = "python3" }
    return args.map(shellQuote).joined(separator: " ")
  }

  public static func shellQuote(_ s: String) -> String {
    if !s.isEmpty, s.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "@%+=:,./-_").contains($0) || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }) {
      return s
    }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// "~/Documents/x" for display.
  public static func abbreviate(_ path: String, home: String) -> String {
    path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }
}
