using H.NotifyIcon.Core;
using LocoLoco.Art;
using Microsoft.UI.Dispatching;
using Microsoft.Win32;
using Windows.UI.ViewManagement;

namespace LocoLoco;

/// <summary>
/// The octopus in the notification area, through H.NotifyIcon. It follows the taskbar's light or dark mode,
/// sleeps when nothing runs, and carries the count as an accent badge.
/// </summary>
sealed class Tray : IDisposable
{
    readonly TrayIcon icon = new(TrayIcon.CreateUniqueGuidForProcessPath());
    readonly DispatcherQueue dispatcher;
    readonly UISettings ui = new();
    nint handle;
    string? drawn;
    int count;
    bool showCount = true;
    DateTime keySelectAt;

    /// <summary>Left click, or Enter or Space on the icon.</summary>
    public event Action? Clicked;
    /// <summary>Right click or the menu key, at this screen point.</summary>
    public event Action<int, int>? MenuRequested;

    public Guid Id => icon.Id;
    public nint WindowHandle => icon.MessageWindow.Handle;
    public nint IconHandle => handle;

    public Tray(DispatcherQueue dispatcher)
    {
        this.dispatcher = dispatcher;
        icon.ToolTip = ToolTip(0);
        icon.MessageWindow.MouseEventReceived += (_, e) =>
        {
            if (e.MouseEvent == MouseEvent.IconLeftMouseUp) Post(() => Clicked?.Invoke());
        };
        icon.MessageWindow.KeyboardEventReceived += (_, e) =>
        {
            switch (e.KeyboardEvent)
            {
                // Enter sends this twice.
                case KeyboardEvent.KeySelect when DateTime.UtcNow - keySelectAt > TimeSpan.FromMilliseconds(300):
                    keySelectAt = DateTime.UtcNow;
                    Post(() => Clicked?.Invoke());
                    break;
                case KeyboardEvent.ContextMenu:
                    var p = e.Point;
                    Post(() => MenuRequested?.Invoke(p.X, p.Y));
                    break;
            }
        };
        // Explorer restarted: the icon is gone until it's added again.
        icon.MessageWindow.TaskbarCreated += (_, _) => Post(Recreate);
        icon.MessageWindow.DpiChanged += (_, _) => Post(Render);
        ui.ColorValuesChanged += (_, _) => Post(Render);
    }

    void Post(Action a) => dispatcher.TryEnqueue(() => a());

    public void Create()
    {
        Render();
        icon.Create();
    }

    void Recreate()
    {
        icon.TryRemove();
        drawn = null;
        Render();
        try { icon.Create(); }
        catch (InvalidOperationException) { }
    }

    static string ToolTip(int n) => n == 0 ? "Loco Loco · Nothing running" : $"Loco Loco · {n} running";

    public void Update(int running, bool show)
    {
        if (running != count || !icon.IsCreated) icon.UpdateToolTip(ToolTip(running));
        count = running;
        showCount = show;
        Render();
    }

    /// <summary>The taskbar's mode, which can differ from the apps' mode.</summary>
    public static bool TaskbarIsLight()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return key?.GetValue("SystemUsesLightTheme") is int v && v != 0;
    }

    /// <summary>The badge colour: Windows' accent, darker on a light taskbar and lighter on a dark one.</summary>
    Rgba Accent(bool light)
    {
        try
        {
            var c = ui.GetColorValue(light ? UIColorType.AccentDark1 : UIColorType.AccentLight2);
            return new Rgba(c.R / 255.0, c.G / 255.0, c.B / 255.0);
        }
        catch (Exception) { return light ? Icons.DefaultAccentLight : Icons.DefaultAccentDark; }
    }

    /// <summary>Draws the icon again when its size, mode, accent, count or sleep changed.</summary>
    public void Render()
    {
        int px = Native.TrayIconSize();
        bool light = TaskbarIsLight();
        var accent = Accent(light);
        int badge = showCount ? count : 0;
        var key = $"{px} {light} {accent} {count == 0} {badge}";
        if (key == drawn) return;
        var next = Make(px, light, count == 0, badge, accent);
        if (next == 0) return;
        drawn = key;
        var old = handle;
        handle = next;
        icon.UpdateIcon(handle);
        if (old != 0) Native.DestroyIcon(old);
    }

    /// <summary>An icon handle for these settings, from the same drawing as the previews.</summary>
    public static nint Make(int px, bool light, bool asleep, int badge, Rgba? accent = null) =>
        Native.IconFromPng(Icons.Tray(px, light, asleep, badge, accent).ToPng(), px);

    /// <summary>Where the icon is, or null when Windows can't say.</summary>
    public Native.RECT? Rect() => icon.IsCreated ? Native.IconRect(WindowHandle, Id) : null;

    /// <summary>The first-run notification. Windows 11 shows it as a notification from Loco Loco.</summary>
    public void Notify(string title, string message)
    {
        try { icon.ShowNotification(title, message, NotificationIcon.None); }
        catch (InvalidOperationException) { }
    }

    /// <summary>The right-click menu: a standard Windows menu at the pointer.</summary>
    public void ShowMenu(int x, int y, IEnumerable<PopupItem> items)
    {
        var menu = new PopupMenu();
        foreach (var item in items) menu.Items.Add(item);
        // Without this the menu stays open after clicking elsewhere.
        Native.SetForegroundWindow(WindowHandle);
        menu.Show(WindowHandle, x, y);
    }

    public void Dispose()
    {
        icon.Dispose();
        if (handle != 0) Native.DestroyIcon(handle);
        handle = 0;
    }
}
