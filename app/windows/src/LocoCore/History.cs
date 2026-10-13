using System.Globalization;
using System.Text.Json;

namespace LocoCore;

/// <summary>A dev server Loco Loco has seen, running or stopped. Stopped entries are the history.</summary>
public sealed class HistoryEntry
{
    public Guid Id { get; set; }
    /// <summary>Set when the server is first seen and kept, so a restarted server keeps its row.</summary>
    public string Name { get; set; } = "";
    public string ProjectDir { get; set; } = "";
    /// <summary>What Restart runs, from CommandDir, with Path as PATH.</summary>
    public string Command { get; set; } = "";
    public string CommandDir { get; set; } = "";
    public string? Path { get; set; }
    public ushort[] Ports { get; set; } = [];
    public DateTime StartedAt { get; set; }
    /// <summary>Null while the server runs.</summary>
    public DateTime? StoppedAt { get; set; }
    public DateTime LastSeenAt { get; set; }
    public ProcRef? Root { get; set; }
    /// <summary>The root and everything under it at the last scan. Finds the server again when its root exits first.</summary>
    public ProcRef[]? Procs { get; set; }
    /// <summary>Why the last restart failed. Shown in red in place of the time.</summary>
    public string? Failure { get; set; }
    public string? LogPath { get; set; }

    public ushort Port => Ports.Length > 0 ? Ports[0] : (ushort)0;
    public bool IsRunning => StoppedAt == null;
    // Windows reports a folder in whatever case it was typed, so folders compare without case.
    internal string Key => CommandDir.ToLowerInvariant() + "\0" + Command;
    /// <summary>The same project on the same port is the same server, whatever command started it.</summary>
    internal string Identity => ProjectDir.ToLowerInvariant() + "\0" + Port;

    public HistoryEntry() { }

    public HistoryEntry(Server s, DateTime now)
    {
        Id = Guid.NewGuid();
        Name = s.Name;
        ProjectDir = s.ProjectDir;
        Command = s.Command;
        CommandDir = s.CommandDir;
        Path = s.Path;
        Ports = s.Ports;
        StartedAt = s.StartedAt;
        LastSeenAt = now;
        Root = s.Root;
        Procs = s.Processes;
    }

    public HistoryEntry Clone() => (HistoryEntry)MemberwiseClone();
}

public sealed class History
{
    readonly List<HistoryEntry> entries;
    public IReadOnlyList<HistoryEntry> Entries => entries;
    /// <summary>How many stopped servers to keep. Running ones are always kept.</summary>
    public int Limit { get; set; }

    public History(IEnumerable<HistoryEntry>? entries = null, int limit = 20)
    {
        this.entries = entries?.ToList() ?? [];
        Limit = limit;
    }

    public HistoryEntry? this[Guid id] => entries.FirstOrDefault(e => e.Id == id);

    public void Remove(Guid id) => entries.RemoveAll(e => e.Id == id);

    /// <summary>Newest first; servers stopped together go by port.</summary>
    public List<HistoryEntry> Stopped =>
        entries.Where(e => !e.IsRunning).OrderByDescending(e => e.StoppedAt!.Value).ThenBy(e => e.Port).ToList();

    /// <summary>Removes stopped entries, except `keep`: ones Loco Loco is starting right now.</summary>
    public void ClearStopped(IReadOnlySet<Guid>? keep = null) =>
        entries.RemoveAll(e => !e.IsRunning && !(keep?.Contains(e.Id) ?? false));

    /// <summary>
    /// Links each scanned dev server to an entry and records the ones that stopped.
    /// A server matches an entry by its root process, then by a pid Loco Loco spawned for that entry, then by any
    /// process the entry had at the last scan. After that it matches the same server started again by hand:
    /// the same folder and command, or else the same project and port, which takes the new command.
    /// Running entries with no server have stopped. On the first scan after launch they get the time they were
    /// last seen, because they may have stopped while Loco Loco wasn't running.
    /// </summary>
    public (Dictionary<ProcRef, Guid> Links, bool Changed) Reconcile(
        IEnumerable<Server> servers, IReadOnlyDictionary<int, Guid>? spawned = null, DateTime? now = null,
        bool firstScan = false, IReadOnlySet<Guid>? keeping = null)
    {
        var at = now ?? DateTime.UtcNow;
        var links = new Dictionary<ProcRef, Guid>();
        var matched = new HashSet<Guid>();
        bool changed = false;
        var dev = servers.Where(s => s.IsDevServer).ToList();

        void Link(Server s, HistoryEntry e)
        {
            if (e.Root != s.Root) { e.Root = s.Root; e.StartedAt = s.StartedAt; changed = true; }
            if (e.StoppedAt != null) { e.StoppedAt = null; changed = true; }
            if (e.Failure != null) { e.Failure = null; changed = true; }
            if (!e.Ports.AsSpan().SequenceEqual(s.Ports)) { e.Ports = s.Ports; changed = true; }
            if (e.Path == null && s.Path != null) { e.Path = s.Path; changed = true; }
            e.Procs = s.Processes;
            e.LastSeenAt = at;
            matched.Add(e.Id);
            links[s.Root] = e.Id;
        }

        // The same process, one Loco Loco started for an entry, or what's left of a running entry's processes.
        var rest = new List<Server>();
        foreach (var s in dev)
        {
            var e = entries.FirstOrDefault(e => e.Root == s.Root && !matched.Contains(e.Id));
            if (e == null && spawned != null)
            {
                foreach (var p in s.Processes)
                {
                    if (!spawned.TryGetValue(p.Pid, out var id)) continue;
                    e = entries.FirstOrDefault(x => x.Id == id && !matched.Contains(id));
                    break;
                }
            }
            e ??= entries.FirstOrDefault(x =>
                x.IsRunning && !matched.Contains(x.Id) && x.Procs != null && x.Procs.Intersect(s.Processes).Any());
            if (e != null) Link(s, e);
            else rest.Add(s);
        }

        // Started again by hand: the most recent entry with the same folder and command, else the same project and port.
        foreach (var s in rest)
        {
            var free = entries.Where(e => !matched.Contains(e.Id)).ToList();
            var byKey = free.Where(e => e.Key == s.Key).MaxBy(e => e.LastSeenAt);
            if (byKey != null) { Link(s, byKey); continue; }
            var byIdentity = free.Where(e => e.Identity == s.Identity).MaxBy(e => e.LastSeenAt);
            if (byIdentity != null)
            {
                byIdentity.Command = s.Command;
                byIdentity.CommandDir = s.CommandDir;
                byIdentity.Path = s.Path;
                Link(s, byIdentity);
                changed = true;
                continue;
            }
            var fresh = new HistoryEntry(s, at);
            entries.Add(fresh);
            Link(s, fresh);
            changed = true;
        }

        foreach (var e in entries)
        {
            if (!e.IsRunning || matched.Contains(e.Id)) continue;
            e.StoppedAt = firstScan ? e.LastSeenAt : at;
            changed = true;
        }
        if (Prune(keeping)) changed = true;
        return (links, changed);
    }

    /// <summary>
    /// The newest `Limit` stopped entries, one per folder and command and one per project and port.
    /// A stopped entry for a server that's running again goes. `keep` is never removed.
    /// </summary>
    public bool Prune(IReadOnlySet<Guid>? keep = null)
    {
        bool Keep(Guid id) => keep?.Contains(id) ?? false;
        var kept = new HashSet<Guid>();
        var claimed = new HashSet<string>();
        foreach (var e in entries.Where(e => e.IsRunning))
        {
            claimed.Add(e.Key);
            claimed.Add(e.Identity);
        }
        foreach (var e in Stopped)
        {
            if (!Keep(e.Id) && (claimed.Contains(e.Key) || claimed.Contains(e.Identity) || kept.Count >= Limit)) continue;
            claimed.Add(e.Key);
            claimed.Add(e.Identity);
            kept.Add(e.Id);
        }
        return entries.RemoveAll(e => !e.IsRunning && !kept.Contains(e.Id) && !Keep(e.Id)) > 0;
    }

    // MARK: File

    const string DateFormat = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'";

    static string FormatDate(DateTime d) => d.ToUniversalTime().ToString(DateFormat, CultureInfo.InvariantCulture);

    static DateTime ParseDate(string s) =>
        DateTime.Parse(s, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal);

    /// <summary>The saved entries. A file that can't be read gives none; an entry that can't be read is skipped.</summary>
    public static List<HistoryEntry> Load(string file)
    {
        var list = new List<HistoryEntry>();
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllBytes(file));
            if (!doc.RootElement.TryGetProperty("entries", out var arr) || arr.ValueKind != JsonValueKind.Array) return list;
            foreach (var el in arr.EnumerateArray())
            {
                try { list.Add(Read(el)); }
                catch (Exception ex) when (ex is FormatException or InvalidOperationException or KeyNotFoundException or OverflowException) { }
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { }
        return list;
    }

    static HistoryEntry Read(JsonElement el)
    {
        string? Str(string k) => el.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        string Req(string k) => Str(k) ?? throw new KeyNotFoundException(k);
        static ProcRef Ref(JsonElement r) => new(r.GetProperty("pid").GetInt32(), r.GetProperty("startMicros").GetUInt64());
        var e = new HistoryEntry
        {
            Id = Guid.Parse(Req("id")),
            Name = Req("name"),
            ProjectDir = Req("projectDir"),
            Command = Req("command"),
            CommandDir = Req("commandDir"),
            Path = Str("path"),
            Ports = el.GetProperty("ports").EnumerateArray().Select(p => p.GetUInt16()).ToArray(),
            StartedAt = ParseDate(Req("startedAt")),
            StoppedAt = Str("stoppedAt") is { } st ? ParseDate(st) : null,
            LastSeenAt = ParseDate(Req("lastSeenAt")),
            Failure = Str("failure"),
            LogPath = Str("logPath"),
        };
        if (el.TryGetProperty("root", out var root) && root.ValueKind == JsonValueKind.Object) e.Root = Ref(root);
        if (el.TryGetProperty("procs", out var procs) && procs.ValueKind == JsonValueKind.Array)
            e.Procs = procs.EnumerateArray().Select(Ref).ToArray();
        return e;
    }

    /// <summary>Writes the file in one step, so a crash mid-write leaves the old one.</summary>
    public void Save(string file)
    {
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(file)!);
        var temp = file + ".tmp";
        using (var stream = File.Create(temp))
        using (var w = new Utf8JsonWriter(stream, new JsonWriterOptions { Indented = true }))
        {
            w.WriteStartObject();
            w.WriteStartArray("entries");
            foreach (var e in entries) Write(w, e);
            w.WriteEndArray();
            w.WriteNumber("version", 1);
            w.WriteEndObject();
        }
        File.Move(temp, file, overwrite: true);
    }

    /// <summary>Keys in sorted order, like the Mac's file, so the two read the same.</summary>
    static void Write(Utf8JsonWriter w, HistoryEntry e)
    {
        static void Ref(Utf8JsonWriter w, ProcRef r)
        {
            w.WriteStartObject();
            w.WriteNumber("pid", r.Pid);
            w.WriteNumber("startMicros", r.StartMicros);
            w.WriteEndObject();
        }
        w.WriteStartObject();
        w.WriteString("command", e.Command);
        w.WriteString("commandDir", e.CommandDir);
        if (e.Failure != null) w.WriteString("failure", e.Failure);
        w.WriteString("id", e.Id.ToString().ToUpperInvariant());
        w.WriteString("lastSeenAt", FormatDate(e.LastSeenAt));
        if (e.LogPath != null) w.WriteString("logPath", e.LogPath);
        w.WriteString("name", e.Name);
        if (e.Path != null) w.WriteString("path", e.Path);
        w.WriteStartArray("ports");
        foreach (var p in e.Ports) w.WriteNumberValue(p);
        w.WriteEndArray();
        if (e.Procs != null)
        {
            w.WriteStartArray("procs");
            foreach (var p in e.Procs) Ref(w, p);
            w.WriteEndArray();
        }
        w.WriteString("projectDir", e.ProjectDir);
        if (e.Root is { } root) { w.WritePropertyName("root"); Ref(w, root); }
        w.WriteString("startedAt", FormatDate(e.StartedAt));
        if (e.StoppedAt is { } stopped) w.WriteString("stoppedAt", FormatDate(stopped));
        w.WriteEndObject();
    }
}
