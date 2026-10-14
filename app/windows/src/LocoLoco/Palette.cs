using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace LocoLoco;

/// <summary>
/// The flyout's colours: Windows 11's Fluent values for Light and Dark on a solid surface,
/// and the system's own colours in a high contrast theme.
/// </summary>
sealed class Palette
{
    public required Brush Surface { get; init; }
    public required Brush Label { get; init; }
    public required Brush Secondary { get; init; }
    /// <summary>Decoration only, never text.</summary>
    public required Brush Tertiary { get; init; }
    public required Brush Hover { get; init; }
    /// <summary>Text on a hovered row. Only differs in high contrast, where the hover is the highlight colour.</summary>
    public required Brush HoverLabel { get; init; }
    public required Brush ButtonHover { get; init; }
    public required Brush ButtonPressed { get; init; }
    public required Brush Red { get; init; }
    public required bool Dark { get; init; }
    public bool HighContrast { get; init; }

    static SolidColorBrush Brush(byte a, byte r, byte g, byte b) => new(Color.FromArgb(a, r, g, b));
    static SolidColorBrush Black(double a) => Brush((byte)Math.Round(a * 255), 0, 0, 0);
    static SolidColorBrush White(double a) => Brush((byte)Math.Round(a * 255), 255, 255, 255);

    public static Palette For(ElementTheme theme)
    {
        if (new AccessibilitySettings().HighContrast) return Contrast();
        return theme == ElementTheme.Dark
            ? new Palette
            {
                Surface = Brush(255, 0x2C, 0x2C, 0x2C),
                Label = White(1),
                Secondary = White(0.786),
                Tertiary = White(0.25),
                Hover = White(0.061),
                HoverLabel = White(1),
                ButtonHover = White(0.084),
                ButtonPressed = White(0.04),
                Red = Brush(255, 0xFF, 0x99, 0xA4),
                Dark = true,
            }
            : new Palette
            {
                Surface = Brush(255, 0xF9, 0xF9, 0xF9),
                Label = Black(0.896),
                Secondary = Black(0.606),
                Tertiary = Black(0.26),
                Hover = Black(0.037),
                HoverLabel = Black(0.896),
                ButtonHover = Black(0.06),
                ButtonPressed = Black(0.024),
                Red = Brush(255, 0xC4, 0x2B, 0x1C),
                Dark = false,
            };
    }

    static Palette Contrast()
    {
        var ui = new UISettings();
        SolidColorBrush Sys(UIElementType t) => new(ui.UIElementColor(t));
        var window = ui.UIElementColor(UIElementType.Window);
        return new Palette
        {
            Surface = new SolidColorBrush(window),
            Label = Sys(UIElementType.WindowText),
            Secondary = Sys(UIElementType.WindowText),
            Tertiary = Sys(UIElementType.GrayText),
            Hover = Sys(UIElementType.Highlight),
            HoverLabel = Sys(UIElementType.HighlightText),
            ButtonHover = Sys(UIElementType.Highlight),
            ButtonPressed = Sys(UIElementType.Highlight),
            Red = Sys(UIElementType.WindowText),
            Dark = window.R + window.G + window.B < 3 * 128,
            HighContrast = true,
        };
    }

    public static readonly Brush Clear = new SolidColorBrush(Colors.Transparent);
}
