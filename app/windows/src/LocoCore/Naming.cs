namespace LocoCore;

/// <summary>
/// Pure rules for reading a launch chain: what is a shell, what is a boundary, what to call a server,
/// and which command brings it back. Ported from the Mac's Naming.swift, with Windows' shells and wrappers.
/// Kept free of system calls so they're easy to check.
/// </summary>
public static class Naming
{
    static readonly StringComparer Ci = StringComparer.OrdinalIgnoreCase;

    static readonly HashSet<string> PosixShells = new(Ci) { "sh", "bash", "zsh", "dash", "ksh", "fish", "tcsh", "csh" };
    static readonly HashSet<string> Shells = new(Ci) { "sh", "bash", "zsh", "dash", "ksh", "fish", "tcsh", "csh", "cmd", "powershell", "pwsh" };

    /// <summary>Long-lived hosts that start servers: agent CLIs, multiplexers, remote logins.</summary>
    static readonly HashSet<string> Hosts = new(Ci)
    {
        "copilot", "claude", "codex", "cursor-agent", "gemini", "aider", "opencode", "goose", "amp",
        "tmux", "screen", "zellij", "login", "sshd", "mosh-server",
    };

    /// <summary>Agent CLIs that run as `node …\@scope\name\…`, so their program is node.</summary>
    static readonly string[] HostPackages = [@"\@github\copilot", @"\@anthropic-ai\claude-code", @"\@openai\codex", @"\@google\gemini-cli"];

    /// <summary>Build-output and docs folders. A server running in one is named after the folder above.</summary>
    static readonly HashSet<string> GenericFolders = new(Ci) { "dist", "build", "public", "docs", "out" };
    static readonly string[] Markers = ["package.json", "pyproject.toml"];
    static readonly HashSet<string> ScriptExtensions = new(Ci) { "py", "js", "mjs", "cjs", "ts", "mts", "rb", "sh", "php", "pl" };

    /// <summary>Runtimes and tools. Their programs live in Program Files or AppData, but what they run is yours.</summary>
    static readonly HashSet<string> Runtimes = new(Ci)
    {
        "node", "py", "pyw", "uv", "uvx", "deno", "bun", "ruby", "rubyw", "php", "php-cgi", "java", "javaw", "dotnet",
        "go", "cargo", "perl", "npm", "npx", "pnpm", "yarn", "caddy", "nginx", "hugo", "cmd", "powershell", "pwsh",
        "bash", "sh", "conda", "pipx", "poetry", "hatch", "pdm", "flask", "uvicorn", "gunicorn", "jupyter", "jekyll",
    };

    /// <summary>Folders that hold tools rather than apps, wherever they are installed.</summary>
    static readonly HashSet<string> ToolFolders = new(Ci)
    {
        "Scripts", "node_modules", "nodejs", "npm", "pnpm", "Yarn", "uv", "pipx", ".venv", "venv", "Python", "Ruby", "Go", ".cargo", ".bun", ".deno",
    };

    /// <summary>"cmd" from "C:\Windows\system32\cmd.exe", "zsh" from "-zsh".</summary>
    public static string ProgramName(string path)
    {
        var name = WinPath.FileName(path.StartsWith('-') ? path[1..] : path);
        foreach (var ext in (string[])[".exe", ".com"])
            if (name.EndsWith(ext, StringComparison.OrdinalIgnoreCase)) return name[..^ext.Length];
        return name;
    }

    public enum ShellKind { None, Posix, Cmd, PowerShell }

    /// <summary>What a shell process is doing.</summary>
    /// <param name="Script">The command it was handed (`cmd /c …`, `pwsh -Command …`, `bash -c …`), or null.</param>
    /// <param name="Interactive">A prompt a person types into: no command, `cmd /k`, `pwsh -NoExit`, or a session reading stdin.</param>
    public readonly record struct ShellInfo(ShellKind Kind, string? Script, bool Interactive);

    public static ShellKind KindOf(string[] argv)
    {
        if (argv.Length == 0) return ShellKind.None;
        var name = ProgramName(argv[0]);
        if (PosixShells.Contains(name)) return ShellKind.Posix;
        if (name.Equals("cmd", StringComparison.OrdinalIgnoreCase)) return ShellKind.Cmd;
        if (name.Equals("pwsh", StringComparison.OrdinalIgnoreCase) || name.Equals("powershell", StringComparison.OrdinalIgnoreCase)) return ShellKind.PowerShell;
        return ShellKind.None;
    }

    public static bool IsShell(ProcCommand c) => KindOf(c.Argv) != ShellKind.None;

    public static ShellInfo Shell(ProcCommand c) => KindOf(c.Argv) switch
    {
        ShellKind.Posix => new(ShellKind.Posix, PosixScript(c.Argv), IsInteractivePosix(c.Argv)),
        ShellKind.Cmd => CmdShell(c.Raw),
        ShellKind.PowerShell => PowerShell(c.Argv),
        _ => new(ShellKind.None, null, false),
    };

    public static string? ShellScript(ProcCommand c) => Shell(c).Script;

    public static bool IsInteractiveShell(ProcCommand c) => Shell(c).Interactive;

    /// <summary>A shell that only runs the command it was handed ("$@" or %*), like a detached supervisor.</summary>
    public static bool IsSupervisor(ProcCommand c)
    {
        var s = ShellScript(c);
        return s != null && (s.Contains("$@") || s.Contains("%*"));
    }

    // MARK: sh, bash, zsh (Git Bash, MSYS, Cygwin)

    /// <summary>The script of `sh -c '&lt;script&gt;'` (also `-lc`, `-ec`, `--norc -c`), or null.</summary>
    static string? PosixScript(string[] argv)
    {
        int i = 1;
        while (i < argv.Length)
        {
            var a = argv[i];
            if (a == "--") return null;
            if (a is "-o" or "+o") { i += 2; continue; }
            if (a.StartsWith('-') && !a.StartsWith("--") && a[1..].Contains('c'))
                return i + 1 < argv.Length ? argv[i + 1] : null;
            if (a.StartsWith('-') || a.StartsWith('+')) { i++; continue; }
            return null;
        }
        return null;
    }

    static bool IsInteractivePosix(string[] argv)
    {
        if (argv[0].StartsWith('-') && PosixShells.Contains(argv[0][1..])) return true;
        if (PosixScript(argv) != null) return false;
        return !argv.Skip(1).Any(a => !a.StartsWith('-') && !a.StartsWith('+'));
    }

    // MARK: cmd

    /// <summary>
    /// Reads cmd's own switches from the raw command line, since cmd doesn't use C rules for the rest.
    /// `/c` runs a command; `/k` runs one and stays at the prompt, so it counts as interactive.
    /// </summary>
    static ShellInfo CmdShell(string raw)
    {
        int i = SkipProgram(raw), n = raw.Length;
        bool s = false;
        while (true)
        {
            while (i < n && raw[i] is ' ' or '\t') i++;
            if (i >= n) return new(ShellKind.Cmd, null, true);
            if (raw[i] != '/') return new(ShellKind.Cmd, null, true);
            char sw = i + 1 < n ? char.ToLowerInvariant(raw[i + 1]) : '\0';
            if (sw is 'c' or 'k')
            {
                var rest = raw[(i + 2)..].Trim();
                if (sw == 'k') return new(ShellKind.Cmd, null, true);
                return new(ShellKind.Cmd, rest.Length == 0 ? null : StripCmdQuotes(rest, s), false);
            }
            if (sw == 's') s = true;
            i += 2;
            while (i < n && raw[i] is not (' ' or '\t' or '/')) i++;
        }
    }

    /// <summary>Where the arguments start, after the program path.</summary>
    static int SkipProgram(string raw)
    {
        int i = 0, n = raw.Length;
        while (i < n && raw[i] is ' ' or '\t') i++;
        if (i < n && raw[i] == '"')
        {
            i++;
            while (i < n && raw[i] != '"') i++;
            return Math.Min(i + 1, n);
        }
        while (i < n && raw[i] is not (' ' or '\t')) i++;
        return i;
    }

    /// <summary>
    /// cmd's quote rule (cmd /?): with /s, or unless the command is exactly one quoted program path,
    /// a leading quote and the last quote on the line are removed.
    /// </summary>
    static string StripCmdQuotes(string rest, bool s)
    {
        if (!rest.StartsWith('"')) return rest;
        int quotes = rest.Count(c => c == '"');
        if (!s && quotes == 2 && rest.EndsWith('"'))
        {
            var inner = rest[1..^1];
            bool special = inner.Any(c => c is '&' or '<' or '>' or '(' or ')' or '@' or '^' or '|');
            bool program = new[] { ".exe", ".com", ".bat", ".cmd" }.Any(e => inner.EndsWith(e, StringComparison.OrdinalIgnoreCase));
            if (!special && program && inner.Any(char.IsWhiteSpace)) return rest;
        }
        int last = rest.LastIndexOf('"');
        return last <= 0 ? rest[1..] : rest[1..last] + rest[(last + 1)..];
    }

    // MARK: PowerShell

    static readonly HashSet<string> PowerShellValueFlags = new(Ci)
    {
        "executionpolicy", "ex", "ep", "workingdirectory", "wd", "windowstyle", "w", "configurationname", "config",
        "configurationfile", "inputformat", "inp", "if", "outputformat", "o", "of", "settingsfile", "settings",
        "custompipename", "psconsolefile", "version", "v", "encodedarguments", "ea",
    };

    static bool IsPrefixOf(string name, string full, int min) => name.Length >= min && full.StartsWith(name, StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// `-Command` and `-c` hand it a command, `-File` a script file, `-EncodedCommand` a command we can't read.
    /// `-NoExit` keeps it at the prompt, as VS Code's terminal does. `-Command -` reads commands from stdin, like an agent's session.
    /// </summary>
    static ShellInfo PowerShell(string[] argv)
    {
        bool pwsh = ProgramName(argv[0]).Equals("pwsh", StringComparison.OrdinalIgnoreCase);
        bool noExit = false;
        for (int i = 1; i < argv.Length; i++)
        {
            var a = argv[i];
            if (a.Length > 1 && a[0] is '-' or '/')
            {
                var name = a.TrimStart('-', '/');
                int colon = name.IndexOf(':');
                bool inline = colon >= 0;
                if (inline) name = name[..colon];
                if (name.Equals("noexit", StringComparison.OrdinalIgnoreCase)) { noExit = true; continue; }
                if (name.Equals("c", StringComparison.OrdinalIgnoreCase) || IsPrefixOf(name, "command", 3) ||
                    name.Equals("cwa", StringComparison.OrdinalIgnoreCase) || IsPrefixOf(name, "commandwithargs", 8))
                {
                    var script = i + 1 < argv.Length ? string.Join(' ', argv[(i + 1)..]) : null;
                    if (script is null or "-") return new(ShellKind.PowerShell, null, true);
                    return new(ShellKind.PowerShell, script, noExit);
                }
                if (name.Equals("f", StringComparison.OrdinalIgnoreCase) || IsPrefixOf(name, "file", 2))
                    return new(ShellKind.PowerShell, null, noExit || (i + 1 < argv.Length && argv[i + 1] == "-"));
                if (name.Equals("e", StringComparison.OrdinalIgnoreCase) || name.Equals("ec", StringComparison.OrdinalIgnoreCase) ||
                    IsPrefixOf(name, "encodedcommand", 3))
                    return new(ShellKind.PowerShell, null, noExit);
                if (!inline && PowerShellValueFlags.Contains(name)) i++;
                continue;
            }
            // A bare argument: a script file for pwsh, a command for Windows PowerShell.
            if (pwsh) return new(ShellKind.PowerShell, null, noExit);
            return new(ShellKind.PowerShell, string.Join(' ', argv[i..]), noExit);
        }
        return new(ShellKind.PowerShell, null, true);
    }

    // MARK: Boundaries

    public static bool IsHost(IEnumerable<string> names, string[] argv) =>
        names.Any(n => n.Length > 0 && Hosts.Contains(ProgramName(n))) ||
        argv.Any(a => HostPackages.Any(p => a.Replace('/', '\\').Contains(p, StringComparison.OrdinalIgnoreCase)));

    public static bool IsRuntime(string exe)
    {
        var name = ProgramName(exe);
        return Runtimes.Contains(name) ||
               name.StartsWith("python", StringComparison.OrdinalIgnoreCase) ||
               name.StartsWith("ruby", StringComparison.OrdinalIgnoreCase) ||
               name.StartsWith("php", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// An installed app's program: under Program Files, Windows, ProgramData, AppData\Local\Programs or AppData\Local\Microsoft.
    /// Runtimes and anything in a tools folder (Python's Scripts, node_modules, a venv) don't count, wherever they are.
    /// </summary>
    public static bool IsAppExecutable(string exe, IReadOnlyList<string> appRoots)
    {
        if (string.IsNullOrEmpty(exe) || !WinPath.IsFullyRooted(exe)) return false;
        if (!appRoots.Any(r => WinPath.IsUnder(exe, r))) return false;
        if (IsRuntime(exe)) return false;
        var folders = WinPath.Normalize(exe).Split('\\');
        return !folders[..^1].Any(f => ToolFolders.Contains(f) || f.StartsWith("Python", StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>A script is safe to run again when it is one line with no heredoc.</summary>
    public static bool IsRerunnable(string script)
    {
        var s = script.Trim();
        return s.Length > 0 && !s.Contains('\n') && !s.Contains("<<");
    }

    // MARK: Names

    /// <summary>The name in `uv run [options] &lt;name&gt;`. Null for `uv run python …`, which says nothing about the project.</summary>
    public static string? UvRunName(string[] argv)
    {
        var args = argv.Where(a => a.Trim().Length > 0).ToArray();
        if (args.Length == 1) args = args[0].Split(' ', StringSplitOptions.RemoveEmptyEntries);
        int u = Array.FindIndex(args, a => ProgramName(a).Equals("uv", StringComparison.OrdinalIgnoreCase));
        if (u < 0 || u + 1 >= args.Length || args[u + 1] != "run") return null;
        string[] takesValue =
        [
            "--project", "--directory", "--with", "--with-editable", "--with-requirements", "--python", "-p",
            "--package", "--extra", "--group", "--only-group", "--no-group", "--env-file", "--index", "--default-index",
        ];
        int i = u + 2;
        while (i < args.Length)
        {
            var a = args[i];
            if (a == "--") { i++; continue; }
            if (a.StartsWith('-')) { i += takesValue.Contains(a) ? 2 : 1; continue; }
            var name = ProgramName(a);
            if (name.StartsWith("python", StringComparison.OrdinalIgnoreCase)) return null;
            return WinPath.Extension(name).Equals("py", StringComparison.OrdinalIgnoreCase) ? WinPath.WithoutExtension(name) : name;
        }
        return null;
    }

    /// <summary>Desktop, Documents and Downloads hold loose scripts, also when OneDrive backs them up.</summary>
    public static string[] LooseFolders(string home) =>
    [
        home + @"\Desktop", home + @"\Documents", home + @"\Downloads",
        home + @"\OneDrive\Desktop", home + @"\OneDrive\Documents",
    ];

    /// <summary>
    /// "auth-mock" from `python C:\Users\me\tools\auth-mock.py --port 8090`. Skips files inside node_modules.
    /// Null when the script sits in the folder it runs from (`python serve.py` in api-mock): the folder names it better.
    /// </summary>
    public static string? ScriptName(string[] argv, string cwd, string home)
    {
        var script = argv.Skip(1).FirstOrDefault(a =>
            !a.StartsWith('-') &&
            !a.Replace('/', '\\').Contains(@"\node_modules\", StringComparison.OrdinalIgnoreCase) &&
            ScriptExtensions.Contains(WinPath.Extension(a)));
        if (script == null) return null;
        var full = WinPath.IsFullyRooted(script) ? script : WinPath.Combine(cwd, script);
        var folder = WinPath.Parent(full);
        if (WinPath.Eq(folder, cwd) && !LooseFolders(home).Any(l => WinPath.Eq(l, folder))) return null;
        return WinPath.WithoutExtension(WinPath.FileName(script));
    }

    /// <summary>
    /// The folder a server belongs to, and whether it is a project.
    /// Inside a git repo: the nearest folder with package.json or pyproject.toml, else the repo root.
    /// Outside git: the folder itself, past dist, build, public, docs and out. Never the user folder or above.
    /// </summary>
    public static (string Dir, bool IsProject) Project(string cwd, string home, Func<string, bool> exists)
    {
        if (!WinPath.IsUnder(cwd, home)) return (cwd, false);
        cwd = WinPath.Normalize(cwd);
        string? marker = null;
        var dir = cwd;
        while (WinPath.IsUnder(dir, home))
        {
            if (marker == null && !GenericFolders.Contains(WinPath.FileName(dir)) && Markers.Any(m => exists(dir + "\\" + m)))
                marker = dir;
            if (exists(dir + @"\.git")) return (marker ?? dir, true);
            dir = WinPath.Parent(dir);
        }
        var folder = cwd;
        while (GenericFolders.Contains(WinPath.FileName(folder)))
        {
            var up = WinPath.Parent(folder);
            if (!WinPath.IsUnder(up, home)) break;
            folder = up;
        }
        return (folder, Markers.Any(m => exists(folder + "\\" + m)));
    }

    // MARK: Commands

    /// <summary>
    /// A command line that runs argv again through cmd. Node's package managers read as themselves
    /// (`node …\npm-cli.js run dev` is `npm run dev`), and a program on the server's PATH goes by its name.
    /// </summary>
    public static string CommandLineFor(string[] argv, string? path)
    {
        var args = argv.ToList();
        while (args.Count > 0 && args[^1].Trim().Length == 0) args.RemoveAt(args.Count - 1);
        if (args.Count == 0) return "";
        if (ProgramName(args[0]).Equals("node", StringComparison.OrdinalIgnoreCase) && args.Count >= 2)
        {
            var script = args[1].Replace('/', '\\');
            string? tool =
                script.EndsWith(@"npm\bin\npm-cli.js", StringComparison.OrdinalIgnoreCase) ? "npm" :
                script.EndsWith(@"npm\bin\npx-cli.js", StringComparison.OrdinalIgnoreCase) ? "npx" :
                script.EndsWith(@"pnpm\bin\pnpm.cjs", StringComparison.OrdinalIgnoreCase) || script.EndsWith(@"pnpm\bin\pnpm.mjs", StringComparison.OrdinalIgnoreCase) ? "pnpm" :
                script.EndsWith(@"pnpm\bin\pnpx.cjs", StringComparison.OrdinalIgnoreCase) ? "pnpx" :
                script.EndsWith(@"yarn\bin\yarn.js", StringComparison.OrdinalIgnoreCase) || script.EndsWith(@"yarn\bin\yarn.cjs", StringComparison.OrdinalIgnoreCase) ? "yarn" :
                null;
            if (tool != null) return CommandLine.Join([tool, .. args.Skip(2)]);
        }
        if (WinPath.IsFullyRooted(args[0]) && path != null && OnPath(WinPath.Parent(args[0]), path))
            args[0] = ProgramName(args[0]);
        return CommandLine.Join(args);
    }

    static bool OnPath(string dir, string path) =>
        path.Split(';').Select(p => p.Trim().Trim('"')).Any(p => p.Length > 0 && WinPath.Eq(p, dir));
}
