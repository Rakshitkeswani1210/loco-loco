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

  static let shellOperators: Set<String> = ["&&", "||", ";", "|", "&", ">", ">>", "2>", "2>&1", "<"]

  /// Splits a command line into words the way a shell would, keeping quoted spaces. Operators like && are their own words.
  public static func shellWords(_ command: String) -> [String] {
    var words: [String] = []
    var word = ""
    var inWord = false
    var quote: Character?
    var escaped = false
    var prev: Character?
    func end() {
      if inWord { words.append(word) }
      word = ""
      inWord = false
    }
    for c in command {
      defer { prev = c }
      if escaped { word.append(c); escaped = false; inWord = true; continue }
      if let q = quote {
        if c == q { quote = nil } else if c == "\\" && q == "\"" { escaped = true } else { word.append(c) }
        continue
      }
      switch c {
      case "'", "\"": quote = c; inWord = true
      case "\\": escaped = true
      case " ", "\t", "\n": end()
      case "&" where inWord && word.hasSuffix(">"):
        word.append(c)  // 2>&1
      case ";", "&", "|":
        end()
        // && and || are one word.
        if c != ";", prev == c, words.last == String(c) { words[words.count - 1] = String([c, c]) } else { words.append(String(c)) }
      default: word.append(c); inWord = true
      }
    }
    end()
    return words
  }

  /// The folder a static file server serves, when it isn't the folder it runs in:
  /// X in `python3 -m http.server --directory X` (or `-d X`), `npx serve X` and `http-server X`.
  /// A relative X is taken from `cwd`. Nil when the command names no folder.
  public static func servedFolder(_ argv: [String], cwd: String, isFolder: (String) -> Bool = defaultIsFolder) -> String? {
    var folder: String?
    if let m = argv.firstIndex(of: "-m"), m + 1 < argv.count, argv[m + 1] == "http.server" {
      for (i, a) in argv.enumerated().dropFirst(m + 2) {
        if (a == "--directory" || a == "-d"), i + 1 < argv.count { folder = argv[i + 1]; break }
        if a.hasPrefix("--directory=") { folder = String(a.dropFirst("--directory=".count)); break }
      }
    } else if let s = argv.firstIndex(where: { ["serve", "http-server"].contains(baseName($0)) || $0.contains("/node_modules/serve/") || $0.contains("/node_modules/http-server/") }) {
      let takesValue: Set<String> = ["-l", "--listen", "-p", "--port", "-a", "-c", "--config", "-o", "-P", "--proxy"]
      var i = s + 1
      while i < argv.count {
        let a = argv[i]
        if a.hasPrefix("-") { i += takesValue.contains(a) ? 2 : 1; continue }
        folder = a
        break
      }
    }
    guard let folder, !folder.isEmpty else { return nil }
    let full = ((folder.hasPrefix("/") ? folder : (cwd as NSString).appendingPathComponent(folder)) as NSString).standardizingPath
    let here = (cwd as NSString).standardizingPath
    return full != here && isFolder(full) ? full : nil
  }

  /// The same, read from a saved command line, up to its first && or ;. For entries saved before names followed it.
  public static func servedFolder(command: String, cwd: String, isFolder: (String) -> Bool = defaultIsFolder) -> String? {
    var dir = cwd
    var argv: [String] = []
    for w in shellWords(command) + [";"] {
      guard shellOperators.contains(w) || w.hasPrefix(">") || w.hasPrefix("2>") else { argv.append(w); continue }
      if argv.first == "cd", argv.count == 2 {
        dir = argv[1].hasPrefix("/") ? argv[1] : (dir as NSString).appendingPathComponent(argv[1])
      } else if let found = servedFolder(argv, cwd: dir, isFolder: isFolder) {
        return found
      }
      argv = []
    }
    return nil
  }

  /// The folder a static server's pages come from, read from its saved command: the folder it names, else the one it
  /// runs in. A custom server handed a folder (`node serve.mjs ~/site`) counts too. Nil when it isn't a static server.
  public static func staticFolder(command: String, cwd: String, isFolder: (String) -> Bool = defaultIsFolder) -> String? {
    var dir = cwd
    var argv: [String] = []
    for w in shellWords(command) + [";"] {
      guard shellOperators.contains(w) || w.hasPrefix(">") || w.hasPrefix("2>") else { argv.append(w); continue }
      defer { argv = [] }
      if argv.first == "cd", argv.count == 2 {
        dir = argv[1].hasPrefix("/") ? argv[1] : (dir as NSString).appendingPathComponent(argv[1])
        continue
      }
      if let served = servedFolder(argv, cwd: dir, isFolder: isFolder) { return served }
      let isStatic = argv.contains("http.server") || argv.contains { ["serve", "http-server"].contains(baseName($0)) }
      if isStatic { return (dir as NSString).standardizingPath }
      if argv.count > 1, let folder = argv.dropFirst().first(where: { $0.hasPrefix("/") && isFolder($0) }) { return folder }
    }
    return nil
  }

  /// Ports the system hands out when a program asks for any free one.
  static let randomPorts: ClosedRange<UInt16> = 49152...65535
  /// How long something on a random port has to last before it counts as a server. Long enough for a test suite.
  public static let taskSeconds: TimeInterval = 600
  static let packageManagers: Set<String> = ["npm", "pnpm", "yarn", "bun"]
  static let taskScripts: Set<String> = ["test", "build", "lint", "typecheck", "check", "gen"]
  static let taskTools: Set<String> = ["vitest", "jest", "pytest", "tsc", "eslint"]

  /// A job that opens a port on the way, not a server: a test run, a build, or anything young on a random port,
  /// like a script that serves a site to a browser it's driving. Hidden until it outlasts `taskSeconds`.
  public static func isTask(command: String, ports: [UInt16], age: TimeInterval) -> Bool {
    if isTaskCommand(command) { return true }
    guard let lowest = ports.min() else { return false }
    return randomPorts.contains(lowest) && age < taskSeconds
  }

  /// True when the command's last step is a test, build, lint or the like. In `npm run build && npm start` the last
  /// step is the server, so it isn't one. `npm test | tail` counts as npm test.
  public static func isTaskCommand(_ command: String) -> Bool {
    var last: [String] = []
    var step: [String] = []
    for w in shellWords(command) + [";"] {
      if ["&&", "||", ";", "&"].contains(w) {
        if !step.isEmpty { last = step }
        step = []
      } else {
        step.append(w)
      }
    }
    if let pipe = last.firstIndex(of: "|") { last = Array(last[..<pipe]) }
    // Past `NAME=value` prefixes, and npx, which only runs what follows.
    var words = last.drop { $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil }
    if let first = words.first, ["npx", "pnpx", "bunx"].contains(baseName(first)) { words = words.dropFirst() }
    if words.first.map(baseName) == "pnpm", words.dropFirst().first == "exec" { words = words.dropFirst(2) }
    let args = Array(words)
    guard let tool = args.first.map(baseName) else { return false }
    if taskTools.contains(tool) { return true }
    if tool == "playwright" { return args.dropFirst().first == "test" }
    if tool == "next" || tool == "vite" { return args.dropFirst().first == "build" }
    guard packageManagers.contains(tool), let script = args.dropFirst().first(where: { !$0.hasPrefix("-") && $0 != "run" && $0 != "run-script" }) else { return false }
    return taskScripts.contains(String(script.prefix { $0 != ":" }))
  }

  public static func defaultIsFolder(_ path: String) -> Bool {
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
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
