using System.Numerics;
using LocoCore;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;
using Windows.System;
using DispatcherQueue = Microsoft.UI.Dispatching.DispatcherQueue;
using Windows.UI.Core;
using Windows.UI.ViewManagement;
using Edge = LocoLoco.Native.Edge;
using RECT = LocoLoco.Native.RECT;

namespace LocoLoco;

/// <summary>The window's content. It takes focus when no row has it, so the arrow keys and Esc still work.</summary>
sealed partial class FlyoutRoot : ContentControl
{
    public FlyoutRoot()
    {
        IsTabStop = true;
        UseSystemFocusVisuals = false;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalContentAlignment = VerticalAlignment.Stretch;
        AutomationProperties.SetName(this, "Loco Loco");
    }
}

/// <summary>
/// The panel that opens from the octopus: a borderless, always-on-top window next to the notification area,
/// listing running and stopped servers. It hides when it loses focus, like Windows' own flyouts.
/// </summary>
sealed partial class Flyout
{
    readonly Engine engine;
    readonly Tray tray;
    readonly Action quit;
    readonly AppWindow appWindow;
    readonly FlyoutRoot root;
    readonly Border surface;
    readonly ScrollViewer scroller;
    readonly StackPanel list;
    readonly GroupHeader running, stopped;
    readonly Border gap = new() { Height = Metrics.Gap };
    readonly Dictionary<string, RowControl> controls = [];
    readonly UISettings ui = new();
    readonly DispatcherQueue dispatcher;
    Palette palette;
    Rows rows = new();
    StackPanel? empty;
    string? highlight, menuRow;
    int holdOpen;
    DateTime hiddenAt;
    bool closing;
    float slideFrom = 16;

    public Window Window { get; }
    public nint Hwnd { get; }
    public bool Visible { get; private set; }
    public bool MenuOpen { get; private set; }
    /// <summary>Stays open when it loses focus. For the screenshot run.</summary>
    public bool StayOpen { get; set; }
    public Rows Rows => rows;
    public FrameworkElement Root => root;
    public Button? OptionsButton => running.MoreButton;

    public Flyout(Engine engine, Tray tray, Action quit)
    {
        this.engine = engine;
        this.tray = tray;
        this.quit = quit;

        list = new StackPanel { Padding = new Thickness(Metrics.Inset) };
        scroller = new ScrollViewer
        {
            Content = list, IsTabStop = false,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        surface = new Border { Child = scroller };
        root = new FlyoutRoot { Content = surface };
        root.PreviewKeyDown += OnKey;
        running = new GroupHeader("Running", ShowOptions);
        stopped = new GroupHeader("Stopped", null);

        Window = new Window { Title = "Loco Loco", Content = root };
        dispatcher = Window.DispatcherQueue;
        Hwnd = WinRT.Interop.WindowNative.GetWindowHandle(Window);
        appWindow = Window.AppWindow;
        var presenter = OverlappedPresenter.Create();
        presenter.IsResizable = false;
        presenter.IsMaximizable = false;
        presenter.IsMinimizable = false;
        presenter.IsAlwaysOnTop = true;
        presenter.SetBorderAndTitleBar(true, false);
        appWindow.SetPresenter(presenter);
        appWindow.IsShownInSwitchers = false;
        appWindow.Closing += (_, e) =>
        {
            if (closing) return;
            e.Cancel = true;
            Hide();
        };
        Window.Activated += (_, e) =>
        {
            if (e.WindowActivationState == WindowActivationState.Deactivated) LostFocus();
        };
        Native.RoundCorners(Hwnd);

        root.ActualThemeChanged += (_, _) => Repaint();
        ui.ColorValuesChanged += (_, _) => dispatcher.TryEnqueue(Repaint);
        palette = Palette.For(root.ActualTheme);
        Repaint();
    }

    // MARK: Showing and hiding

    public void Toggle()
    {
        if (Visible) Hide();
        // The click on the octopus already closed it by taking focus away.
        else if (DateTime.UtcNow - hiddenAt > TimeSpan.FromMilliseconds(300)) Show();
    }

    public void Show()
    {
        if (Visible)
        {
            Native.SetForegroundWindow(Hwnd);
            return;
        }
        highlight = null;
        engine.Expanded = false;
        Refresh(force: true);
        Place();
        Visible = true;
        appWindow.Show(true);
        Window.Activate();
        Native.SetForegroundWindow(Hwnd);
        Animate();
        root.Focus(FocusState.Programmatic);
        engine.IsOpen = true;
    }

    public void Hide()
    {
        if (!Visible) return;
        Visible = false;
        hiddenAt = DateTime.UtcNow;
        appWindow.Hide();
        engine.IsOpen = false;
        engine.Expanded = false;
        highlight = menuRow = null;
    }

    void LostFocus()
    {
        if (!Visible || StayOpen || MenuOpen || holdOpen > 0) return;
        Hide();
    }

    public void Close()
    {
        closing = true;
        Window.Close();
    }

    void Animate()
    {
        if (!ui.AnimationsEnabled) return;
        ElementCompositionPreview.SetIsTranslationEnabled(scroller, true);
        var visual = ElementCompositionPreview.GetElementVisual(scroller);
        var c = visual.Compositor;
        var ease = c.CreateCubicBezierEasingFunction(new Vector2(0.1f, 0.9f), new Vector2(0.2f, 1f));
        var duration = TimeSpan.FromMilliseconds(250);
        var slide = c.CreateVector3KeyFrameAnimation();
        slide.InsertKeyFrame(0, new Vector3(0, slideFrom, 0));
        slide.InsertKeyFrame(1, Vector3.Zero, ease);
        slide.Duration = duration;
        visual.StartAnimation("Translation", slide);
        var fade = c.CreateScalarKeyFrameAnimation();
        fade.InsertKeyFrame(0, 0);
        fade.InsertKeyFrame(1, 1, ease);
        fade.Duration = duration;
        visual.StartAnimation("Opacity", fade);
    }

    // MARK: Placement

    double DesiredHeight()
    {
        double h = 2 * Metrics.Inset + Metrics.Header + (rows.Running.Count > 0 ? rows.Running.Count * Metrics.Row : Metrics.Empty);
        if (rows.Stopped.Count > 0)
            h += Metrics.Gap + Metrics.Header + rows.Stopped.Count * Metrics.Row + (rows.HasMore ? Metrics.Row : 0);
        return holdOpen > 0 ? Math.Max(h, Metrics.DialogMinHeight) : h;
    }

    /// <summary>Where the window went last time, for the screenshot run.</summary>
    public string Placement { get; private set; } = "";

    /// <summary>Above the octopus when it's on the taskbar, else in the corner by the clock.</summary>
    public void Place()
    {
        var icon = tray.Rect();
        var bar = Native.Taskbar();
        var (_, work, scale) = icon is { } ir ? Native.Monitor(ir) : bar is { } b ? Native.Monitor(b.Rect) : Native.Monitor(Native.Cursor());
        int Px(double dip) => (int)Math.Round(dip * scale);
        int margin = Px(Metrics.Margin), w = Px(Metrics.Width);
        // Rounded up, so the list never scrolls by a fraction of a pixel.
        int h = Math.Min((int)Math.Ceiling(DesiredHeight() * scale), work.Height - 2 * margin);
        // Onto the right monitor first, so the client size uses its scale.
        if (!Visible) appWindow.Move(new PointInt32(work.Right - margin - w, work.Bottom - margin - h));
        appWindow.ResizeClient(new SizeInt32(w, h));
        // ResizeClient leaves room for a title bar this window doesn't have, and the window has an
        // invisible resize border. So size and place the client area, the part people see.
        var outer = Native.WindowRect(Hwnd);
        var client = Native.ClientRect(Hwnd);
        if (client.Width > 0 && (client.Width != w || client.Height != h))
        {
            appWindow.Resize(new SizeInt32(outer.Width + w - client.Width, outer.Height + h - client.Height));
            outer = Native.WindowRect(Hwnd);
            client = Native.ClientRect(Hwnd);
        }
        if (client.Width <= 0) client = outer;
        var (x, y, edge) = Spot(icon, bar, work, margin, client.Width, client.Height);
        appWindow.Move(new PointInt32(x - (client.Left - outer.Left), y - (client.Top - outer.Top)));
        slideFrom = edge switch { Edge.Top => -16, _ => 16 };
        Placement = $"icon {icon?.ToString() ?? "none"}, taskbar {bar?.Edge.ToString() ?? "none"}, work {work}, scale {scale}, window {x},{y} {client.Width}x{client.Height}";
    }

    static (int X, int Y, Edge Edge) Spot(RECT? icon, (RECT Rect, Edge Edge)? bar, RECT work, int m, int w, int h)
    {
        int right = work.Right - m - w, bottom = work.Bottom - m - h;
        if (icon is not { } ir || bar is not { } tb || !Inside(tb.Rect, ir)) return (right, bottom, Edge.Bottom);
        int cx = (ir.Left + ir.Right) / 2, cy = (ir.Top + ir.Bottom) / 2;
        int X(int x) => Math.Clamp(x, work.Left + m, Math.Max(work.Left + m, right));
        int Y(int y) => Math.Clamp(y, work.Top + m, Math.Max(work.Top + m, bottom));
        return tb.Edge switch
        {
            Edge.Top => (X(cx - w / 2), work.Top + m, Edge.Top),
            Edge.Left => (work.Left + m, Y(cy - h / 2), Edge.Left),
            Edge.Right => (right, Y(cy - h / 2), Edge.Right),
            _ => (X(cx - w / 2), bottom, Edge.Bottom),
        };
    }

    /// <summary>On the taskbar, not in the overflow window above it.</summary>
    static bool Inside(RECT bar, RECT icon)
    {
        int cx = (icon.Left + icon.Right) / 2, cy = (icon.Top + icon.Bottom) / 2;
        return cx >= bar.Left && cx < bar.Right && cy >= bar.Top && cy < bar.Bottom;
    }

    // MARK: Content

    void Repaint()
    {
        palette = Palette.For(root.ActualTheme);
        surface.Background = palette.Surface;
        Native.DarkFrame(Hwnd, palette.Dark);
        empty = null;
        Build();
    }

    /// <summary>Asks the engine for rows and updates the list when they changed.</summary>
    public void Refresh(bool force = false)
    {
        var next = engine.BuildRows();
        bool same = next.Same(rows);
        rows = next;
        if (same && !force) return;
        Build();
        if (Visible) Place();
    }

    void Build()
    {
        var focused = FocusedElement();
        var focusedRow = focused as RowControl;
        int focusedIndex = focusedRow is null ? -1 : list.Children.IndexOf(focusedRow);
        var focusState = focusedRow?.FocusState ?? FocusState.Unfocused;

        var order = rows.Order;
        var live = order.ToHashSet();
        foreach (var id in controls.Keys.Where(k => !live.Contains(k)).ToList()) controls.Remove(id);
        if (highlight != null && !live.Contains(highlight)) highlight = null;

        var kids = new List<UIElement>();
        running.Set(rows.Running.Count > 0 ? rows.Running.Count : null, palette);
        kids.Add(running.View);
        if (rows.Running.Count == 0) kids.Add(empty ??= EmptyState.Make(palette));
        foreach (var r in rows.Running) kids.Add(RowFor(r));
        if (rows.Stopped.Count > 0)
        {
            kids.Add(gap);
            stopped.Set(rows.StoppedTotal, palette);
            kids.Add(stopped.View);
            foreach (var r in rows.Stopped) kids.Add(RowFor(r));
            if (rows.HasMore)
            {
                if (!controls.TryGetValue(Rows.More, out var more)) controls[Rows.More] = more = new RowControl(this, Rows.More, palette);
                more.SetMore(rows.StoppedTotal - rows.Stopped.Count, palette);
                more.SetHighlight(highlight == Rows.More, !MenuOpen);
                kids.Add(more);
            }
        }

        if (!list.Children.SequenceEqual(kids))
        {
            list.Children.Clear();
            foreach (var k in kids) list.Children.Add(k);
            // Keep the keyboard where it was: on the same row, or the one that took its place.
            if (focusedRow != null && Visible)
            {
                var target = controls.GetValueOrDefault(focusedRow.Id)
                    ?? kids.Skip(Math.Max(0, focusedIndex)).OfType<RowControl>().FirstOrDefault()
                    ?? kids.OfType<RowControl>().LastOrDefault();
                if (target != null) target.Focus(focusState == FocusState.Unfocused ? FocusState.Programmatic : focusState);
                else root.Focus(FocusState.Programmatic);
            }
        }
    }

    RowControl RowFor(Row r)
    {
        if (!controls.TryGetValue(r.Id, out var c)) controls[r.Id] = c = new RowControl(this, r.Id, palette);
        c.Set(r, palette, highlight == r.Id || menuRow == r.Id, !MenuOpen);
        return c;
    }

    object? FocusedElement() => root.XamlRoot is { } x ? FocusManager.GetFocusedElement(x) : null;

    /// <summary>A small borderless icon button, as in Windows' own flyouts.</summary>
    public static Button IconButton(string glyph, string label, Palette p, bool tabStop = false)
    {
        var b = new Button
        {
            Width = 28, Height = 24, Padding = new Thickness(0), BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(4), VerticalAlignment = VerticalAlignment.Center,
            Content = new FontIcon { Glyph = glyph, FontSize = 12 },
            IsTabStop = tabStop, AllowFocusOnInteraction = tabStop,
        };
        var r = b.Resources;
        r["ButtonBackground"] = Palette.Clear;
        r["ButtonBackgroundPointerOver"] = p.ButtonHover;
        r["ButtonBackgroundPressed"] = p.ButtonPressed;
        r["ButtonBackgroundDisabled"] = Palette.Clear;
        foreach (var state in new[] { "", "PointerOver", "Pressed", "Disabled" }) r["ButtonBorderBrush" + state] = Palette.Clear;
        r["ButtonForeground"] = p.HoverLabel;
        r["ButtonForegroundPointerOver"] = p.HoverLabel;
        r["ButtonForegroundPressed"] = p.HighContrast ? p.HoverLabel : p.Secondary;
        r["ButtonForegroundDisabled"] = p.Tertiary;
        ToolTipService.SetToolTip(b, label);
        AutomationProperties.SetName(b, label);
        return b;
    }

    // MARK: Highlight

    void SetHighlight(string? id)
    {
        if (id == highlight) return;
        var old = highlight;
        highlight = id;
        Paint(old);
        Paint(id);
    }

    void Paint(string? id)
    {
        if (id != null && controls.TryGetValue(id, out var c)) c.SetHighlight(id == highlight || id == menuRow, !MenuOpen);
    }

    void PaintAll()
    {
        foreach (var (id, c) in controls) c.SetHighlight(id == highlight || id == menuRow, !MenuOpen);
    }

    public void PointerOver(string id)
    {
        if (!MenuOpen) SetHighlight(id);
    }

    public void PointerLeft(string id)
    {
        if (!MenuOpen && highlight == id) SetHighlight(null);
    }

    public void KeyboardFocused(string id)
    {
        if (!MenuOpen) SetHighlight(id);
    }

    /// <summary>For the screenshot run: the hover look on one row.</summary>
    public void Highlight(string? id) => SetHighlight(id);

    public RowControl? Control(string id) => controls.GetValueOrDefault(id);

    public void OpenOptions()
    {
        if (OptionsButton is { } b) ShowOptions(b);
    }

    public void SetTheme(ElementTheme theme) => root.RequestedTheme = theme;

    // MARK: Actions

    /// <summary>Click or Enter: open a running server, restart a stopped one, or show more.</summary>
    public void Primary(RowControl c)
    {
        if (c.IsMore)
        {
            int index = rows.Order.IndexOf(Rows.More);
            bool keyboard = c.FocusState == FocusState.Keyboard;
            engine.Expanded = true;
            Refresh(force: true);
            if (keyboard && index >= 0 && index < rows.Order.Count && controls.TryGetValue(rows.Order[index], out var next))
            {
                SetHighlight(next.Id);
                next.Focus(FocusState.Keyboard);
            }
            return;
        }
        if (c.Row is not { State: RowState.Idle } row) return;
        if (row.Group == RowGroup.Running)
        {
            if (row.Server == null) return;
            Shell.OpenUrl(row.Url);
            Hide();
        }
        else if (row.CanRestart)
        {
            engine.Restart(row);
            Refresh();
        }
    }

    public void Act(RowControl c, RowAction a)
    {
        if (c.Row is not { } row) return;
        switch (a)
        {
            case RowAction.Stop when row.CanStop: engine.Stop(row); break;
            case RowAction.Restart when row.CanRestart: engine.Restart(row); break;
            case RowAction.Force: engine.ForceStop(row.Id); break;
            case RowAction.Log when row.LogPath is { } log:
                Shell.OpenLog(log);
                Hide();
                return;
        }
        Refresh();
    }

    // MARK: Keys

    RowControl? Current()
    {
        var f = FocusedElement();
        if (f is RowControl rc) return rc;
        if (f == null || ReferenceEquals(f, root)) return highlight != null ? controls.GetValueOrDefault(highlight) : null;
        return null;
    }

    void OnKey(object sender, KeyRoutedEventArgs e)
    {
        if (MenuOpen || holdOpen > 0) return;
        bool ctrl = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control).HasFlag(CoreVirtualKeyStates.Down);
        var row = Current();
        switch (e.Key)
        {
            case VirtualKey.Escape:
                Hide();
                break;
            case VirtualKey.Down:
                Move(1);
                break;
            case VirtualKey.Up:
                Move(-1);
                break;
            case VirtualKey.Enter when row != null:
                Primary(row);
                break;
            case VirtualKey.Delete when row?.Row is { State: RowState.Force } r:
                engine.ForceStop(r.Id);
                Refresh();
                break;
            case VirtualKey.Delete when row?.Row is { CanStop: true } r:
                engine.Stop(r);
                Refresh();
                break;
            case VirtualKey.R when ctrl && row?.Row is { CanRestart: true } r:
                engine.Restart(r);
                Refresh();
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    void Move(int delta)
    {
        var order = rows.Order;
        if (order.Count == 0) return;
        var current = (FocusedElement() as RowControl)?.Id ?? highlight;
        int i = current is null ? -1 : order.IndexOf(current);
        var next = i < 0 ? (delta > 0 ? order[0] : order[^1]) : order[Math.Clamp(i + delta, 0, order.Count - 1)];
        SetHighlight(next);
        if (controls.TryGetValue(next, out var c))
        {
            c.Focus(FocusState.Keyboard);
            c.StartBringIntoView();
        }
    }
}
