namespace LocoCore;

/// <summary>One exact process. With the start time, a pid that Windows reused never matches.</summary>
public readonly record struct ProcRef(int Pid, ulong StartMicros);

/// <summary>One running server: every process under one launch, with the ports they listen on.</summary>
public sealed record Server
{
    /// <summary>The top of the launch chain, below the shell, agent or app that started it.</summary>
    public required ProcRef Root { get; init; }
    public required DateTime StartedAt { get; init; }
    /// <summary>Sorted, unique. The row shows the first.</summary>
    public required ushort[] Ports { get; init; }
    public ushort Port => Ports.Length > 0 ? Ports[0] : (ushort)0;
    public required string Name { get; init; }
    public required string ProjectDir { get; init; }
    public required string Command { get; init; }
    public required string CommandDir { get; init; }
    public string? Path { get; init; }
    /// <summary>Runs from a folder inside the user folder and wasn't started by an app.</summary>
    public required bool IsDevServer { get; init; }
    /// <summary>The root and everything under it. Stop reaches all of them.</summary>
    public required ProcRef[] Processes { get; init; }
    public string? Executable { get; init; }

    internal string Key => CommandDir.ToLowerInvariant() + "\0" + Command;
    internal string Identity => ProjectDir.ToLowerInvariant() + "\0" + Port;

    public bool Equals(Server? o) =>
        o is not null && Root == o.Root && StartedAt == o.StartedAt && Ports.AsSpan().SequenceEqual(o.Ports) &&
        Name == o.Name && ProjectDir == o.ProjectDir && Command == o.Command && CommandDir == o.CommandDir &&
        Path == o.Path && IsDevServer == o.IsDevServer && Processes.AsSpan().SequenceEqual(o.Processes) && Executable == o.Executable;

    public override int GetHashCode() => HashCode.Combine(Root, Port, Name);
}
