using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using System.Text.Json;
using LocoCore;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;
using Png = LocoLoco.Art.Png;
using RECT = LocoLoco.Native.RECT;

namespace LocoLoco;

/// <summary>
/// Proof for a Mac-built Windows app: icons as Windows draws them, and screenshots of every panel state,
/// taken by the app itself on a Windows build machine.
/// </summary>
static class TestHooks
{
    static readonly int[] TraySizes = [16, 20, 24, 32];
    static readonly (string Name, bool Asleep, int Count)[] States = [("asleep", true, 0), ("awake", false, 0), ("4", false, 4), ("10", false, 10)];

    /// <summary>Every tray icon through a real HICON and DrawIconEx, plus the exe's own icon, and a sheet of them all.</summary>
    public static int WriteIcons(string dir)
    {
        try
        {
            Directory.CreateDirectory(dir);
            var cells = new List<(int Px, bool Light, byte[] Rgba)>();
            foreach (var px in TraySizes)
                foreach (var light in new[] { true, false })
                    foreach (var (name, asleep, count) in States)
                    {
                        var icon = Tray.Make(px, light, asleep, count);
                        if (icon == 0) throw new InvalidOperationException($"CreateIconFromResourceEx failed for {px} {name}");
                        var rgba = Native.RenderIcon(icon, px);
                        Native.DestroyIcon(icon);
                        File.WriteAllBytes(Path.Combine(dir, $"tray-{px}-{(light ? "light" : "dark")}-{name}.png"), Png.Encode(px, px, rgba));
                        cells.Add((px, light, rgba));
                    }
            File.WriteAllBytes(Path.Combine(dir, "tray-sheet.png"), Sheet(cells));

            var (large, small) = Native.ExeIcons(Environment.ProcessPath!);
            if (large == 0) throw new InvalidOperationException("The exe has no icon.");
            foreach (var (h, px) in new[] { (large, 32), (small, 16) })
            {
                File.WriteAllBytes(Path.Combine(dir, $"exe-{px}.png"), Png.Encode(px, px, Native.RenderIcon(h, px)));
                Native.DestroyIcon(h);
            }
            return 0;
        }
        catch (Exception ex)
        {
            Fail(dir, ex);
            return 1;
        }
    }

    /// <summary>One row per size; light taskbar on the left, dark on the right; 4× so pixels show.</summary>
    static byte[] Sheet(List<(int Px, bool Light, byte[] Rgba)> cells)
    {
        const int zoom = 4, cell = 32 * zoom + 16, columns = 8;
        int rows = TraySizes.Length, w = columns * cell, h = rows * cell;
        var sheet = new byte[w * h * 4];
        for (int i = 0; i < cells.Count; i++)
        {
            var (px, light, rgba) = cells[i];
            int col = i % columns, row = i / columns;
            byte bg = light ? (byte)0xEE : (byte)0x1C;
            int ox = col * cell, oy = row * cell, inset = (cell - px * zoom) / 2;
            for (int y = 0; y < cell; y++)
                for (int x = 0; x < cell; x++)
                {
                    int sx = (x - inset) / zoom, sy = (y - inset) / zoom;
                    double a = 0;
                    byte r = 0, g = 0, b = 0;
                    if (x >= inset && y >= inset && sx < px && sy < px)
                    {
                        int s = (sy * px + sx) * 4;
                        (r, g, b, a) = (rgba[s], rgba[s + 1], rgba[s + 2], rgba[s + 3] / 255.0);
                    }
                    int d = ((oy + y) * w + ox + x) * 4;
                    sheet[d] = (byte)Math.Round(r * a + bg * (1 - a));
                    sheet[d + 1] = (byte)Math.Round(g * a + bg * (1 - a));
                    sheet[d + 2] = (byte)Math.Round(b * a + bg * (1 - a));
                    sheet[d + 3] = 255;
                }
        }
        return Png.Encode(w, h, sheet);
    }

    public static void Fail(string dir, Exception ex)
    {
        try
        {
            Directory.CreateDirectory(dir);
            File.AppendAllText(Path.Combine(dir, "error.txt"), ex + Environment.NewLine);
        }
        catch (IOException) { }
        App.ExitCode = 1;
    }

    /// <summary>Opens the panel and walks through its states, saving a screenshot of each, then quits.</summary>
    public static async Task Run(string dir, Engine engine, Flyout flyout, Tray tray, int expected, Action quit)
    {
        var log = new StringBuilder();
        void Note(string s) => log.AppendLine($"{DateTime.Now:HH:mm:ss.fff} {s}");
        try
        {
            Directory.CreateDirectory(dir);
            Note("waiting for servers");
            await Until(() => flyout.Rows.Running.Count >= Math.Max(1, expected), 30, "the demo servers to show up", flyout, engine);

            flyout.Show();
            await Task.Delay(900);
            Note(flyout.Placement);
            await Capture(dir, "01-open", flyout, xaml: true);

            var first = flyout.Rows.Running[0];
            flyout.Highlight(first.Id);
            await Task.Delay(300);
            await Capture(dir, "02-hover", flyout);
            flyout.Highlight(null);

            flyout.ShowRowMenu(flyout.Control(first.Id)!, null);
            await Task.Delay(700);
            await Capture(dir, "03-row-menu", flyout);
            flyout.CloseMenu();
            await Task.Delay(400);

            flyout.OpenOptions();
            await Task.Delay(700);
            await Capture(dir, "04-more-menu", flyout);
            flyout.CloseMenu();
            await Task.Delay(400);

            flyout.SetTheme(ElementTheme.Dark);
            await Task.Delay(500);
            await Capture(dir, "05-dark", flyout);
            flyout.SetTheme(ElementTheme.Default);
            await Task.Delay(400);

            Note($"stopping {first.Name}");
            engine.Stop(first);
            flyout.Refresh();
            await Task.Delay(150);
            await Capture(dir, "06-stopping", flyout);
            await Until(() => flyout.Rows.Running.All(r => r.Id != first.Id), 20, $"{first.Name} to stop", flyout, engine);
            await Task.Delay(400);
            await Capture(dir, "07-stopped", flyout);

            if (engine.Stoppable.Count > 0)
            {
                var asking = flyout.ConfirmStopAll();
                await Task.Delay(900);
                await Capture(dir, "08-dialog", flyout);
                flyout.CloseDialog();
                await asking;
            }
            else Note("08-dialog skipped: nothing left to stop");
            engine.StopAll();
            flyout.Refresh();
            await Until(() => flyout.Rows.Running.Count == 0, 30, "every server to stop", flyout, engine);
            await Task.Delay(400);
            await Capture(dir, "09-empty", flyout);
            foreach (var shape in Descendants(flyout.Root).OfType<Microsoft.UI.Xaml.Shapes.Path>())
                Note($"empty octopus {shape.ActualWidth:0}x{shape.ActualHeight:0}");

            var again = flyout.Rows.Stopped.FirstOrDefault(r => r.CanRestart) ?? throw new InvalidOperationException("Nothing to restart.");
            Note($"restarting {again.Name}");
            engine.Restart(again);
            flyout.Refresh();
            await Until(() => flyout.Rows.Running.Any(r => r.Port == again.Port && r.State == RowState.Idle), 45, $"{again.Name} to restart", flyout, engine);
            await Task.Delay(500);
            await Capture(dir, "10-restarted", flyout);

            WriteState(dir, flyout, engine);
            if (tray.IconHandle != 0)
            {
                int px = Native.TrayIconSize();
                File.WriteAllBytes(Path.Combine(dir, "tray.png"), Png.Encode(px, px, Native.RenderIcon(tray.IconHandle, px)));
            }
            Note("done");
            App.ExitCode = 0;
        }
        catch (Exception ex)
        {
            Note("failed: " + ex.Message);
            try { await Capture(dir, "failure", flyout); } catch (Exception) { }
            try { WriteState(dir, flyout, engine); } catch (Exception) { }
            Fail(dir, ex);
        }
        finally
        {
            File.WriteAllText(Path.Combine(dir, "log.txt"), log.ToString());
            quit();
        }
    }

    /// <summary>Waits for a condition, force-stopping anything stuck so the run can't hang.</summary>
    static async Task Until(Func<bool> done, int seconds, string what, Flyout flyout, Engine engine)
    {
        var end = DateTime.UtcNow.AddSeconds(seconds);
        while (true)
        {
            flyout.Refresh();
            if (done()) return;
            foreach (var r in flyout.Rows.Running.Where(r => r.State == RowState.Force).ToList()) engine.ForceStop(r.Id);
            if (DateTime.UtcNow > end) throw new TimeoutException($"Gave up after {seconds}s waiting for {what}.");
            await Task.Delay(250);
        }
    }

    static void WriteState(string dir, Flyout flyout, Engine engine)
    {
        object Describe(Row r) => new { r.Id, r.Name, r.Port, r.Ports, r.Folder, State = r.State.ToString(), r.Failure, r.IsApp, Spoken = r.AccessibleName(DateTime.UtcNow) };
        var state = new
        {
            flyout.Placement,
            Running = flyout.Rows.Running.Select(Describe),
            Stopped = flyout.Rows.Stopped.Select(Describe),
            flyout.Rows.StoppedTotal,
            engine.RunningCount,
            TrayIconSize = Native.TrayIconSize(),
            TaskbarLight = Tray.TaskbarIsLight(),
            History = engine.History.Entries.Select(e => new { e.Name, e.Command, e.CommandDir, e.Ports, e.StoppedAt, e.Failure }),
        };
        File.WriteAllText(Path.Combine(dir, "state.json"), JsonSerializer.Serialize(state, new JsonSerializerOptions { WriteIndented = true }));
    }

    /// <summary>The screen around the panel, with room for menus above and to the left, down to the taskbar.</summary>
    static async Task Capture(string dir, string name, Flyout flyout, bool xaml = false)
    {
        var w = Native.WindowRect(flyout.Hwnd);
        var (bounds, _, scale) = Native.Monitor(w);
        var r = new RECT
        {
            Left = Math.Max(bounds.Left, w.Left - (int)(340 * scale)),
            Top = Math.Max(bounds.Top, w.Top - (int)(420 * scale)),
            Right = bounds.Right,
            Bottom = bounds.Bottom,
        };
        var pixels = r.Width > 0 && r.Height > 0 ? Native.Grab(r) : [];
        bool blank = pixels.Length == 0 || pixels.Where((_, i) => i % 4 != 3).All(b => b == 0);
        if (!blank) File.WriteAllBytes(Path.Combine(dir, name + ".png"), Png.Encode(r.Width, r.Height, pixels));
        if (xaml || blank) await CaptureXaml(dir, name + (blank ? ".png" : "-xaml.png"), flyout.Root);
    }

    static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        for (int i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, i);
            yield return child;
            foreach (var d in Descendants(child)) yield return d;
        }
    }

    /// <summary>The panel as XAML drew it, without the desktop. Works even where screen capture doesn't.</summary>
    static async Task CaptureXaml(string dir, string file, UIElement element)
    {
        var bitmap = new RenderTargetBitmap();
        await bitmap.RenderAsync(element);
        var bgra = (await bitmap.GetPixelsAsync()).ToArray();
        var rgba = new byte[bgra.Length];
        for (int i = 0; i < bgra.Length; i += 4)
        {
            byte a = bgra[i + 3];
            double k = a > 0 ? 255.0 / a : 0;
            rgba[i] = (byte)Math.Min(255, Math.Round(bgra[i + 2] * k));
            rgba[i + 1] = (byte)Math.Min(255, Math.Round(bgra[i + 1] * k));
            rgba[i + 2] = (byte)Math.Min(255, Math.Round(bgra[i] * k));
            rgba[i + 3] = a;
        }
        File.WriteAllBytes(Path.Combine(dir, file), Png.Encode(bitmap.PixelWidth, bitmap.PixelHeight, rgba));
    }
}
