using System.ComponentModel;
using System.Diagnostics;
using Windows.ApplicationModel.DataTransfer;

namespace LocoLoco;

/// <summary>Opening things: the browser, File Explorer, a terminal, Cursor, a log, and the clipboard.</summary>
static class Shell
{
    static readonly string LocalAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

    static bool Run(ProcessStartInfo info)
    {
        try
        {
            using var _ = Process.Start(info);
            return true;
        }
        catch (Exception ex) when (ex is Win32Exception or InvalidOperationException or FileNotFoundException) { return false; }
    }

    public static void OpenUrl(string url) => Run(new ProcessStartInfo(url) { UseShellExecute = true });

    public static void ShowInExplorer(string folder)
    {
        // Explorer reads its own command line, in this exact form.
        Run(new ProcessStartInfo("explorer.exe", $"/select,\"{folder}\"") { UseShellExecute = false });
    }

    static string WindowsTerminal => Path.Combine(LocalAppData, "Microsoft", "WindowsApps", "wt.exe");

    /// <summary>Windows Terminal in the folder, else Command Prompt.</summary>
    public static void OpenTerminal(string folder)
    {
        if (File.Exists(WindowsTerminal))
        {
            var wt = new ProcessStartInfo(WindowsTerminal) { UseShellExecute = false };
            wt.ArgumentList.Add("-d");
            wt.ArgumentList.Add(folder);
            if (Run(wt)) return;
        }
        var comspec = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
        Run(new ProcessStartInfo(comspec) { UseShellExecute = true, WorkingDirectory = folder });
    }

    /// <summary>Cursor's exe, when it's installed for this user or for everyone.</summary>
    public static string? Cursor
    {
        get
        {
            string[] places =
            [
                Path.Combine(LocalAppData, "Programs", "cursor", "Cursor.exe"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "cursor", "Cursor.exe"),
            ];
            return places.FirstOrDefault(File.Exists);
        }
    }

    public static void OpenInCursor(string folder)
    {
        if (Cursor is not { } exe) return;
        var info = new ProcessStartInfo(exe) { UseShellExecute = false };
        info.ArgumentList.Add(folder);
        Run(info);
    }

    /// <summary>The log in the default app for .log files, else Notepad.</summary>
    public static void OpenLog(string path)
    {
        if (Run(new ProcessStartInfo(path) { UseShellExecute = true })) return;
        var notepad = new ProcessStartInfo("notepad.exe") { UseShellExecute = false };
        notepad.ArgumentList.Add(path);
        Run(notepad);
    }

    public static void Copy(string text)
    {
        try
        {
            var data = new DataPackage();
            data.SetText(text);
            Clipboard.SetContent(data);
            Clipboard.Flush();
        }
        catch (Exception) { }
    }
}
