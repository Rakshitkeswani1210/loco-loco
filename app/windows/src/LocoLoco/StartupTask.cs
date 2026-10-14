using Microsoft.Win32;

namespace LocoLoco;

/// <summary>
/// "Start with Windows": a value under HKCU\...\Run, which Settings > Apps > Startup lists and can turn off.
/// Turning it off there writes StartupApproved, so both are read.
/// </summary>
static class StartupTask
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    const string Name = "Loco Loco";

    static string Command => $"\"{Environment.ProcessPath}\"";

    public static bool IsEnabled
    {
        get
        {
            try
            {
                using var run = Registry.CurrentUser.OpenSubKey(RunKey);
                if (run?.GetValue(Name) is not string) return false;
                using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey);
                // The first byte is odd when Settings or Task Manager turned it off.
                return approved?.GetValue(Name) is not byte[] { Length: > 0 } state || (state[0] & 1) == 0;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException) { return false; }
        }
    }

    public static void Set(bool on)
    {
        try
        {
            using (var run = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (on) run.SetValue(Name, Command);
                else run.DeleteValue(Name, throwOnMissingValue: false);
            }
            using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey, writable: true);
            approved?.DeleteValue(Name, throwOnMissingValue: false);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
    }

    /// <summary>Points the Run value at this copy, in case the folder moved since it was turned on.</summary>
    public static void Refresh()
    {
        try
        {
            using var run = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (run?.GetValue(Name) is string value && !string.Equals(value, Command, StringComparison.OrdinalIgnoreCase))
                run.SetValue(Name, Command);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
    }
}
