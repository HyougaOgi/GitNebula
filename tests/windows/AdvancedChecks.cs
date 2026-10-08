using GitNebula;
public static class AdvancedChecks
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    public static async Task Run(string temporary) {
        var path = Path.Combine(temporary, "advanced"); Directory.CreateDirectory(path);
        var repo = new GitRepository(path); await repo.Run("init", "-q", "-b", "main"); await repo.SetIdentity("Test", "test@example.invalid");
        var file = Path.Combine(path, "file.txt"); await File.WriteAllTextAsync(file, "base\n"); await repo.Commit(["file.txt"], "base"); var first = await repo.Revision("HEAD");
        await File.WriteAllTextAsync(file, "next\n"); await repo.Commit(["file.txt"], "next"); var second = await repo.Revision("HEAD");
        Check((await repo.Compare(first, second)).Contains("+next") && (await repo.Blame("file.txt", "HEAD")).Contains("Test") && (await repo.FileHistory("file.txt")).Contains(first) && (await repo.Reflog()).Contains(second), "compare, blame, full file history and reflog");
        await File.WriteAllTextAsync(Path.Combine(path, "keep.tmp"), "keep"); var rejected = false;
        try { await repo.Reset(first, "hard"); } catch (InvalidOperationException) { rejected = true; }
        Check(rejected && await repo.Revision("HEAD") == second, "reset protects work in progress");
        await repo.Ignore(["keep.tmp"]); Check(!(await repo.Changes()).Any(c => c.Path == "keep.tmp"), "ignore literal selected file"); await repo.Commit([".gitignore"], "ignore");
        await File.WriteAllTextAsync(file, "patch\n"); var patch = Path.Combine(temporary, "changes.patch"); await repo.ExportPatch(patch);
        rejected = false; try { await repo.ExportPatch(patch); } catch (IOException) { rejected = true; }
        Check(rejected && (await File.ReadAllTextAsync(patch)).Contains("+patch"), "patch export preserves existing files");
        await repo.Discard(["file.txt"]); await repo.ApplyPatch(patch, true); Check(await File.ReadAllTextAsync(file) == "next\n", "check does not apply patch");
        await repo.ApplyPatch(patch); Check(await File.ReadAllTextAsync(file) == "patch\n", "patch applies"); await repo.Discard(["file.txt"]);
        await repo.Reset(second, "soft"); Check(await repo.Revision("HEAD") == second && (await repo.Changes()).Any(c => c.Path == ".gitignore"), "soft reset retains staged changes"); await repo.Commit([".gitignore"], "ignore again");
        var target = Path.Combine(temporary, "worktree"); await repo.AddWorktree(target, "worktree-branch"); var tree = new GitRepository(target); await tree.Open();
        Check(await tree.Branch() == "worktree-branch" && (await repo.Worktrees()).Contains(target), "worktree creates separate working branch");
        rejected = false; try { await repo.Blame("../outside", "HEAD"); } catch (InvalidOperationException) { rejected = true; } Check(rejected, "file tools reject external paths");
        var modulePath = Path.Combine(temporary, "module"); Directory.CreateDirectory(modulePath); var module = new GitRepository(modulePath); await module.Run("init", "-q"); await module.SetIdentity("Test", "test@example.invalid");
        await File.WriteAllTextAsync(Path.Combine(modulePath, "module.txt"), "initial\n"); await module.Commit(["module.txt"], "module");
        var count = Environment.GetEnvironmentVariable("GIT_CONFIG_COUNT"); var key = Environment.GetEnvironmentVariable("GIT_CONFIG_KEY_0"); var value = Environment.GetEnvironmentVariable("GIT_CONFIG_VALUE_0");
        try {
            Environment.SetEnvironmentVariable("GIT_CONFIG_COUNT", "1"); Environment.SetEnvironmentVariable("GIT_CONFIG_KEY_0", "protocol.file.allow"); Environment.SetEnvironmentVariable("GIT_CONFIG_VALUE_0", "always");
            await repo.AddSubmodule(modulePath, "dependencies/module"); Check((await repo.Submodules()).Contains(await module.Revision("HEAD")), "submodule registered revision");
            await repo.Commit([".gitmodules", "dependencies/module"], "add module"); await repo.UpdateSubmodules();
            Check(await new GitRepository(Path.Combine(path, "dependencies/module")).Revision("HEAD") == await module.Revision("HEAD"), "submodule updates to recorded revision");
        } finally { Environment.SetEnvironmentVariable("GIT_CONFIG_COUNT", count); Environment.SetEnvironmentVariable("GIT_CONFIG_KEY_0", key); Environment.SetEnvironmentVariable("GIT_CONFIG_VALUE_0", value); }
        var changed = Path.Combine(path, "file.txt"); await File.WriteAllTextAsync(changed, "next\ninserted\n");
        var document = await repo.FileComparison("file.txt"); Check(document.Rows.Length == 2 && document.Rows[0].Kind == "unchanged" && document.Rows[1].Kind == "added" && document.Hunks.SequenceEqual([1]), "aligned full file insertion");
        await repo.Commit(["file.txt"], "insert"); await repo.Run("mv", "file.txt", "renamed.txt"); await repo.Commit(["renamed.txt"], "rename");
        var renamedFiles = await repo.RevisionFiles("HEAD"); Check(renamedFiles.Length == 1 && renamedFiles[0].Original == "file.txt" && renamedFiles[0].Path == "renamed.txt", "rename source retained");
        Check((await repo.FileComparison("renamed.txt", "HEAD", original: "file.txt")).Rows.All(r => r.Kind == "unchanged"), "rename comparison aligns identical content");
        Check((await repo.FileComparison("file.txt", first)).Rows.All(r => r.Kind == "added"), "root comparison uses empty tree");
        await File.WriteAllBytesAsync(Path.Combine(path, "binary"), [1, 0, 2]); Check((await repo.FileComparison("binary")).Rows.Length == 0, "binary bytes are not rendered");
        Console.WriteLine("PASS: compare, blame, file history, reflog, reset, ignore/discard, patch, worktree and submodule");
    }
}
