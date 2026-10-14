namespace LocoLoco.Art;

public readonly record struct Pt(double X, double Y)
{
    public static Pt operator +(Pt a, Pt b) => new(a.X + b.X, a.Y + b.Y);
    public static Pt operator -(Pt a, Pt b) => new(a.X - b.X, a.Y - b.Y);
    public static Pt operator *(Pt a, double k) => new(a.X * k, a.Y * k);
    public double Length => Math.Sqrt(X * X + Y * Y);
}

public readonly record struct Cubic(Pt P0, Pt P1, Pt P2, Pt P3)
{
    public Pt At(double t)
    {
        double u = 1 - t, a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
        return new(a * P0.X + b * P1.X + c * P2.X + d * P3.X, a * P0.Y + b * P1.Y + c * P2.Y + d * P3.Y);
    }

    public Cubic Mirrored
    {
        get
        {
            static Pt M(Pt p) => new(512 - p.X, p.Y);
            return new(M(P0), M(P1), M(P2), M(P3));
        }
    }

    public Cubic Reversed => new(P3, P2, P1, P0);
}

/// <summary>
/// The Loco Loco octopus, from the same paths as app/macos/Sources/LocoLoco/Octopus.swift: a 512 grid with y pointing down.
/// The app icon, the tray icons and the flyout's sleeping octopus all come from here.
/// </summary>
public static class Octopus
{
    // The solid mark: head, two eyes, four tapered arms.
    public static readonly Cubic[] Head = Parse("M256 60C336 60 392 116 392 196C392 248 368 284 332 302L180 302C144 284 120 248 120 196C120 116 176 60 256 60");
    public static readonly Pt[] Eyes = [new(212, 218), new(300, 218)];
    public const double EyeRx = 24, EyeRy = 30;
    static readonly Cubic[] OuterArm = Parse("M194 270C160 296 104 290 76 324C54 352 60 392 92 398C114 402 126 386 116 372");
    static readonly Cubic[] InnerArm = Parse("M234 292C236 338 230 376 222 406C214 434 196 448 174 440");
    public static readonly Cubic[][] Arms = [OuterArm, InnerArm, Mirror(InnerArm), Mirror(OuterArm)];

    // The line mark: one stroke from the left arm tip over the head to the right arm tip. The inner arms hang free.
    static readonly Cubic[] LineSide = Parse("M116 372C126 386 114 402 92 398C60 392 54 352 76 324C96 298 128 300 142 290C154 281 124 246 122 200");
    static readonly Cubic[] LineTop = Parse("M122 200C122 116 178 60 256 60C334 60 390 116 390 200");
    public static readonly Cubic[] LineOuter = [.. LineSide, .. LineTop, .. LineSide.Reverse().Select(c => c.Mirrored.Reversed)];
    static readonly Cubic[] LineInnerArm = Parse("M228 302C230 342 226 378 218 406C210 432 192 446 172 438");
    public static readonly Cubic[][] LineInner = [LineInnerArm, Mirror(LineInnerArm)];

    /// <summary>The tray glyph's view box in the grid.</summary>
    public const double GlyphX = 31, GlyphY = 30, GlyphSide = 450;

    static Cubic[] Mirror(Cubic[] c) => [.. c.Select(s => s.Mirrored)];

    /// <summary>Reads the M, C and L commands the mark uses.</summary>
    public static Cubic[] Parse(string d)
    {
        var tokens = new List<string>();
        var number = "";
        void Flush()
        {
            if (number.Length > 0) tokens.Add(number);
            number = "";
        }
        foreach (var ch in d)
        {
            if (char.IsLetter(ch)) { Flush(); tokens.Add(ch.ToString()); }
            else if (ch is ' ' or ',') Flush();
            else if (ch == '-') { Flush(); number = "-"; }
            else number += ch;
        }
        Flush();

        var inv = System.Globalization.CultureInfo.InvariantCulture;
        var segments = new List<Cubic>();
        string command = "M";
        var current = new Pt(0, 0);
        int i = 0;
        Pt Point()
        {
            var p = new Pt(double.Parse(tokens[i], inv), double.Parse(tokens[i + 1], inv));
            i += 2;
            return p;
        }
        while (i < tokens.Count)
        {
            if (char.IsLetter(tokens[i][0])) command = tokens[i++];
            switch (command)
            {
                case "M":
                    current = Point();
                    break;
                case "L":
                    var p = Point();
                    var third = (p - current) * (1.0 / 3);
                    segments.Add(new(current, current + third, current + third * 2, p));
                    current = p;
                    break;
                default:
                    Pt a = Point(), b = Point(), e = Point();
                    segments.Add(new(current, a, b, e));
                    current = e;
                    break;
            }
        }
        return [.. segments];
    }

    /// <summary>Points along the curves, `steps` per segment.</summary>
    public static List<Pt> Flatten(IReadOnlyList<Cubic> segments, int steps = 48)
    {
        var points = new List<Pt>();
        for (int i = 0; i < segments.Count; i++)
            for (int k = i == 0 ? 0 : 1; k <= steps; k++) points.Add(segments[i].At((double)k / steps));
        return points;
    }

    /// <summary>An arm that thins from r0 to r1 along its length, as discs to union.</summary>
    public static List<(Pt C, double R)> Taper(IReadOnlyList<Cubic> segments, double r0, double r1, double ease = 0.9)
    {
        var points = Flatten(segments, 80);
        var lengths = new double[points.Count];
        for (int i = 1; i < points.Count; i++) lengths[i] = lengths[i - 1] + (points[i] - points[i - 1]).Length;
        double total = lengths[^1] > 0 ? lengths[^1] : 1;
        var discs = new List<(Pt, double)>(points.Count);
        for (int i = 0; i < points.Count; i++) discs.Add((points[i], r0 + (r1 - r0) * Math.Pow(lengths[i] / total, ease)));
        return discs;
    }

    /// <summary>A quadratic curve as points.</summary>
    public static List<Pt> Quad(Pt a, Pt control, Pt b, int steps = 32)
    {
        var points = new List<Pt>(steps + 1);
        for (int k = 0; k <= steps; k++)
        {
            double t = (double)k / steps, u = 1 - t;
            points.Add(a * (u * u) + control * (2 * u * t) + b * (t * t));
        }
        return points;
    }

    /// <summary>Closed eyes on the line mark: an arc under each eye position.</summary>
    public static List<List<Pt>> SleepingEyes(double width, double sag, double dy) =>
        [.. Eyes.Select(e =>
        {
            double y = e.Y + dy - sag / 2;
            return Quad(new(e.X - width / 2, y), new(e.X, y + 2 * sag), new(e.X + width / 2, y));
        })];

    /// <summary>Closed eyes on the solid mark, stroked 0.85 rx wide.</summary>
    public static List<List<Pt>> SolidSleepingEyes() =>
        [.. Eyes.Select(e => Quad(new(e.X - 1.5 * EyeRx, e.Y - 4), new(e.X, e.Y + 1.4 * EyeRy), new(e.X + 1.5 * EyeRx, e.Y - 4)))];
}
