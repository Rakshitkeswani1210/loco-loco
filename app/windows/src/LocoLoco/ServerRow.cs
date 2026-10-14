using LocoCore;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Octo = LocoLoco.Art.Octopus;
using Pt = LocoLoco.Art.Pt;

namespace LocoLoco;

/// <summary>Sizes in device-independent pixels, shared by the layout and the height sum.</summary>
static class Metrics
{
    public const double Width = 360, Margin = 12, Inset = 4, Row = 32, Header = 32, Empty = 94, Gap = 8;
    public const double DialogMinHeight = 240;
    public static readonly Thickness RowPadding = new(12, 0, 4, 0);
}

/// <summary>One server, or the "More" row: port, name, and a trailing slot for the time, a spinner or buttons.</summary>
sealed partial class RowControl : ContentControl
{
    enum Kind { None, Time, Failure, Busy, Force, Actions, More }

    readonly Flyout host;
    readonly Border back;
    readonly TextBlock port, name;
    readonly Border slot;
    string slotKey = "";
    Palette palette;
    bool highlighted;

    public string Id { get; }
    public Row? Row { get; private set; }
    public bool IsMore => Id == Rows.More;
    int moreCount;

    public RowControl(Flyout host, string id, Palette palette)
    {
        this.host = host;
        this.palette = palette;
        Id = id;
        IsTabStop = true;
        UseSystemFocusVisuals = true;
        Height = Metrics.Row;
        // The focus rectangle follows this.
        CornerRadius = new CornerRadius(4);
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalContentAlignment = VerticalAlignment.Stretch;

        port = new TextBlock { FontSize = 14, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.NoWrap };
        Typography.SetNumeralAlignment(port, FontNumeralAlignment.Tabular);
        name = new TextBlock
        {
            FontSize = 14, VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis,
        };
        slot = new Border { VerticalAlignment = VerticalAlignment.Center };

        var grid = new Grid { ColumnSpacing = 8 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.Children.Add(port);
        Grid.SetColumn(name, 1);
        grid.Children.Add(name);
        Grid.SetColumn(slot, 2);
        grid.Children.Add(slot);
        if (IsMore) Grid.SetColumnSpan(port, 2);

        back = new Border { CornerRadius = new CornerRadius(4), Padding = Metrics.RowPadding, Child = grid };
        Content = back;

        PointerEntered += (_, _) => host.PointerOver(Id);
        PointerExited += (_, _) => host.PointerLeft(Id);
        Tapped += (_, e) =>
        {
            if (InsideButton(e.OriginalSource as DependencyObject)) return;
            e.Handled = true;
            host.Primary(this);
        };
        ContextRequested += (_, e) =>
        {
            e.Handled = true;
            host.ShowRowMenu(this, e.TryGetPosition(this, out var p) ? p : null);
        };
        GotFocus += (_, _) =>
        {
            if (FocusState == FocusState.Keyboard) host.KeyboardFocused(Id);
        };
    }

    bool InsideButton(DependencyObject? d)
    {
        for (; d != null && d != this; d = VisualTreeHelper.GetParent(d))
            if (d is Microsoft.UI.Xaml.Controls.Primitives.ButtonBase) return true;
        return false;
    }

    /// <summary>What Narrator reads.</summary>
    public string Spoken => Row?.AccessibleName(DateTime.UtcNow) ?? $"More, {moreCount} stopped servers";

    public void SetMore(int count, Palette p)
    {
        if (!ReferenceEquals(p, palette)) slotKey = "";
        moreCount = count;
        palette = p;
        port.Text = "More";
        name.Text = "";
        Paint();
        SetSlot("more " + count, () =>
        {
            var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(0, 0, 8, 0) };
            line.Children.Add(Small(count.ToString(), palette.Secondary));
            line.Children.Add(new FontIcon { Glyph = "\uE76C", FontSize = 10, Foreground = palette.Secondary });
            return line;
        });
        AutomationProperties.SetName(this, Spoken);
    }

    /// <summary>Brings the row up to date. Rebuilds the trailing slot only when its kind changes.</summary>
    public void Set(Row row, Palette p, bool highlight, bool showActions)
    {
        bool repaint = !ReferenceEquals(p, palette) || highlight != highlighted;
        bool changed = Row is null || !Row.Equals(row);
        Row = row;
        palette = p;
        highlighted = highlight;
        port.Text = row.Port.ToString();
        name.Text = row.Name;
        bool busy = row.State != RowState.Idle;
        port.Opacity = name.Opacity = busy ? 0.45 : 1;
        if (repaint || changed) Paint();

        var actions = highlight && showActions && row.State == RowState.Idle ? row.Actions : [];
        var now = DateTime.UtcNow;
        var (kind, key) = row.State switch
        {
            RowState.Stopping or RowState.Starting => (Kind.Busy, "busy"),
            RowState.Force => (Kind.Force, "force"),
            _ when actions.Length > 0 => (Kind.Actions, "actions " + string.Join(",", actions)),
            _ when row.Failure != null => (Kind.Failure, "failure " + row.Failure),
            _ => (Kind.Time, "time " + TimeText.Short(row.Time, now)),
        };
        if (repaint) slotKey = "";
        SetSlot(key, () => kind switch
        {
            Kind.Busy => new ProgressRing { Width = 14, Height = 14, IsActive = true, Margin = new Thickness(0, 0, 8, 0) },
            Kind.Force => ForceButton(),
            Kind.Actions => ActionButtons(actions),
            Kind.Failure => Failure(row.Failure!),
            _ => Small(TimeText.Short(row.Time, now), palette.Secondary, 8),
        });
        AutomationProperties.SetName(this, Spoken);
    }

    public void SetHighlight(bool on, bool showActions)
    {
        if (Row is { } row) Set(row, palette, on, showActions);
        else if (on != highlighted)
        {
            highlighted = on;
            Paint();
        }
    }

    void Paint()
    {
        back.Background = highlighted ? palette.Hover : Palette.Clear;
        var label = highlighted ? palette.HoverLabel : palette.Label;
        port.Foreground = highlighted && palette.HighContrast ? palette.HoverLabel : palette.Secondary;
        name.Foreground = label;
    }

    void SetSlot(string key, Func<FrameworkElement> make)
    {
        if (key == slotKey) return;
        slotKey = key;
        slot.Child = make();
    }

    TextBlock Small(string text, Brush brush, double right = 0) => new()
    {
        Text = text, FontSize = 12, Foreground = highlighted && palette.HighContrast ? palette.HoverLabel : brush,
        VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, right, 0),
    };

    FrameworkElement Failure(string text)
    {
        var t = Small(text, palette.Red, 8);
        t.MaxWidth = 150;
        t.TextTrimming = TextTrimming.CharacterEllipsis;
        ToolTipService.SetToolTip(t, text);
        return t;
    }

    Button ForceButton()
    {
        var b = new Button
        {
            Content = "Force stop", Height = 24, Padding = new Thickness(8, 0, 8, 0), FontSize = 12,
            VerticalAlignment = VerticalAlignment.Center, IsTabStop = false,
        };
        b.Click += (_, _) => host.Act(this, RowAction.Force);
        AutomationProperties.SetName(b, $"Force stop {Row?.Name}");
        return b;
    }

    static readonly Dictionary<RowAction, (string Glyph, string Label)> Glyphs = new()
    {
        [RowAction.Stop] = ("\uE71A", "Stop"),
        [RowAction.Restart] = ("\uE72C", "Restart"),
        [RowAction.Log] = ("\uE8A5", "Show log"),
    };

    FrameworkElement ActionButtons(RowAction[] actions)
    {
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
        foreach (var a in actions)
        {
            var (glyph, label) = Glyphs[a];
            var b = Flyout.IconButton(glyph, label, palette);
            AutomationProperties.SetName(b, $"{label} {Row?.Name}");
            b.Click += (_, _) => host.Act(this, a);
            line.Children.Add(b);
        }
        return line;
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new RowPeer(this);

    public void Invoke() => host.Primary(this);

    sealed partial class RowPeer(RowControl owner) : FrameworkElementAutomationPeer(owner), IInvokeProvider
    {
        protected override string GetNameCore() => owner.Spoken;
        protected override string GetClassNameCore() => nameof(RowControl);
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Button;
        protected override object? GetPatternCore(PatternInterface pattern) =>
            pattern == PatternInterface.Invoke ? this : base.GetPatternCore(pattern);
        public void Invoke() => owner.Invoke();
    }
}

/// <summary>"Running 2" or "Stopped 5", with the ··· button on the Running header.</summary>
sealed class GroupHeader
{
    readonly TextBlock title, count;
    readonly StackPanel label;
    readonly Action<Button>? onMore;
    Palette? palette;
    public Grid View { get; }
    public Button? MoreButton { get; private set; }

    public GroupHeader(string text, Action<Button>? onMore)
    {
        this.onMore = onMore;
        title = new TextBlock { Text = text, FontSize = 12, FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
        count = new TextBlock { FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
        label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, VerticalAlignment = VerticalAlignment.Center };
        label.Children.Add(title);
        label.Children.Add(count);
        AutomationProperties.SetHeadingLevel(label, AutomationHeadingLevel.Level2);

        View = new Grid { Height = Metrics.Header, Padding = Metrics.RowPadding };
        View.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        View.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        View.Children.Add(label);
    }

    public void Set(int? n, Palette p)
    {
        count.Text = n?.ToString() ?? "";
        count.Visibility = n is null ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetName(label, n is null ? title.Text : $"{title.Text}, {n}");
        if (ReferenceEquals(p, palette)) return;
        palette = p;
        title.Foreground = p.Label;
        count.Foreground = p.Secondary;
        if (onMore == null) return;
        // Lightweight button colours only apply when the template loads, so a new palette needs a new button.
        if (MoreButton != null) View.Children.Remove(MoreButton);
        var b = Flyout.IconButton("\uE712", "More options", p, tabStop: true);
        b.Click += (_, _) => onMore(b);
        Grid.SetColumn(b, 1);
        View.Children.Add(b);
        MoreButton = b;
    }
}

/// <summary>The sleeping octopus and "Nothing running".</summary>
static class EmptyState
{
    public static StackPanel Make(Palette p)
    {
        var panel = new StackPanel
        {
            Height = Metrics.Empty, Padding = new Thickness(0, 16, 0, 18), Spacing = 6,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        // Scaled here rather than with Stretch, which drew nothing on Windows.
        var (data, width) = Geometry(Size, Stroke);
        var path = new Microsoft.UI.Xaml.Shapes.Path
        {
            Data = data, Width = width, Height = Size,
            Stroke = p.Tertiary, StrokeThickness = Stroke,
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        AutomationProperties.SetAccessibilityView(path, AccessibilityView.Raw);
        panel.Children.Add(path);
        panel.Children.Add(new TextBlock
        {
            Text = "Nothing running", FontSize = 14, Foreground = p.Secondary, HorizontalAlignment = HorizontalAlignment.Center,
        });
        return panel;
    }

    const double Size = 34, Stroke = 1.5;

    /// <summary>The line octopus with closed eyes, fitted to the given height, and its width.</summary>
    static (PathGeometry Data, double Width) Geometry(double height, double stroke)
    {
        var curves = new List<IReadOnlyList<Art.Cubic>> { Octo.LineOuter };
        curves.AddRange(Octo.LineInner);
        var eyes = Octo.SleepingEyes(52, 20, 4);
        var all = curves.SelectMany(cs => cs.SelectMany(c => new[] { c.P0, c.P1, c.P2, c.P3 })).Concat(eyes.SelectMany(e => e)).ToList();
        double x0 = all.Min(q => q.X), y0 = all.Min(q => q.Y), x1 = all.Max(q => q.X), y1 = all.Max(q => q.Y);
        double k = (height - stroke) / (y1 - y0);
        Point P(Pt q) => new((q.X - x0) * k + stroke / 2, (q.Y - y0) * k + stroke / 2);

        var g = new PathGeometry();
        foreach (var cs in curves)
        {
            var f = new PathFigure { StartPoint = P(cs[0].P0), IsClosed = false, IsFilled = false };
            foreach (var c in cs) f.Segments.Add(new BezierSegment { Point1 = P(c.P1), Point2 = P(c.P2), Point3 = P(c.P3) });
            g.Figures.Add(f);
        }
        foreach (var eye in eyes)
        {
            var f = new PathFigure { StartPoint = P(eye[0]), IsClosed = false, IsFilled = false };
            var line = new PolyLineSegment();
            foreach (var pt in eye.Skip(1)) line.Points.Add(P(pt));
            f.Segments.Add(line);
            g.Figures.Add(f);
        }
        return (g, Math.Ceiling((x1 - x0) * k + stroke));
    }
}
