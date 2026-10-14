namespace LocoLoco.Art;

/// <summary>Draws the app icon and the tray icons from the octopus geometry.</summary>
public static class Icons
{
    public static readonly int[] AppSizes = [16, 20, 24, 32, 40, 48, 64, 256];

    static readonly Rgba NavyTop = Rgba.Hex(0x16465A), NavyBottom = Rgba.Hex(0x0D2B3B);
    static readonly Rgba White = new(1, 1, 1);

    /// <summary>Windows 11's default accent fills: the light theme's dark shade and the dark theme's light one.</summary>
    public static readonly Rgba DefaultAccentLight = Rgba.Hex(0x005FB8), DefaultAccentDark = Rgba.Hex(0x60CDFF);

    /// <summary>The white line octopus on a deep sea navy plate with round corners.</summary>
    public static Canvas App(int px)
    {
        var c = new Canvas(px, px);
        double inset = px <= 32 ? 1 : Math.Round(px * 0.04);
        double side = px - 2 * inset;
        var plate = new RoundRect(inset, inset, px - inset, px - inset, side * 0.19);
        c.Paint(plate, (_, y) => Rgba.Mix(NavyTop, NavyBottom, Math.Clamp((y - inset) / side, 0, 1)));

        // Same proportions as the Mac icon: the 512 grid at 1.06 on an 824 plate, centred a little low.
        double unit = side * 1.06 / 824;
        var g = new Grid(unit, px / 2.0 - 256 * unit, px / 2.0 - 254 * unit + 6 * side / 824);
        bool small = px <= 32;
        // At the smallest sizes the line would fade under a pixel, so keep it at least this wide.
        double minLine = px <= 24 ? 1.0 : px <= 32 ? 1.25 : 0;
        double line = Math.Max((small ? 34 : 22) * unit, minLine);
        double eye = Math.Max((small ? 20 : 15) * unit, line * 0.62);
        var strokes = new List<List<Pt>> { g.Map(Octopus.Flatten(Octopus.LineOuter)) };
        strokes.AddRange(Octopus.LineInner.Select(a => g.Map(Octopus.Flatten(a))));
        c.Paint(new Stroke(strokes, line), White);
        foreach (var e in Octopus.Eyes)
        {
            var p = g.Map(new Pt(e.X, e.Y + 4));
            c.Paint(new Ellipse(p, eye, eye), White);
        }
        return c;
    }

    /// <summary>
    /// The solid octopus for the notification area, in one colour that suits the taskbar.
    /// Its eyes close when nothing runs. A count above zero adds an accent badge with a cut-out ring.
    /// </summary>
    public static Canvas Tray(int px, bool lightTaskbar, bool asleep, int count, Rgba? accent = null)
    {
        var c = new Canvas(px, px);
        var ink = lightTaskbar ? Rgba.Hex(0x1A1A1A) : White;
        double unit = px / Octopus.GlyphSide;
        var g = new Grid(unit, -Octopus.GlyphX * unit, -Octopus.GlyphY * unit);

        var body = new Union(
            new Fill(g.Map(Octopus.Flatten(Octopus.Head))),
            new Union(Octopus.Arms.Select(a => (Shape)new Discs(Octopus.Taper(a, 36, 20).Select(d => (g.Map(d.C), d.R * unit))))));
        c.Paint(body, ink);
        if (asleep)
        {
            c.Erase(new Stroke(Octopus.SolidSleepingEyes().Select(l => (IReadOnlyList<Pt>)g.Map(l)), 0.85 * Octopus.EyeRx * unit));
        }
        else
        {
            foreach (var e in Octopus.Eyes) c.Erase(new Ellipse(g.Map(e), Octopus.EyeRx * unit, Octopus.EyeRy * unit));
        }

        if (count > 0)
        {
            var fill = accent ?? (lightTaskbar ? DefaultAccentLight : DefaultAccentDark);
            var b = Badge.Layout(px, count);
            var pill = new RoundRect(b.X, b.Y, b.X + b.Width, b.Y + b.Height, b.Height / 2.0);
            c.Erase(new Grow(pill, b.Ring));
            c.Paint(pill, fill);
            c.Paint(new Union(b.Pixels.Select(p => (Shape)new RoundRect(p.X, p.Y, p.X + p.Size, p.Y + p.Size, 0))), fill.Ink);
        }
        return c;
    }
}

/// <summary>
/// The count badge: an accent pill in the bottom-right corner with bitmap digits, so they stay sharp at 16 and 24 px
/// where a font would blur. 3×5 digits at the smallest sizes, 5×7 from 24 px, doubled at 200% and up.
/// </summary>
public static class Badge
{
    public sealed record Box(string Text, int X, int Y, int Width, int Height, int Ring, List<(int X, int Y, int Size)> Pixels);

    /// <summary>"4", "10", or "9+" at 16 px where two digits are too small. Over 99 shows "99+".</summary>
    public static string Text(int px, int count) =>
        count < 10 ? count.ToString() : px <= 16 ? "9+" : count > 99 ? "99+" : count.ToString();

    static readonly Dictionary<char, string> Small = new()
    {
        ['0'] = "### #.# #.# #.# ###",
        ['1'] = ".#. ##. .#. .#. ###",
        ['2'] = "### ..# ### #.. ###",
        ['3'] = "### ..# .## ..# ###",
        ['4'] = "#.# #.# ### ..# ..#",
        ['5'] = "### #.. ### ..# ###",
        ['6'] = "### #.. ### #.# ###",
        ['7'] = "### ..# ..# ..# ..#",
        ['8'] = "### #.# ### #.# ###",
        ['9'] = "### #.# ### ..# ###",
        ['+'] = "... .#. ### .#. ...",
    };

    static readonly Dictionary<char, string> Large = new()
    {
        ['0'] = ".###. #...# #...# #...# #...# #...# .###.",
        ['1'] = "..#.. .##.. ..#.. ..#.. ..#.. ..#.. .###.",
        ['2'] = ".###. #...# ....# ...#. ..#.. .#... #####",
        ['3'] = ".###. #...# ....# ..##. ....# #...# .###.",
        ['4'] = "...#. ..##. .#.#. #..#. ##### ...#. ...#.",
        ['5'] = "##### #.... ####. ....# ....# #...# .###.",
        ['6'] = "..##. .#... #.... ####. #...# #...# .###.",
        ['7'] = "##### ....# ...#. ..#.. .#... .#... .#...",
        ['8'] = ".###. #...# #...# .###. #...# #...# .###.",
        ['9'] = ".###. #...# #...# .#### ....# ...#. .##..",
        ['+'] = "..... ..#.. ..#.. ##### ..#.. ..#.. .....",
    };

    public static Box Layout(int px, int count)
    {
        var text = Text(px, count);
        // The font and scale whose height is closest to 30% of the icon.
        var (font, scale) = new[] { (Small, 1), (Large, 1), (Small, 2), (Large, 2), (Small, 3), (Large, 3) }
            .MinBy(f => Math.Abs(Rows(f.Item1) * f.Item2 - px * 0.3));
        int cw = Cols(font) * scale, ch = Rows(font) * scale, gap = scale;
        int tw = text.Length * cw + (text.Length - 1) * gap;

        int pad = Math.Max(2, (int)Math.Round(px * 0.08));
        int h = ch + 2 * pad;
        int w = Math.Max(h, tw + 2 * pad);
        if ((w - tw) % 2 != 0) w++;
        int x = px - w, y = px - h;
        int ring = Math.Max(1, (int)Math.Round(px * 0.06));

        var pixels = new List<(int, int, int)>();
        int gx = x + (w - tw) / 2, gy = y + pad;
        foreach (var chr in text)
        {
            var rows = font[chr].Split(' ');
            for (int r = 0; r < rows.Length; r++)
                for (int c = 0; c < rows[r].Length; c++)
                    if (rows[r][c] == '#') pixels.Add((gx + c * scale, gy + r * scale, scale));
            gx += cw + gap;
        }
        return new Box(text, x, y, w, h, ring, pixels);
    }

    static int Rows(Dictionary<char, string> font) => font['0'].Split(' ').Length;
    static int Cols(Dictionary<char, string> font) => font['0'].Split(' ')[0].Length;
}
