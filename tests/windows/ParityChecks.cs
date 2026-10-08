using GitNebula;
using System.Numerics;
public static class ParityChecks
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    public static async Task Run(string temporary)
    {
        var path = Path.Combine(temporary, "parity-source"); Directory.CreateDirectory(path);
        var source = new GitRepository(path); await source.Run("init", "-q", "-b", "main"); await source.SetIdentity("Committer", "committer@example.invalid");
        await File.WriteAllTextAsync(Path.Combine(path, "base.txt"), "base\n"); await source.Commit(["base.txt"], "Subject\n\nBody first\nBody second\n\nReviewed-by: Test");
        var record = (await source.History()).First(); var raw = await source.Run("cat-file", "commit", record.Id);
        Check(record.Id == await source.Revision("HEAD") && record.Id.Length == 40, "full history ID");
        Check(record.Message == raw[(raw.IndexOf("\n\n", StringComparison.Ordinal) + 2)..], "full message body and terminal newline");
        Check(record.Email == "committer@example.invalid" && record.Committer == "Committer" && record.CommitterEmail == record.Email, "author and committer metadata");
        Check(raw.StartsWith("tree " + record.Tree + "\n", StringComparison.Ordinal) && record.DetailFields.All(f => record.DetailsText.Contains(f.Value, StringComparison.Ordinal)), "tree and all-copy values");
        await source.Run("branch", "release/HEAD"); await source.Run("tag", "v1");
        await source.Run("update-ref", "refs/remotes/team/release/HEAD", record.Id);
        await source.Run("symbolic-ref", "refs/remotes/team/HEAD", "refs/remotes/team/release/HEAD");
        await source.Run("update-ref", "refs/notes/review", record.Id);
        var namedHistory = await source.History(topological: true);
        Check(namedHistory.First().BranchNames!.SequenceEqual(["main", "release/HEAD", "team/release/HEAD"]) && NebulaBranch.Group(namedHistory).First().Title == "main, release/HEAD, team/release/HEAD", "actual Git refs distinguish valid HEAD branch names from symbolic aliases and notes");
        await source.Run("branch", "-D", "release/HEAD"); await source.Run("tag", "-d", "v1");
        await source.Run("update-ref", "--no-deref", "-d", "refs/remotes/team/HEAD"); await source.Run("update-ref", "-d", "refs/remotes/team/release/HEAD"); await source.Run("update-ref", "-d", "refs/notes/review");
        await source.CreateBranch("feature/nested"); await File.WriteAllTextAsync(Path.Combine(path, "feature"), "feature"); await source.Commit(["feature"], "feature"); await source.SwitchBranch("main");
        Check((await source.History(reference: "main")).Select(c => c.Id).SequenceEqual([record.Id]) && (await source.History(reference: "feature/nested")).Length == 2, "history branch filter preserves ancestry");
        var bare = Path.Combine(temporary, "parity.git"); await GitProcess.Run(temporary, "clone", "--bare", path, bare);
        var clonePath = Path.Combine(temporary, "parity-clone"); await GitProcess.Run(temporary, "clone", "--single-branch", bare, clonePath);
        var clone = new GitRepository(clonePath); await clone.Open();
        Check((await clone.Branches()).SequenceEqual(["main"]) && !(await clone.BranchRecords(true)).Any(b => b.IsRemote), "single-branch clone starts local-only");
        await clone.Transfer("fetch", "origin", allBranches: true);
        var remote = (await clone.BranchRecords(true)).Single(b => b.Name == "origin/feature/nested");
        Check(remote.IsRemote && remote.LocalName == "feature/nested" && !(await clone.BranchRecords(true)).Any(b => b.Name == "origin/HEAD"), "remote branch choices and symbolic alias exclusion");
        var before = await clone.HeadRevision(); await File.WriteAllTextAsync(Path.Combine(clonePath, "dirty"), "keep");
        var rejected = false; try { await clone.SwitchBranch(remote.Id); } catch (InvalidOperationException) { rejected = true; }
        Check(rejected && await clone.HeadRevision() == before && await File.ReadAllTextAsync(Path.Combine(clonePath, "dirty")) == "keep", "dirty work protected"); File.Delete(Path.Combine(clonePath, "dirty"));
        await clone.Run("branch", "feature/nested", "main"); rejected = false; try { await clone.SwitchBranch(remote.Id); } catch (InvalidOperationException) { rejected = true; }
        Check(rejected && await clone.Revision("feature/nested") == before, "local name collision protected"); await clone.Run("branch", "-D", "feature/nested");
        await clone.SwitchBranch(remote.Id);
        Check(await clone.Branch() == "feature/nested" && await clone.Revision("HEAD") == await source.Revision("feature/nested"), "remote switch creates correct local branch");
        Check(await clone.Configuration("branch.feature/nested.remote") == "origin" && await clone.Configuration("branch.feature/nested.merge") == "refs/heads/feature/nested", "tracking upstream");
        Check(!(await clone.BranchRecords(true)).Any(b => b.Name == remote.Name) && (await clone.Run("config", "--get-all", "remote.origin.fetch")).Contains("+refs/heads/main:refs/remotes/origin/main", StringComparison.Ordinal), "no duplicate choice and original fetch mapping retained");
        var reports = new List<TransferProgress>(); var clone2 = await GitRepository.Clone(new Uri(bare).AbsoluteUri, Path.Combine(temporary, "progress-clone"), p => reports.Add(p));
        Check(reports.Any(p => p.Percent.HasValue) && reports.All(p => p.Percent is null or >= 0 and <= 100), "real clone stage percentages");
        var chunks = new List<TransferProgress>(); var parser = new TransferProgressParser(chunks.Add);
        foreach (var chunk in new[] { "remote: Counting obj", "ects: 5", "0% (1/2)\r", "Counting objects: 100% (2/2)\n", "fatal: detail\n" }) parser.Feed(chunk);
        Check(chunks.Select(p => p.Percent).SequenceEqual(new int?[] { 50, 100 }), "chunked CR and remote progress");
        if (!OperatingSystem.IsWindows()) {
            var wrapper = Path.Combine(temporary, "parity-progress.sh"); await File.WriteAllTextAsync(wrapper, "#!/bin/sh\nprintf 'Counting objects: 25%% (1/4)\\r' >&2\nsleep 1\nprintf 'done\\000data'\nprintf 'diagnostic\\n' >&2\n");
            File.SetUnixFileMode(wrapper, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            var original = AppSettings.Current.GitExecutable;
            try {
                AppSettings.Current.GitExecutable = wrapper; var arrived = new TaskCompletionSource<TransferProgress>(TaskCreationOptions.RunContinuationsAsynchronously);
                var transfer = GitProcess.RunWithOutput(temporary, ["fetch"], [0], p => arrived.TrySetResult(p));
                await arrived.Task.WaitAsync(TimeSpan.FromSeconds(5)); Check(!transfer.IsCompleted, "progress arrives before process exit"); var output = await transfer;
                Check(output.Output == "done\0data" && output.Diagnostics == "Counting objects: 25% (1/4)\rdiagnostic\n", "stdout and diagnostics preserved");
            } finally { AppSettings.Current.GitExecutable = original; }
        }
        var fixture = new[] {
            new CommitRecord("9", "Author", "date", "Main", "body", ["8"], "HEAD -> main"), new CommitRecord("8", "Author", "date", "Merge", "body", ["7", "4"]),
            new CommitRecord("7", "Author", "date", "Main", "body", ["6"]), new CommitRecord("6", "Author", "date", "Base", "body", []),
            new CommitRecord("5", "Author", "date", "Feature", "body", ["4"], "feature"), new CommitRecord("4", "Author", "date", "Feature", "body", ["6"]),
            new CommitRecord("3", "Author", "date", "Other", "body", ["6"], "other"), new CommitRecord("2", "Author", "date", "Fourth", "body", ["6"], "fourth")
        };
        var branches = NebulaBranch.Group(fixture); var links = NebulaBranch.Links(branches);
        var labelFixture = new[] {
            new CommitRecord("tip", "Tester", "date", "tip", "tip", ["merge"], "tag: v2, origin/main, HEAD -> main, origin/HEAD"),
            new CommitRecord("merge", "Tester", "date", "merge", "merge", ["old", "merged"]),
            new CommitRecord("old", "Tester", "date", "old", "old", ["base"]), new CommitRecord("base", "Tester", "date", "base", "base", []),
            new CommitRecord("feature", "Tester", "date", "feature", "feature", ["base"], "tag: v1, feature/topic, origin/feature/topic"),
            new CommitRecord("merged", "Tester", "date", "merged", "merged", ["base"], "tag: deleted"),
            new CommitRecord("orphan", "Tester", "date", "orphan", "orphan", [], "tag: orphan")
        };
        var labels = NebulaBranch.Group(labelFixture).SelectMany(b => b.Commits.Select(c => (c.Id, b.Title))).ToDictionary(p => p.Id, p => p.Title);
        Check(labels["tip"] == "main, origin/main" && labels["feature"] == "feature/topic, origin/feature/topic" && labels["merged"] == "main, origin/main" && labels["orphan"] == "orphan", "4D uses actual branch refs and containing branches for merged logs");
        Check(NebulaBranch.BranchNames("HEAD, tag: v1, refs/stash, refs/notes/review").Length == 0 && NebulaBranch.BranchNames("tag: v1, refs/heads/release/HEAD, refs/remotes/origin/release/HEAD, refs/remotes/origin/HEAD").SequenceEqual(["release/HEAD", "origin/release/HEAD"]), "tags, stash, notes and symbolic HEAD aliases are not branch labels");
        Check(branches.SelectMany(b => b.Commits).Select(c => c.Id).ToHashSet().SetEquals(fixture.Select(c => c.Id)) && branches.Sum(b => b.Commits.Length) == fixture.Length, "4D logs retain every commit exactly once");
        var membership = branches.SelectMany(b => b.Commits.Select(c => (c.Id, Branch: b.Id))).ToDictionary(p => p.Id, p => p.Branch);
        var actual = links.Values.SelectMany(v => v).ToHashSet(); var expected = fixture.SelectMany(c => c.Parents.Where(p => membership.ContainsKey(p) && membership[p] != membership[c.Id]).Select(p => (c.Id, p))).ToHashSet();
        Check(actual.SetEquals(expected), "branch connections retain actual Git parent relationships");
        Check(branches.Max(b => b.Radius) > branches.Min(b => b.Radius), "branch size grows with log count");
        var a = branches[0].Position; Check(Math.Abs(Vector3.Dot(branches[1].Position - a, Vector3.Cross(branches[2].Position - a, branches[3].Position - a))) > .1, "4D spatial layout is not planar");
        var camera = new OrbitCamera(); var point = new Vector3(2, 3, 4); var projection = camera.Project(point, 800, 500); var pixels = NebulaVolume.Pixels(camera, 48, 30);
        camera.Zoom(-1000); camera.Zoom(1000); Check(camera.Project(point, 800, 500) == projection && NebulaVolume.Pixels(camera, 48, 30).SequenceEqual(pixels), "equal reverse scroll returns exact position even past zoom limits");
        camera.Rotate(150, 70); Check(camera.Project(point, 800, 500) != projection && !NebulaVolume.Pixels(camera, 48, 30).SequenceEqual(pixels), "rotation changes both 3D geometry and volume");
        var transformed = camera.Transform(point); Check(Vector3.Distance(camera.Inverse(transformed.X, transformed.Y, transformed.Z), point) < .00001, "camera inverse");
        Check(!NebulaVolume.Pixels(new OrbitCamera(), 48, 30, 10).SequenceEqual(pixels), "nebula gas evolves over time");
        var distant = new OrbitCamera(); distant.Zoom(1000); Check(NebulaVolume.Pixels(distant, 48, 30).Where((_, i) => i % 4 == 0).Max() > 30, "nebula remains visible when zoomed out");
        Console.WriteLine("PASS: full commit information/copy values, remote and single-branch tracking, live progress, protected switch, spatial nebula and reversible camera");
    }
}
