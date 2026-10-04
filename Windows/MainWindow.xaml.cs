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
    private LaunchRequest request = new("open", []);
    private string action = "open", currentBranch = "";
    private bool initialSelection = true, merging, succeeded, initialized;
    private List<Change> visibleChanges = [], allChanges = [];
    public MainWindow() : this(null) { }
    public MainWindow(LaunchRequest? initialRequest)
    {
        InitializeComponent();
        OtherActions.Items.Add(new ComboBoxItem { Content = "その他の操作…", Tag = "placeholder" });
        foreach (var (name, metadata) in LaunchRequest.Actions)
        {
            OtherActions.Items.Add(new ComboBoxItem { Content = metadata.Title, Tag = name });
            if (name is "open" or "workspace") continue;
            var button = new Button { Content = metadata.Title, Tag = name, HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(14, 18, 14, 18) };
            button.Click += (_, _) => SetAction(name); Launcher.Children.Add(button);
        }
        initialized = true; OtherActions.SelectedIndex = 0; SetAction("open");
        Closing += (_, e) => { if (busy) e.Cancel = true; };
        Loaded += async (_, _) => {
            await Act(async () => {
                request = initialRequest ?? LaunchRequest.Parse(Environment.GetCommandLineArgs().Skip(1).ToArray()); SetAction(request.Action);
                if (request.Paths.Length > 0 && action != "clone") await OpenPath(request.Paths[0]);
            });
        };
    }
    private static Visibility Show(bool value) => value ? Visibility.Visible : Visibility.Collapsed;
    private void SetAction(string name)
    {
        action = name; succeeded = false;
        Heading.Text = LaunchRequest.Actions[name].Title; Hint.Text = LaunchRequest.Actions[name].Hint;
        Title = Heading.Text + " — GitNebula";
        Width = name is "commit" or "diff" or "log" or "workspace" ? 960 : 720;
        Height = name is "commit" or "diff" or "log" or "workspace" ? 760 : name == "open" ? 640 : 560;
        if (name == "clone" && string.IsNullOrEmpty(CloneDestination.Text))
            CloneDestination.Text = System.IO.Path.Combine(LaunchRequest.DirectoryFor(request.Paths.FirstOrDefault() ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)), "new-repository");
        Status.Text = "準備完了";
        if (repository != null) Render(allChanges, currentBranch);
        Controls();
    }
    private void Controls()
    {
        if (!initialized) return;
        var ready = repository != null && !busy;
        Launcher.Visibility = Show(action == "open");
        RemotePanel.Visibility = Show(action is "pull" or "push" or "fetch" && repository != null);
        BranchPanel.Visibility = Show(action is "switch" or "workspace" && repository != null);
        AdvancedBranches.Visibility = Show(action == "workspace");
        ClonePanel.Visibility = Show(action == "clone");
        FilePanel.Visibility = Show(action is "commit" or "diff" or "workspace" && repository != null);
        History.Visibility = Show(action == "log" && repository != null);
        CommitPanel.Visibility = Show(action is "commit" or "workspace" && repository != null);
        SelectionButtons.Visibility = Show(action != "diff");
        ConflictPanel.Visibility = Show(action is not ("open" or "clone") && (merging || ConflictChoice.Items.Count > 0));
        Progress.Visibility = Show(busy);
        OpenButton.Visibility = RefreshButton.Visibility = Location.Visibility = Show(action != "clone");
        RefreshButton.IsEnabled = ready;
        CommitButton.IsEnabled = ready && selected.Count > 0 && !string.IsNullOrWhiteSpace(Message.Text) && !merging;
        SelectionCount.Text = $"{selected.Count} ファイルを選択";
        ExecuteButton.Content = Heading.Text; ExecuteButton.IsEnabled = ready && RemoteChoice.SelectedItem != null && !succeeded;
        RemoteNotice.Visibility = Show(RemoteChoice.Items.Count == 0);
        SwitchButton.IsEnabled = ready && !string.IsNullOrEmpty(Branch) && Branch != currentBranch;
        CloneButton.IsEnabled = !busy && !succeeded && !string.IsNullOrWhiteSpace(CloneSource.Text) && !string.IsNullOrWhiteSpace(CloneDestination.Text);
        foreach (Button button in Launcher.Children) button.IsEnabled = ready || (string)button.Tag == "clone";
    }
    private void Message_Changed(object sender, TextChangedEventArgs e) => Controls();
    private void Branch_Changed(object sender, SelectionChangedEventArgs e) => Controls();
    private void OtherAction_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!initialized || OtherActions.SelectedItem is not ComboBoxItem item || item.Tag is not string name || name == "placeholder") return;
        SetAction(name); OtherActions.SelectedIndex = 0;
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
        if (action == "fetch") await Repo.Fetch(Remote);
        else if (action == "pull") await Repo.Pull(Remote);
        else if (action == "push") await Repo.Push(Remote);
        await Refresh();
    }, "完了しました。閉じて作業に戻れます。");
    private void CloneParent_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Clone の親フォルダを選択" };
        if (dialog.ShowDialog(this) == true) CloneDestination.Text = System.IO.Path.Combine(dialog.FolderName, "new-repository");
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
    }
    private async Task Act(Func<Task> work, string success = "準備完了")
    {
        if (busy) return;
        busy = true; succeeded = false; Controls(); Workspace.IsEnabled = false; Status.Foreground = new SolidColorBrush(Color.FromRgb(165, 177, 207)); Status.Text = "処理中…";
        try { await work(); Status.Text = success; succeeded = success != "準備完了"; }
        catch (Exception error) {
            if (repository != null) { try { await Refresh(); } catch { /* Preserve the original operation's error. */ } }
            Status.Text = error.Message; Status.Foreground = new SolidColorBrush(Color.FromRgb(255, 190, 144));
        }
        finally { busy = false; Workspace.IsEnabled = true; Controls(); }
    }
    private async void Open_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Git リポジトリを選択" };
        if (dialog.ShowDialog(this) != true) return;
        request = new(action, [dialog.FolderName]); initialSelection = true; selected.Clear(); Message.Clear(); repository = null; merging = false;
        RemoteChoice.ItemsSource = null; BranchChoice.ItemsSource = null; ConflictChoice.ItemsSource = null;
        await Act(() => OpenPath(dialog.FolderName));
    }
    private async Task OpenPath(string path)
    {
        var candidate = new GitRepository(LaunchRequest.DirectoryFor(path)); await candidate.Open();
        foreach (var selectedPath in request.Paths.Skip(1))
        {
            var other = new GitRepository(LaunchRequest.DirectoryFor(selectedPath)); await other.Open();
            if (!string.Equals(other.Path, candidate.Path, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("同じリポジトリ内のファイルを選択してください。");
        }
        var changes = await candidate.Changes(); var branch = await candidate.Branch();
        repository = candidate; Render(changes, branch); await RefreshDetails();
        if (visibleChanges.Count > 0 && action is "commit" or "diff") DiffView.Text = await repository.Diff(visibleChanges[0].Path);
    }
    private async Task Refresh()
    {
        if (repository == null) throw new InvalidOperationException("リポジトリを開いてください。");
        Render(await repository.Changes(), await repository.Branch());
        await RefreshDetails();
    }
    private async Task RefreshDetails()
    {
        if (repository == null) return;
        History.Text = await repository.Graph();
        var remote = RemoteChoice.SelectedItem as string;
        var remotes = await repository.Remotes(); RemoteChoice.ItemsSource = remotes;
        RemoteChoice.SelectedItem = remotes.Contains(remote) ? remote : await repository.PreferredRemote();
        var branches = await repository.Branches(); var previous = Branch;
        BranchChoice.ItemsSource = branches; BranchChoice.SelectedItem = branches.Contains(previous) ? previous : branches.FirstOrDefault(b => b != currentBranch) ?? currentBranch;
        ConflictChoice.ItemsSource = await repository.Conflicts(); ConflictChoice.SelectedIndex = 0;
        merging = await repository.MergeInProgress();
    }
    private GitRepository Repo => repository ?? throw new InvalidOperationException("リポジトリを開いてください。");
    private string Remote => RemoteChoice.SelectedItem as string ?? "";
    private string Branch => BranchChoice.SelectedItem as string ?? "";
    private string Conflict => ConflictChoice.SelectedItem as string ?? "";
    private async Task Operate(Func<Task> action) { await action(); await Refresh(); }
    private bool Confirm(string text) => MessageBox.Show(this, text, "GitNebula", MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK;
    private string[]? Prompt(string title, params string[] labels)
    {
        var dialog = new Window { Title = title, Owner = this, Width = 550, SizeToContent = SizeToContent.Height, WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Background, Foreground = Foreground };
        var box = new StackPanel { Margin = new Thickness(20) }; dialog.Content = box;
        var fields = new List<TextBox>();
        foreach (var label in labels) { box.Children.Add(new TextBlock { Text = label }); var field = new TextBox { Margin = new Thickness(0, 6, 0, 12) }; box.Children.Add(field); fields.Add(field); }
        var accept = new Button { Content = "実行", IsDefault = true }; accept.Click += (_, _) => dialog.DialogResult = true; box.Children.Add(accept);
        var cancel = new Button { Content = "キャンセル", IsCancel = true }; box.Children.Add(cancel);
        return dialog.ShowDialog() == true ? fields.Select(field => field.Text).ToArray() : null;
    }
    private async void Clone_Click(object sender, RoutedEventArgs e)
    {
        await Act(async () => { repository = await GitRepository.Clone(CloneSource.Text, CloneDestination.Text); request = new("clone", []); initialSelection = true; selected.Clear(); await Refresh(); }, "Clone が完了しました。閉じて作業を始められます。");
    }
    private async void Switch_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.SwitchBranch(Branch)), "ブランチを切り替えました。");
    private async void CreateBranch_Click(object sender, RoutedEventArgs e)
    {
        var values = Prompt("ブランチを作成して切替", "名前"); if (values != null) await Act(() => Operate(() => Repo.CreateBranch(values[0])));
    }
    private async void RenameBranch_Click(object sender, RoutedEventArgs e)
    {
        var values = Prompt("ブランチ名を変更", "新しい名前"); if (values != null) await Act(() => Operate(() => Repo.RenameBranch(Branch, values[0])));
    }
    private async void DeleteBranch_Click(object sender, RoutedEventArgs e)
    {
        if (Confirm("選択したマージ済みブランチを削除します。")) await Act(() => Operate(() => Repo.DeleteBranch(Branch)));
    }
    private async void Merge_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.Merge(Branch)));
    private async void EditConflict_Click(object sender, RoutedEventArgs e)
    {
        string text = "", file = Conflict;
        await Act(async () => text = await Repo.ConflictText(file));
        if (Status.Text != "準備完了") return;
        var dialog = new Window { Title = file, Owner = this, Width = 900, Height = 600, Background = Background, Foreground = Foreground, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var dock = new DockPanel(); var save = new Button { Content = "保存して解決" }; DockPanel.SetDock(save, Dock.Bottom); dock.Children.Add(save);
        var editor = new TextBox { Text = text, AcceptsReturn = true, AcceptsTab = true, FontFamily = new System.Windows.Media.FontFamily("Consolas"), VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
        dock.Children.Add(editor); dialog.Content = dock; save.Click += (_, _) => dialog.DialogResult = true;
        if (dialog.ShowDialog() == true) await Act(() => Operate(() => Repo.SaveResolution(file, editor.Text)));
    }
    private async void MarkResolved_Click(object sender, RoutedEventArgs e)
    {
        if (Confirm("現在の内容（削除を含む）を解決済みとしてステージします。")) await Act(() => Operate(() => Repo.MarkResolved(Conflict)));
    }
    private async void FinishMerge_Click(object sender, RoutedEventArgs e)
    {
        var values = Prompt("マージ完了（ステージ済みの全変更を含みます）", "コミットメッセージ");
        if (values != null) await Act(() => Operate(() => Repo.FinishMerge(values[0])), "マージが完了しました。");
    }
    private async void AbortMerge_Click(object sender, RoutedEventArgs e)
    {
        if (Confirm("競合解決作業を破棄してマージを中止します。")) await Act(() => Operate(Repo.AbortMerge));
    }
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await Act(Refresh);
    private void Render(List<Change> changes, string branch)
    {
        allChanges = changes; currentBranch = branch; visibleChanges = changes.Where(c => action == "workspace" || request.Includes(c.Path, repository!.Path)).ToList();
        var available = visibleChanges.Select(c => c.Path).ToHashSet();
        if (initialSelection) selected.UnionWith(available); else selected.IntersectWith(available);
        initialSelection = false; Files.Children.Clear(); Location.Text = $"{repository!.Path}  ·  {branch}";
        FileCount.Text = $"対象の変更 · {visibleChanges.Count} ファイル";
        DiffView.Text = "ファイルを選ぶと差分が表示されます。";
        foreach (var change in visibleChanges)
        {
            var row = new DockPanel { Margin = new Thickness(2) };
            var check = new CheckBox { IsChecked = selected.Contains(change.Path), Visibility = Show(action != "diff"), VerticalAlignment = VerticalAlignment.Center, ToolTip = $"{change.Path} をコミット対象にする" };
            check.Checked += (_, _) => { selected.Add(change.Path); Controls(); };
            check.Unchecked += (_, _) => { selected.Remove(change.Path); Controls(); };
            var button = new Button { Content = $"{change.Label}  {change.Path}", HorizontalContentAlignment = HorizontalAlignment.Left };
            button.Click += async (_, _) => await Act(async () => DiffView.Text = await repository.Diff(change.Path));
            row.Children.Add(check); row.Children.Add(button); Files.Children.Add(row);
        }
        if (visibleChanges.Count == 0) Files.Children.Add(new TextBlock { Text = "対象に未コミットの変更はありません。", Margin = new Thickness(12) });
    }
    private async void Commit_Click(object sender, RoutedEventArgs e) => await Act(async () => {
        if (repository == null) throw new InvalidOperationException("リポジトリを開いてください。");
        await repository.Commit(selected.ToArray(), Message.Text); Message.Clear(); await Refresh();
    }, "コミットしました。閉じて作業に戻れます。");
}
