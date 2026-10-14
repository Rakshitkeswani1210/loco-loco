using LocoLoco.Art;

if (args.Length is < 1 or > 2)
{
    Console.Error.WriteLine("usage: make-icon <out.ico> [preview-folder]");
    return 2;
}

var images = Icons.AppSizes.Select(px => (px, Icons.App(px).ToPng())).ToList();
File.WriteAllBytes(args[0], Ico.Encode(images));
Console.WriteLine($"wrote {args[0]} ({string.Join(", ", Icons.AppSizes)} px)");

if (args.Length == 2)
{
    var dir = args[1];
    Directory.CreateDirectory(dir);
    File.WriteAllBytes(Path.Combine(dir, "app-256.png"), Icons.App(256).ToPng());
    File.WriteAllBytes(Path.Combine(dir, "app-sizes.png"), AppSheet().ToPng());
    File.WriteAllBytes(Path.Combine(dir, "tray-sheet.png"), TraySheet().ToPng());
    Console.WriteLine($"wrote previews to {dir}");
}
return 0;

// Each app icon size at 1x, then the small ones at 8x to check pixels.
static Canvas AppSheet()
{
    var sheet = new Canvas(1400, 760);
    sheet.Clear(Rgba.Hex(0xF3F3F3));
    int x = 24;
    foreach (var px in Icons.AppSizes)
    {
        sheet.Draw(Icons.App(px), x, 24 + (256 - px));
        x += px + 24;
    }
    x = 24;
    foreach (var px in new[] { 16, 20, 24, 32 })
    {
        sheet.Draw(Icons.App(px), x, 320, 10);
        x += px * 10 + 24;
    }
    return sheet;
}

// Rows: light taskbar then dark. Columns: asleep, awake, 4, 10 and 37 at each tray size, zoomed and at 1x.
static Canvas TraySheet()
{
    int[] sizes = [16, 20, 24, 32];
    int[] counts = [-1, 0, 4, 10, 37];
    const int zoom = 8;
    int cell = 32 * zoom + 24;
    int width = 24 + counts.Length * cell;
    int rowH = sizes.Sum(s => s * zoom + 24 + s + 12) + 24;
    var sheet = new Canvas(width, 2 * rowH);
    int y = 0;
    foreach (bool light in new[] { true, false })
    {
        var bg = light ? Rgba.Hex(0xEEEEEE) : Rgba.Hex(0x202020);
        int top = y;
        sheet.Paint(new RoundRect(0, top, width, top + rowH, 0), bg);
        y += 24;
        foreach (var px in sizes)
        {
            int x = 24;
            foreach (var n in counts)
            {
                var icon = Icons.Tray(px, light, asleep: n < 0, count: Math.Max(n, 0));
                sheet.Draw(icon, x, y, zoom);
                sheet.Draw(icon, x, y + px * zoom + 12);
                x += cell;
            }
            y += px * zoom + 24 + px + 12;
        }
        y = top + rowH;
    }
    return sheet;
}
