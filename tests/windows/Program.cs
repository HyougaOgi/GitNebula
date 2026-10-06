using GitNebula;

static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
var temporary = Path.Combine(Path.GetTempPath(), "gitnebula-tests-" + Guid.NewGuid());
Directory.CreateDirectory(temporary);
try
{
    var root = Path.Combine(temporary, "repo with spaces"); Directory.CreateDirectory(root);
    var repo = new GitRepository(root);
    await repo.Run("init", "-q"); await repo.Run("config", "user.name", "Test"); await repo.Run("config", "user.email", "test@example.invalid");
    var request = LaunchRequest.Parse(["--action", "commit", "--path", Path.Combine(root, "星 雲.txt"), "--path", Path.Combine(root, "src")]);
    Check(request.Action == "commit" && request.Includes("星 雲.txt", root), "file selection");
    Check(request.Includes(Path.Combine("src", "nested", "file"), root), "directory scope");
    Check(!request.Includes(Path.Combine("src-other", "file"), root), "directory boundary");
    Check(!request.Includes("unrelated", root), "exclude unrelated changes");
    Check(LaunchRequest.Parse(["--open", root]).Action == "open", "legacy launch");
    bool invalidAction = false;
    try { LaunchRequest.Parse(["--action", "reset"]); } catch (ArgumentException) { invalidAction = true; }
    Check(invalidAction, "reject unknown action");
    await repo.Open(); Check((await repo.Changes()).Count == 0, "empty repository");
    bool rejected = false;
    try { await repo.Push("origin"); } catch (InvalidOperationException error) { rejected = error.Message.Contains("最初のコミット"); }
    Check(rejected, "unborn push explains that a first commit is needed");
    await File.WriteAllTextAsync(Path.Combine(root, "old.txt"), "base\n");
    Check((await repo.Diff("old.txt")) == "base\n", "untracked preview");
    await File.WriteAllTextAsync(Path.Combine(root, "other.txt"), "unselected\n"); await repo.Run("add", "other.txt");
    await repo.Unstage(["old.txt", "other.txt"]);
    Check(await repo.Run("diff", "--cached", "--name-only") == "" && await File.ReadAllTextAsync(Path.Combine(root, "other.txt")) == "unselected\n", "unstage mixed selection before first commit preserves files");
    await repo.Run("add", "other.txt");
    await repo.Commit(["old.txt"], "initial");
    Check((await repo.Run("diff", "--cached", "--name-only")).Trim() == "other.txt", "preserve unselected stage");
    await repo.Commit(["other.txt"], "other");
    await repo.Run("mv", "old.txt", "new.txt"); await File.WriteAllTextAsync(Path.Combine(root, "old.txt"), "unselected recreation\n");
    var before = await repo.Run("write-tree"); rejected = false;
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
    await repo.Run("switch", "--detach", "HEAD");
    rejected = false; try { await repo.Push("origin"); } catch (InvalidOperationException error) { rejected = error.Message.Contains("ブランチを選んでください"); }
    Check(rejected, "detached push explains selecting a branch"); await repo.SwitchBranch(main);
    var clone = await GitRepository.Clone(remotePath, Path.Combine(temporary, "clone"));
    foreach (var source in new[] { "https://example.invalid/team/星%20repo.git/?token=123#fragment", "git@example.invalid:team/星 repo.git", "ssh://git@example.invalid/team/星%20repo.git", "/tmp/星 repo.git/", @"C:\Projects\星 repo.git" })
        Check(CloneLocation.RepositoryName(source) == "星 repo", "clone source name: " + source);
    var parent = Path.Combine(temporary, "occupied parent 星 #&"); Directory.CreateDirectory(parent);
    await File.WriteAllTextAsync(Path.Combine(parent, "keep.txt"), "keep\n"); Directory.CreateDirectory(Path.Combine(parent, "other folder"));
    var destination = CloneLocation.Destination(parent, remotePath);
    var childClone = await GitRepository.Clone(remotePath, destination);
    Check(File.Exists(Path.Combine(destination, "new.txt")) && !Directory.Exists(Path.Combine(parent, ".git")), "clone creates named child of occupied parent");
    Check(await File.ReadAllTextAsync(Path.Combine(parent, "keep.txt")) == "keep\n" && !Directory.EnumerateFileSystemEntries(Path.Combine(parent, "other folder")).Any(), "parent contents preserved");
    foreach (var source in new[] { "", ".", ".." }) {
        rejected = false; try { CloneLocation.Destination(parent, source); } catch (ArgumentException) { rejected = true; }
        Check(rejected, "reject clone source without a repository name: " + source);
    }
    var emptyCloneTarget = Path.Combine(temporary, "Clone 星 empty"); Directory.CreateDirectory(emptyCloneTarget);
    var emptyClone = await GitRepository.Clone(remotePath, emptyCloneTarget);
    Check(await emptyClone.Revision("HEAD") == await repo.Revision("HEAD") && File.Exists(Path.Combine(emptyCloneTarget, "new.txt")), "clone into an existing empty selected directory");
    await File.WriteAllTextAsync(Path.Combine(emptyCloneTarget, "keep.txt"), "preserve\n");
    rejected = false; try { await GitRepository.Clone(remotePath, emptyCloneTarget); } catch (InvalidOperationException) { rejected = true; }
    Check(rejected && await File.ReadAllTextAsync(Path.Combine(emptyCloneTarget, "keep.txt")) == "preserve\n", "clone rejects a nonempty directory and preserves its files");
    await clone.Run("config", "user.name", "Test"); await clone.Run("config", "user.email", "test@example.invalid");
    await File.WriteAllTextAsync(Path.Combine(clone.Path, "new.txt"), "remote update\n"); await clone.Commit(["new.txt"], "remote update"); await clone.Push("origin");
    await repo.RenameBranch(main, "local-work"); await repo.Run("remote", "rename", "origin", "team");
    await repo.Run("remote", "add", "origin", remotePath);
    Check(await repo.PreferredRemote() == "team", "prefer configured remote");
    Check(await repo.RemoteBranch("team") == "refs/heads/" + main, "use upstream branch");
    await repo.Fetch("team"); await repo.Pull("team");
    Check(await File.ReadAllTextAsync(Path.Combine(root, "new.txt")) == "remote update\n", "clone/fetch/push/pull");
    await File.WriteAllTextAsync(Path.Combine(root, "new.txt"), "local reply\n"); await repo.Commit(["new.txt"], "reply"); await repo.Push("team");
    await clone.Pull("origin");
    Check(await File.ReadAllTextAsync(Path.Combine(clone.Path, "new.txt")) == "local reply\n", "push upstream branch");

    Check(GitProcess.Lines("origin\r\nteam\r\n").SequenceEqual(new[] { "origin", "team" }), "CRLF remote names");
    Check(GitProcess.Lines("main\r\nfeature/星\r\n").SequenceEqual(new[] { "main", "feature/星" }), "CRLF branch names");
    Check((await repo.Remotes()).Contains("team"), "remote list usable for commands");
    await repo.Push((await repo.Remotes()).Single(name => name == "team"));
    await repo.CreateTag("v1.0", "HEAD", "release"); await repo.PushTag("v1.0", "team");
    Check((await remote.Tags()).Contains("v1.0"), "tag push to local bare repository");
    await repo.DeleteTag("v1.0");
    await repo.SetRemote("backup", remotePath); Check((await repo.Remotes()).Contains("backup"), "set remote"); await repo.RemoveRemote("backup");
    await File.WriteAllTextAsync(Path.Combine(root, "new.txt"), "staged\n"); await repo.Stage(["new.txt"]);
    await repo.Run("config", "diff.external", "gitnebula-nonexistent-diff-helper");
    Check((await repo.Diff("new.txt")).Contains("+staged"), "diff stays inside the GUI even with external diff configured");
    await repo.Run("config", "--unset", "diff.external");
    await File.WriteAllTextAsync(Path.Combine(root, "new.txt"), "working\n");
    await File.WriteAllTextAsync(Path.Combine(root, "星 & [new].txt"), "untracked\n");
    await repo.Unstage(["new.txt", "星 & [new].txt"]);
    Check(await repo.Run("diff", "--cached", "--name-only") == "" && await File.ReadAllTextAsync(Path.Combine(root, "new.txt")) == "working\n", "unstage skips untracked files and preserves working changes");
    await File.WriteAllTextAsync(Path.Combine(root, "new.txt"), "staged\n"); await repo.Stage(["new.txt"]);
    await File.WriteAllTextAsync(Path.Combine(root, "new.txt"), "working\n");
    await repo.SaveStash("first", true); var first = (await repo.Stashes()).First();
    Check((await repo.Changes()).Count == 0, "stash cleans index and worktree");
    await File.WriteAllTextAsync(Path.Combine(root, "new.txt"), "second\n"); await repo.SaveStash("second", false);
    Check((await repo.Stashes()).Single(entry => entry.Id == first.Id).Reference == "stash@{1}", "stable stash selection");
    await repo.ApplyStash(first.Id);
    Check(await File.ReadAllTextAsync(Path.Combine(root, "new.txt")) == "working\n" && await repo.Run("show", ":new.txt") == "staged\n", "restore stash worktree and index");
    Check(File.Exists(Path.Combine(root, "星 & [new].txt")) && (await repo.Stashes()).Length == 2, "apply preserves stash and restores untracked");
    await repo.Commit(["new.txt", "星 & [new].txt"], "restored stash"); await repo.DropStash(first.Id);
    var second = (await repo.Stashes()).First(); await repo.DropStash(second.Id);
    await File.WriteAllTextAsync(Path.Combine(root, "new.txt"), "pop value\n"); await repo.SaveStash("pop", false);
    var popEntry = (await repo.Stashes()).First(); await repo.ApplyStash(popEntry.Id, true);
    Check((await repo.Stashes()).Length == 0, "successful pop removes stash");
    await repo.Commit(["new.txt"], "pop result");
    await File.WriteAllTextAsync(Path.Combine(root, "untracked-only.txt"), "only\n");
    rejected = false; try { await repo.SaveStash("no-op", false); } catch (InvalidOperationException) { rejected = true; }
    Check(rejected && (await repo.Stashes()).Length == 0, "untracked-only stash cannot claim success without include-untracked");
    File.Delete(Path.Combine(root, "untracked-only.txt"));
    var localBranch = await repo.Branch();
    await repo.CreateBranch("pick-source"); await File.WriteAllTextAsync(Path.Combine(root, "pick.txt"), "picked\n"); await repo.Commit(["pick.txt"], "pick this");
    var pickId = await repo.Revision("HEAD"); await repo.SwitchBranch(localBranch);
    await repo.CherryPick(pickId); var picked = await repo.Revision("HEAD"); await repo.Revert(picked);
    Check(!File.Exists(Path.Combine(root, "pick.txt")) && (await repo.History()).Any(c => c.Subject.StartsWith("Revert")), "revert preserves history");
    await repo.CreateBranch("rebase-source"); await File.WriteAllTextAsync(Path.Combine(root, "new.txt"), "feature conflict\n"); await repo.Commit(["new.txt"], "feature conflict");
    var featureId = await repo.Revision("HEAD"); await repo.SwitchBranch(localBranch);
    await File.WriteAllTextAsync(Path.Combine(root, "new.txt"), "main conflict\n"); await repo.Commit(["new.txt"], "main conflict");
    rejected = false; try { await repo.CherryPick(featureId); } catch (InvalidOperationException) { rejected = true; }
    Check(rejected && await repo.Sequence() == "cherry-pick", "cherry-pick conflict state");
    rejected = false; try { await repo.RenameBranch(localBranch, "rename-during-sequence"); } catch (InvalidOperationException) { rejected = true; }
    Check(rejected && (await repo.Branches()).Contains(localBranch), "branch rename must not disturb an active sequence");
    await repo.SaveResolution("new.txt", "picked conflict resolved\n"); await repo.ContinueSequence();
    Check(await repo.Sequence() == null, "continue cherry-pick");
    // Revert an older conflicting change and retain an actionable state on failure.
    rejected = false; try { await repo.Revert(featureId); } catch (InvalidOperationException) { rejected = true; }
    Check(rejected && await repo.Sequence() == "revert", "revert conflict state"); await repo.AbortSequence();
    await repo.SwitchBranch("rebase-source");
    rejected = false; try { await repo.Rebase(localBranch); } catch (InvalidOperationException) { rejected = true; }
    Check(rejected && await repo.Sequence() == "rebase", "rebase conflict state"); await repo.AbortSequence();
    Check(await repo.Revision("HEAD") == featureId, "abort rebase returns original head");
    try { await repo.Rebase(localBranch); } catch (InvalidOperationException) { }
    await repo.SaveResolution("new.txt", "rebased resolution\n"); await repo.ContinueSequence();
    Check(await repo.Sequence() == null && await File.ReadAllTextAsync(Path.Combine(root, "new.txt")) == "rebased resolution\n", "continue rebase");
    await File.WriteAllTextAsync(Path.Combine(root, "new.txt"), "stashed conflict\n"); await repo.SaveStash("conflicting stash", true);
    var conflictingStash = (await repo.Stashes()).First();
    await File.WriteAllTextAsync(Path.Combine(root, "new.txt"), "new base\n"); await repo.Commit(["new.txt"], "new base");
    rejected = false; try { await repo.ApplyStash(conflictingStash.Id, true); } catch (InvalidOperationException) { rejected = true; }
    Check(rejected && (await repo.Stashes()).Any(s => s.Id == conflictingStash.Id), "failed pop preserves stash");
    Check((await repo.Conflicts()).Contains("new.txt"), "stash conflicts visible");
    await repo.SaveResolution("new.txt", "stash resolved\n"); await repo.Commit(["new.txt"], "stash resolved");
    await repo.DropStash(conflictingStash.Id);
    if (!OperatingSystem.IsWindows()) {
        // Reproduce CRLF command output on macOS without needing a Windows host.
        var wrapper = Path.Combine(temporary, "git-crlf.py"); var originalExecutable = AppSettings.Current.GitExecutable;
        var executable = System.Text.Json.JsonSerializer.Serialize(GitProcess.Executable);
        await File.WriteAllTextAsync(wrapper, "#!/usr/bin/env python3\nimport subprocess,sys\nr=subprocess.run([" + executable + ",*sys.argv[1:]],capture_output=True)\nsys.stdout.buffer.write(r.stdout.replace(b'\\n', b'\\r\\n'))\nsys.stderr.buffer.write(r.stderr)\nsys.exit(r.returncode)\n");
        File.SetUnixFileMode(wrapper, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        try {
            AppSettings.Current.GitExecutable = wrapper;
            Check((await repo.Remotes()).Contains("team") && (await repo.Branches()).Contains("rebase-source"), "CRLF output parsed at process boundary");
            await repo.Push((await repo.Remotes()).Single(name => name == "team")); await repo.Fetch("team");
            await repo.SwitchBranch(localBranch); await repo.SwitchBranch("rebase-source");
            Check(await repo.Branch() == "rebase-source", "CRLF branch choices execute correctly");
            Console.WriteLine("PASS: simulated CRLF process output — remote selection, push, fetch and branch switch");
        } finally { AppSettings.Current.GitExecutable = originalExecutable; }
    }
    // Large outputs are drained concurrently; diagnostics include stderr and the exit status.
    Check((await repo.Run("log", "--all", "--format=%H%B%P")).Length > 0, "history output");
    rejected = false; try { await repo.Run("this-command-does-not-exist"); } catch (InvalidOperationException error) { rejected = error.Message.Contains("終了コード") && error.Message.Contains("not a git command"); }
    Check(rejected, "actionable Git stderr");
    Console.WriteLine("PASS: CRLF parsing, stash save/list/apply/pop/drop, tag/remote, cherry-pick/revert/rebase and conflict recovery");
    Console.WriteLine("PASS: Windows Git backend — preview, selected commit, rename guard, deletion, branches, graph, conflicts, clone/fetch/push/pull");
}
finally
{
    // Git object files are read-only on Windows.
    foreach (var file in Directory.EnumerateFiles(temporary, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
    Directory.Delete(temporary, true);
}
