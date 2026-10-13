using System.Globalization;

namespace LocoCore;

public enum RowGroup { Running, Stopped }

public enum RowAction { Stop, Restart, Log, Force }

public enum RowState { Idle, Stopping, Starting, Force }

/// <summary>One line in the flyout.</summary>
public sealed record Row
{
    /// <summary>The history entry's id, or `app-&lt;pid&gt;-&lt;start&gt;` for app and Windows servers.</summary>
    public required string Id { get; init; }
    public required RowGroup Group { get; init; }
    public required ushort Port { get; init; }
    public required ushort[] Ports { get; init; }
    public required string Name { get; init; }
    public required string Folder { get; init; }
    /// <summary>Start time while running, stop time once stopped. UTC.</summary>
    public required DateTime Time { get; init; }
    public string? Failure { get; init; }
    public RowState State { get; init; }
    public Guid? EntryId { get; init; }
    public Server? Server { get; init; }
    public string? LogPath { get; init; }
    /// <summary>Set by the engine: the log file exists.</summary>
    public bool HasLog { get; init; }

    public bool IsApp => EntryId == null;
    /// <summary>A server Loco Loco can stop now. App and Windows servers too, though they can't restart.</summary>
    public bool CanStop => Group == RowGroup.Running && Server != null && State == RowState.Idle;
    public bool CanRestart => EntryId != null && State == RowState.Idle && (Group == RowGroup.Stopped || Server != null);

    /// <summary>The buttons that take the place of the time on hover.</summary>
    public RowAction[] Actions
    {
        get
        {
            if (State == RowState.Force) return [RowAction.Force];
            if (State != RowState.Idle) return [];
            if (Group == RowGroup.Running) return Server == null ? [] : [RowAction.Stop];
            return Failure != null && HasLog ? [RowAction.Log, RowAction.Restart] : [RowAction.Restart];
        }
    }

    public string Url => "http://localhost:" + Port;

    /// <summary>What Narrator reads: "api, port 8000, running since 11:09 AM".</summary>
    public string AccessibleName(DateTime now)
    {
        var status = State switch
        {
            RowState.Stopping => "stopping",
            RowState.Force => "not stopping, force stop available",
            RowState.Starting => "starting",
            _ when Failure != null => "didn't start: " + Failure,
            _ when Group == RowGroup.Running => "running since " + TimeText.Short(Time, now),
            _ => "stopped " + TimeText.Short(Time, now),
        };
        return $"{Name}, port {Port}, {status}";
    }

    public bool Equals(Row? o) =>
        o is not null && Id == o.Id && Group == o.Group && Port == o.Port && Ports.AsSpan().SequenceEqual(o.Ports) &&
        Name == o.Name && Folder == o.Folder && Time == o.Time && Failure == o.Failure && State == o.State &&
        EntryId == o.EntryId && Equals(Server, o.Server) && LogPath == o.LogPath && HasLog == o.HasLog;

    public override int GetHashCode() => HashCode.Combine(Id, State, Time);
}

public sealed class Rows
{
    public const string More = "more";
    /// <summary>Stopped rows shown before More.</summary>
    public const int ShownStopped = 5;

    public List<Row> Running { get; } = [];
    public List<Row> Stopped { get; } = [];
    /// <summary>Every stopped server, including the ones under More.</summary>
    public int StoppedTotal { get; set; }

    public bool HasMore => Stopped.Count < StoppedTotal;
    /// <summary>Top to bottom, as the arrow keys move.</summary>
    public List<string> Order => [.. Running.Select(r => r.Id), .. Stopped.Select(r => r.Id), .. HasMore ? [More] : Array.Empty<string>()];

    public Row? Find(string? id) => id == null ? null : Running.FirstOrDefault(r => r.Id == id) ?? Stopped.FirstOrDefault(r => r.Id == id);

    public bool Same(Rows o) => StoppedTotal == o.StoppedTotal && Running.SequenceEqual(o.Running) && Stopped.SequenceEqual(o.Stopped);
}

public static class TimeText
{
    /// <summary>"10:37 AM" today, "Oct 7" this year, "Oct 7, 2025" before. In the user's time zone and format.</summary>
    public static string Short(DateTime utc, DateTime nowUtc, CultureInfo? culture = null)
    {
        var c = culture ?? CultureInfo.CurrentCulture;
        var d = utc.ToLocalTime();
        var now = nowUtc.ToLocalTime();
        if (d.Date == now.Date) return d.ToString(c.DateTimeFormat.ShortTimePattern, c).Replace('\u202F', ' ');
        if (d.Year == now.Year) return d.ToString("MMM d", c);
        return d.ToString("MMM d, yyyy", c);
    }
}

public static class ExitText
{
    /// <summary>"Exited with code 1", "Exited with code 0xC0000005", or "Stopped by Ctrl+C".</summary>
    public static string Describe(uint code) => code switch
    {
        0xC000013A => "Stopped by Ctrl+C",
        >= 0xC0000000 => $"Exited with code 0x{code:X8}",
        _ => $"Exited with code {code}",
    };
}
