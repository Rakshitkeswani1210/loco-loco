namespace LocoCore.Tests;

/// <summary>Ported from the Mac's HistoryTests, with Windows paths.</summary>
public class HistoryTests
{
    static readonly DateTime T0 = DateTime.UnixEpoch.AddSeconds(1_790_000_000);

    internal static ProcRef Proc(int pid) => new(pid, (ulong)pid * 1000);

    internal static Server Server(
        int root, int[]? children = null, ushort port = 3000, string command = "npm run dev",
        string dir = @"C:\Users\me\site", string project = @"C:\Users\me\site", string name = "site", bool dev = true) => new()
    {
        Root = Proc(root),
        StartedAt = T0,
        Ports = [port],
        Name = name,
        ProjectDir = project,
        Command = command,
        CommandDir = dir,
        IsDevServer = dev,
        Processes = [Proc(root), .. (children ?? []).Select(Proc)],
    };

    [Fact]
    public void KeepsTheEntryWhenTheRootShellExitsFirst()
    {
        var h = new History();
        var shell = Server(10, [11, 12], 4193, @"cd /d C:\Users\me\site && npx vite preview");
        var id = h.Reconcile([shell], now: T0).Links[Proc(10)];

        // The shell is gone; npx (11) is now the top of the chain, with a different command line.
        var orphan = Server(11, [12], 4193, "npx vite preview");
        var links = h.Reconcile([orphan], now: T0.AddSeconds(2)).Links;
        Assert.Equal(id, links[Proc(11)]);
        Assert.Single(h.Entries);
        Assert.Equal(@"cd /d C:\Users\me\site && npx vite preview", h.Entries[0].Command);
        Assert.True(h.Entries[0].IsRunning);
    }

    [Fact]
    public void SameProjectAndPortWithANewCommandReusesTheEntry()
    {
        var h = new History();
        h.Reconcile([Server(20, port: 8094, command: "npx -y http-server -p 8094")], now: T0);
        h.Reconcile([], now: T0.AddSeconds(10));
        Assert.Single(h.Stopped);

        h.Reconcile([Server(30, port: 8094, command: "node http-server -p 8094 -s")], now: T0.AddSeconds(20));
        Assert.Single(h.Entries);
        Assert.Empty(h.Stopped);
        Assert.Equal("node http-server -p 8094 -s", h.Entries[0].Command);
    }

    [Fact]
    public void SameCommandOnAnotherPortReusesTheEntry()
    {
        var h = new History();
        h.Reconcile([Server(40, port: 5173)], now: T0);
        h.Reconcile([], now: T0.AddSeconds(10));
        h.Reconcile([Server(41, port: 5174)], now: T0.AddSeconds(20));
        Assert.Single(h.Entries);
        Assert.Equal(5174, h.Entries[0].Port);
    }

    [Fact]
    public void FoldersMatchWithoutCase()
    {
        var h = new History();
        h.Reconcile([Server(42, port: 5173, dir: @"C:\Users\me\Site")], now: T0);
        h.Reconcile([], now: T0.AddSeconds(10));
        h.Reconcile([Server(43, port: 5173, dir: @"c:\users\me\site")], now: T0.AddSeconds(20));
        Assert.Single(h.Entries);
    }

    [Fact]
    public void PruneDropsStoppedCopiesOfRunningAndOlderServers()
    {
        var a = new HistoryEntry(Server(50, port: 8094, command: "a"), T0);
        var b = new HistoryEntry(Server(51, port: 8094, command: "b"), T0) { StoppedAt = T0.AddSeconds(5) };
        var c = new HistoryEntry(Server(52, port: 4193, command: "c", project: @"C:\Users\me\q"), T0) { StoppedAt = T0.AddSeconds(1) };
        var d = new HistoryEntry(Server(53, port: 4193, command: "d", project: @"C:\Users\me\q"), T0) { StoppedAt = T0.AddSeconds(2) };
        var h = new History([a, b, c, d]);
        Assert.True(h.Prune());
        Assert.Equal(new[] { a.Id, d.Id }.Order(), h.Entries.Select(e => e.Id).Order());
    }

    [Fact]
    public void PruneKeepsEntriesBeingStarted()
    {
        var running = new HistoryEntry(Server(60, port: 8094, command: "a"), T0);
        var starting = new HistoryEntry(Server(61, port: 8094, command: "b"), T0) { StoppedAt = T0.AddSeconds(5) };
        var h = new History([running, starting]);
        Assert.False(h.Prune(new HashSet<Guid> { starting.Id }));
        Assert.Equal(2, h.Entries.Count);
    }

    [Fact]
    public void PruneKeepsTheNewestUpToTheLimit()
    {
        var entries = Enumerable.Range(0, 5).Select(i =>
            new HistoryEntry(Server(70 + i, port: (ushort)(3000 + i), command: "s" + i), T0) { StoppedAt = T0.AddSeconds(i) });
        var h = new History(entries, limit: 3);
        h.Prune();
        Assert.Equal(new ushort[] { 3004, 3003, 3002 }, h.Stopped.Select(e => e.Port));
    }

    [Fact]
    public void HistoryFilesWithoutProcsStillLoad()
    {
        var file = Path.Combine(Path.GetTempPath(), $"loco-test-{Guid.NewGuid()}.json");
        try
        {
            var e = new HistoryEntry(Server(80, port: 3000, command: "x"), T0) { Procs = null };
            new History([e]).Save(file);
            Assert.DoesNotContain("procs", File.ReadAllText(file));
            Assert.Single(History.Load(file));
        }
        finally { File.Delete(file); }
    }

    [Fact]
    public void SavedFilesRoundTripAndMatchTheMacShape()
    {
        var file = Path.Combine(Path.GetTempPath(), $"loco-test-{Guid.NewGuid()}.json");
        try
        {
            var e = new HistoryEntry(Server(81, [82], 8000, "python -m http.server 8000"), T0.AddMilliseconds(123))
            {
                StoppedAt = T0.AddSeconds(9), Failure = "Port 8000 in use", LogPath = @"C:\Users\me\AppData\Local\Loco Loco\Logs\site.log",
                Path = @"C:\Windows;C:\Python",
            };
            new History([e]).Save(file);
            var text = File.ReadAllText(file);
            Assert.Contains("\"version\": 1", text);
            Assert.Contains("\"lastSeenAt\": \"2026-09-21T", text);
            Assert.Contains(".123Z\"", text);
            Assert.Contains(e.Id.ToString().ToUpperInvariant(), text);
            Assert.True(text.IndexOf("\"command\"") < text.IndexOf("\"commandDir\"") && text.IndexOf("\"commandDir\"") < text.IndexOf("\"failure\""));

            var back = Assert.Single(History.Load(file));
            Assert.Equal(e.Id, back.Id);
            Assert.Equal(e.Command, back.Command);
            Assert.Equal(e.Path, back.Path);
            Assert.Equal(e.Ports, back.Ports);
            Assert.Equal(e.LastSeenAt, back.LastSeenAt);
            Assert.Equal(e.StoppedAt, back.StoppedAt);
            Assert.Equal(e.Root, back.Root);
            Assert.Equal(e.Procs, back.Procs);
            Assert.Equal(e.Failure, back.Failure);
        }
        finally { File.Delete(file); }
    }

    [Fact]
    public void ABadEntryIsSkippedAndAMissingFileGivesNone()
    {
        var file = Path.Combine(Path.GetTempPath(), $"loco-test-{Guid.NewGuid()}.json");
        try
        {
            var good = new HistoryEntry(Server(90), T0) { StoppedAt = T0 };
            new History([good]).Save(file);
            var text = File.ReadAllText(file).Replace("\"entries\": [", "\"entries\": [ { \"name\": \"broken\" },");
            File.WriteAllText(file, text);
            Assert.Equal(good.Id, Assert.Single(History.Load(file)).Id);
        }
        finally { File.Delete(file); }
        Assert.Empty(History.Load(file));
    }

    [Fact]
    public void RunningEntriesMissingAtTheFirstScanStopWhenTheyWereLastSeen()
    {
        var e = new HistoryEntry(Server(95), T0);
        var h = new History([e]);
        h.Reconcile([], now: T0.AddHours(3), firstScan: true);
        Assert.Equal(T0, h.Entries[0].StoppedAt);
    }
}
