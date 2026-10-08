using System.IO;
using System.Text.RegularExpressions;
namespace GitNebula;
public record DiffRow(int? OldNumber, int? NewNumber, string Old, string New, string Kind);
public record DiffDocument(string Path, string OldTitle, string NewTitle, DiffRow[] Rows, int[] Hunks, string Notice = "")
{
    public static (DiffRow[] Rows, int[] Hunks) Align(string[] old, string[] current, string patch) {
        var rows = new List<DiffRow>(); var hunks = new List<int>(); var left = 0; var right = 0;
        void Unchanged(int end) {
            if (end < left || end > old.Length) throw new InvalidOperationException(Localization.Text("差分の行情報を読み取れませんでした。更新して再度お試しください。"));
            while (left < end) { rows.Add(new(left + 1, right + 1, old[left], current[right], "unchanged")); left++; right++; }
        }
        foreach (Match match in Regex.Matches(patch, @"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", RegexOptions.Multiline)) {
            int Number(int id, int fallback = 1) => match.Groups[id].Success ? int.Parse(match.Groups[id].Value) : fallback;
            var count = Number(2); var added = Number(4); var start = Number(1) - (count > 0 ? 1 : 0); var after = Number(3) - (added > 0 ? 1 : 0);
            Unchanged(start);
            if (right != after || start + count > old.Length || after + added > current.Length) throw new InvalidOperationException(Localization.Text("差分の行情報を読み取れませんでした。更新して再度お試しください。"));
            hunks.Add(rows.Count);
            for (var offset = 0; offset < Math.Max(count, added); offset++) {
                int? a = offset < count ? start + offset : null; int? b = offset < added ? after + offset : null;
                rows.Add(new(a + 1, b + 1, a.HasValue ? old[a.Value] : "", b.HasValue ? current[b.Value] : "", a == null ? "added" : b == null ? "removed" : "modified"));
            }
            left += count; right += added;
        }
        Unchanged(old.Length); if (right != current.Length) throw new InvalidOperationException(Localization.Text("差分の行情報を読み取れませんでした。更新して再度お試しください。"));
        return (rows.ToArray(), hunks.ToArray());
    }
}
public record RevisionFile(string Code, string Path, string? Original);
public sealed partial class GitRepository
{
    private async Task<string> BlobText(string? revision, string path) {
        FilePath(path); if (revision == null) return ""; var objectName = revision + ":" + path;
        var exists = await GitProcess.RunWithOutput(Path, ["cat-file", "-e", objectName], [0, 128]);
        if (exists.Diagnostics.Length > 0) return "";
        var size = long.Parse((await Run("cat-file", "-s", objectName)).Trim());
        if (size > 1024 * 1024) throw new InvalidOperationException(Localization.Text("1 MiB を超えるファイルは表示できません。"));
        return await Run("cat-file", "-p", objectName);
    }
    public async Task<DiffDocument> FileComparison(string path, string? revision = null, string? parent = null, string? original = null) {
        FilePath(path); string old, current, oldTitle, newTitle;
        if (revision != null) {
            revision = await Revision(revision);
            if (parent == null) parent = (await Run("rev-list", "--parents", "-1", revision)).Trim().Split(' ').Skip(1).FirstOrDefault();
            else if (parent.Length > 0) parent = await Revision(parent);
            old = await BlobText(string.IsNullOrEmpty(parent) ? null : parent, original ?? path); current = await BlobText(revision, path);
            oldTitle = parent ?? Localization.Text("空のツリー"); newTitle = revision;
        } else {
            var change = (await Changes()).FirstOrDefault(c => c.Path == path) ?? throw new InvalidOperationException(Localization.Text("変更ファイルを選択してください。"));
            old = await BlobText(await HeadRevision(), change.Original ?? path); oldTitle = "HEAD"; newTitle = Localization.Text("作業ファイル");
            var target = FilePath(path);
            if (File.Exists(target) && new FileInfo(target).Length > 1024 * 1024) return new(path, oldTitle, newTitle, [], [], Localization.Text("1 MiB を超えるファイルは表示できません。"));
            current = Directory.Exists(target) ? await Run("submodule", "status", "--", path) : ReadFile(path);
        }
        if (old.Contains('\0') || current.Contains('\0') || current.StartsWith(Localization.Text("バイナリ"))) return new(path, oldTitle, newTitle, [], [], Localization.Text("バイナリファイルは外部で確認してください。"));
        var notice = (old.Length > 0 && !old.EndsWith('\n') || current.Length > 0 && !current.EndsWith('\n')) ? Localization.Text("末尾に改行がないファイルがあります。") : "";
        var temporary = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "nebula-diff-" + Guid.NewGuid()); Directory.CreateDirectory(temporary);
        try {
            var first = System.IO.Path.Combine(temporary, "before"); var second = System.IO.Path.Combine(temporary, "after");
            await File.WriteAllTextAsync(first, old); await File.WriteAllTextAsync(second, current);
            var patch = await GitProcess.RunAccepting(temporary, ["diff", "--no-index", "--no-ext-diff", "--no-textconv", "--text", "--unified=0", "--", first, second], [0, 1]);
            string[] Lines(string text) { var lines = text.Length == 0 ? Array.Empty<string>() : text.Split('\n'); return lines.Length > 0 && lines[^1] == "" ? lines[..^1] : lines; }
            var result = DiffDocument.Align(Lines(old), Lines(current), patch); return new(path, oldTitle, newTitle, result.Rows, result.Hunks, notice);
        } finally { Directory.Delete(temporary, true); }
    }
    public async Task<RevisionFile[]> RevisionFiles(string revision, string? parent = null) {
        revision = await Revision(revision);
        if (parent == null) parent = (await Run("rev-list", "--parents", "-1", revision)).Trim().Split(' ').Skip(1).FirstOrDefault();
        var output = parent == null ? await Run("diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z", "-M", revision, "--") : await Run("diff", "--name-status", "-z", "-M", await Revision(parent), revision, "--");
        var fields = output.Split('\0'); var result = new List<RevisionFile>();
        for (var i = 0; i + 1 < fields.Length;) {
            var code = fields[i++]; var file = fields[i++]; string? original = null;
            if (code[0] is 'R' or 'C') { original = file; file = fields[i++]; }
            result.Add(new(code, file, original));
        }
        return result.ToArray();
    }
}
