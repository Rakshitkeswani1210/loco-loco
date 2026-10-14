using System.Runtime.InteropServices;

namespace LocoLoco;

/// <summary>The Win32 calls the app needs that WinUI and H.NotifyIcon don't cover.</summary>
static partial class Native
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
        public readonly int Width => Right - Left;
        public readonly int Height => Bottom - Top;
        public readonly bool Contains(RECT r) => r.Left >= Left && r.Top >= Top && r.Right <= Right && r.Bottom <= Bottom;
        public override readonly string ToString() => $"{Left},{Top} {Width}x{Height}";
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    struct NOTIFYICONIDENTIFIER
    {
        public uint cbSize;
        public nint hWnd;
        public uint uID;
        public Guid guidItem;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct APPBARDATA
    {
        public uint cbSize;
        public nint hWnd;
        public uint uCallbackMessage;
        public uint uEdge;
        public RECT rc;
        public nint lParam;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MONITORINFO
    {
        public uint cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct BITMAPINFOHEADER
    {
        public uint biSize;
        public int biWidth, biHeight;
        public ushort biPlanes, biBitCount;
        public uint biCompression, biSizeImage;
        public int biXPelsPerMeter, biYPelsPerMeter;
        public uint biClrUsed, biClrImportant;
    }

    public enum Edge : uint { Left = 0, Top = 1, Right = 2, Bottom = 3 }

    const int SM_CXSMICON = 49;
    const uint MONITOR_DEFAULTTONEAREST = 2;
    const uint ABM_GETTASKBARPOS = 5;
    const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20, DWMWA_WINDOW_CORNER_PREFERENCE = 33, DWMWCP_ROUND = 2;
    const uint SRCCOPY = 0x00CC0020, CAPTUREBLT = 0x40000000;
    const uint DI_NORMAL = 3;
    public const int ASFW_ANY = -1;

    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(nint hWnd);
    [DllImport("user32.dll")] public static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int dwProcessId);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool GetWindowRect(nint hWnd, out RECT r);
    [DllImport("user32.dll")] static extern bool GetClientRect(nint hWnd, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(nint hWnd, ref POINT p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern nint FindWindowW(string? cls, string? name);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(nint hWnd);
    [DllImport("user32.dll")] static extern int GetSystemMetricsForDpi(int index, uint dpi);
    [DllImport("user32.dll")] static extern nint MonitorFromRect(ref RECT r, uint flags);
    [DllImport("user32.dll")] static extern nint MonitorFromPoint(POINT p, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfoW(nint monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] static extern nint CreateIconFromResourceEx(byte[] bits, uint size, bool icon, uint version, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool DestroyIcon(nint icon);
    [DllImport("user32.dll")] static extern bool DrawIconEx(nint dc, int x, int y, nint icon, int cx, int cy, uint step, nint brush, uint flags);
    [DllImport("user32.dll")] static extern nint GetDC(nint hWnd);
    [DllImport("user32.dll")] static extern int ReleaseDC(nint hWnd, nint dc);
    [DllImport("shell32.dll")] static extern int Shell_NotifyIconGetRect(ref NOTIFYICONIDENTIFIER id, out RECT r);
    [DllImport("shell32.dll")] static extern nuint SHAppBarMessage(uint msg, ref APPBARDATA data);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern uint ExtractIconExW(string file, int index, out nint large, out nint small, uint count);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(nint monitor, int type, out uint dpiX, out uint dpiY);
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(nint hWnd, int attribute, ref int value, int size);
    [DllImport("gdi32.dll")] static extern nint CreateCompatibleDC(nint dc);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(nint dc);
    [DllImport("gdi32.dll")] static extern nint CreateDIBSection(nint dc, ref BITMAPINFOHEADER bmi, uint usage, out nint bits, nint section, uint offset);
    [DllImport("gdi32.dll")] static extern nint SelectObject(nint dc, nint obj);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(nint obj);
    [DllImport("gdi32.dll")] static extern bool BitBlt(nint dst, int x, int y, int w, int h, nint src, int sx, int sy, uint rop);

    public static POINT Cursor() => GetCursorPos(out var p) ? p : default;

    public static RECT WindowRect(nint hwnd) => GetWindowRect(hwnd, out var r) ? r : default;

    /// <summary>The client area on screen. With no title bar, it's the part of the window people see.</summary>
    public static RECT ClientRect(nint hwnd)
    {
        if (!GetClientRect(hwnd, out var r)) return default;
        var p = new POINT();
        ClientToScreen(hwnd, ref p);
        return new RECT { Left = p.X, Top = p.Y, Right = p.X + r.Width, Bottom = p.Y + r.Height };
    }

    /// <summary>The tray icon's place on screen. Null when Windows can't say.</summary>
    public static RECT? IconRect(nint hwnd, Guid id)
    {
        var nid = new NOTIFYICONIDENTIFIER { cbSize = (uint)Marshal.SizeOf<NOTIFYICONIDENTIFIER>(), hWnd = hwnd, guidItem = id };
        return Shell_NotifyIconGetRect(ref nid, out var r) == 0 && r.Width > 0 ? r : null;
    }

    /// <summary>The primary taskbar and the screen edge it sits on.</summary>
    public static (RECT Rect, Edge Edge)? Taskbar()
    {
        var data = new APPBARDATA { cbSize = (uint)Marshal.SizeOf<APPBARDATA>() };
        if (SHAppBarMessage(ABM_GETTASKBARPOS, ref data) == 0) return null;
        return (data.rc, (Edge)data.uEdge);
    }

    /// <summary>The monitor's whole area, its work area (without the taskbar) and its scale.</summary>
    public static (RECT Bounds, RECT Work, double Scale) Monitor(RECT near)
    {
        var monitor = MonitorFromRect(ref near, MONITOR_DEFAULTTONEAREST);
        return Describe(monitor);
    }

    public static (RECT Bounds, RECT Work, double Scale) Monitor(POINT near) => Describe(MonitorFromPoint(near, MONITOR_DEFAULTTONEAREST));

    static (RECT, RECT, double) Describe(nint monitor)
    {
        var info = new MONITORINFO { cbSize = (uint)Marshal.SizeOf<MONITORINFO>() };
        GetMonitorInfoW(monitor, ref info);
        double scale = GetDpiForMonitor(monitor, 0, out var dpi, out _) == 0 && dpi > 0 ? dpi / 96.0 : 1;
        return (info.rcMonitor, info.rcWork, scale);
    }

    /// <summary>The size of a tray icon on the taskbar's monitor: 16 at 100%, 24 at 150%, 32 at 200%.</summary>
    public static int TrayIconSize()
    {
        var bar = FindWindowW("Shell_TrayWnd", null);
        uint dpi = bar != 0 ? GetDpiForWindow(bar) : 0;
        if (dpi == 0) dpi = 96;
        int size = GetSystemMetricsForDpi(SM_CXSMICON, dpi);
        return size > 0 ? size : (int)Math.Round(16 * dpi / 96.0);
    }

    /// <summary>An icon handle from PNG bytes. Destroy it with DestroyIcon.</summary>
    public static nint IconFromPng(byte[] png, int size) => CreateIconFromResourceEx(png, (uint)png.Length, true, 0x00030000, size, size, 0);

    /// <summary>The icon embedded in an exe, at the small and large system sizes.</summary>
    public static (nint Large, nint Small) ExeIcons(string exe) =>
        ExtractIconExW(exe, 0, out var large, out var small, 1) > 0 ? (large, small) : (0, 0);

    public static void RoundCorners(nint hwnd)
    {
        int value = DWMWCP_ROUND;
        DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, ref value, sizeof(int));
    }

    public static void DarkFrame(nint hwnd, bool dark)
    {
        int value = dark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref value, sizeof(int));
    }

    /// <summary>Draws an icon handle onto a transparent bitmap and returns its RGBA pixels, as Windows would show it.</summary>
    public static byte[] RenderIcon(nint icon, int size) =>
        WithBitmap(size, size, dc => DrawIconEx(dc, 0, 0, icon, size, size, 0, 0, DI_NORMAL), keepAlpha: true);

    /// <summary>What's on screen in `r`, as RGBA.</summary>
    public static byte[] Grab(RECT r)
    {
        var screen = GetDC(0);
        try { return WithBitmap(r.Width, r.Height, dc => BitBlt(dc, 0, 0, r.Width, r.Height, screen, r.Left, r.Top, SRCCOPY | CAPTUREBLT), keepAlpha: false); }
        finally { ReleaseDC(0, screen); }
    }

    static byte[] WithBitmap(int w, int h, Action<nint> draw, bool keepAlpha)
    {
        var bmi = new BITMAPINFOHEADER
        {
            biSize = (uint)Marshal.SizeOf<BITMAPINFOHEADER>(), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32,
        };
        var screen = GetDC(0);
        var dc = CreateCompatibleDC(screen);
        ReleaseDC(0, screen);
        var dib = CreateDIBSection(dc, ref bmi, 0, out var bits, 0, 0);
        var old = SelectObject(dc, dib);
        try
        {
            var bgra = new byte[w * h * 4];
            Marshal.Copy(bgra, 0, bits, bgra.Length);
            draw(dc);
            Marshal.Copy(bits, bgra, 0, bgra.Length);
            var rgba = new byte[bgra.Length];
            for (int i = 0; i < bgra.Length; i += 4)
            {
                byte a = keepAlpha ? bgra[i + 3] : (byte)255;
                // DrawIconEx leaves premultiplied colour; PNG wants it straight.
                double k = keepAlpha && a > 0 ? 255.0 / a : 1;
                rgba[i] = (byte)Math.Min(255, Math.Round(bgra[i + 2] * k));
                rgba[i + 1] = (byte)Math.Min(255, Math.Round(bgra[i + 1] * k));
                rgba[i + 2] = (byte)Math.Min(255, Math.Round(bgra[i] * k));
                rgba[i + 3] = a;
            }
            return rgba;
        }
        finally
        {
            SelectObject(dc, old);
            DeleteObject(dib);
            DeleteDC(dc);
        }
    }
}
