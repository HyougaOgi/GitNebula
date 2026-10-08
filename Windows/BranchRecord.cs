namespace GitNebula;
public record BranchRecord(string Id, string Name, string Subject, string Upstream, string Remote = "")
{
    public bool IsRemote => Remote.Length > 0;
    public string LocalName => IsRemote ? Name[(Remote.Length + 1)..] : Name;
    public string DisplayName => Name + (IsRemote ? "  · " + Localization.Text("リモート") : "");
}
public sealed partial class GitRepository
{
    public async Task<BranchRecord[]> BranchRecords(bool includeRemote = false)
    {
        var arguments = new List<string> { "for-each-ref", "--format=%(refname)%00%(subject)%00%(upstream:short)%00%(symref)", "refs/heads" };
        if (includeRemote) arguments.Add("refs/remotes");
        var remotes = (await Remotes()).OrderByDescending(r => r.Length).ToArray();
        var rows = GitProcess.Lines(await Run(arguments.ToArray())).Select(r => r.Split('\0')).Where(f => f.Length == 4 && f[3].Length == 0).ToArray();
        var tracked = rows.Where(f => f[0].StartsWith("refs/heads/", StringComparison.Ordinal)).Select(f => f[2]).ToHashSet();
        return rows.Select(f => {
            var local = f[0].StartsWith("refs/heads/", StringComparison.Ordinal);
            var name = f[0][(local ? 11 : 13)..];
            return new BranchRecord(local ? name : f[0], name, f[1], f[2], local ? "" : remotes.FirstOrDefault(r => name.StartsWith(r + "/", StringComparison.Ordinal)) ?? "");
        }).Where(r => !r.IsRemote || !tracked.Contains(r.Name)).ToArray();
    }
    private static bool MapsReference(string mapping, string reference)
    {
        if (mapping.StartsWith('^')) return false;
        var parts = mapping.TrimStart('+').Split(':', 2);
        if (parts.Length != 2) return false;
        var destination = parts[1]; var star = destination.IndexOf('*');
        return star < 0 ? destination == reference : reference.Length >= destination.Length - 1 && reference.StartsWith(destination[..star], StringComparison.Ordinal) && reference.EndsWith(destination[(star + 1)..], StringComparison.Ordinal);
    }
}
