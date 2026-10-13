namespace LocoCore.Tests;

/// <summary>A process table built by hand. Start times default to pid × 1000, so parents start before children.</summary>
sealed class FakeTable : IProcTable
{
    public int Self { get; set; } = 2;
    readonly Dictionary<int, ProcInfo> procs = [];
    readonly Dictionary<int, ushort[]> listeners = [];
    readonly Dictionary<int, (string Exe, ProcCommand Cmd, string? Cwd, string? Path)> details = [];

    public IReadOnlyDictionary<int, ProcInfo> Processes => procs;
    public IReadOnlyDictionary<int, ushort[]> Listeners => listeners;
    public string Exe(int pid) => details.TryGetValue(pid, out var d) ? d.Exe : "";
    public ProcCommand Command(int pid) => details.TryGetValue(pid, out var d) ? d.Cmd : ProcCommand.Empty;
    public string? Cwd(int pid) => details.TryGetValue(pid, out var d) ? d.Cwd : null;
    public string? Env(int pid, string name) =>
        name.Equals("PATH", StringComparison.OrdinalIgnoreCase) && details.TryGetValue(pid, out var d) ? d.Path : null;

    public FakeTable Add(int pid, int ppid, string exe, string raw, string? cwd = null, ushort[]? ports = null,
        string? path = null, ulong? start = null)
    {
        procs[pid] = new ProcInfo(pid, ppid, start ?? (ulong)pid * 1000, WinPath.FileName(exe));
        details[pid] = (exe, ProcCommand.From(raw), cwd, path);
        if (ports != null) listeners[pid] = ports;
        return this;
    }
}

public class ScannerTests
{
    const string Home = @"C:\Users\me";
    const string Node = @"C:\Program Files\nodejs\node.exe";
    const string NpmCli = @"C:\Program Files\nodejs\node_modules\npm\bin\npm-cli.js";
    const string Cmd = @"C:\Windows\System32\cmd.exe";
    const string Pwsh = @"C:\Program Files\PowerShell\7\pwsh.exe";
    const string Python = @"C:\Users\me\AppData\Local\Programs\Python\Python312\python.exe";
    const string UserPath = @"C:\Windows\system32;C:\Program Files\nodejs\;C:\Program Files\PowerShell\7;C:\Users\me\AppData\Local\Programs\Python\Python312";

    static readonly Places Places = new(Home,
        [@"C:\Program Files", @"C:\Windows", @"C:\Users\me\AppData\Local\Programs", @"C:\Users\me\AppData\Local\Microsoft"],
        [@"C:\Users\me\AppData\Local\Temp"]);

    static readonly HashSet<string> Files = new(StringComparer.OrdinalIgnoreCase)
    {
        @"C:\Users\me\site\package.json", @"C:\Users\me\site\.git",
        @"C:\Users\me\mono\.git", @"C:\Users\me\mono\web\package.json", @"C:\Users\me\mono\api\pyproject.toml",
    };

    static List<Server> Scan(FakeTable t) => Scanner.Build(t, Places, Files.Contains, exe => exe.EndsWith("com.docker.backend.exe") ? "Docker Desktop" : null);

    /// <summary>Windows Terminal, then an interactive pwsh, then the server.</summary>
    static FakeTable Terminal() => new FakeTable()
        .Add(20, 4, @"C:\Program Files\WindowsApps\Microsoft.WindowsTerminal_1.21\WindowsTerminal.exe", "wt.exe")
        .Add(30, 20, Pwsh, $"\"{Pwsh}\" -NoLogo", Home, path: UserPath);

    [Fact]
    public void NpmRunDevFromATerminal()
    {
        var t = Terminal()
            .Add(100, 30, Node, $"\"{Node}\" \"{NpmCli}\" run dev", @"C:\Users\me\site", path: UserPath)
            .Add(101, 100, Cmd, @"C:\Windows\system32\cmd.exe /d /s /c vite", @"C:\Users\me\site")
            .Add(102, 101, Node, $"\"{Node}\" C:\\Users\\me\\site\\node_modules\\vite\\bin\\vite.js", @"C:\Users\me\site", [5173, 24678]);
        var s = Assert.Single(Scan(t));
        Assert.Equal(new ProcRef(100, 100_000), s.Root);
        Assert.Equal("site", s.Name);
        Assert.Equal(@"C:\Users\me\site", s.ProjectDir);
        Assert.Equal("npm run dev", s.Command);
        Assert.Equal(@"C:\Users\me\site", s.CommandDir);
        Assert.Equal(UserPath, s.Path);
        Assert.Equal(new ushort[] { 5173, 24678 }, s.Ports);
        Assert.True(s.IsDevServer);
        Assert.Equal(new[] { 100, 101, 102 }, s.Processes.Select(p => p.Pid).Order());
        Assert.Equal(Node, s.Executable);
    }

    [Fact]
    public void AnAgentsCmdScriptRunsAgain()
    {
        var t = new FakeTable()
            .Add(40, 4, Node, $"\"{Node}\" C:\\Users\\me\\AppData\\Roaming\\npm\\node_modules\\@github\\copilot\\index.js")
            .Add(50, 40, Cmd, $"{Cmd} /d /s /c \"\"C:\\Program Files\\nodejs\\npm.cmd\" run dev\"", @"C:\Users\me\site", path: UserPath)
            .Add(51, 50, Node, $"\"{Node}\" \"{NpmCli}\" run dev", @"C:\Users\me\site")
            .Add(52, 51, Node, $"\"{Node}\" server.js", @"C:\Users\me\site", [3000]);
        var s = Assert.Single(Scan(t));
        Assert.Equal(50, s.Root.Pid);
        Assert.Equal("npm run dev", s.Command);
    }

    [Fact]
    public void AnAgentsPowerShellScriptRunsAgainAsPowerShell()
    {
        var t = new FakeTable()
            .Add(40, 4, @"C:\Users\me\AppData\Local\Programs\claude\claude.exe", "claude")
            .Add(60, 40, Pwsh, $"\"{Pwsh}\" -NoProfile -Command \"npx vite preview --port 4193\"", @"C:\Users\me\site", path: UserPath)
            .Add(61, 60, Node, $"\"{Node}\" C:\\Users\\me\\site\\node_modules\\vite\\bin\\vite.js preview --port 4193", @"C:\Users\me\site", [4193]);
        var s = Assert.Single(Scan(t));
        Assert.Equal(60, s.Root.Pid);
        Assert.Equal("pwsh -NoProfile -Command \"npx vite preview --port 4193\"", s.Command);
    }

    [Fact]
    public void ALooseScriptIsNamedAfterItsFile()
    {
        var t = Terminal().Add(70, 30, Python, $"\"{Python}\" C:\\Users\\me\\tools\\auth-mock.py --port 8090", @"C:\Users\me\Documents\Work", [8090], UserPath);
        var s = Assert.Single(Scan(t));
        Assert.Equal("auth-mock", s.Name);
        Assert.Equal(@"C:\Users\me\Documents\Work", s.ProjectDir);
        Assert.Equal(@"python C:\Users\me\tools\auth-mock.py --port 8090", s.Command);
    }

    [Fact]
    public void ALooseFolderIsNamedAfterItself()
    {
        var t = Terminal().Add(70, 30, Python, "python -m http.server 8000", @"C:\Users\me\Downloads\photos\dist", [8000]);
        var s = Assert.Single(Scan(t));
        Assert.Equal("photos", s.Name);
        Assert.Equal(@"C:\Users\me\Downloads\photos", s.ProjectDir);
        Assert.Equal("python -m http.server 8000", s.Command);
        Assert.Equal(@"C:\Users\me\Downloads\photos\dist", s.CommandDir);
    }

    [Fact]
    public void ServersInAMonorepoTakeTheirPackagesNames()
    {
        var t = Terminal()
            .Add(80, 30, Node, $"\"{Node}\" server.js", @"C:\Users\me\mono\web", [3000])
            .Add(90, 30, Python, "python -m uvicorn app:app", @"C:\Users\me\mono\api\src", [8000]);
        var servers = Scan(t);
        Assert.Equal(new[] { "web", "api" }, servers.Select(s => s.Name));
        Assert.Equal(new[] { @"C:\Users\me\mono\web", @"C:\Users\me\mono\api" }, servers.Select(s => s.ProjectDir));
    }

    [Fact]
    public void UvRunNamesTheServer()
    {
        var t = Terminal()
            .Add(110, 30, @"C:\Users\me\.local\bin\uv.exe", "uv run --project api serve", @"C:\Users\me\mono")
            .Add(111, 110, Python, "python serve.py", @"C:\Users\me\mono", [8001]);
        Assert.Equal("serve", Assert.Single(Scan(t)).Name);
    }

    [Fact]
    public void OneLaunchWithTwoListenersIsOneServerNamedByTheLowestPort()
    {
        var t = new FakeTable()
            .Add(40, 4, @"C:\Users\me\AppData\Local\Programs\claude\claude.exe", "claude")
            .Add(120, 40, Cmd, $"{Cmd} /d /s /c \"npm run dev:all\"", @"C:\Users\me\mono")
            .Add(121, 120, Python, "python -m uvicorn app:app --port 8000", @"C:\Users\me\mono\api", [8000])
            .Add(122, 120, Node, $"\"{Node}\" server.js", @"C:\Users\me\mono\web", [3000]);
        var s = Assert.Single(Scan(t));
        Assert.Equal(new ushort[] { 3000, 8000 }, s.Ports);
        Assert.Equal("web", s.Name);
        Assert.Equal("npm run dev:all", s.Command);
        Assert.Equal(3, s.Processes.Length);
    }

    [Fact]
    public void AnAppsOwnServerIsNotADevServer()
    {
        var t = new FakeTable()
            .Add(130, 4, @"C:\Program Files\Docker\Docker\Docker Desktop.exe", "\"Docker Desktop.exe\"")
            .Add(131, 130, @"C:\Program Files\Docker\Docker\resources\com.docker.backend.exe", "com.docker.backend.exe", @"C:\Program Files\Docker", [2375]);
        var s = Assert.Single(Scan(t));
        Assert.False(s.IsDevServer);
        Assert.Equal("Docker Desktop", s.Name);
        Assert.Equal(@"C:\Program Files\Docker\Docker\resources", s.ProjectDir);
    }

    [Fact]
    public void AServerStartedFromAnAppsTerminalIsADevServer()
    {
        const string code = @"C:\Users\me\AppData\Local\Programs\Microsoft VS Code\Code.exe";
        var t = new FakeTable()
            .Add(140, 4, code, $"\"{code}\"")
            .Add(141, 140, Pwsh, $"\"{Pwsh}\" -NoExit -Command \"& {{. shellIntegration.ps1}}\"", Home)
            .Add(142, 141, Node, $"\"{Node}\" server.js", @"C:\Users\me\site", [3001]);
        var s = Assert.Single(Scan(t));
        Assert.True(s.IsDevServer);
        Assert.Equal(142, s.Root.Pid);
        Assert.Equal(@"""C:\Program Files\nodejs\node.exe"" server.js", s.Command);
    }

    [Fact]
    public void ServersInAppDataAreNotDevServersButTempOnesAre()
    {
        var t = Terminal()
            .Add(150, 30, Node, $"\"{Node}\" x.js", @"C:\Users\me\AppData\Roaming\tool", [9000])
            .Add(151, 30, Node, $"\"{Node}\" y.js", @"C:\Users\me\AppData\Local\Temp\job", [9001])
            .Add(152, 30, Node, $"\"{Node}\" z.js", @"C:\dev\site", [9002]);
        Assert.Equal(new[] { false, true, false }, Scan(t).Select(s => s.IsDevServer));
    }

    [Fact]
    public void AReusedParentPidIsNotTheParent()
    {
        // 160's parent died; pid 30 now belongs to a later process.
        var t = new FakeTable()
            .Add(30, 4, Cmd, $"{Cmd} /c \"node server.js\"", @"C:\Users\me\site", start: 999_999_999)
            .Add(160, 30, Node, $"\"{Node}\" server.js", @"C:\Users\me\site", [3002]);
        Assert.Equal(160, Assert.Single(Scan(t)).Root.Pid);
    }

    [Fact]
    public void AnotherUsersParentIsABoundary()
    {
        var t = new FakeTable().Add(170, 999, Node, $"\"{Node}\" server.js", @"C:\Users\me\site", [3003]);
        var s = Assert.Single(Scan(t));
        Assert.Equal(170, s.Root.Pid);
    }

    [Fact]
    public void ASupervisorIsABoundary()
    {
        const string bash = @"C:\Program Files\Git\usr\bin\bash.exe";
        var t = Terminal()
            .Add(180, 30, bash, $"\"{bash}\" -c \"exec \\\"$@\\\"\" sh npm run dev", @"C:\Users\me\site")
            .Add(181, 180, Node, $"\"{Node}\" \"{NpmCli}\" run dev", @"C:\Users\me\site")
            .Add(182, 181, Node, $"\"{Node}\" server.js", @"C:\Users\me\site", [3004]);
        var s = Assert.Single(Scan(t));
        Assert.Equal(181, s.Root.Pid);
        Assert.Equal("npm run dev", s.Command);
    }

    [Fact]
    public void LocoLocosOwnProcessesAreSkipped()
    {
        var t = new FakeTable { Self = 190 }
            .Add(190, 4, @"C:\Users\me\AppData\Local\Programs\Loco Loco\LocoLoco.exe", "LocoLoco.exe", ports: [49000])
            .Add(191, 190, Cmd, $"{Cmd} /d /s /c \"npm run dev\"", @"C:\Users\me\site", path: UserPath)
            .Add(192, 191, Node, $"\"{Node}\" server.js", @"C:\Users\me\site", [3005]);
        var s = Assert.Single(Scan(t));
        Assert.Equal(191, s.Root.Pid);
        Assert.Equal("npm run dev", s.Command);
        Assert.DoesNotContain(s.Processes, p => p.Pid == 190);
    }

    [Fact]
    public void TreeFollowsTheRootAndChecksItsStartTime()
    {
        var t = Terminal()
            .Add(100, 30, Node, "node a.js")
            .Add(101, 100, Node, "node b.js")
            .Add(102, 101, Node, "node c.js")
            .Add(103, 30, Node, "node d.js");
        Assert.Equal(new[] { 100, 101, 102 }, Scanner.Tree(t, new ProcRef(100, 100_000)).Select(p => p.Pid).Order());
        Assert.Empty(Scanner.Tree(t, new ProcRef(100, 1)));
        Assert.Empty(Scanner.Tree(t, new ProcRef(404, 404_000)));
    }

    [Theory]
    [InlineData(@"""C:\Program Files\nodejs\npm.cmd"" run dev", "npm run dev")]
    [InlineData(@"C:\Python312\python.exe -m http.server", "python -m http.server")]
    [InlineData(@"""C:\Program Files\my tools\x y.exe"" a", @"""C:\Program Files\my tools\x y.exe"" a")]
    [InlineData(@"""C:\Elsewhere\npm.cmd"" run dev", @"""C:\Elsewhere\npm.cmd"" run dev")]
    [InlineData("npm run dev", "npm run dev")]
    [InlineData(@"""C:\Program Files\nodejs\npm.cmd", @"""C:\Program Files\nodejs\npm.cmd")]
    public void TidiesProgramsOnThePath(string line, string tidy) =>
        Assert.Equal(tidy, Scanner.TidyProgram(line, @"C:\Windows;""C:\Program Files\nodejs\"";C:\Python312;C:\Program Files\my tools"));

    [Fact]
    public void TidyNeedsAPath() => Assert.Equal(@"C:\Python312\python.exe x", Scanner.TidyProgram(@"C:\Python312\python.exe x", null));

    [Fact]
    public void DevPlaces()
    {
        Assert.True(Places.IsDevPlace(@"C:\Users\me\site"));
        Assert.True(Places.IsDevPlace(@"c:\users\me\appdata\local\temp"));
        Assert.False(Places.IsDevPlace(@"C:\Users\me\AppData\Local\x"));
        Assert.False(Places.IsDevPlace(Home));
        Assert.False(Places.IsDevPlace(@"C:\dev\site"));
    }
}
