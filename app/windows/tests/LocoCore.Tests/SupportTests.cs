using System.Globalization;

namespace LocoCore.Tests;

public class SupportTests
{
    static DateTime Local(int y, int mo, int d, int h, int mi) => new DateTime(y, mo, d, h, mi, 0, DateTimeKind.Local).ToUniversalTime();

    [Fact]
    public void TimesReadShort()
    {
        var now = Local(2026, 9, 21, 15, 0);
        var us = new CultureInfo("en-US");
        Assert.Equal("10:37 AM", TimeText.Short(Local(2026, 9, 21, 10, 37), now, us));
        Assert.Equal("10:37", TimeText.Short(Local(2026, 9, 21, 10, 37), now, CultureInfo.InvariantCulture));
        Assert.Equal("Mar 7", TimeText.Short(Local(2026, 3, 7, 9, 0), now, us));
        Assert.Equal("Oct 7, 2025", TimeText.Short(Local(2025, 10, 7, 9, 0), now, us));
    }

    [Theory]
    [InlineData(0u, "Exited with code 0")]
    [InlineData(1u, "Exited with code 1")]
    [InlineData(0xC0000005u, "Exited with code 0xC0000005")]
    [InlineData(0xC000013Au, "Stopped by Ctrl+C")]
    public void ExitCodes(uint code, string text) => Assert.Equal(text, ExitText.Describe(code));

    [Theory]
    [InlineData("site", "site")]
    [InlineData("a/b:c*d?", "a-b-c-d-")]
    [InlineData("x\ty", "x-y")]
    [InlineData("site. ", "site")]
    [InlineData("", "server")]
    [InlineData("...", "server")]
    public void LogNamesAreSafe(string name, string safe) => Assert.Equal(safe, AppPaths.SafeName(name));

    [Fact]
    public void LogsLiveInTheAppFolder()
    {
        var p = new AppPaths(Path.Combine("base", "Loco Loco"));
        Assert.Equal(Path.Combine("base", "Loco Loco", "Logs", "a-b.log"), p.LogFor("a:b"));
        Assert.Equal(Path.Combine("base", "Loco Loco", "history.json"), p.History);
    }

    [Fact]
    public void SettingsFallBackToDefaults()
    {
        var file = Path.Combine(Path.GetTempPath(), $"loco-settings-{Guid.NewGuid()}.json");
        try
        {
            var missing = Settings.Load(file);
            Assert.Equal((true, false, 20, false), (missing.ShowCount, missing.ShowAll, missing.HistoryLimit, missing.FirstRunDone));
            File.WriteAllText(file, "{\"historyLimit\": 0, \"showAll\": true}");
            var odd = Settings.Load(file);
            Assert.Equal((20, true), (odd.HistoryLimit, odd.ShowAll));
            File.WriteAllText(file, "not json");
            Assert.Equal(20, Settings.Load(file).HistoryLimit);
            new Settings { HistoryLimit = 50, ShowCount = false }.Save(file);
            Assert.Equal((50, false), (Settings.Load(file).HistoryLimit, Settings.Load(file).ShowCount));
        }
        finally { File.Delete(file); }
    }

    [Fact]
    public void RowActions()
    {
        static Row Make(RowGroup g, RowState s = RowState.Idle, string? failure = null, bool log = false, bool server = true) => new()
        {
            Id = "x", Group = g, Port = 1, Ports = [1], Name = "x", Folder = "x", Time = DateTime.UnixEpoch, State = s,
            Failure = failure, HasLog = log, EntryId = Guid.NewGuid(),
            Server = server ? HistoryTests.Server(1) : null,
        };
        Assert.Equal(new[] { RowAction.Stop }, Make(RowGroup.Running).Actions);
        Assert.Empty(Make(RowGroup.Running, RowState.Starting, server: false).Actions);
        Assert.Equal(new[] { RowAction.Force }, Make(RowGroup.Running, RowState.Force).Actions);
        Assert.Equal(new[] { RowAction.Restart }, Make(RowGroup.Stopped, server: false).Actions);
        Assert.Equal(new[] { RowAction.Restart }, Make(RowGroup.Stopped, failure: "x", server: false).Actions);
        Assert.Equal(new[] { RowAction.Log, RowAction.Restart }, Make(RowGroup.Stopped, failure: "x", log: true, server: false).Actions);
        Assert.Equal("http://localhost:1", Make(RowGroup.Running).Url);
    }
}
