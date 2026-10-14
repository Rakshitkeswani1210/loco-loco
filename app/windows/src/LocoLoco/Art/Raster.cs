namespace LocoLoco.Art;

/// <summary>A straight-alpha colour, each channel 0 to 1.</summary>
public readonly record struct Rgba(double R, double G, double B, double A = 1)
{
    public static Rgba Hex(uint rgb, double a = 1) => new((rgb >> 16 & 0xFF) / 255.0, (rgb >> 8 & 0xFF) / 255.0, (rgb & 0xFF) / 255.0, a);
    public static Rgba Mix(Rgba x, Rgba y, double t) => new(x.R + (y.R - x.R) * t, x.G + (y.G - x.G) * t, x.B + (y.B - x.B) * t, x.A + (y.A - x.A) * t);
    /// <summary>Black or white, whichever reads better on this colour.</summary>
    public Rgba Ink => 0.2126 * Lin(R) + 0.7152 * Lin(G) + 0.0722 * Lin(B) > 0.36 ? new(0, 0, 0) : new(1, 1, 1);
    static double Lin(double c) => c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
}

/// <summary>A shape as a signed distance in pixels: negative inside. Each shape keeps its bounding box so far pixels skip it.</summary>
public abstract class Shape
{
    public double X0 { get; protected set; } = double.NegativeInfinity;
    public double Y0 { get; protected set; } = double.NegativeInfinity;
    public double X1 { get; protected set; } = double.PositiveInfinity;
    public double Y1 { get; protected set; } = double.PositiveInfinity;

    public abstract double Distance(double x, double y);

    /// <summary>A lower bound of the distance: how far the point is from the bounding box.</summary>
    public double BoxDistance(double x, double y)
    {
        double dx = Math.Max(Math.Max(X0 - x, x - X1), 0), dy = Math.Max(Math.Max(Y0 - y, y - Y1), 0);
        return Math.Sqrt(dx * dx + dy * dy);
    }

    protected void Bound(IEnumerable<Pt> points, double pad)
    {
        X0 = Y0 = double.PositiveInfinity;
        X1 = Y1 = double.NegativeInfinity;
        foreach (var p in points)
        {
            X0 = Math.Min(X0, p.X - pad); Y0 = Math.Min(Y0, p.Y - pad);
            X1 = Math.Max(X1, p.X + pad); Y1 = Math.Max(Y1, p.Y + pad);
        }
    }

    protected static double SegmentDistance(double x, double y, Pt a, Pt b)
    {
        double vx = b.X - a.X, vy = b.Y - a.Y, wx = x - a.X, wy = y - a.Y;
        double len = vx * vx + vy * vy;
        double t = len > 0 ? Math.Clamp((wx * vx + wy * vy) / len, 0, 1) : 0;
        double dx = wx - t * vx, dy = wy - t * vy;
        return Math.Sqrt(dx * dx + dy * dy);
    }
}

/// <summary>Maps shapes from a design grid to pixels: pixel = grid * Scale + Offset.</summary>
public readonly record struct Grid(double Scale, double OffsetX, double OffsetY)
{
    public Pt Map(Pt p) => new(p.X * Scale + OffsetX, p.Y * Scale + OffsetY);
    public List<Pt> Map(IEnumerable<Pt> points) => [.. points.Select(Map)];
}

/// <summary>A closed polygon, filled with the nonzero rule.</summary>
public sealed class Fill : Shape
{
    readonly Pt[] p;

    public Fill(IReadOnlyList<Pt> points)
    {
        p = [.. points];
        Bound(p, 0);
    }

    public override double Distance(double x, double y)
    {
        double best = double.PositiveInfinity;
        int winding = 0;
        for (int i = 0, j = p.Length - 1; i < p.Length; j = i++)
        {
            Pt a = p[j], b = p[i];
            best = Math.Min(best, SegmentDistance(x, y, a, b));
            if (a.Y <= y)
            {
                if (b.Y > y && Cross(a, b, x, y) > 0) winding++;
            }
            else if (b.Y <= y && Cross(a, b, x, y) < 0)
            {
                winding--;
            }
        }
        return winding != 0 ? -best : best;
    }

    static double Cross(Pt a, Pt b, double x, double y) => (b.X - a.X) * (y - a.Y) - (x - a.X) * (b.Y - a.Y);
}

/// <summary>A union of discs, for the tapered arms.</summary>
public sealed class Discs : Shape
{
    readonly (Pt C, double R)[] discs;

    public Discs(IEnumerable<(Pt C, double R)> d)
    {
        discs = [.. d];
        double r = discs.Max(x => x.R);
        Bound(discs.Select(x => x.C), r);
    }

    public override double Distance(double x, double y)
    {
        double best = double.PositiveInfinity;
        foreach (var (c, r) in discs)
        {
            double dx = x - c.X, dy = y - c.Y;
            if (Math.Abs(dx) - r >= best || Math.Abs(dy) - r >= best) continue;
            best = Math.Min(best, Math.Sqrt(dx * dx + dy * dy) - r);
        }
        return best;
    }
}

/// <summary>Polylines stroked with round caps and joins.</summary>
public sealed class Stroke : Shape
{
    readonly Pt[][] lines;
    readonly double half;

    public Stroke(IEnumerable<IReadOnlyList<Pt>> polylines, double width)
    {
        lines = [.. polylines.Select(l => l.ToArray())];
        half = width / 2;
        Bound(lines.SelectMany(l => l), half);
    }

    public override double Distance(double x, double y)
    {
        double best = double.PositiveInfinity;
        foreach (var l in lines)
        {
            if (l.Length == 1) best = Math.Min(best, (new Pt(x, y) - l[0]).Length);
            for (int i = 1; i < l.Length; i++) best = Math.Min(best, SegmentDistance(x, y, l[i - 1], l[i]));
        }
        return best - half;
    }
}

public sealed class Ellipse : Shape
{
    readonly Pt c;
    readonly double rx, ry;

    public Ellipse(Pt center, double rx, double ry)
    {
        (c, this.rx, this.ry) = (center, rx, ry);
        (X0, Y0, X1, Y1) = (c.X - rx, c.Y - ry, c.X + rx, c.Y + ry);
    }

    public override double Distance(double x, double y)
    {
        double px = (x - c.X) / rx, py = (y - c.Y) / ry;
        double k0 = Math.Sqrt(px * px + py * py);
        if (k0 < 1e-9) return -Math.Min(rx, ry);
        double qx = px / rx, qy = py / ry;
        double k1 = Math.Sqrt(qx * qx + qy * qy);
        return k0 * (k0 - 1) / k1;
    }
}

/// <summary>A rectangle with round corners. A radius of half the height makes a pill.</summary>
public sealed class RoundRect : Shape
{
    readonly double r;

    public RoundRect(double x0, double y0, double x1, double y1, double radius)
    {
        (X0, Y0, X1, Y1) = (x0, y0, x1, y1);
        r = Math.Min(radius, Math.Min(x1 - x0, y1 - y0) / 2);
    }

    public override double Distance(double x, double y)
    {
        double cx = (X0 + X1) / 2, cy = (Y0 + Y1) / 2;
        double qx = Math.Abs(x - cx) - ((X1 - X0) / 2 - r), qy = Math.Abs(y - cy) - ((Y1 - Y0) / 2 - r);
        double ox = Math.Max(qx, 0), oy = Math.Max(qy, 0);
        return Math.Sqrt(ox * ox + oy * oy) + Math.Min(Math.Max(qx, qy), 0) - r;
    }
}

public sealed class Union : Shape
{
    readonly Shape[] parts;

    public Union(params IEnumerable<Shape> shapes)
    {
        parts = [.. shapes];
        (X0, Y0, X1, Y1) = (parts.Min(s => s.X0), parts.Min(s => s.Y0), parts.Max(s => s.X1), parts.Max(s => s.Y1));
    }

    public override double Distance(double x, double y)
    {
        double best = double.PositiveInfinity;
        foreach (var s in parts)
        {
            if (s.BoxDistance(x, y) >= best) continue;
            best = Math.Min(best, s.Distance(x, y));
        }
        return best;
    }
}

/// <summary>`a` with `b` cut out.</summary>
public sealed class Subtract : Shape
{
    readonly Shape a, b;

    public Subtract(Shape a, Shape b)
    {
        (this.a, this.b) = (a, b);
        (X0, Y0, X1, Y1) = (a.X0, a.Y0, a.X1, a.Y1);
    }

    public override double Distance(double x, double y)
    {
        double da = a.Distance(x, y);
        // Outside b's box, -distance(b) is at most -boxDistance, so b can't win.
        double box = b.BoxDistance(x, y);
        if (box > 0 && box >= -da) return da;
        return Math.Max(da, -b.Distance(x, y));
    }
}

/// <summary>The shape grown by `by` pixels, for cut-out rings.</summary>
public sealed class Grow : Shape
{
    readonly Shape s;
    readonly double by;

    public Grow(Shape shape, double by)
    {
        (s, this.by) = (shape, by);
        (X0, Y0, X1, Y1) = (s.X0 - by, s.Y0 - by, s.X1 + by, s.Y1 + by);
    }

    public override double Distance(double x, double y) => s.Distance(x, y) - by;
}

/// <summary>A premultiplied RGBA image that shapes paint into.</summary>
public sealed class Canvas(int width, int height)
{
    public int Width { get; } = width;
    public int Height { get; } = height;
    readonly double[] px = new double[width * height * 4];

    /// <summary>Samples per pixel side: more at small sizes, where a pixel is a large share of the drawing.</summary>
    public int Samples { get; set; } = Math.Max(width, height) <= 64 ? 4 : Math.Max(width, height) <= 256 ? 2 : 1;

    public double Coverage(Shape s, int x, int y)
    {
        double cx = x + 0.5, cy = y + 0.5;
        if (s.BoxDistance(cx, cy) >= 0.75) return 0;
        double d = s.Distance(cx, cy);
        if (d >= 0.75) return 0;
        if (d <= -0.75) return 1;
        int n = Samples;
        if (n == 1) return Math.Clamp(0.5 - d, 0, 1);
        double step = 1.0 / n, sum = 0;
        for (int j = 0; j < n; j++)
            for (int i = 0; i < n; i++)
                sum += Math.Clamp(0.5 - s.Distance(x + (i + 0.5) * step, y + (j + 0.5) * step) / step, 0, 1);
        return sum / (n * n);
    }

    IEnumerable<(int X, int Y)> Area(Shape s)
    {
        int x0 = Math.Max(0, (int)Math.Floor(s.X0 - 1)), y0 = Math.Max(0, (int)Math.Floor(s.Y0 - 1));
        int x1 = Math.Min(Width - 1, (int)Math.Ceiling(s.X1 + 1)), y1 = Math.Min(Height - 1, (int)Math.Ceiling(s.Y1 + 1));
        for (int y = y0; y <= y1; y++)
            for (int x = x0; x <= x1; x++) yield return (x, y);
    }

    public void Paint(Shape s, Rgba c) => Paint(s, (_, _) => c);

    /// <summary>Paints the shape over what is there, with a colour that can vary by pixel.</summary>
    public void Paint(Shape s, Func<double, double, Rgba> color)
    {
        foreach (var (x, y) in Area(s))
        {
            double cov = Coverage(s, x, y);
            if (cov <= 0) continue;
            var c = color(x + 0.5, y + 0.5);
            double a = c.A * cov;
            int i = (y * Width + x) * 4;
            px[i] = c.R * a + px[i] * (1 - a);
            px[i + 1] = c.G * a + px[i + 1] * (1 - a);
            px[i + 2] = c.B * a + px[i + 2] * (1 - a);
            px[i + 3] = a + px[i + 3] * (1 - a);
        }
    }

    /// <summary>Clears what is under the shape.</summary>
    public void Erase(Shape s)
    {
        foreach (var (x, y) in Area(s))
        {
            double cov = Coverage(s, x, y);
            if (cov <= 0) continue;
            int i = (y * Width + x) * 4;
            for (int k = 0; k < 4; k++) px[i + k] *= 1 - cov;
        }
    }

    /// <summary>Paints another canvas over this one at (x, y), each pixel scaled up `zoom` times.</summary>
    public void Draw(Canvas src, int x, int y, int zoom = 1)
    {
        for (int sy = 0; sy < src.Height * zoom; sy++)
            for (int sx = 0; sx < src.Width * zoom; sx++)
            {
                int dx = x + sx, dy = y + sy;
                if (dx < 0 || dy < 0 || dx >= Width || dy >= Height) continue;
                int si = ((sy / zoom) * src.Width + sx / zoom) * 4, di = (dy * Width + dx) * 4;
                double a = src.px[si + 3];
                for (int k = 0; k < 4; k++) px[di + k] = src.px[si + k] + px[di + k] * (1 - a);
            }
    }

    public void Clear(Rgba c)
    {
        for (int i = 0; i < px.Length; i += 4)
        {
            px[i] = c.R * c.A; px[i + 1] = c.G * c.A; px[i + 2] = c.B * c.A; px[i + 3] = c.A;
        }
    }

    /// <summary>Straight-alpha RGBA bytes, rows top to bottom.</summary>
    public byte[] ToRgba()
    {
        var o = new byte[px.Length];
        for (int i = 0; i < px.Length; i += 4)
        {
            double a = px[i + 3];
            o[i + 3] = (byte)Math.Round(Math.Clamp(a, 0, 1) * 255);
            if (o[i + 3] == 0) continue;
            for (int k = 0; k < 3; k++) o[i + k] = (byte)Math.Round(Math.Clamp(px[i + k] / a, 0, 1) * 255);
        }
        return o;
    }

    public byte[] ToPng() => Png.Encode(Width, Height, ToRgba());
}
