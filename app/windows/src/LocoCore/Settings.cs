using System.Text.Json;
using System.Text.Json.Serialization;

namespace LocoCore;

/// <summary>Where Loco Loco keeps its files: %LOCALAPPDATA%\Loco Loco.</summary>
public sealed class AppPaths(string folder)
{
    public static AppPaths Default => new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Loco Loco"));

    public string Folder { get; } = folder;
    public string History => Path.Combine(Folder, "history.json");
    public string Settings => Path.Combine(Folder, "settings.json");
    public string Logs => Path.Combine(Folder, "Logs");

    /// <summary>One log per server name, with characters Windows can't use in a file name replaced.</summary>
    public string LogFor(string name) => Path.Combine(Logs, SafeName(name) + ".log");

    public static string SafeName(string name)
    {
        var safe = new string(name.Select(c => c is '\\' or '/' or ':' or '*' or '?' or '"' or '<' or '>' or '|' || c < ' ' ? '-' : c).ToArray())
            .TrimEnd('.', ' ');
        return safe.Length == 0 ? "server" : safe;
    }
}

public sealed class Settings
{
    [JsonPropertyName("showCount")] public bool ShowCount { get; set; } = true;
    [JsonPropertyName("showAll")] public bool ShowAll { get; set; }
    [JsonPropertyName("historyLimit")] public int HistoryLimit { get; set; } = 20;
    [JsonPropertyName("firstRunDone")] public bool FirstRunDone { get; set; }

    static readonly JsonSerializerOptions Options = new() { WriteIndented = true };

    public static Settings Load(string file)
    {
        try
        {
            var s = JsonSerializer.Deserialize<Settings>(File.ReadAllText(file), Options) ?? new();
            if (s.HistoryLimit is < 1 or > 1000) s.HistoryLimit = 20;
            return s;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { return new(); }
    }

    public void Save(string file)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllText(file + ".tmp", JsonSerializer.Serialize(this, Options));
            File.Move(file + ".tmp", file, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }
}
