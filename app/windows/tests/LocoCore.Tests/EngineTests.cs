namespace LocoCore.Tests;

/// <summary>Servers held in a list. Stopping removes them unless they ignore Ctrl+C.</summary>
sealed class FakePlatform : IPlatform
{
    public readonly List<Server> Running = [];
    public int Scans;
    public bool ThrowOnScan, IgnoreInterrupt, SpawnThrows;
    public readonly List<ProcRef[]> Interrupted = [], Killed = [];
    public readonly List<int> KilledTrees = [];
    public readonly HashSet<ushort> TakenPorts = [];
    public readonly HashSet<string> Folders = new(StringComparer.OrdinalIgnoreCase) { @"C:\Users\me\site" };
    public readonly HashSet<string> Files = [];
    public readonly List<(string Command, string Dir, string? Path, string Log)> Spawns = [];
    public Action<int, string>? Exited;
    int nextPid = 500;

    public List<Server> Scan()
    {
        Scans++;
        if (ThrowOnScan) throw new InvalidOperationException("scan failed");
        return [.. Running];
    }

    public ProcRef[] Tree(ProcRef root) => Running.FirstOrDefault(s => s.Root == root)?.Processes ?? [];
    public bool Alive(ProcRef p) => Running.Any(s => s.Processes.Contains(p));

    public void Interrupt(ProcRef[] procs)
    {
        Interrupted.Add(procs);
        if (!IgnoreInterrupt) Running.RemoveAll(s => procs.Contains(s.Root));
    }

    public void Kill(ProcRef[] procs)
    {
        Killed.Add(procs);
        Running.RemoveAll(s => procs.Contains(s.Root));
    }

    public void KillTree(int pid) => KilledTrees.Add(pid);
    public bool PortInUse(ushort port) => TakenPorts.Contains(port) || Running.Any(s => s.Ports.Contains(port));
    public bool IsFolder(string path) => Folders.Contains(path);
    public bool FileExists(string path) => Files.Contains(path);

    public int Spawn(string command, string dir, string? path, string log, Action<int, string> exited)
    {
        if (SpawnThrows) throw new IOException("Couldn't start");
        Spawns.Add((command, dir, path, log));
        Exited = exited;
        return nextPid++;
    }
}

/// <summary>An engine on a fake platform and clock. Posted work waits in a queue until Pump.</summary>
sealed class Rig : IDisposable
{
    public static readonly DateTime T0 = DateTime.UnixEpoch.AddSeconds(1_790_000_000);
    public readonly FakePlatform P = new();
    public readonly AppPaths Paths = new(Path.Combine(Path.GetTempPath(), "loco-engine-" + Guid.NewGuid().ToString("N")));
    readonly Queue<Action> queue = new();
    public DateTime Now = T0;
    public readonly List<TimeSpan> Schedules = [];
    Engine? engine;

    public Rig(params HistoryEntry[] saved)
    {
        if (saved.Length > 0) new History(saved).Save(Paths.History);
    }

    public Engine E => engine ??= Make();

    public Engine Make()
    {
        var e = new Engine(P, Paths, queue.Enqueue, queue.Enqueue, () => Now);
        e.ScheduleRequested += Schedules.Add;
        return e;
    }

    public void Pump()
    {
        for (int i = 0; queue.Count > 0; i++)
        {
            if (i > 1000) throw new InvalidOperationException("Runaway scans");
            queue.Dequeue()();
        }
    }

    public Rows Scan()
    {
        E.ScanNow();
        Pump();
        return E.BuildRows();
    }

    public Row Row(ushort port)
    {
        var rows = E.BuildRows();
        return rows.Running.Concat(rows.Stopped).First(r => r.Port == port);
    }

    public void Dispose()
    {
        if (Directory.Exists(Paths.Folder)) Directory.Delete(Paths.Folder, recursive: true);
    }
}

public class EngineTests
{
    static readonly DateTime T0 = Rig.T0;

    static Server Site(int root = 10, ushort port = 3000, string command = "npm run dev") =>
        HistoryTests.Server(root, [root + 1], port, command);

    static Server App(int root = 20, ushort port = 2375) =>
        HistoryTests.Server(root, null, port, "com.docker.backend.exe", @"C:\Program Files\Docker", @"C:\Program Files\Docker", "Docker Desktop", dev: false);

    static HistoryEntry StoppedEntry(int i, string dir = @"C:\Users\me\site") =>
        new(HistoryTests.Server(100 + i, null, (ushort)(4000 + i), "s" + i, dir, dir), T0) { StoppedAt = T0.AddSeconds(i) };

    [Fact]
    public void ARunningDevServerGetsARowAndIsSaved()
    {
        using var r = new Rig();
        r.P.Running.Add(Site());
        var row = Assert.Single(r.Scan().Running);
        Assert.Equal(("site", RowGroup.Running, RowState.Idle), (row.Name, row.Group, row.State));
        Assert.Equal(new[] { RowAction.Stop }, row.Actions);
        Assert.True(row.CanRestart);
        Assert.False(row.IsApp);
        Assert.Equal(1, r.E.RunningCount);
        Assert.StartsWith("site, port 3000, running since ", row.AccessibleName(r.Now));
        Assert.Single(History.Load(r.Paths.History));
        Assert.Equal(TimeSpan.FromSeconds(10), r.Schedules[^1]);
    }

    [Fact]
    public void AppServersShowOnlyWhenAskedAndNeverRestart()
    {
        using var r = new Rig();
        r.P.Running.AddRange([Site(), App()]);
        Assert.Single(r.Scan().Running);

        r.E.SetShowAll(true);
        var rows = r.E.BuildRows();
        Assert.Equal(new ushort[] { 2375, 3000 }, rows.Running.Select(x => x.Port));
        var app = rows.Running[0];
        Assert.True(app.IsApp);
        Assert.Equal("app-20-20000", app.Id);
        Assert.False(app.CanRestart);
        Assert.Equal(new[] { RowAction.Stop }, app.Actions);
        Assert.Single(r.E.Stoppable);
        Assert.Equal(1, r.E.RunningCount);
        Assert.Single(r.E.History.Entries);
    }

    [Fact]
    public void StopMovesTheServerToStopped()
    {
        using var r = new Rig();
        r.P.Running.Add(Site());
        r.Scan();
        r.E.Stop(r.Row(3000));

        var during = Assert.Single(r.E.BuildRows().Running);
        Assert.Equal(RowState.Stopping, during.State);
        Assert.Empty(during.Actions);
        Assert.Equal(TimeSpan.FromSeconds(0.3), r.E.Interval);
        Assert.Equal(new[] { new ProcRef(10, 10_000), new ProcRef(11, 11_000) }, Assert.Single(r.P.Interrupted));

        r.Now = T0.AddSeconds(1);
        r.Pump();
        var rows = r.E.BuildRows();
        Assert.Empty(rows.Running);
        var stopped = Assert.Single(rows.Stopped);
        Assert.Equal(r.Now, stopped.Time);
        Assert.Equal(new[] { RowAction.Restart }, stopped.Actions);
        Assert.Equal(r.Now, Assert.Single(History.Load(r.Paths.History)).StoppedAt);
        Assert.Equal(TimeSpan.FromSeconds(10), r.E.Interval);
    }

    [Fact]
    public void AServerThatIgnoresCtrlCOffersForceStopAfterFiveSeconds()
    {
        using var r = new Rig();
        r.P.IgnoreInterrupt = true;
        r.P.Running.Add(Site());
        r.Scan();
        r.E.Stop(r.Row(3000));
        r.Pump();
        r.Now = T0.AddSeconds(4.9);
        Assert.Equal(RowState.Stopping, Assert.Single(r.Scan().Running).State);

        r.Now = T0.AddSeconds(5);
        var row = Assert.Single(r.Scan().Running);
        Assert.Equal(RowState.Force, row.State);
        Assert.Equal(new[] { RowAction.Force }, row.Actions);
        Assert.Contains("force stop available", row.AccessibleName(r.Now));

        r.E.ForceStop(row.Id);
        Assert.Equal(new[] { new ProcRef(10, 10_000), new ProcRef(11, 11_000) }, Assert.Single(r.P.Killed).OrderBy(p => p.Pid));
        r.Pump();
        Assert.Single(r.E.BuildRows().Stopped);
        Assert.Empty(r.E.BusyRows);
    }

    [Fact]
    public void RestartStopsStartsAndLinksTheNewProcess()
    {
        using var r = new Rig();
        r.P.Running.Add(Site());
        r.Scan();
        var id = r.Row(3000).EntryId;

        r.E.Restart(r.Row(3000));
        r.Pump();
        var spawn = Assert.Single(r.P.Spawns);
        Assert.Equal(("npm run dev", @"C:\Users\me\site", r.Paths.LogFor("site")), (spawn.Command, spawn.Dir, spawn.Log));
        var rows = r.E.BuildRows();
        var starting = Assert.Single(rows.Running);
        Assert.Equal((RowState.Starting, id), (starting.State, starting.EntryId));
        Assert.Empty(rows.Stopped);
        Assert.Equal("site, port 3000, starting", starting.AccessibleName(r.Now));

        // The cmd Loco Loco started (500) is the new server's root.
        r.P.Running.Add(Site(500));
        var up = Assert.Single(r.Scan().Running);
        Assert.Equal((RowState.Idle, id, 500), (up.State, up.EntryId, up.Server!.Root.Pid));
        Assert.Single(r.E.History.Entries);
        Assert.Empty(r.E.BusyRows);
    }

    [Fact]
    public void RestartingAStoppedServerStartsItFromItsFolder()
    {
        var e = StoppedEntry(0, @"C:\Users\me\site\dist");
        e.ProjectDir = @"C:\Users\me\site";
        using var r = new Rig(e);
        var row = Assert.Single(r.Scan().Stopped);
        r.E.Restart(row);
        Assert.Equal(@"C:\Users\me\site", Assert.Single(r.P.Spawns).Dir);
        Assert.Equal(RowState.Starting, Assert.Single(r.E.BuildRows().Running).State);
    }

    [Fact]
    public void AMissingFolderFailsToStart()
    {
        using var r = new Rig(StoppedEntry(0, @"C:\Users\me\gone"));
        r.E.Restart(Assert.Single(r.Scan().Stopped));
        var row = Assert.Single(r.E.BuildRows().Stopped);
        Assert.Equal("Folder not found", row.Failure);
        Assert.Equal(new[] { RowAction.Restart }, row.Actions);
        Assert.Equal("site, port 4000, didn't start: Folder not found", row.AccessibleName(r.Now));
        Assert.Empty(r.P.Spawns);
    }

    [Fact]
    public void ATakenPortFailsToStart()
    {
        using var r = new Rig(StoppedEntry(0));
        r.P.TakenPorts.Add(4000);
        r.E.Restart(Assert.Single(r.Scan().Stopped));
        Assert.Equal("Port 4000 in use", Assert.Single(r.E.BuildRows().Stopped).Failure);
    }

    [Fact]
    public void ASpawnErrorFailsToStart()
    {
        using var r = new Rig(StoppedEntry(0));
        r.P.SpawnThrows = true;
        r.E.Restart(Assert.Single(r.Scan().Stopped));
        Assert.Equal("Couldn't start", Assert.Single(r.E.BuildRows().Stopped).Failure);
    }

    [Fact]
    public void AServerThatExitsShowsWhyAndItsLog()
    {
        using var r = new Rig(StoppedEntry(0));
        r.E.Restart(Assert.Single(r.Scan().Stopped));
        r.P.Files.Add(r.Paths.LogFor("site"));
        r.Now = T0.AddMinutes(5);
        r.P.Exited!(500, "Exited with code 1");
        r.Pump();
        var row = Assert.Single(r.E.BuildRows().Stopped);
        Assert.Equal("Exited with code 1", row.Failure);
        Assert.Equal(r.Now, row.Time);
        Assert.Equal(new[] { RowAction.Log, RowAction.Restart }, row.Actions);
        Assert.Equal("Exited with code 1", Assert.Single(History.Load(r.Paths.History)).Failure);
    }

    [Fact]
    public void AServerThatNeverListensTimesOut()
    {
        using var r = new Rig(StoppedEntry(0));
        r.E.Restart(Assert.Single(r.Scan().Stopped));
        r.Now = T0.AddSeconds(59);
        r.Scan();
        Assert.Empty(r.P.KilledTrees);
        r.Now = T0.AddSeconds(60);
        r.Scan();
        Assert.Equal(new[] { 500 }, r.P.KilledTrees);
        Assert.Equal("Timed out", Assert.Single(r.E.BuildRows().Stopped).Failure);
    }

    [Fact]
    public void ASuccessfulStartClearsTheLastFailure()
    {
        var e = StoppedEntry(0);
        e.Failure = "Port 4000 in use";
        using var r = new Rig(e);
        r.E.Restart(Assert.Single(r.Scan().Stopped));
        r.P.Running.Add(HistoryTests.Server(500, null, 4000, "s0"));
        Assert.Null(Assert.Single(r.Scan().Running).Failure);
        Assert.Null(r.E.History.Entries[0].Failure);
    }

    [Fact]
    public void StoppedShowsFiveOrAllWhenThereAreSix()
    {
        using var six = new Rig(Enumerable.Range(0, 6).Select(i => StoppedEntry(i)).ToArray());
        var rows6 = six.Scan();
        Assert.Equal(6, rows6.Stopped.Count);
        Assert.False(rows6.HasMore);

        using var seven = new Rig(Enumerable.Range(0, 7).Select(i => StoppedEntry(i)).ToArray());
        var rows7 = seven.Scan();
        Assert.Equal(5, rows7.Stopped.Count);
        Assert.Equal(7, rows7.StoppedTotal);
        Assert.Equal(new ushort[] { 4006, 4005, 4004, 4003, 4002 }, rows7.Stopped.Select(x => x.Port));
        Assert.Equal(Rows.More, rows7.Order[^1]);

        seven.E.Expanded = true;
        Assert.Equal(7, seven.E.BuildRows().Stopped.Count);
    }

    [Fact]
    public void ServersRunningWhileLocoLocoWasClosedStopWhenLastSeen()
    {
        var e = new HistoryEntry(Site(), T0.AddMinutes(-30));
        using var r = new Rig(e);
        r.Now = T0.AddHours(2);
        Assert.Equal(T0.AddMinutes(-30), Assert.Single(r.Scan().Stopped).Time);
    }

    [Fact]
    public void ScansAreQuickWhileBusyAndOpen()
    {
        using var r = new Rig();
        r.Scan();
        Assert.Equal(TimeSpan.FromSeconds(10), r.Schedules[^1]);
        r.E.IsOpen = true;
        r.Pump();
        Assert.Equal(TimeSpan.FromSeconds(2), r.Schedules[^1]);
        r.E.IsOpen = false;
        Assert.Equal(TimeSpan.FromSeconds(10), r.Schedules[^1]);
    }

    [Fact]
    public void AScanAskedForMidScanRunsAfterIt()
    {
        using var r = new Rig();
        r.E.ScanNow();
        r.E.ScanNow();
        r.E.ScanNow();
        r.Pump();
        Assert.Equal(2, r.P.Scans);
    }

    [Fact]
    public void AFailedScanKeepsTheLastServers()
    {
        using var r = new Rig();
        r.P.Running.Add(Site());
        r.Scan();
        r.P.ThrowOnScan = true;
        Assert.Single(r.Scan().Running);
    }

    [Fact]
    public void StopAllStopsDevServersOnly()
    {
        using var r = new Rig();
        r.P.Running.AddRange([Site(10, 3000, "a"), Site(30, 3001, "b"), App()]);
        r.Scan();
        r.E.SetShowAll(true);
        r.E.StopAll();
        Assert.Equal(2, r.P.Interrupted.Count);
        r.Pump();
        Assert.Equal("Docker Desktop", Assert.Single(r.E.BuildRows().Running).Name);
        Assert.Equal(2, r.E.BuildRows().Stopped.Count);
    }

    [Fact]
    public void StoppingAnAppServerLeavesNoHistory()
    {
        using var r = new Rig();
        r.P.Running.Add(App());
        r.Scan();
        r.E.SetShowAll(true);
        r.E.Stop(r.Row(2375));
        Assert.Equal(RowState.Stopping, r.Row(2375).State);
        r.Pump();
        var rows = r.E.BuildRows();
        Assert.Empty(rows.Running);
        Assert.Empty(rows.Stopped);
        Assert.Empty(r.E.BusyRows);
    }

    [Fact]
    public void ClearHistoryKeepsRunningServers()
    {
        using var r = new Rig(StoppedEntry(1), StoppedEntry(2));
        r.P.Running.Add(Site());
        r.Scan();
        r.E.ClearHistory();
        var rows = r.E.BuildRows();
        Assert.Single(rows.Running);
        Assert.Empty(rows.Stopped);
        Assert.Single(History.Load(r.Paths.History));
    }

    [Fact]
    public void SettingsPersist()
    {
        using var r = new Rig(StoppedEntry(1), StoppedEntry(2), StoppedEntry(3));
        r.Scan();
        r.E.SetHistoryLimit(1);
        r.E.SetShowCount(false);
        r.E.SetShowAll(true);
        r.E.SetFirstRunDone();
        Assert.Equal(4003, Assert.Single(r.E.BuildRows().Stopped).Port);

        var again = r.Make();
        Assert.Equal((1, false, true, true), (again.Settings.HistoryLimit, again.Settings.ShowCount, again.Settings.ShowAll, again.Settings.FirstRunDone));
        Assert.Equal(1, again.History.Limit);
        Assert.Single(again.History.Entries);
    }

    [Fact]
    public void OnlyPortsLimitsTheRows()
    {
        using var r = new Rig(StoppedEntry(1));
        r.P.Running.AddRange([Site(10, 3000, "a"), Site(30, 3001, "b")]);
        r.Scan();
        r.E.OnlyPorts = [3001];
        var rows = r.E.BuildRows();
        Assert.Equal(3001, Assert.Single(rows.Running).Port);
        Assert.Empty(rows.Stopped);
    }
}
