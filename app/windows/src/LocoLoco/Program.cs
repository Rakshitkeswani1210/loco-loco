using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace LocoLoco;

/// <summary>What the command line asked for.</summary>
sealed class Options
{
    /// <summary>Open the panel at launch.</summary>
    public bool Open { get; private init; }
    /// <summary>Keep history and settings here instead of %LOCALAPPDATA%\Loco Loco.</summary>
    public string? Data { get; private init; }
    /// <summary>Only list servers on these ports.</summary>
    public HashSet<ushort>? Only { get; private init; }
    /// <summary>Run the screenshot script, save the images here, and quit.</summary>
    public string? Screenshot { get; private init; }
    /// <summary>Save the tray and app icons as Windows draws them, and quit.</summary>
    public string? Icons { get; private init; }

    public const string Usage = "Loco Loco [--open] [--data <folder>] [--only <port,port>] [--screenshot <folder>] [--icons <folder>]";

    public static Options Parse(string[] args)
    {
        bool open = false;
        string? data = null, screenshot = null, icons = null;
        HashSet<ushort>? only = null;
        for (int i = 0; i < args.Length; i++)
        {
            string Value() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"{args[i]} needs a value.\n{Usage}");
            switch (args[i])
            {
                case "--open": open = true; break;
                case "--data": data = Path.GetFullPath(Value()); break;
                case "--screenshot": screenshot = Path.GetFullPath(Value()); break;
                case "--icons": icons = Path.GetFullPath(Value()); break;
                case "--only":
                    only = [];
                    foreach (var part in Value().Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                        only.Add(ushort.TryParse(part, out var p) && p > 0 ? p : throw new ArgumentException($"Not a port: {part}"));
                    break;
                default: throw new ArgumentException($"Unknown option {args[i]}.\n{Usage}");
            }
        }
        return new Options { Open = open, Data = data, Only = only, Screenshot = screenshot, Icons = icons };
    }
}

static class Program
{
    const string InstanceName = @"Local\LocoLoco", OpenEventName = @"Local\LocoLoco.Open";

    [STAThread]
    static int Main(string[] args)
    {
        // Stop runs this program again, hidden, to send Ctrl+C. It does only that, before any window or tray icon.
        if (args is [LocoCore.Stopper.HelperFlag, var refs]) return LocoCore.Stopper.RunHelper(refs);

        Options options;
        try { options = Options.Parse(args); }
        catch (ArgumentException e)
        {
            Console.Error.WriteLine(e.Message);
            return 2;
        }
        if (options.Icons is { } iconDir) return TestHooks.WriteIcons(iconDir);

        Mutex? single = null;
        EventWaitHandle? openRequests = null;
        if (options.Screenshot == null)
        {
            single = new Mutex(true, InstanceName, out bool first);
            if (!first)
            {
                // Already running: ask that copy to open its panel, and let it take the foreground.
                if (EventWaitHandle.TryOpenExisting(OpenEventName, out var other))
                {
                    Native.AllowSetForegroundWindow(Native.ASFW_ANY);
                    other.Set();
                    other.Dispose();
                }
                return 0;
            }
            openRequests = new EventWaitHandle(false, EventResetMode.AutoReset, OpenEventName);
        }

        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(p =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            _ = new App(options, openRequests);
        });
        GC.KeepAlive(single);
        return App.ExitCode;
    }
}
