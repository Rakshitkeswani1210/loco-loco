namespace LocoCore.Tests;

/// <summary>A test that needs real Windows processes. Skipped elsewhere.</summary>
public sealed class WindowsFactAttribute : FactAttribute
{
    public WindowsFactAttribute()
    {
        if (!OperatingSystem.IsWindows()) Skip = "Needs Windows";
    }
}
