using H.NotifyIcon.Core;
using LocoCore;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.XamlTypeInfo;

namespace LocoLoco;

/// <summary>
/// Wires the engine to the octopus and the panel. There is no XAML: the controls are built in code
/// and the metadata comes from WinUI's own provider.
/// </summary>
sealed partial class App : Application, IXamlMetadataProvider
{
    public static int ExitCode { get; set; }

    readonly XamlControlsXamlMetaDataProvider provider = new();
    readonly Options options;
    readonly EventWaitHandle? openRequests;
    RegisteredWaitHandle? openListener;
    DispatcherQueue dispatcher = null!;
    DispatcherQueueTimer timer = null!;
    Engine engine = null!;
    Tray tray = null!;
    Flyout flyout = null!;

    public App(Options options, EventWaitHandle? openRequests)
    {
        this.options = options;
        this.openRequests = openRequests;
        UnhandledException += (_, e) =>
        {
            if (options.Screenshot is { } dir) TestHooks.Fail(dir, e.Exception);
        };
    }

    public IXamlType GetXamlType(Type type) => provider.GetXamlType(type);
    public IXamlType GetXamlType(string fullName) => provider.GetXamlType(fullName);
    public XmlnsDefinition[] GetXmlnsDefinitions() => provider.GetXmlnsDefinitions();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        Resources.MergedDictionaries.Add(new XamlControlsResources());
        // The panel is hidden most of the time; closing it must not end the app.
        DispatcherShutdownMode = DispatcherShutdownMode.OnExplicitShutdown;
        dispatcher = DispatcherQueue.GetForCurrentThread();

        var paths = options.Data is { } data ? new AppPaths(data) : AppPaths.Default;
        // Always queued, so the engine never re-enters itself.
        engine = new Engine(new WindowsPlatform(), paths, a => dispatcher.TryEnqueue(() => a())) { OnlyPorts = options.Only };
        timer = dispatcher.CreateTimer();
        timer.IsRepeating = false;
        timer.Tick += (_, _) => engine.ScanNow();
        engine.ScheduleRequested += delay => Post(() =>
        {
            timer.Stop();
            timer.Interval = delay;
            timer.Start();
        });
        engine.Changed += Changed;

        tray = new Tray(dispatcher);
        flyout = new Flyout(engine, tray, Quit) { StayOpen = options.Screenshot != null };
        tray.Clicked += flyout.Toggle;
        tray.MenuRequested += TrayMenu;
        tray.Update(0, engine.Settings.ShowCount);
        try { tray.Create(); }
        // A machine without a taskbar, like some build servers. The panel still works.
        catch (InvalidOperationException) when (options.Screenshot != null) { }

        engine.ScanNow();

        if (options.Screenshot is { } dir)
        {
            _ = TestHooks.Run(dir, engine, flyout, tray, options.Only?.Count ?? 0, Quit);
            return;
        }

        StartupTask.Refresh();
        if (!engine.Settings.FirstRunDone)
        {
            StartupTask.Set(true);
            tray.Notify("Loco Loco is running", "To keep it in view, drag the octopus from ^ to the taskbar.");
            engine.SetFirstRunDone();
        }
        if (options.Open) flyout.Show();
        if (openRequests != null)
            openListener = ThreadPool.RegisterWaitForSingleObject(openRequests, (_, _) => Post(flyout.Show), null, Timeout.Infinite, executeOnlyOnce: false);
    }

    void Post(Action a)
    {
        if (dispatcher.HasThreadAccess) a();
        else dispatcher.TryEnqueue(() => a());
    }

    void Changed()
    {
        tray.Update(engine.RunningCount, engine.Settings.ShowCount);
        if (flyout.Visible || options.Screenshot != null) flyout.Refresh();
    }

    void TrayMenu(int x, int y)
    {
        var stopAll = new PopupMenuItem("Stop all…", (_, _) => _ = flyout.ConfirmStopAll()) { Enabled = engine.Stoppable.Count > 0 };
        tray.ShowMenu(x, y,
        [
            new PopupMenuItem("Open Loco Loco", (_, _) => flyout.Show()),
            stopAll,
            new PopupMenuSeparator(),
            // After the menu has fully closed, since quitting removes the window that owns it.
            new PopupMenuItem("Quit Loco Loco", (_, _) => dispatcher.TryEnqueue(Quit)),
        ]);
    }

    void Quit()
    {
        openListener?.Unregister(null);
        timer.Stop();
        engine.Save();
        flyout.Hide();
        tray.Dispose();
        flyout.Close();
        Exit();
    }
}
