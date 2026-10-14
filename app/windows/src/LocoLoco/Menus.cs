using LocoCore;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Windows.Foundation;

namespace LocoLoco;

/// <summary>The row menu, the ··· menu, and the two confirmations.</summary>
sealed partial class Flyout
{
    MenuFlyout? openMenu;
    ContentDialog? openDialog;

    static MenuFlyoutItem Item(string text, string? glyph, string? keys, bool enabled, Action click)
    {
        var item = new MenuFlyoutItem { Text = text, IsEnabled = enabled };
        if (glyph != null) item.Icon = new FontIcon { Glyph = glyph };
        if (keys != null) item.KeyboardAcceleratorTextOverride = keys;
        item.Click += (_, _) => click();
        return item;
    }

    static ToggleMenuFlyoutItem Toggle(string text, bool on, Action<bool> changed)
    {
        var item = new ToggleMenuFlyoutItem { Text = text, IsChecked = on };
        item.Click += (_, _) => changed(item.IsChecked);
        return item;
    }

    /// <summary>Right click, Shift+F10 or the menu key on a row.</summary>
    public void ShowRowMenu(RowControl c, Point? at)
    {
        if (c.Row is not { } row || MenuOpen || holdOpen > 0) return;
        bool isDev = row.EntryId != null;
        bool folder = row.Folder.Length > 0 && Directory.Exists(row.Folder);
        var menu = new MenuFlyout();
        var items = menu.Items;
        items.Add(Item("Open in browser", "\uE774", "Enter", row.Server != null && row.State == RowState.Idle, () => { Shell.OpenUrl(row.Url); Hide(); }));
        items.Add(Item("Copy URL", "\uE71B", null, true, () => Shell.Copy(row.Url)));
        foreach (var port in row.Ports.Skip(1))
            items.Add(Item($"Open localhost:{port}", null, null, row.Server != null, () => { Shell.OpenUrl($"http://localhost:{port}"); Hide(); }));
        items.Add(new MenuFlyoutSeparator());
        items.Add(Item("Restart", "\uE72C", "Ctrl+R", row.CanRestart, () => { engine.Restart(row); Refresh(); }));
        items.Add(Item("Stop", "\uE71A", "Delete", row.CanStop, () => { engine.Stop(row); Refresh(); }));
        items.Add(new MenuFlyoutSeparator());
        items.Add(Item("Show in File Explorer", "\uE8B7", null, folder, () => { Shell.ShowInExplorer(row.Folder); Hide(); }));
        items.Add(Item("Open in Terminal", "\uE756", null, isDev && folder, () => { Shell.OpenTerminal(row.Folder); Hide(); }));
        if (Shell.Cursor != null)
            items.Add(Item("Open in Cursor", "\uE943", null, isDev && folder, () => { Shell.OpenInCursor(row.Folder); Hide(); }));
        items.Add(Item("Show log", "\uE8A5", null, row.HasLog, () => { if (row.LogPath is { } log) Shell.OpenLog(log); Hide(); }));

        // From the keyboard there's no point, so it opens under the row's text.
        var options = new FlyoutShowOptions { Position = at ?? new Point(Metrics.RowPadding.Left, c.ActualHeight), ShowMode = FlyoutShowMode.Standard };
        Open(menu, c, options, row.Id);
    }

    void ShowOptions(Button anchor)
    {
        if (MenuOpen || holdOpen > 0) return;
        var menu = new MenuFlyout();
        var items = menu.Items;
        items.Add(Item("Stop all…", null, null, engine.Stoppable.Count > 0, () => _ = ConfirmStopAll()));
        items.Add(new MenuFlyoutSeparator());
        items.Add(Toggle("Start with Windows", StartupTask.IsEnabled, StartupTask.Set));
        items.Add(Toggle("Show count on icon", engine.Settings.ShowCount, engine.SetShowCount));
        items.Add(Toggle("Show app and Windows servers", engine.Settings.ShowAll, engine.SetShowAll));
        items.Add(new MenuFlyoutSeparator());
        var keep = new MenuFlyoutSubItem { Text = "Keep history" };
        foreach (var n in new[] { 10, 20, 50 })
        {
            var item = new RadioMenuFlyoutItem { Text = $"{n} servers", GroupName = "keep", IsChecked = engine.Settings.HistoryLimit == n };
            item.Click += (_, _) => engine.SetHistoryLimit(n);
            keep.Items.Add(item);
        }
        items.Add(keep);
        items.Add(Item("Clear history…", null, null, engine.History.Entries.Any(e => !e.IsRunning), () => _ = ConfirmClearHistory()));
        items.Add(new MenuFlyoutSeparator());
        items.Add(Item("Quit Loco Loco", null, null, true, quit));
        Open(menu, anchor, new FlyoutShowOptions { Placement = FlyoutPlacementMode.TopEdgeAlignedRight, ShowMode = FlyoutShowMode.Standard }, null);
    }

    void Open(MenuFlyout menu, FrameworkElement target, FlyoutShowOptions options, string? row)
    {
        // A menu may reach past the panel's edges.
        menu.ShouldConstrainToRootBounds = false;
        MenuOpen = true;
        menuRow = row;
        if (row != null) highlight = row;
        PaintAll();
        menu.Closed += (_, _) =>
        {
            openMenu = null;
            MenuOpen = false;
            menuRow = null;
            highlight = null;
            PaintAll();
            // Let a chosen item open its dialog first, then close if the click went to another app.
            dispatcher.TryEnqueue(DispatcherQueuePriority.Low, () =>
            {
                if (Visible && !StayOpen && holdOpen == 0 && !MenuOpen && Native.GetForegroundWindow() != Hwnd) Hide();
            });
        };
        openMenu = menu;
        menu.ShowAt(target, options);
    }

    /// <summary>For the screenshot run.</summary>
    public void CloseMenu() => openMenu?.Hide();

    public void CloseDialog() => openDialog?.Hide();

    public async Task ConfirmStopAll()
    {
        int n = engine.Stoppable.Count;
        if (n == 0) return;
        if (await Confirm(n == 1 ? "Stop 1 server?" : $"Stop all {n} servers?", "Stop all"))
        {
            engine.StopAll();
            Refresh();
        }
    }

    async Task ConfirmClearHistory()
    {
        if (await Confirm("Clear history?", "Clear history"))
        {
            engine.ClearHistory();
            Refresh(force: true);
        }
    }

    /// <summary>A Windows confirmation inside the panel. True when the action is chosen.</summary>
    async Task<bool> Confirm(string title, string action)
    {
        if (!Visible) Show();
        if (openDialog != null) return false;
        if (root.XamlRoot == null)
        {
            var loaded = new TaskCompletionSource();
            root.Loaded += (_, _) => loaded.TrySetResult();
            if (root.XamlRoot == null) await loaded.Task;
        }
        var dialog = new ContentDialog
        {
            Title = title,
            PrimaryButtonText = action,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = root.XamlRoot,
            RequestedTheme = root.ActualTheme,
        };
        if (Application.Current.Resources.TryGetValue("DefaultContentDialogStyle", out var style) && style is Style s) dialog.Style = s;
        holdOpen++;
        openDialog = dialog;
        Place();
        try
        {
            return await dialog.ShowAsync() == ContentDialogResult.Primary;
        }
        finally
        {
            openDialog = null;
            holdOpen--;
            if (Visible)
            {
                Place();
                if (!StayOpen && Native.GetForegroundWindow() != Hwnd) Hide();
            }
        }
    }
}
