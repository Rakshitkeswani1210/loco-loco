using System.Diagnostics;
using System.Runtime.Versioning;

namespace LocoCore;

/// <summary>The real system, for the app and loco-scan.</summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsPlatform : IPlatform
{
    public Places Places { get; } = DefaultPlaces();

    public static Places DefaultPlaces()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var roots = new List<string>();
        foreach (var v in (string[])["ProgramFiles", "ProgramFiles(x86)", "ProgramW6432", "SystemRoot", "ProgramData"])
            if (Environment.GetEnvironmentVariable(v) is { Length: > 0 } p) roots.Add(p);
        if (local.Length > 0)
        {
            roots.Add(Path.Combine(local, "Programs"));
            roots.Add(Path.Combine(local, "Microsoft"));
        }
        var temps = new List<string> { Path.GetTempPath().TrimEnd('\\') };
        foreach (var v in (string[])["TEMP", "TMP"])
            if (Environment.GetEnvironmentVariable(v) is { Length: > 0 } p) temps.Add(p.TrimEnd('\\'));
        return new Places(home, roots.Distinct(StringComparer.OrdinalIgnoreCase).ToList(), temps.Distinct(StringComparer.OrdinalIgnoreCase).ToList());
    }

    /// <summary>"Docker Desktop" from the program's version info, else its product name.</summary>
    public static string? AppName(string exe)
    {
        try
        {
            var v = FileVersionInfo.GetVersionInfo(exe);
            return !string.IsNullOrWhiteSpace(v.FileDescription) ? v.FileDescription.Trim()
                : !string.IsNullOrWhiteSpace(v.ProductName) ? v.ProductName.Trim() : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { return null; }
    }

    static bool Exists(string p) => File.Exists(p) || Directory.Exists(p);

    public List<Server> Scan() => Scanner.Build(new WinProcTable(), Places, Exists, AppName);
    public ProcRef[] Tree(ProcRef root) => Scanner.Tree(new WinProcTable(listeners: false), root);
    public bool Alive(ProcRef p) => Win32.IsAlive(p);
    public void Interrupt(ProcRef[] procs) => Stopper.Interrupt(procs);
    public void Kill(ProcRef[] procs) => Stopper.Kill(procs);
    public void KillTree(int pid) => Stopper.KillTree(pid);
    public bool PortInUse(ushort port) => WinLauncher.PortInUse(port);
    public bool IsFolder(string path) => Directory.Exists(path);
    public bool FileExists(string path) => File.Exists(path);

    public int Spawn(string command, string dir, string? path, string log, Action<int, string> exited) =>
        WinLauncher.Spawn(command, dir, path, log, exited);
}
