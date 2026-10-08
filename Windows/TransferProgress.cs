using System.Text;
using System.Text.RegularExpressions;
namespace GitNebula;
public record TransferProgress(string Stage, int? Percent, bool Completed = false)
{
    public static TransferProgress Waiting => new(Localization.Text("接続中…"), null);
    public static TransferProgress Complete => new(Localization.Text("完了"), 100, true);
}
public sealed class TransferProgressParser(Action<TransferProgress> notify)
{
    private readonly StringBuilder pending = new();
    private static readonly Regex Percentage = new(@"^(.*?):\s*(\d{1,3})%", RegexOptions.Compiled);
    public void Feed(string chunk)
    {
        foreach (var character in chunk) {
            if (character is '\r' or '\n') { Emit(); continue; }
            pending.Append(character);
            if (pending.Length > 16384) pending.Remove(0, pending.Length - 16384);
        }
    }
    public void Finish() => Emit();
    private void Emit()
    {
        var line = pending.ToString().Trim(); pending.Clear();
        if (line.StartsWith("remote: ", StringComparison.Ordinal)) line = line[8..];
        var match = Percentage.Match(line);
        if (match.Success && int.TryParse(match.Groups[2].Value, out var percent) && percent <= 100)
            notify(new(match.Groups[1].Value, percent));
        else if (line.StartsWith("Enumerating objects:", StringComparison.Ordinal)) notify(new(Localization.Text("オブジェクトを確認中…"), null));
    }
}
