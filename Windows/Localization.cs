using System.Globalization;
using System.Text.Json;
namespace GitNebula;
public static class Localization
{
    private static readonly Dictionary<string, string> English = Load();
    public static string Language => AppSettings.Current.Language == "en" ? "en" : "ja";
    private static Dictionary<string, string> Load()
    {
        using var stream = typeof(Localization).Assembly.GetManifestResourceStream("GitNebula.en.json");
        return stream == null ? new() : JsonSerializer.Deserialize<Dictionary<string, string>>(stream) ?? new();
    }
    public static string Text(string source) => Language == "en" && English.TryGetValue(source, out var translated) ? translated : source;
    public static string Format(FormattableString source) => string.Format(CultureInfo.CurrentCulture, Text(source.Format), source.GetArguments());
}
