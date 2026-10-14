using System.Diagnostics;
using System.Globalization;
using System.Runtime.Versioning;
using LocoCore;

[assembly: SupportedOSPlatform("windows")]

// Tests Loco Loco's core from the terminal.
//   loco-scan [--all]                 what the panel would list
//   loco-scan stop <port>             stop a server the way the Stop button does
//   loco-scan run <dir> <command>     start a command the way Restart does, and wait for its port
//   loco-scan history <file>          reconcile a scan with a history file, print and save it

if (!OperatingSystem.IsWindows())
{
    Console.Error.WriteLine("loco-scan reads the Windows process table. On a Mac, use the Mac's loco-scan.");
    return 2;
}

var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
var platform = new WindowsPlatform();

switch (args.FirstOrDefault())
{
    case "stop":
    {
        if (args.Length != 2 || !ushort.TryParse(args[1], out var port)) return Usage("loco-scan stop <port>");
        var s = platform.Scan().FirstOrDefault(s => s.Ports.Contains(port));
        if (s == null)
        {
            Console.WriteLine($"nothing on {port}");
            return 1;
        }
        var procs = platform.Tree(s.Root);
        Console.WriteLine($"Ctrl+C {string.Join(' ', procs.Select(p => p.Pid))} ({s.Name})");
        var sent = CtrlC(procs);
        if (!sent) Console.WriteLine("couldn't send Ctrl+C: something else shares its console, or it has none");
        var t0 = Stopwatch.StartNew();
        while (sent && procs.Any(platform.Alive) && t0.Elapsed < TimeSpan.FromSeconds(5)) Thread.Sleep(100);
        var left = procs.Where(platform.Alive).ToArray();
        if (left.Length == 0)
        {
            Console.WriteLine($"stopped in {t0.ElapsedMilliseconds} ms");
            return 0;
        }
        Console.WriteLine($"still running: {string.Join(' ', left.Select(p => p.Pid))}, force stop");
        platform.Kill(left);
        return 0;
    }

    case "run":
    {
        if (args.Length < 3) return Usage("loco-scan run <dir> <command>");
        var dir = args[1];
        var command = string.Join(' ', args[2..]);
        var log = Path.Combine(Path.GetTempPath(), "loco-scan-run.log");
        string? exit = null;
        var pid = platform.Spawn(command, dir, Environment.GetEnvironmentVariable("PATH"), log, (_, reason) => exit = reason);
        Console.WriteLine($"spawned {pid}, log {log}");
        var t0 = Stopwatch.StartNew();
        while (t0.Elapsed < TimeSpan.FromSeconds(30))
        {
            if (exit != null)
            {
                Console.WriteLine(exit);
                return 1;
            }
            var s = platform.Scan().FirstOrDefault(s => s.Processes.Any(p => p.Pid == pid));
            if (s != null)
            {
                Console.WriteLine($"listening on {string.Join(',', s.Ports)} as {s.Name} after {t0.ElapsedMilliseconds} ms, root {s.Root.Pid}");
                List([s]);
                return 0;
            }
            Thread.Sleep(250);
        }
        Console.WriteLine("timed out");
        return 1;
    }

    case "history":
    {
        if (args.Length != 2) return Usage("loco-scan history <file>");
        var history = new History(History.Load(args[1]));
        var (links, changed) = history.Reconcile(platform.Scan(), firstScan: true);
        history.Save(args[1]);
        Console.WriteLine($"changed {changed}, {links.Count} linked");
        foreach (var e in history.Entries.OrderBy(e => e.IsRunning ? 0 : 1).ThenBy(e => e.Port))
            Console.WriteLine($"{(e.IsRunning ? "running" : "stopped")} {e.Port} {e.Name} {e.Failure}");
        return 0;
    }

    case Stopper.HelperFlag:
        // The helper `stop` starts, hidden, so loco-scan keeps its own console while this one joins the server's.
        return args.Length == 2 ? Stopper.RunHelper(args[1]) : 2;

    default:
    {
        var all = args.Contains("--all");
        var t0 = Stopwatch.StartNew();
        var servers = platform.Scan().Where(s => all || s.IsDevServer).ToList();
        var ms = t0.ElapsedMilliseconds;
        List(servers);
        Console.WriteLine($"{servers.Count} servers in {ms} ms");
        return 0;
    }
}

void List(IEnumerable<Server> servers)
{
    foreach (var s in servers)
    {
        var ports = string.Join(',', s.Ports);
        var started = s.StartedAt.ToLocalTime().ToString("MMM d HH:mm", CultureInfo.InvariantCulture);
        var path = s.Path == null ? "missing" : $"{s.Path.Split(';', StringSplitOptions.RemoveEmptyEntries).Length} entries";
        Console.WriteLine($"{ports,-12} {s.Name,-34} {started}  root {s.Root.Pid}  procs {s.Processes.Length}{(s.IsDevServer ? "" : "  [app/system]")}");
        Console.WriteLine($"    folder   {WinPath.Abbreviate(s.ProjectDir, home)}");
        Console.WriteLine($"    command  {(s.Command.Length > 160 ? s.Command[..160] : s.Command)}");
        Console.WriteLine($"    in       {WinPath.Abbreviate(s.CommandDir, home)}   PATH {path}");
    }
}

static bool CtrlC(ProcRef[] procs)
{
    using var helper = Stopper.Ask(Environment.ProcessPath!, procs);
    if (helper == null) return false;
    helper.WaitForExit();
    return Stopper.Asked(helper.ExitCode);
}

static int Usage(string usage)
{
    Console.WriteLine("usage: " + usage);
    return 2;
}
