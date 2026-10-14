using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.Versioning;

namespace LocoCore.Tests;

/// <summary>Records what the engine starts, so the tests can end exactly those processes.</summary>
[SupportedOSPlatform("windows")]
sealed class RecordingPlatform(WindowsPlatform real) : IPlatform
{
    public readonly ConcurrentBag<ProcRef> Started = [];
    public List<Server> Scan() => real.Scan();
    public ProcRef[] Tree(ProcRef root) => real.Tree(root);
    public bool Alive(ProcRef p) => real.Alive(p);
    public void Interrupt(ProcRef[] procs) => real.Interrupt(procs);
    public void Kill(ProcRef[] procs) => real.Kill(procs);
    public void KillTree(int pid) => real.KillTree(pid);
    public bool PortInUse(ushort port) => real.PortInUse(port);
    public bool IsFolder(string path) => real.IsFolder(path);
    public bool FileExists(string path) => real.FileExists(path);

    public int Spawn(string command, string dir, string? path, string log, Action<int, string> exited)
    {
        int pid = real.Spawn(command, dir, path, log, exited);
        if (new WinProcTable(listeners: false).Processes.TryGetValue(pid, out var info)) Started.Add(info.Ref);
        return pid;
    }
}

/// <summary>
/// Real servers on a real Windows PC: Python and Node, in folders under %USERPROFILE%\loco-it.
/// The tests stop only processes they started.
/// </summary>
[SupportedOSPlatform("windows")]
[Collection("Real servers")]
public sealed class IntegrationTests : IDisposable
{
    readonly string root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "loco-it", Guid.NewGuid().ToString("N")[..8]);
    readonly ConcurrentQueue<Action> posted = new();
    readonly List<Process> byHand = [];
    RecordingPlatform? platform;
    Engine? engine;

    AppPaths Paths => new(Path.Combine(root, "app"));
    /// <summary>loco-scan sends Ctrl+C for the tests, as the app sends its own; it's copied here as a project reference.</summary>
    static readonly string Helper = Path.Combine(AppContext.BaseDirectory, "loco-scan.exe");

    RecordingPlatform Platform => platform ??= new RecordingPlatform(new WindowsPlatform(Helper));
    Engine E => engine ??= new Engine(Platform, Paths, posted.Enqueue, a => a());

    string Folder(string name)
    {
        var dir = Path.Combine(root, name);
        Directory.CreateDirectory(dir);
        return dir;
    }

    static ushort FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        var port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return (ushort)port;
    }

    /// <summary>Started the way a person would, with its own hidden console, so Ctrl+C reaches only it.</summary>
    Process StartByHand(string dir, string file, Dictionary<string, string>? env, params string[] args)
    {
        var psi = new ProcessStartInfo(file) { WorkingDirectory = dir, UseShellExecute = false, CreateNoWindow = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        if (env != null) foreach (var (k, v) in env) psi.Environment[k] = v;
        var p = Process.Start(psi)!;
        byHand.Add(p);
        return p;
    }

    void Pump()
    {
        while (posted.TryDequeue(out var a)) a();
    }

    Row? Find(ushort port)
    {
        var rows = E.BuildRows();
        return rows.Running.FirstOrDefault(r => r.Port == port) ?? rows.Stopped.FirstOrDefault(r => r.Port == port);
    }

    /// <summary>Scans until `ok`, up to `seconds`.</summary>
    void Until(Func<bool> ok, string what, int seconds = 15)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds);
        while (true)
        {
            Pump();
            E.ScanNow();
            Pump();
            if (ok()) return;
            if (DateTime.UtcNow > end) throw new TimeoutException($"Waited {seconds}s for {what}");
            Thread.Sleep(250);
        }
    }

    /// <summary>Reads a log the server still has open for writing, as a text editor would.</summary>
    static string ReadShared(string path)
    {
        using var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        return new StreamReader(f).ReadToEnd();
    }

    Row Running(ushort port)
    {
        Until(() => Find(port) is { Group: RowGroup.Running, State: RowState.Idle }, $"a server on port {port}");
        return Find(port)!;
    }

    [WindowsFact]
    public void ReadsAnotherProcesssCommandFolderAndEnvironment()
    {
        var dir = Folder("py-site");
        var port = FreePort();
        var p = StartByHand(dir, "python", new() { ["LOCO_IT"] = "octopus" }, "-m", "http.server", port.ToString(), "--bind", "127.0.0.1");
        Until(() => new WinProcTable().Listeners.TryGetValue(p.Id, out var ports) && ports.Contains(port), "python to listen");

        var t = new WinProcTable();
        Assert.Equal(Environment.ProcessId, t.Processes[p.Id].Ppid);
        Assert.EndsWith("python.exe", t.Exe(p.Id), StringComparison.OrdinalIgnoreCase);
        Assert.Equal(["-m", "http.server", port.ToString(), "--bind", "127.0.0.1"], t.Command(p.Id).Argv[1..]);
        Assert.Equal(dir, t.Cwd(p.Id), ignoreCase: true);
        Assert.Equal("octopus", t.Env(p.Id, "loco_it"));
        Assert.NotNull(t.Env(p.Id, "PATH"));
        Assert.Equal(p.StartTime.ToUniversalTime(), t.Processes[p.Id].StartDate, TimeSpan.FromSeconds(1));
    }

    [WindowsFact]
    public void SeesAServerAndStopsItWithCtrlC()
    {
        var dir = Folder("py-site");
        var port = FreePort();
        var p = StartByHand(dir, "python", null, "-m", "http.server", port.ToString(), "--bind", "127.0.0.1");
        var row = Running(port);
        Assert.Equal("py-site", row.Name);
        Assert.Equal(dir, row.Folder, ignoreCase: true);
        Assert.Equal(p.Id, row.Server!.Root.Pid);
        Assert.Equal(1, E.History.Entries.Count(e => e.Port == port));

        E.Stop(row);
        Until(() => p.HasExited && !WinLauncher.PortInUse(port), "Ctrl+C to stop python");
        Until(() => Find(port) is { Group: RowGroup.Stopped }, "the row to move to Stopped");
        Assert.Contains(History.Load(Paths.History), e => e.Port == port && e.StoppedAt != null);
    }

    [WindowsFact]
    public void RestartRunsTheServerAgainWithALog()
    {
        var dir = Folder("node-site");
        File.WriteAllText(Path.Combine(dir, "package.json"), "{ \"name\": \"node-site\", \"private\": true }");
        File.WriteAllText(Path.Combine(dir, "server.js"),
            "const port = Number(process.argv[2]);\n" +
            "require('http').createServer((q, s) => s.end('ok')).listen(port, '127.0.0.1', () => console.log('listening on ' + port));\n");
        var port = FreePort();
        var p = StartByHand(dir, "node", null, "server.js", port.ToString());
        var row = Running(port);
        Assert.Equal("node-site", row.Name);
        Assert.EndsWith($"server.js {port}", E.History[row.EntryId!.Value]!.Command);

        E.Restart(row);
        Until(() => p.HasExited, "the first node to stop");
        Until(() => Find(port) is { Group: RowGroup.Running, State: RowState.Idle } r && r.Server!.Root.Pid != p.Id, "node to run again");
        var again = Find(port)!;
        Assert.Equal(row.EntryId, again.EntryId);
        Assert.True(WinLauncher.PortInUse(port));

        var log = Paths.LogFor("node-site");
        Until(() => File.Exists(log) && ReadShared(log).Contains("listening on " + port), "the log");
        var text = ReadShared(log);
        Assert.Contains("[Loco Loco]", text);
        Assert.Contains("$ " + E.History[row.EntryId!.Value]!.Command, text);

        // Loco Loco's servers have their own console, so Ctrl+C stops them too.
        E.Stop(again);
        Until(() => !WinLauncher.PortInUse(port) && Find(port) is { Group: RowGroup.Stopped }, "the restarted node to stop");
    }

    [WindowsFact]
    public void ABadCommandShowsItsExitCode()
    {
        var dir = Folder("bad-site");
        var port = FreePort();
        var entry = new HistoryEntry
        {
            Id = Guid.NewGuid(), Name = "bad-site", ProjectDir = dir, Command = "exit /b 3", CommandDir = dir, Ports = [port],
            StartedAt = DateTime.UtcNow.AddMinutes(-5), StoppedAt = DateTime.UtcNow.AddMinutes(-1), LastSeenAt = DateTime.UtcNow.AddMinutes(-1),
        };
        new History([entry]).Save(Paths.History);

        E.Start(entry.Id);
        Until(() => E.History[entry.Id]!.Failure != null, "the start to fail");
        Assert.Equal("Exited with code 3", E.History[entry.Id]!.Failure);
        var row = Find(port)!;
        Assert.Equal(RowGroup.Stopped, row.Group);
        Assert.Equal(new[] { RowAction.Log, RowAction.Restart }, row.Actions);
    }

    [WindowsFact]
    public void AServerThatIgnoresCtrlCNeedsForceStop()
    {
        var dir = Folder("stubborn");
        var port = FreePort();
        var p = StartByHand(dir, "python", null, "-c",
            "import signal, http.server as h\n" +
            "signal.signal(signal.SIGINT, signal.SIG_IGN)\n" +
            $"h.ThreadingHTTPServer(('127.0.0.1', {port}), h.SimpleHTTPRequestHandler).serve_forever()\n");
        var row = Running(port);

        E.Stop(row);
        for (int i = 0; i < 8; i++)
        {
            Thread.Sleep(250);
            Pump();
            E.ScanNow();
            Pump();
        }
        Assert.False(p.HasExited);
        Assert.Equal(RowState.Stopping, Find(port)!.State);

        E.ForceStop(row.Id);
        Until(() => p.HasExited && Find(port) is { Group: RowGroup.Stopped }, "force stop");
        Assert.False(WinLauncher.PortInUse(port));
    }

    public void Dispose()
    {
        foreach (var p in byHand)
        {
            try { if (!p.HasExited) p.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            p.Dispose();
        }
        if (platform != null)
        {
            var table = new WinProcTable(listeners: false);
            foreach (var r in platform.Started) Stopper.Kill(Scanner.Tree(table, r));
        }
        for (int i = 0; i < 10 && Directory.Exists(root); i++)
        {
            try { Directory.Delete(root, recursive: true); }
            catch (IOException) { Thread.Sleep(300); }
            catch (UnauthorizedAccessException) { Thread.Sleep(300); }
        }
    }
}
