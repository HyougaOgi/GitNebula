using System.Windows;
using System.Windows.Controls;
namespace GitNebula;

public partial class MainWindow
{
    public void ShowHome()
    {
        if (busy) homeRequested = true;
        else if (action != "open") Navigate("open");
        Show(); WindowState = WindowState.Normal; Activate();
    }
    public async Task ShowRequest(LaunchRequest value)
    {
        initialRequestHandled = true;
        Show(); WindowState = WindowState.Normal; Activate();
        while (busy) await Task.Delay(50);
        if (value.Action == "open" && value.Paths.Length == 0) { ShowHome(); return; }
        if (value.Action != action || value.Paths.Length > 0) CaptureRoute();
        transferReport = null;
        await Act(async () => {
            if (repository != null) drafts[repository.Path] = Message.Text;
            request = value.Paths.Length == 0 && repository != null ? new LaunchRequest(value.Action, request.Paths) : value;
            if (value.Action == "clone" && value.Paths.Length > 0) CloneParent.Text = LaunchRequest.DirectoryFor(value.Paths[0]);
            var opensRepository = value.Action is not ("clone" or "settings") && value.Paths.Length > 0;
            if (opensRepository) { repository = null; hasHead = false; sequence = null; merging = false; initialSelection = true; selected.Clear(); Message.Clear(); }
            SetAction(value.Action);
            if (opensRepository) {
                await OpenPath(value.Paths[0]);
                Message.Text = drafts.GetValueOrDefault(Repo.Path, "");
            } else if (repository != null && value.Action is not ("clone" or "settings")) await Refresh();
        });
        Show(); WindowState = WindowState.Normal; Activate();
    }
    private void Home_Click(object sender, RoutedEventArgs e) => ShowHome();
    private void Navigate_Click(object sender, RoutedEventArgs e) => Navigate((string)((Button)sender).Tag);
    private async Task RefreshActionData()
    {
        if (repository == null) return;
        if (action == "graph") { RenderGraph(GraphLayout.Rows(await Repo.History(true, graphLimit))); if (GraphList.SelectedItem is ListBoxItem graph && graph.Tag is string graphId) GraphDetails.Text = await Repo.ShowCommit(graphId); }
        else if (action is "log" or "cherry-pick" or "revert") {
            var id = (CommitList.SelectedItem as CommitRecord)?.Id;
            var commits = await Repo.History(); CommitList.ItemsSource = commits;
            CommitList.SelectedItem = commits.FirstOrDefault(c => c.Id == id) ?? commits.FirstOrDefault();
            if (CommitList.SelectedItem is CommitRecord commit) History.Text = await Repo.ShowCommit(commit.Id);
            else History.Text = Localization.Text("まだコミットはありません。");
        } else if (action == "stash") {
            var id = (StashList.SelectedItem as StashEntry)?.Id;
            var entries = await Repo.Stashes(); StashList.ItemsSource = entries;
            StashList.SelectedItem = entries.FirstOrDefault(s => s.Id == id) ?? entries.FirstOrDefault();
            StashPreview.Text = StashList.SelectedItem is StashEntry entry ? await Repo.ShowStash(entry.Id) : Localization.Text("退避データはありません。");
        } else if (action == "tags") TagList.ItemsSource = await Repo.Tags();
        else if (action == "remotes") RemoteList.ItemsSource = await Repo.Remotes();
        else if (action == "identity") {
            IdentityName.Text = await Repo.Configuration("user.name") ?? "";
            IdentityEmail.Text = await Repo.Configuration("user.email") ?? "";
        }
        if (action is "push" or "pull" or "fetch") await UpdateRemoteTarget();
    }
    private async void Commit_Changed(object sender, SelectionChangedEventArgs e)
    {
        Controls();
        if (busy || CommitList.SelectedItem is not CommitRecord commit) return;
        await Act(async () => History.Text = await Repo.ShowCommit(commit.Id));
    }
    private async void CherryPick_Click(object sender, RoutedEventArgs e)
    {
        if (CommitList.SelectedItem is CommitRecord commit && Confirm(Localization.Format($"{commit.ShortId} · {commit.Subject}\n現在の {currentBranch} に変更を取り込みます（Cherry-pick）。")))
            await Act(() => Operate(() => Repo.CherryPick(commit.Id)), Localization.Text("Cherry-pick が完了しました。"));
    }
    private async void Revert_Click(object sender, RoutedEventArgs e)
    {
        if (CommitList.SelectedItem is CommitRecord commit && Confirm(Localization.Format($"{commit.ShortId} · {commit.Subject}\n履歴を残したまま、この変更を打ち消す新しいコミットを {currentBranch} に作成します（Revert）。")))
            await Act(() => Operate(() => Repo.Revert(commit.Id)), Localization.Text("Revert が完了しました。履歴を残して変更を取り消しました。"));
    }
    private async void Integrate_Click(object sender, RoutedEventArgs e)
    {
        var branch = Branch;
        if (!Confirm(action == "rebase" ? Localization.Format($"{currentBranch} のコミットを {branch} の上につなぎ直します（Rebase）。コミット ID が変わります。") : Localization.Format($"{branch} の変更を {currentBranch} に取り込みます（Merge）。"))) return;
        await Act(() => Operate(() => action == "rebase" ? Repo.Rebase(branch) : Repo.Merge(branch)), Localization.Text("ブランチの変更を取り込みました。"));
    }
    private async void Continue_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(Repo.ContinueSequence), Localization.Text("操作を再開しました。"));
    private async void AbortSequence_Click(object sender, RoutedEventArgs e)
    {
        if (Confirm(Localization.Format($"{sequence} の競合解決作業を破棄し、開始前に戻します。"))) await Act(() => Operate(Repo.AbortSequence), Localization.Text("操作を中止しました。"));
    }
    private async void SaveStash_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.SaveStash(StashMessage.Text, IncludeUntracked.IsChecked == true)), Localization.Text("変更を退避しました。"));
    private async void Stash_Changed(object sender, SelectionChangedEventArgs e)
    {
        Controls();
        if (!busy && StashList.SelectedItem is StashEntry entry) await Act(async () => StashPreview.Text = await Repo.ShowStash(entry.Id));
    }
    private StashEntry SelectedStash => StashList.SelectedItem as StashEntry ?? throw new InvalidOperationException(Localization.Text("退避データを選択してください。"));
    private async void ApplyStash_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.ApplyStash(SelectedStash.Id)), Localization.Text("変更を適用しました。退避データは残っています。"));
    private async void PopStash_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.ApplyStash(SelectedStash.Id, true)), Localization.Text("退避を取り出しました。"));
    private async void DropStash_Click(object sender, RoutedEventArgs e)
    {
        if (StashList.SelectedItem is StashEntry entry && Confirm(Localization.Format($"退避データ「{entry.Title}」を削除します（Drop）。"))) await Act(() => Operate(() => Repo.DropStash(entry.Id)), Localization.Text("退避を削除しました。"));
    }
    private async void Stage_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.Stage(selected.ToArray())), Localization.Text("選択した変更をステージしました。"));
    private async void Unstage_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.Unstage(selected.ToArray())), Localization.Text("選択した変更をステージ解除しました。"));
    private async void CreateTag_Click(object sender, RoutedEventArgs e)
    {
        var values = Prompt(Localization.Text("タグを作成"), Localization.Text("タグ名"), Localization.Text("対象コミット / ブランチ（例: HEAD）"), Localization.Text("注釈（空欄なら軽量タグ）"));
        if (values != null) await Act(() => Operate(() => Repo.CreateTag(values[0], values[1], values[2])), Localization.Text("タグを作成しました。"));
    }
    private async void DeleteTag_Click(object sender, RoutedEventArgs e)
    {
        if (TagList.SelectedItem is string tag && Confirm(Localization.Format($"ローカルのタグ {tag} を削除します。"))) await Act(() => Operate(() => Repo.DeleteTag(tag)), Localization.Text("タグを削除しました。"));
    }
    private async void PushTag_Click(object sender, RoutedEventArgs e)
    {
        if (TagList.SelectedItem is not string tag) { Status.Text = Localization.Text("タグを選択してください。"); return; }
        var values = Prompt(Localization.Text("タグの送信先を指定"), Localization.Text("登録済みのリモート名（例: origin）"));
        if (values != null) await Act(() => Operate(() => Repo.PushTag(tag, values[0])), Localization.Text("タグを送信しました。"));
    }
    private async void RemoteSetting_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!busy && RemoteList.SelectedItem is string name) await Act(async () => { RemoteName.Text = name; RemoteUrl.Text = (await Repo.Run("remote", "get-url", name)).TrimEnd('\r', '\n'); });
    }
    private async void SaveRemote_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.SetRemote(RemoteName.Text, RemoteUrl.Text)), Localization.Text("リモート設定を保存しました。"));
    private async void RemoveRemote_Click(object sender, RoutedEventArgs e)
    {
        var name = RemoteName.Text;
        if (Confirm(Localization.Format($"リモート {name} の登録と追跡参照を削除します。サーバー上のリポジトリは残ります。"))) await Act(() => Operate(() => Repo.RemoveRemote(name)), Localization.Text("リモートの登録を削除しました。"));
    }
    private async void SaveIdentity_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.SetIdentity(IdentityName.Text, IdentityEmail.Text)), Localization.Text("コミット作成者を保存しました。"));
    private async Task UpdateRemoteTarget()
    {
        if (repository == null || string.IsNullOrEmpty(Remote)) { RemoteTarget.Text = Localization.Text("送受信先を選択してください。"); return; }
        var url = (await Repo.Run("remote", "get-url", Remote)).TrimEnd('\r', '\n');
        if (action != "fetch" && (!hasHead || currentBranch == "detached HEAD")) {
            RemoteTarget.Text = !hasHead ? Localization.Text("送受信する前に最初のコミットを作成してください。") : Localization.Text("送受信するブランチを選んでください（現在は detached HEAD）。");
            return;
        }
        RemoteTarget.Text = action == "fetch" ? Localization.Format($"取得元: {Remote}\n{url}") : $"{currentBranch} ↔ {Remote}/{(await Repo.RemoteBranch(Remote))[11..]}\n{url}";
    }
    private async void Remote_Changed(object sender, SelectionChangedEventArgs e)
    {
        Controls(); if (!busy && repository != null && action is "push" or "pull" or "fetch") await Act(UpdateRemoteTarget);
    }
    private async void SaveSettings_Click(object sender, RoutedEventArgs e) => await Act(() => {
        var settings = AppSettings.Current;
        var key = string.IsNullOrWhiteSpace(SshKeyPath.Text) ? "" : LaunchRequest.InputPath(SshKeyPath.Text);
        if (key.Length > 0) {
            if (!System.IO.File.Exists(key) || key.EndsWith(".pub", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException(Localization.Text("読み込み可能な秘密鍵を選択してください。公開鍵（.pub）は使用できません。"));
            using (System.IO.File.OpenRead(key)) { }
            if (SshPassphrase.Password.Length > 0) SSHCredentialStore.Save(key, SshPassphrase.Password);
        } else if (SshPassphrase.Password.Length > 0) throw new ArgumentException(Localization.Text("パスフレーズを保存する秘密鍵を選択してください。"));
        settings.KeepRunning = KeepRunning.IsChecked == true; settings.GitExecutable = GitExecutable.Text.Trim(); settings.SshKeyPath = key; settings.Save();
        SshKeyPath.Text = key; LoadSavedPassphrase();
        GitDetected.Text = Localization.Text("使用する Git: ") + GitProcess.Executable;
        return Task.CompletedTask;
    }, Localization.Text("アプリの設定を保存しました。"));
    private void ChooseSshKey_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = Localization.Text("SSH 秘密鍵を選択"), InitialDirectory = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh") };
        if (dialog.ShowDialog(this) == true) SshKeyPath.Text = dialog.FileName;
    }
    private async void ForgetSshPassphrase_Click(object sender, RoutedEventArgs e) => await Act(() => {
        SSHCredentialStore.Remove(LaunchRequest.InputPath(SshKeyPath.Text)); SshPassphrase.Clear(); return Task.CompletedTask;
    }, Localization.Text("保存したパスフレーズを削除しました。"));
    private void Quit_Click(object sender, RoutedEventArgs e) { if (Application.Current is App app) app.Quit(); }
}
