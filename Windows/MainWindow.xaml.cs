using Microsoft.Win32;
using System.Windows;
using System.Windows.Controls;
using System.IO;
using System.Windows.Media;
using System.Windows.Shapes;
namespace GitNebula;
public partial class MainWindow : Window
{
    private GitRepository? repository;
    private readonly HashSet<string> selected = [];
    private bool busy;
    public bool IsBusy => busy;
    private bool homeRequested;
    private bool initialRequestHandled;
    private bool hasHead;
    private string? sequence;
    private readonly Dictionary<string, string> drafts = new();
    private LaunchRequest request = new("open", []);
    private string action = "open", currentBranch = "";
    private bool initialSelection = true, merging, initialized;
    private List<Change> visibleChanges = [], allChanges = [];
    public MainWindow() : this(null) { }
    public MainWindow(LaunchRequest? initialRequest)
    {
        initialRequestHandled = initialRequest == null || initialRequest.Action == "open" && initialRequest.Paths.Length == 0;
        InitializeComponent();
        OtherActions.Items.Add(new ComboBoxItem { Content = Localization.Text("機能を選ぶ…"), Tag = "placeholder" });
        foreach (var group in LaunchRequest.MenuGroups)
        {
            OtherActions.Items.Add(new ComboBoxItem { Content = group.Title, Tag = "placeholder", IsEnabled = false });
            foreach (var name in group.Actions)
                OtherActions.Items.Add(new ComboBoxItem { Content = LaunchRequest.Actions[name].Title, Tag = name });
        }
        OtherActions.Items.Add(new ComboBoxItem { Content = Localization.Text("アプリ"), Tag = "placeholder", IsEnabled = false });
        foreach (var name in new[] { "open", "settings" }) OtherActions.Items.Add(new ComboBoxItem { Content = LaunchRequest.Actions[name].Title, Tag = name });
        initialized = true; OtherActions.SelectedIndex = 0; SetAction("open"); InitializeAppearance();
        Closing += (_, e) => {
            if (Application.Current is App exiting && exiting.IsExiting) return;
            if (AppSettings.Current.KeepRunning && Application.Current is App app && app.ResidentEnabled) { e.Cancel = true; Hide(); }
            else if (busy) e.Cancel = true;
            else if (Application.Current is App running && running.ResidentEnabled) running.Quit();
        };
        Loaded += async (_, _) => {
            if (initialRequestHandled) return;
            initialRequestHandled = true;
            await Act(async () => {
                request = initialRequest ?? LaunchRequest.Parse(Environment.GetCommandLineArgs().Skip(1).ToArray()); SetAction(request.Action);
                if (request.Paths.Length > 0 && action != "clone") await OpenPath(request.Paths[0]);
            });
        };
    }
    private static Visibility Show(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    private void SetAction(string name)
    {
        action = name;
        Heading.Text = LaunchRequest.Actions[name].Title; Hint.Text = LaunchRequest.Actions[name].Hint;
        Title = name == "open" ? "GitNebula" : Heading.Text + " — GitNebula";
        Width = 1050;
        Height = 820;
        if (name == "clone" && string.IsNullOrEmpty(CloneParent.Text))
            CloneParent.Text = LaunchRequest.DirectoryFor(request.Paths.FirstOrDefault() ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
        Status.Text = Localization.Text("準備完了");
        if (repository != null) Render(allChanges, currentBranch);
        Controls();
        if (name == "settings") {
            KeepRunning.IsChecked = AppSettings.Current.KeepRunning; GitExecutable.Text = AppSettings.Current.GitExecutable;
            GitDetected.Text = Localization.Text("使用する Git: ") + GitProcess.Executable;
            SshKeyPath.Text = AppSettings.Current.SshKeyPath; LoadSavedPassphrase();
            LoadAppearanceControls();
        }
        if (!busy && repository != null && name is not ("open" or "settings" or "clone")) _ = Act(Refresh);
    }
    private void Controls()
    {
        if (!initialized) return;
        var ready = repository != null && !busy;
        var hasConflicts = sequence != null || ConflictChoice.Items.Count > 0;
        HomePanel.Visibility = Show(action == "open");
        Heading.Visibility = Hint.Visibility = StatusPanel.Visibility = HomeButton.Visibility = Show(action != "open");
        ManagementPanel.Visibility = Show(action == "workspace" && repository != null);
        StashPanel.Visibility = Show(action == "stash" && repository != null);
        TagsPanel.Visibility = Show(action == "tags" && repository != null);
        RemoteSettingsPanel.Visibility = Show(action == "remotes" && repository != null);
        IdentityPanel.Visibility = Show(action == "identity" && repository != null);
        SettingsPanel.Visibility = Show(action == "settings");
        RemotePanel.Visibility = Show((action is "pull" or "push" or "fetch") && repository != null);
        TaskPanel.Visibility = Show(action == "clone" || repository != null && (action is "pull" or "push" or "fetch" or "switch" or "branches" or "merge" or "rebase"));
        BranchPanel.Visibility = Show((action is "switch" or "branches" or "merge" or "rebase") && repository != null);
        AdvancedBranches.Visibility = Show(action == "branches");
        AdvancedBranches.IsEnabled = ready && !hasConflicts;
        BranchNotice.Text = hasConflicts ? Localization.Text("進行中の操作を完了または中止してください。") : allChanges.Count > 0 ? Localization.Text("切り替え・Merge・Rebase の前に、変更をコミットまたは Stash してください。") : Localization.Text("操作するブランチを選んでください。");
        SwitchButton.Visibility = Show(action is "switch" or "branches");
        IntegrateButton.Visibility = Show(action is "merge" or "rebase");
        IntegrateButton.Content = action == "rebase" ? Localization.Format($"{currentBranch} を {Branch} の上に Rebase") : Localization.Format($"{Branch} を {currentBranch} に Merge");
        ClonePanel.Visibility = Show(action == "clone");
        FilePanel.Visibility = Show((action is "commit" or "diff" or "files") && repository != null);
        var historyAction = action is "log" or "cherry-pick" or "revert";
        HistoryPanel.Visibility = Show(historyAction && repository != null);
        History.Visibility = Show(historyAction && repository != null);
        CherryPickButton.Visibility = Show(action is "log" or "cherry-pick");
        RevertButton.Visibility = Show(action is "log" or "revert");
        CommitPanel.Visibility = Show(action == "commit" && repository != null);
        SelectionButtons.Visibility = Show(action is "commit" or "files");
        StageButtons.Visibility = Show(action == "files");
        StageButtons.IsEnabled = ready && !hasConflicts;
        StageButton.IsEnabled = ready && !hasConflicts && selected.Count > 0;
        UnstageButton.IsEnabled = ready && !hasConflicts && allChanges.Any(c => selected.Contains(c.Path) && c.Code[0] is not (' ' or '?'));
        SequenceBanner.Visibility = Show(action is not ("open" or "clone" or "settings" or "conflicts") && hasConflicts);
        ConflictPanel.Visibility = Show(action == "conflicts" && repository != null);
        SequenceNotice.Text = sequence == null ? Localization.Text("競合があります。解決後に通常のコミットとして保存してください。") : Localization.Format($"{sequence} が進行中です。競合を解決して再開、または中止してください。");
        if (!hasConflicts) SequenceNotice.Text = Localization.Text("解決が必要な競合や進行中の操作はありません。");
        ConflictChoice.Visibility = ConflictActions.Visibility = Show(ConflictChoice.Items.Count > 0);
        ConflictActions.IsEnabled = ready && ConflictChoice.SelectedItem != null;
        FinishMergeButton.Visibility = AbortMergeButton.Visibility = Show(merging);
        ContinueButton.Visibility = AbortSequenceButton.Visibility = Show(sequence != null && !merging);
        FinishMergeButton.IsEnabled = ContinueButton.IsEnabled = ready && ConflictChoice.Items.Count == 0;
        var commit = CommitList.SelectedItem as CommitRecord;
        CherryPickButton.IsEnabled = RevertButton.IsEnabled = ready && commit != null && commit.Parents.Length <= 1 && !hasConflicts && allChanges.Count == 0;
        HistoryNotice.Text = allChanges.Count > 0 ? Localization.Text("実行する前に作業中の変更をコミットまたは Stash してください。") : sequence != null ? Localization.Text("進行中の操作を完了または中止してください。") : commit?.Parents.Length > 1 ? Localization.Text("マージコミットは親の指定が必要なため、この画面からは実行できません。") : Localization.Text("コミットを選び、変更の取り込みまたは取り消しを実行できます。");
        var stash = StashList.SelectedItem as StashEntry;
        SaveStashButton.IsEnabled = ready && hasHead && !hasConflicts && allChanges.Any(c => IncludeUntracked.IsChecked == true || c.Code != "??");
        ApplyStashButton.IsEnabled = PopStashButton.IsEnabled = ready && stash != null && !hasConflicts && allChanges.Count == 0;
        DropStashButton.IsEnabled = ready && stash != null && !hasConflicts;
        StashNotice.Text = !hasHead ? Localization.Text("Stash を使う前に最初のコミットを作成してください。") : hasConflicts ? Localization.Text("競合を解決してから Stash を使ってください。") : allChanges.Count > 0 ? Localization.Text("現在の変更を退避できます。適用・取り出しの前に、変更をコミットまたは退避してください。") : Localization.Text("退避データを選ぶと、内容を確認して作業を再開できます。");
        Progress.Visibility = Show(busy);
        OpenButton.Visibility = RefreshButton.Visibility = Location.Visibility = Show(action is not ("open" or "clone" or "settings"));
        PathPanel.Visibility = Show(action is not ("open" or "clone" or "settings"));
        BackButton.Visibility = Show(routeHistory.Count > 0); BackButton.IsEnabled = !busy;
        CommitEntry.Visibility = Show(repository != null && action is not ("open" or "settings" or "commit"));
        GraphPanel.Visibility = Show(action == "graph" && repository != null);
        RemoteResultPanel.Visibility = Show(transferReport != null && transferReport.Action == action);
        OtherActions.Visibility = Show(action is not ("open" or "settings"));
        RefreshButton.IsEnabled = ready;
        CommitButton.IsEnabled = ready && selected.Count > 0 && !string.IsNullOrWhiteSpace(Message.Text) && !hasConflicts;
        SelectionCount.Text = Localization.Format($"{selected.Count} ファイルを選択");
        ExecuteButton.Content = Heading.Text;
        ExecuteButton.IsEnabled = ready && RemoteChoice.SelectedItem != null && (action == "fetch" || hasHead && currentBranch != "detached HEAD" && (action != "pull" || allChanges.Count == 0 && !hasConflicts));
        RemoteNotice.Visibility = Show(RemoteChoice.Items.Count == 0);
        SwitchButton.IsEnabled = ready && !string.IsNullOrEmpty(Branch) && Branch != currentBranch && allChanges.Count == 0 && !hasConflicts;
        IntegrateButton.IsEnabled = ready && Branch.Length > 0 && Branch != currentBranch && allChanges.Count == 0 && !hasConflicts;
        string destination;
        try { destination = CloneLocation.Destination(CloneParent.Text, CloneSource.Text); }
        catch (ArgumentException) { destination = ""; }
        CloneDestination.Text = Localization.Text("実際の作成先: ") + (destination.Length > 0 ? destination : Localization.Text("取得元と保存先を指定してください"));
        CloneButton.IsEnabled = !busy && !string.IsNullOrWhiteSpace(CloneSource.Text) && destination.Length > 0;
    }
    private void Message_Changed(object sender, TextChangedEventArgs e) => Controls();
    private void StashOption_Changed(object sender, RoutedEventArgs e) => Controls();
    private void Branch_Changed(object sender, SelectionChangedEventArgs e) => Controls();
    private void OtherAction_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!initialized || OtherActions.SelectedItem is not ComboBoxItem item || item.Tag is not string name || name == "placeholder") return;
        Navigate(name); OtherActions.SelectedIndex = 0;
    }
    private void Close_Click(object sender, RoutedEventArgs e) => Close();
    private void SelectAll_Click(object sender, RoutedEventArgs e) => SelectFiles(true);
    private void SelectNone_Click(object sender, RoutedEventArgs e) => SelectFiles(false);
    private void SelectFiles(bool active)
    {
        foreach (var row in Files.Children.OfType<DockPanel>())
            foreach (var check in row.Children.OfType<CheckBox>()) check.IsChecked = active;
    }
    private async void Execute_Click(object sender, RoutedEventArgs e) => await Act(async () => {
        transferReport = null;
        transferReport = await Repo.Transfer(action, Remote);
        await RefreshAfterOperation();
        RemoteResult.Text = transferReport.Summary + "\nHEAD: " + transferReport.Before?[..8] + " → " + transferReport.After?[..8];
        RemoteOutput.Text = transferReport.Output;
    }, result: () => transferReport!.Summary);
    private void CloneParent_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = Localization.Text("Clone の保存先（親フォルダ）を選択"), InitialDirectory = Directory.Exists(CloneParent.Text) ? CloneParent.Text : Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) };
        if (dialog.ShowDialog(this) == true) CloneParent.Text = dialog.FolderName;
    }
    private void Stars_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        Stars.Children.Clear();
        for (var index = 0; index < 70; index++)
        {
            var star = new System.Windows.Shapes.Ellipse { Width = index % 7 == 0 ? 2 : 1, Height = index % 7 == 0 ? 2 : 1, Fill = Brushes.White, Opacity = index % 3 == 0 ? .45 : .18 };
            Canvas.SetLeft(star, ((index * 137 + 31) % 997) / 997.0 * e.NewSize.Width);
            Canvas.SetTop(star, ((index * 251 + 73) % 991) / 991.0 * e.NewSize.Height); Stars.Children.Add(star);
        }
        AnimateVisible();
    }
    private async Task Act(Func<Task> work, string success = "準備完了", Func<string>? result = null)
    {
        if (busy) return;
        busy = true; Controls(); Workspace.IsEnabled = false; Status.Foreground = new SolidColorBrush(Color.FromRgb(165, 177, 207)); Status.Text = Localization.Text("処理中…");
        try { await work(); Status.Text = result?.Invoke() ?? Localization.Text(success); }
        catch (Exception error) {
            var refreshError = "";
            if (repository != null) { try { await Refresh(); } catch (Exception updateError) { refreshError = Localization.Text("\n画面の更新にも失敗しました: ") + updateError.Message; } }
            Status.Text = error.Message + refreshError; Status.Foreground = new SolidColorBrush(Color.FromRgb(255, 190, 144));
        }
        finally {
            busy = false; Workspace.IsEnabled = true; Controls();
            if (homeRequested) { homeRequested = false; ShowHome(); }
        }
    }
    private async void Open_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = Localization.Text("Git リポジトリを選択") };
        if (dialog.ShowDialog(this) != true) return;
        await OpenManualPath(dialog.FolderName);
    }
    private async void OpenPath_Click(object sender, RoutedEventArgs e) => await OpenManualPath(RepositoryPath.Text);
    private async void RepositoryPath_KeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (e.Key != System.Windows.Input.Key.Enter) return;
        e.Handled = true; await OpenManualPath(RepositoryPath.Text);
    }
    private async Task OpenManualPath(string input)
    {
        if (busy) return;
        await Act(async () => {
            var path = LaunchRequest.InputPath(input);
            if (repository != null) drafts[repository.Path] = Message.Text;
            RepositoryPath.Text = path;
            request = new(action, [path]); initialSelection = true; selected.Clear(); Message.Clear(); repository = null; merging = false; sequence = null; hasHead = false;
            RemoteChoice.ItemsSource = null; BranchChoice.ItemsSource = null; ConflictChoice.ItemsSource = null;
            await OpenPath(path); Message.Text = drafts.GetValueOrDefault(Repo.Path, "");
        });
    }
    private async Task OpenPath(string path)
    {
        RepositoryPath.Text = path;
        var candidate = new GitRepository(LaunchRequest.DirectoryFor(path)); await candidate.Open();
        foreach (var selectedPath in request.Paths.Skip(1))
        {
            var other = new GitRepository(LaunchRequest.DirectoryFor(selectedPath)); await other.Open();
            if (!string.Equals(other.Path, candidate.Path, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException(Localization.Text("同じリポジトリ内のファイルを選択してください。"));
        }
        var changes = await candidate.Changes(); var branch = await candidate.Branch();
        repository = candidate; Render(changes, branch); await RefreshDetails();
        AppSettings.Current.Remember(candidate.Path);
        if (visibleChanges.Count > 0 && action is "commit" or "diff" or "files") DiffView.Text = await repository.Diff(visibleChanges[0].Path);
    }
    private async Task Refresh()
    {
        if (repository == null) throw new InvalidOperationException(Localization.Text("リポジトリを開いてください。"));
        Render(await repository.Changes(), await repository.Branch());
        await RefreshDetails();
    }
    private async Task RefreshDetails()
    {
        if (repository == null) return;
        // Load action-specific records below; hidden screens do not issue preview commands.
        var remote = RemoteChoice.SelectedItem as string;
        var remotes = await repository.Remotes(); RemoteChoice.ItemsSource = remotes;
        RemoteChoice.SelectedItem = remotes.Contains(remote) ? remote : await repository.PreferredRemote();
        var branches = await repository.Branches(); var previous = Branch;
        BranchChoice.ItemsSource = branches; BranchChoice.SelectedItem = branches.Contains(previous) ? previous : branches.FirstOrDefault(b => b != currentBranch) ?? currentBranch;
        ConflictChoice.ItemsSource = await repository.Conflicts(); ConflictChoice.SelectedIndex = 0;
        merging = await repository.MergeInProgress(); sequence = await repository.Sequence(); hasHead = await repository.HeadRevision() != null;
        await RefreshActionData();
    }
    private GitRepository Repo => repository ?? throw new InvalidOperationException(Localization.Text("リポジトリを開いてください。"));
    private string Remote => RemoteChoice.SelectedItem as string ?? "";
    private string Branch => BranchChoice.SelectedItem as string ?? "";
    private string Conflict => ConflictChoice.SelectedItem as string ?? "";
    private async Task Operate(Func<Task> action) { await action(); await RefreshAfterOperation(); }
    private async Task RefreshAfterOperation()
    {
        try { await Refresh(); }
        catch (Exception error) { throw new InvalidOperationException(Localization.Text("Git 操作は完了しましたが、画面の更新に失敗しました。操作を再実行せず「更新」で確認してください。\n") + error.Message, error); }
    }
    private bool Confirm(string text) => MessageBox.Show(this, text, "GitNebula", MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK;
    private string[]? Prompt(string title, params string[] labels)
    {
        var dialog = new Window { Title = title, Owner = this, Width = 550, SizeToContent = SizeToContent.Height, WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Background, Foreground = Foreground };
        var box = new StackPanel { Margin = new Thickness(20) }; dialog.Content = box;
        var fields = new List<TextBox>();
        foreach (var label in labels) { box.Children.Add(new TextBlock { Text = label }); var field = new TextBox { Margin = new Thickness(0, 6, 0, 12) }; box.Children.Add(field); fields.Add(field); }
        var accept = new Button { Content = Localization.Text("実行"), IsDefault = true }; accept.Click += (_, _) => dialog.DialogResult = true; box.Children.Add(accept);
        var cancel = new Button { Content = Localization.Text("キャンセル"), IsCancel = true }; box.Children.Add(cancel);
        return dialog.ShowDialog() == true ? fields.Select(field => field.Text).ToArray() : null;
    }
    private async void Clone_Click(object sender, RoutedEventArgs e)
    {
        await Act(async () => { if (repository != null) drafts[repository.Path] = Message.Text; repository = await GitRepository.Clone(CloneSource.Text, CloneLocation.Destination(CloneParent.Text, CloneSource.Text)); request = new("clone", []); Message.Clear(); initialSelection = true; selected.Clear(); await RefreshAfterOperation(); }, Localization.Text("Clone が完了しました。閉じて作業を始められます。"));
    }
    private async void Switch_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.SwitchBranch(Branch)), Localization.Text("ブランチを切り替えました。"));
    private async void CreateBranch_Click(object sender, RoutedEventArgs e)
    {
        var values = Prompt(Localization.Text("ブランチを作成して切替"), Localization.Text("名前")); if (values != null) await Act(() => Operate(() => Repo.CreateBranch(values[0])));
    }
    private async void RenameBranch_Click(object sender, RoutedEventArgs e)
    {
        var values = Prompt(Localization.Text("ブランチ名を変更"), Localization.Text("新しい名前")); if (values != null) await Act(() => Operate(() => Repo.RenameBranch(Branch, values[0])));
    }
    private async void DeleteBranch_Click(object sender, RoutedEventArgs e)
    {
        if (Confirm(Localization.Text("選択したマージ済みブランチを削除します。"))) await Act(() => Operate(() => Repo.DeleteBranch(Branch)));
    }
    private async void Merge_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.Merge(Branch)));
    private async void EditConflict_Click(object sender, RoutedEventArgs e)
    {
        string text = "", file = Conflict;
        await Act(async () => text = await Repo.ConflictText(file));
        if (Status.Text != Localization.Text("準備完了")) return;
        var dialog = new Window { Title = file, Owner = this, Width = 900, Height = 600, Background = Background, Foreground = Foreground, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var dock = new DockPanel(); var save = new Button { Content = Localization.Text("保存して解決") }; DockPanel.SetDock(save, Dock.Bottom); dock.Children.Add(save);
        var editor = new TextBox { Text = text, AcceptsReturn = true, AcceptsTab = true, FontFamily = new System.Windows.Media.FontFamily("Consolas"), VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
        dock.Children.Add(editor); dialog.Content = dock; save.Click += (_, _) => dialog.DialogResult = true;
        if (dialog.ShowDialog() == true) await Act(() => Operate(() => Repo.SaveResolution(file, editor.Text)));
    }
    private async void MarkResolved_Click(object sender, RoutedEventArgs e)
    {
        if (Confirm(Localization.Text("現在の内容（削除を含む）を解決済みとしてステージします。"))) await Act(() => Operate(() => Repo.MarkResolved(Conflict)));
    }
    private async void FinishMerge_Click(object sender, RoutedEventArgs e)
    {
        var values = Prompt(Localization.Text("マージ完了（ステージ済みの全変更を含みます）"), Localization.Text("コミットメッセージ"));
        if (values != null) await Act(() => Operate(() => Repo.FinishMerge(values[0])), Localization.Text("マージが完了しました。"));
    }
    private async void AbortMerge_Click(object sender, RoutedEventArgs e)
    {
        if (Confirm(Localization.Text("競合解決作業を破棄してマージを中止します。"))) await Act(() => Operate(Repo.AbortMerge));
    }
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await Act(Refresh);
    private void Render(List<Change> changes, string branch)
    {
        allChanges = changes; currentBranch = branch; visibleChanges = changes.Where(c => action is "files" or "workspace" || request.Includes(c.Path, repository!.Path)).ToList();
        var available = visibleChanges.Select(c => c.Path).ToHashSet();
        if (initialSelection) selected.UnionWith(available); else selected.IntersectWith(available);
        initialSelection = false; Files.Children.Clear(); Location.Text = $"{repository!.Path}  ·  {branch}";
        FileCount.Text = Localization.Format($"対象の変更 · {visibleChanges.Count} ファイル");
        DiffView.Text = Localization.Text("ファイルを選ぶと差分が表示されます。");
        foreach (var change in visibleChanges)
        {
            var row = new DockPanel { Margin = new Thickness(2) };
            var check = new CheckBox { IsChecked = selected.Contains(change.Path), Visibility = Show(action != "diff"), VerticalAlignment = VerticalAlignment.Center, ToolTip = Localization.Format($"{change.Path} をコミット対象にする") };
            check.Checked += (_, _) => { selected.Add(change.Path); Controls(); };
            check.Unchecked += (_, _) => { selected.Remove(change.Path); Controls(); };
            var button = new Button { Content = $"{change.Label}  {change.Path}", HorizontalContentAlignment = HorizontalAlignment.Left };
            button.Click += async (_, _) => await Act(async () => DiffView.Text = await repository.Diff(change.Path));
            row.Children.Add(check); row.Children.Add(button); Files.Children.Add(row);
        }
        if (visibleChanges.Count == 0) Files.Children.Add(new TextBlock { Text = Localization.Text("対象に未コミットの変更はありません。"), Margin = new Thickness(12) });
    }
    private async void Commit_Click(object sender, RoutedEventArgs e) => await Act(async () => {
        if (repository == null) throw new InvalidOperationException(Localization.Text("リポジトリを開いてください。"));
        await repository.Commit(selected.ToArray(), Message.Text); Message.Clear(); await RefreshAfterOperation();
    }, Localization.Text("コミットしました。閉じて作業に戻れます。"));
}
