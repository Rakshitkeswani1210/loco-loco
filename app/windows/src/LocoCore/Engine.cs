namespace LocoCore;

/// <summary>What the engine needs from the system. Windows has the real one; tests use a fake.</summary>
public interface IPlatform
{
    /// <summary>Reads the process table. Runs off the UI thread.</summary>
    List<Server> Scan();
    /// <summary>The root and everything under it now. Empty when the root is gone.</summary>
    ProcRef[] Tree(ProcRef root);
    bool Alive(ProcRef p);
    /// <summary>Asks the processes to stop: Ctrl+C, the way a terminal stops them, else a close message.</summary>
    void Interrupt(ProcRef[] procs);
    /// <summary>Ends the processes now.</summary>
    void Kill(ProcRef[] procs);
    /// <summary>Ends a process Loco Loco started and everything under it.</summary>
    void KillTree(int pid);
    bool PortInUse(ushort port);
    bool IsFolder(string path);
    bool FileExists(string path);
    /// <summary>Runs `command` with cmd from `dir`, output appended to `log`. Calls `exited` with a reason when it ends.</summary>
    int Spawn(string command, string dir, string? path, string log, Action<int, string> exited);
}

/// <summary>
/// The servers, the history and what Loco Loco is doing to them. Ported from the Mac's Model.
/// Lives on the UI thread: scans run through `background` and come back through `post`.
/// </summary>
public sealed class Engine
{
    public abstract record Busy(DateTime Since);
    public sealed record Stopping(ProcRef[] Procs, DateTime Since, bool ThenStart, Guid? Entry, ProcRef? AppRoot) : Busy(Since);
    public sealed record Starting(int Pid, DateTime Since) : Busy(Since);

    public static readonly TimeSpan ForceAfter = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan StartTimeout = TimeSpan.FromSeconds(60);
    static readonly TimeSpan SaveEvery = TimeSpan.FromSeconds(60);

    readonly IPlatform platform;
    readonly AppPaths paths;
    readonly Action<Action> post;
    readonly Action<Action> background;
    readonly Func<DateTime> clock;

    readonly Dictionary<string, Busy> busy = [];
    readonly HashSet<string> forced = [];
    readonly Dictionary<int, Guid> spawned = [];
    bool scanning, rescan, firstScan = true, isOpen;
    DateTime lastSave = DateTime.MinValue;

    public Settings Settings { get; }
    public History History { get; }
    public IReadOnlyList<Server> Servers { get; private set; } = [];
    public IReadOnlyDictionary<ProcRef, Guid> Links { get; private set; } = new Dictionary<ProcRef, Guid>();
    public IReadOnlyDictionary<string, Busy> BusyRows => busy;
    public bool Expanded { get; set; }
    /// <summary>Set only by the test hooks, to show just these ports in screenshots.</summary>
    public HashSet<ushort>? OnlyPorts { get; set; }

    /// <summary>The servers or history changed. Rebuild the rows.</summary>
    public event Action? Changed;
    /// <summary>Scan again after this long.</summary>
    public event Action<TimeSpan>? ScheduleRequested;

    public Engine(IPlatform platform, AppPaths paths, Action<Action> post, Action<Action>? background = null, Func<DateTime>? clock = null)
    {
        this.platform = platform;
        this.paths = paths;
        this.post = post;
        this.background = background ?? (a => Task.Run(a));
        this.clock = clock ?? (() => DateTime.UtcNow);
        Settings = Settings.Load(paths.Settings);
        History = new History(History.Load(paths.History), Settings.HistoryLimit);
    }

    public bool IsOpen
    {
        get => isOpen;
        set
        {
            if (value == isOpen) return;
            isOpen = value;
            if (value) ScanNow();
            else Schedule();
        }
    }

    HashSet<Guid> BusyEntries => busy.Keys.Select(k => Guid.TryParse(k, out var g) ? g : Guid.Empty).Where(g => g != Guid.Empty).ToHashSet();

    static string AppId(ProcRef r) => $"app-{r.Pid}-{r.StartMicros}";

    // MARK: Rows

    public Rows BuildRows()
    {
        var rows = new Rows();
        var shown = new HashSet<Guid>();
        var only = OnlyPorts;
        foreach (var s in Servers)
        {
            if (only != null && !only.Contains(s.Port)) continue;
            if (s.IsDevServer && Links.TryGetValue(s.Root, out var id) && History[id] is { } e)
            {
                shown.Add(id);
                rows.Running.Add(new Row
                {
                    Id = id.ToString(), Group = RowGroup.Running, Port = s.Port, Ports = s.Ports, Name = e.Name, Folder = e.ProjectDir,
                    Time = e.StartedAt, State = StateOf(id.ToString()), EntryId = id, Server = s, LogPath = e.LogPath, HasLog = HasLog(e.LogPath),
                });
            }
            else if (Settings.ShowAll && !s.IsDevServer)
            {
                var appId = AppId(s.Root);
                rows.Running.Add(new Row
                {
                    Id = appId, Group = RowGroup.Running, Port = s.Port, Ports = s.Ports, Name = s.Name, Folder = s.ProjectDir,
                    Time = s.StartedAt, State = StateOf(appId), Server = s,
                });
            }
        }
        // Starting, not listening yet: shown in Running with a spinner.
        foreach (var (key, b) in busy)
        {
            if (b is not Starting || !Guid.TryParse(key, out var id) || shown.Contains(id) || History[id] is not { } e) continue;
            if (only != null && !only.Contains(e.Port)) continue;
            rows.Running.Add(new Row
            {
                Id = key, Group = RowGroup.Running, Port = e.Port, Ports = e.Ports, Name = e.Name, Folder = e.ProjectDir,
                Time = e.StartedAt, State = RowState.Starting, EntryId = id, LogPath = e.LogPath, HasLog = HasLog(e.LogPath),
            });
        }
        rows.Running.Sort((a, b) =>
            a.Port != b.Port ? a.Port.CompareTo(b.Port) :
            string.CompareOrdinal(a.Name, b.Name) is var n and not 0 ? n : string.CompareOrdinal(a.Id, b.Id));

        var stopped = History.Stopped.Where(e => !busy.ContainsKey(e.Id.ToString()) && (only == null || only.Contains(e.Port))).ToList();
        rows.StoppedTotal = stopped.Count;
        // A More row that would hide a single entry takes that entry's height, so show it instead.
        int limit = Expanded || stopped.Count <= Rows.ShownStopped + 1 ? stopped.Count : Rows.ShownStopped;
        foreach (var e in stopped.Take(limit))
        {
            rows.Stopped.Add(new Row
            {
                Id = e.Id.ToString(), Group = RowGroup.Stopped, Port = e.Port, Ports = e.Ports, Name = e.Name, Folder = e.ProjectDir,
                Time = e.StoppedAt ?? e.LastSeenAt, Failure = e.Failure, EntryId = e.Id, LogPath = e.LogPath, HasLog = HasLog(e.LogPath),
            });
        }
        return rows;
    }

    bool HasLog(string? path) => path != null && platform.FileExists(path);

    RowState StateOf(string id) => busy.GetValueOrDefault(id) switch
    {
        Stopping => forced.Contains(id) ? RowState.Force : RowState.Stopping,
        Starting => RowState.Starting,
        _ => RowState.Idle,
    };

    /// <summary>Dev servers Stop all would stop. App and Windows servers are left alone.</summary>
    public List<Row> Stoppable => BuildRows().Running.Where(r => r.CanStop && !r.IsApp).ToList();

    /// <summary>Running dev servers, for the icon's count and tooltip.</summary>
    public int RunningCount => Servers.Count(s => s.IsDevServer && Links.ContainsKey(s.Root));

    // MARK: Settings

    public void SetShowCount(bool on) { Settings.ShowCount = on; Settings.Save(paths.Settings); Changed?.Invoke(); }

    public void SetShowAll(bool on) { Settings.ShowAll = on; Settings.Save(paths.Settings); Changed?.Invoke(); }

    public void SetFirstRunDone() { Settings.FirstRunDone = true; Settings.Save(paths.Settings); }

    public void SetHistoryLimit(int n)
    {
        Settings.HistoryLimit = n;
        Settings.Save(paths.Settings);
        History.Limit = n;
        History.Prune(BusyEntries);
        Save();
        Changed?.Invoke();
    }

    public void ClearHistory()
    {
        History.ClearStopped(BusyEntries);
        Expanded = false;
        Save();
        Changed?.Invoke();
    }

    // MARK: Scanning

    public void ScanNow()
    {
        if (scanning) { rescan = true; return; }
        scanning = true;
        background(() =>
        {
            List<Server> found;
            try { found = platform.Scan(); }
            catch (Exception) { found = [.. Servers]; }
            post(() => Finish(found));
        });
    }

    void Finish(List<Server> found)
    {
        scanning = false;
        Apply(found);
        if (rescan)
        {
            rescan = false;
            ScanNow();
        }
        else
        {
            Schedule();
        }
    }

    /// <summary>Quick while something is stopping or starting, every 2 seconds while the flyout is open, else every 10.</summary>
    public TimeSpan Interval => busy.Count > 0 ? TimeSpan.FromSeconds(0.3) : isOpen ? TimeSpan.FromSeconds(2) : TimeSpan.FromSeconds(10);

    void Schedule()
    {
        if (scanning) return;
        ScheduleRequested?.Invoke(Interval);
    }

    internal void Apply(List<Server> found)
    {
        var now = clock();
        var result = History.Reconcile(found, spawned, now, firstScan, BusyEntries);
        firstScan = false;
        Servers = found;
        Links = result.Links;
        bool changed = result.Changed;

        var linked = result.Links.Values.ToHashSet();
        foreach (var (key, b) in busy.ToList())
        {
            switch (b)
            {
                case Stopping st:
                    bool gone = st.Entry is { } entry ? !linked.Contains(entry) : !found.Any(s => s.Root == st.AppRoot);
                    if (gone)
                    {
                        busy.Remove(key);
                        forced.Remove(key);
                        if (st.ThenStart && st.Entry is { } id) Start(id);
                    }
                    else if (!forced.Contains(key) && now - st.Since >= ForceAfter)
                    {
                        forced.Add(key);
                    }
                    break;
                case Starting sp:
                    var sid = Guid.Parse(key);
                    if (linked.Contains(sid))
                    {
                        busy.Remove(key);
                        changed = true;
                    }
                    else if (now - sp.Since >= StartTimeout)
                    {
                        platform.KillTree(sp.Pid);
                        Fail(sid, "Timed out");
                    }
                    break;
            }
        }
        if (changed || (result.Links.Count > 0 && now - lastSave > SaveEvery)) Save();
        Changed?.Invoke();
    }

    public void Save()
    {
        try { History.Save(paths.History); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        lastSave = clock();
    }

    // MARK: Stop and start

    public void Restart(Row row)
    {
        if (row.EntryId is not { } id || !row.CanRestart) return;
        if (row.Group == RowGroup.Running) Stop(row, thenStart: true);
        else Start(id);
    }

    public void Stop(Row row, bool thenStart = false)
    {
        if (busy.ContainsKey(row.Id)) return;
        ProcRef root;
        if (row.EntryId is { } id)
        {
            if (!Links.Values.Contains(id) || History[id]?.Root is not { } r) return;
            root = r;
        }
        else
        {
            if (row.Server == null) return;
            root = row.Server.Root;
            thenStart = false;
        }
        var procs = platform.Tree(root);
        if (procs.Length == 0) { ScanNow(); return; }
        platform.Interrupt(procs);
        busy[row.Id] = new Stopping(procs, clock(), thenStart, row.EntryId, row.EntryId == null ? root : null);
        Changed?.Invoke();
        ScanNow();
    }

    public void StopAll()
    {
        foreach (var row in Stoppable) Stop(row);
    }

    public void ForceStop(string rowId)
    {
        if (busy.GetValueOrDefault(rowId) is not Stopping st) return;
        var all = st.Procs.Where(platform.Alive).ToHashSet();
        var root = st.Entry is { } id ? History[id]?.Root : st.AppRoot;
        if (root is { } r) all.UnionWith(platform.Tree(r));
        platform.Kill([.. all]);
        forced.Remove(rowId);
        busy[rowId] = st with { Procs = [.. all], Since = clock() };
        Changed?.Invoke();
        ScanNow();
    }

    public void Start(Guid id)
    {
        var key = id.ToString();
        if (busy.ContainsKey(key) || History[id] is not { } e) return;
        string dir;
        if (platform.IsFolder(e.CommandDir)) dir = e.CommandDir;
        else if (platform.IsFolder(e.ProjectDir)) dir = e.ProjectDir;
        else { Fail(id, "Folder not found"); return; }
        foreach (var p in e.Ports)
        {
            if (platform.PortInUse(p)) { Fail(id, $"Port {p} in use"); return; }
        }

        var log = paths.LogFor(e.Name);
        int pid;
        try
        {
            pid = platform.Spawn(e.Command, dir, e.Path, log, (p, reason) => post(() => ChildExited(p, reason)));
        }
        catch (Exception)
        {
            Fail(id, "Couldn't start");
            return;
        }
        e.LogPath = log;
        e.Failure = null;
        // Newest of the stopped entries until it links, so pruning can't drop it.
        e.StoppedAt = clock();
        spawned[pid] = id;
        busy[key] = new Starting(pid, clock());
        Save();
        Changed?.Invoke();
        ScanNow();
    }

    void ChildExited(int pid, string reason)
    {
        if (!spawned.Remove(pid, out var id)) return;
        if (busy.GetValueOrDefault(id.ToString()) is Starting) Fail(id, reason);
        ScanNow();
    }

    /// <summary>Moves the entry to the top of Stopped with the reason in red.</summary>
    void Fail(Guid id, string reason)
    {
        busy.Remove(id.ToString());
        if (History[id] is { } e)
        {
            e.Failure = reason;
            e.StoppedAt = clock();
            Save();
        }
        Changed?.Invoke();
    }
}
