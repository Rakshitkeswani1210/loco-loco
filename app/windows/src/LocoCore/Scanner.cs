namespace LocoCore;

/// <summary>One process, as read from the process table.</summary>
public readonly record struct ProcInfo(int Pid, int Ppid, ulong StartMicros, string Name)
{
    public DateTime StartDate => DateTime.UnixEpoch.AddTicks((long)StartMicros * 10);
    public ProcRef Ref => new(Pid, StartMicros);
}

/// <summary>A read of the process table: the real one on Windows, a fake one in tests.</summary>
public interface IProcTable
{
    int Self { get; }
    /// <summary>The current user's processes.</summary>
    IReadOnlyDictionary<int, ProcInfo> Processes { get; }
    /// <summary>Listening TCP ports by pid, IPv4 and IPv6 together.</summary>
    IReadOnlyDictionary<int, ushort[]> Listeners { get; }
    /// <summary>The program's full path, or "".</summary>
    string Exe(int pid);
    ProcCommand Command(int pid);
    /// <summary>The working folder without a trailing separator, or null.</summary>
    string? Cwd(int pid);
    /// <summary>An environment variable, matched without case.</summary>
    string? Env(int pid, string name);
}

/// <summary>Where things live on this PC. Injected so the rules can be tested anywhere.</summary>
public sealed record Places(string Home, IReadOnlyList<string> AppRoots, IReadOnlyList<string> TempDirs)
{
    /// <summary>Your files, not AppData. Temp folders count too: scripts and agents run servers from there.</summary>
    public bool IsDevPlace(string cwd) =>
        (WinPath.IsUnder(cwd, Home) && !WinPath.IsSameOrUnder(cwd, Home + @"\AppData")) ||
        TempDirs.Any(t => WinPath.IsSameOrUnder(cwd, t));
}

public static class Scanner
{
    enum Stop { Root, Us, Foreign, App, Host, Shell, Supervisor }

    /// <summary>
    /// The parent, if it is still the process that started this one. Windows keeps a dead parent's pid,
    /// and a new process can reuse it, so a parent that started later isn't the parent.
    /// </summary>
    static int ParentOf(IProcTable t, ProcInfo p) =>
        t.Processes.TryGetValue(p.Ppid, out var parent) && parent.Pid != p.Pid && parent.StartMicros <= p.StartMicros ? p.Ppid : 0;

    /// <summary>Groups listening processes by their launch, and names each group.</summary>
    public static List<Server> Build(IProcTable t, Places places, Func<string, bool> exists, Func<string, string?> appName)
    {
        var cmdCache = new Dictionary<int, ProcCommand>();
        ProcCommand Cmd(int pid) => cmdCache.TryGetValue(pid, out var c) ? c : cmdCache[pid] = t.Command(pid);
        var exeCache = new Dictionary<int, string>();
        string Exe(int pid) => exeCache.TryGetValue(pid, out var e) ? e : exeCache[pid] = t.Exe(pid);

        Stop? Boundary(int pid)
        {
            if (pid <= 4) return Stop.Root;
            if (pid == t.Self) return Stop.Us;
            if (!t.Processes.TryGetValue(pid, out var info)) return Stop.Foreign;
            if (Naming.IsAppExecutable(Exe(pid), places.AppRoots)) return Stop.App;
            var c = Cmd(pid);
            if (Naming.IsHost([Exe(pid), c.Argv.FirstOrDefault() ?? "", info.Name], c.Argv)) return Stop.Host;
            if (Naming.IsInteractiveShell(c)) return Stop.Shell;
            if (Naming.IsSupervisor(c)) return Stop.Supervisor;
            return null;
        }

        // Listening processes, grouped by the root of their launch chain.
        var groups = new Dictionary<int, (SortedSet<ushort> Ports, int Listener, List<int> Chain, Stop Stop)>();
        foreach (var (pid, ports) in t.Listeners.OrderBy(kv => kv.Key))
        {
            if (pid == t.Self || ports.Length == 0 || !t.Processes.ContainsKey(pid)) continue;
            var lowest = ports.Min();
            // Walk up from the listener to the shell, agent, app or system process that started it.
            var chain = new List<int> { pid };
            var stop = Stop.Root;
            while (chain.Count < 64)
            {
                int parent = ParentOf(t, t.Processes[chain[^1]]);
                if (parent == 0) { stop = Stop.Root; break; }
                if (Boundary(parent) is { } b) { stop = b; break; }
                chain.Add(parent);
            }
            int root = chain[^1];
            if (groups.TryGetValue(root, out var g))
            {
                // The listener on the lowest port names the server.
                if (lowest < g.Ports.Min) { g.Listener = pid; g.Chain = chain; }
                g.Ports.UnionWith(ports);
                groups[root] = g;
            }
            else
            {
                groups[root] = (new SortedSet<ushort>(ports), pid, chain, stop);
            }
        }

        var children = ChildMap(t);
        var servers = new List<Server>();
        foreach (var (root, g) in groups)
        {
            var rootInfo = t.Processes[root];
            var listenerCwd = t.Cwd(g.Listener) ?? "";
            var listenerExe = Exe(g.Listener);
            var rootCmd = Cmd(root);
            // An app's terminal or task runner starts servers through a shell. Anything else an app starts is its own.
            bool appOwned = g.Stop == Stop.App && Naming.ShellScript(rootCmd) == null && !Naming.IsShell(rootCmd);
            bool isDev = listenerCwd.Length > 0 && places.IsDevPlace(listenerCwd) && !appOwned &&
                         !Naming.IsAppExecutable(listenerExe, places.AppRoots);

            // Name and folder
            string name;
            var projectDir = listenerCwd;
            if (isDev)
            {
                var project = Naming.Project(listenerCwd, places.Home, exists);
                projectDir = project.Dir;
                var uv = g.Chain.Select(p => Naming.UvRunName(Cmd(p).Argv)).FirstOrDefault(n => n != null);
                if (uv != null) name = uv;
                else if (project.IsProject) name = WinPath.FileName(project.Dir);
                else if (Naming.ScriptName(Cmd(g.Listener).Argv, listenerCwd, places.Home) is { } script)
                {
                    name = script;
                    projectDir = listenerCwd;
                }
                else name = WinPath.FileName(project.Dir);
            }
            else
            {
                name = (listenerExe.Length > 0 ? appName(listenerExe) : null) ??
                       Naming.ProgramName(t.Processes.TryGetValue(g.Listener, out var li) ? li.Name : rootInfo.Name);
                if (listenerExe.Length > 0) projectDir = WinPath.Parent(listenerExe);
            }

            // The command that brings it back: the launching shell's one-line script, else the top process's own command.
            var path = t.Env(root, "PATH") ?? t.Env(g.Listener, "PATH");
            string command;
            var commandDir = t.Cwd(root) ?? listenerCwd;
            var shell = Naming.Shell(rootCmd);
            if (shell.Script is { } s && Naming.IsRerunnable(s))
            {
                // cmd runs its script directly. Another shell runs again as itself, from cmd.
                command = shell.Kind == Naming.ShellKind.Cmd ? TidyProgram(s.Trim(), path) : TidyProgram(rootCmd.Raw.Trim(), path);
            }
            else
            {
                var top = Enumerable.Reverse(g.Chain).FirstOrDefault(p => Naming.ShellScript(Cmd(p)) == null, g.Listener);
                command = Naming.CommandLineFor(Cmd(top).Argv, path);
                commandDir = t.Cwd(top) ?? commandDir;
            }

            servers.Add(new Server
            {
                Root = rootInfo.Ref,
                StartedAt = rootInfo.StartDate,
                Ports = g.Ports.ToArray(),
                Name = name,
                ProjectDir = projectDir,
                Command = command,
                CommandDir = commandDir,
                Path = path,
                IsDevServer = isDev,
                Processes = Descendants(t, root, children),
                Executable = listenerExe.Length == 0 ? null : listenerExe,
            });
        }
        return servers.OrderBy(s => s.Port).ThenBy(s => s.Root.Pid).ToList();
    }

    /// <summary>
    /// `npm run dev` for `"C:\Program Files\nodejs\npm.cmd" run dev` when that folder is on PATH.
    /// Only the program changes; the rest stays as written, since cmd reads it.
    /// </summary>
    internal static string TidyProgram(string line, string? path)
    {
        if (path == null || line.Length == 0) return line;
        int end;
        string program;
        if (line[0] == '"')
        {
            end = line.IndexOf('"', 1);
            if (end < 0) return line;
            program = line[1..end];
            end++;
        }
        else
        {
            end = line.IndexOfAny([' ', '\t']);
            if (end < 0) end = line.Length;
            program = line[..end];
        }
        if (!WinPath.IsFullyRooted(program)) return line;
        var dir = WinPath.Parent(program);
        bool onPath = path.Split(';').Select(p => p.Trim().Trim('"')).Any(p => p.Length > 0 && WinPath.Eq(p, dir));
        if (!onPath) return line;
        var file = WinPath.FileName(program);
        var bare = WinPath.Extension(file).ToLowerInvariant() is "exe" or "cmd" or "bat" or "com" ? WinPath.WithoutExtension(file) : file;
        if (bare.Any(c => c is ' ' or '&' or '(' or ')')) return line;
        return bare + line[end..];
    }

    static Dictionary<int, List<int>> ChildMap(IProcTable t)
    {
        var children = new Dictionary<int, List<int>>();
        foreach (var p in t.Processes.Values)
        {
            int parent = ParentOf(t, p);
            if (parent == 0) continue;
            if (!children.TryGetValue(parent, out var list)) children[parent] = list = [];
            list.Add(p.Pid);
        }
        return children;
    }

    static ProcRef[] Descendants(IProcTable t, int root, Dictionary<int, List<int>> children)
    {
        var procs = new List<ProcRef>();
        var seen = new HashSet<int>();
        var queue = new Stack<int>([root]);
        while (queue.Count > 0)
        {
            int p = queue.Pop();
            if (p == t.Self || !seen.Add(p) || !t.Processes.TryGetValue(p, out var info)) continue;
            procs.Add(info.Ref);
            if (children.TryGetValue(p, out var list)) foreach (var c in list) queue.Push(c);
        }
        return procs.ToArray();
    }

    /// <summary>The root and everything under it now, including children started since the last scan.</summary>
    public static ProcRef[] Tree(IProcTable t, ProcRef root)
    {
        if (!t.Processes.TryGetValue(root.Pid, out var info) || info.StartMicros != root.StartMicros) return [];
        return Descendants(t, root.Pid, ChildMap(t));
    }
}
