using GitNebula;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
var temporary = Path.Combine(Path.GetTempPath(), "gitnebula-tests-" + Guid.NewGuid());
Directory.CreateDirectory(temporary);
try
{
    var root = Path.Combine(temporary, "repo with spaces"); Directory.CreateDirectory(root);
    var repo = new GitRepository(root);
    await repo.Run("init", "-q"); await repo.Run("config", "user.name", "Test"); await repo.Run("config", "user.email", "test@example.invalid");
    await repo.Open(); Check((await repo.Changes()).Count == 0, "empty repository");
    await File.WriteAllTextAsync(Path.Combine(root, "old.txt"), "base\n");
    Check((await repo.Diff("old.txt")) == "base\n", "untracked preview");
    await File.WriteAllTextAsync(Path.Combine(root, "other.txt"), "unselected\n"); await repo.Run("add", "other.txt");
    await repo.Commit(["old.txt"], "initial");
    Check((await repo.Run("diff", "--cached", "--name-only")).Trim() == "other.txt", "preserve unselected stage");
    await repo.Commit(["other.txt"], "other");
    await repo.Run("mv", "old.txt", "new.txt"); await File.WriteAllTextAsync(Path.Combine(root, "old.txt"), "unselected recreation\n");
    var before = await repo.Run("write-tree"); bool rejected = false;
    try { await repo.Commit(["new.txt"], "unsafe"); } catch (InvalidOperationException) { rejected = true; }
    Check(rejected && before == await repo.Run("write-tree"), "rename must reject before mutation");
    await repo.Commit(["old.txt", "new.txt"], "explicit selection");
    await repo.Run("rm", "old.txt"); await repo.Commit(["old.txt"], "staged delete");
    Check(!(await repo.Run("ls-tree", "--name-only", "HEAD")).Contains("old.txt"), "staged deletion");
    var main = await repo.Branch(); await repo.CreateBranch("feature");
    await repo.RenameBranch("feature", "incoming");
    await File.WriteAllTextAsync(Path.Combine(root, "new.txt"), "incoming\n"); await repo.Commit(["new.txt"], "incoming");
    await repo.SwitchBranch(main);
    await File.WriteAllTextAsync(Path.Combine(root, "new.txt"), "current\n"); await repo.Commit(["new.txt"], "current");
    try { await repo.Merge("incoming"); } catch (InvalidOperationException) { }
    Check((await repo.Conflicts()).SequenceEqual(new[] { "new.txt" }), "merge conflict");
    Check((await repo.ConflictText("new.txt")).Contains("<<<<<<<"), "conflict editor content");
    await repo.SaveResolution("new.txt", "resolved\n"); await repo.FinishMerge("resolved merge");
    Check(!await repo.MergeInProgress(), "merge finished");
    Check((await repo.Run("rev-list", "--parents", "-1", "HEAD")).Split(' ', StringSplitOptions.RemoveEmptyEntries).Length == 3, "two parents");
    await repo.DeleteBranch("incoming"); Check((await repo.Graph()).Contains("resolved merge"), "history graph");
    var remotePath = Path.Combine(temporary, "remote.git"); Directory.CreateDirectory(remotePath);
    var remote = new GitRepository(remotePath); await remote.Run("init", "--bare", "-q"); await remote.Run("symbolic-ref", "HEAD", "refs/heads/" + main);
    await repo.Run("remote", "add", "origin", remotePath); await repo.Push("origin");
    var clone = await GitRepository.Clone(remotePath, Path.Combine(temporary, "clone"));
    await clone.Run("config", "user.name", "Test"); await clone.Run("config", "user.email", "test@example.invalid");
    await File.WriteAllTextAsync(Path.Combine(clone.Path, "new.txt"), "remote update\n"); await clone.Commit(["new.txt"], "remote update"); await clone.Push("origin");
    await repo.Fetch("origin"); await repo.Pull("origin");
    Check(await File.ReadAllTextAsync(Path.Combine(root, "new.txt")) == "remote update\n", "clone/fetch/push/pull");
    Console.WriteLine("PASS: Windows Git backend — preview, selected commit, rename guard, deletion, branches, graph, conflicts, clone/fetch/push/pull");
}
finally
{
    // Git object files are read-only on Windows.
    foreach (var file in Directory.EnumerateFiles(temporary, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
    Directory.Delete(temporary, true);
}
