using System.Text.Json;
using System.Globalization;
namespace GitNebula;

public sealed class AppSettings
{
    private static readonly string FilePath = Environment.GetEnvironmentVariable("GITNEBULA_SETTINGS_PATH") ?? System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GitNebula", "settings.json");
    public static AppSettings Current { get; } = Load();
    public string Theme { get; set; } = "system";
    public string Language { get; set; } = DefaultLanguage;
    private static string DefaultLanguage => CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ja" ? "ja" : "en";
    public double Transparency { get; set; }
    public bool ShowHomeOnLaunch { get; set; }
    public bool KeepRunning { get; set; } = true;
    public string GitExecutable { get; set; } = "";
    public string SshKeyPath { get; set; } = "";
    public List<string> RecentRepositories { get; set; } = [];
    private static AppSettings Load()
    {
        try {
            var settings = JsonSerializer.Deserialize<AppSettings>(System.IO.File.ReadAllText(FilePath)) ?? new();
            if (settings.Language is not ("ja" or "en")) settings.Language = DefaultLanguage;
            return settings;
        }
        catch (System.IO.FileNotFoundException) { return new(); }
        catch (System.IO.DirectoryNotFoundException) { return new(); }
        catch (JsonException) { return new(); }
    }
    public void Save()
    {
        System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(FilePath)!);
        var temporary = FilePath + ".tmp";
        System.IO.File.WriteAllText(temporary, JsonSerializer.Serialize(this));
        System.IO.File.Move(temporary, FilePath, true);
    }
    public void Remember(string path)
    {
        RecentRepositories.RemoveAll(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase));
        RecentRepositories.Insert(0, path);
        RecentRepositories = RecentRepositories.Take(10).ToList(); Save();
    }
}
