using Microsoft.Win32;
using System.Windows;
using System.Windows.Controls;
namespace GitNebula;
public partial class MainWindow : Window
{
    private GitRepository? repository;
    private readonly HashSet<string> selected = [];
    private bool busy;
    public MainWindow()
    {
        InitializeComponent();
        Loaded += async (_, _) => {
            var args = Environment.GetCommandLineArgs(); var index = Array.IndexOf(args, "--open");
            if (index >= 0 && index + 1 < args.Length) await Act(() => OpenPath(args[index + 1]));
        };
    }
    private async Task Act(Func<Task> work)
    {
        if (busy) return;
        busy = true; Workspace.IsEnabled = false; Status.Text = "処理中…";
        try { await work(); Status.Text = "準備完了"; }
        catch (Exception error) {
            if (repository != null) { try { await Refresh(); } catch { /* Preserve the original operation's error. */ } }
            Status.Text = error.Message;
        }
        finally { busy = false; Workspace.IsEnabled = true; }
    }
    private async void Open_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Git リポジトリを選択" };
        if (dialog.ShowDialog(this) != true) return;
        await Act(() => OpenPath(dialog.FolderName));
    }
    private async Task OpenPath(string path)
    {
        var candidate = new GitRepository(path); await candidate.Open();
        var changes = await candidate.Changes(); var branch = await candidate.Branch();
        repository = candidate; Render(changes, branch); await RefreshDetails();
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
        RemoteChoice.SelectedItem = remotes.Contains(remote) ? remote : remotes.FirstOrDefault();
        BranchChoice.ItemsSource = await repository.Branches(); BranchChoice.SelectedItem = await repository.Branch();
        ConflictChoice.ItemsSource = await repository.Conflicts(); ConflictChoice.SelectedIndex = 0;
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
        var values = Prompt("リポジトリを複製", "取得元 URL / パス", "新しいフォルダのパス");
        if (values == null) return;
        await Act(async () => { repository = await GitRepository.Clone(values[0], values[1]); await Refresh(); });
    }
    private async void Fetch_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.Fetch(Remote)));
    private async void Pull_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.Pull(Remote)));
    private async void Push_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.Push(Remote)));
    private async void Switch_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.SwitchBranch(Branch)));
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
        var dialog = new Window { Title = file, Owner = this, Width = 900, Height = 600, WindowStartupLocation = WindowStartupLocation.CenterOwner };
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
        if (Confirm("ステージ済みの全変更をマージコミットに含めます。")) await Act(() => Operate(() => Repo.FinishMerge(Message.Text)));
    }
    private async void AbortMerge_Click(object sender, RoutedEventArgs e)
    {
        if (Confirm("競合解決作業を破棄してマージを中止します。")) await Act(() => Operate(Repo.AbortMerge));
    }
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await Act(Refresh);
    private void Render(List<Change> changes, string branch)
    {
        selected.Clear(); Files.Children.Clear(); Location.Text = $"{repository!.Path}  ·  {branch}  ·  {changes.Count} changes";
        DiffView.Text = "ファイルを選択すると差分を表示します。";
        foreach (var change in changes)
        {
            var row = new DockPanel { Margin = new Thickness(8) };
            var check = new CheckBox { VerticalAlignment = VerticalAlignment.Center, ToolTip = $"{change.Path} をコミット対象にする" };
            check.Checked += (_, _) => selected.Add(change.Path);
            check.Unchecked += (_, _) => selected.Remove(change.Path);
            var button = new Button { Content = $"{change.Code}  {change.Path}", HorizontalContentAlignment = HorizontalAlignment.Left };
            button.Click += async (_, _) => await Act(async () => DiffView.Text = await repository.Diff(change.Path));
            row.Children.Add(check); row.Children.Add(button); Files.Children.Add(row);
        }
        if (changes.Count == 0) Files.Children.Add(new TextBlock { Text = "作業ツリーはクリーンです。", Margin = new Thickness(16) });
    }
    private async void Commit_Click(object sender, RoutedEventArgs e) => await Act(async () => {
        if (repository == null) throw new InvalidOperationException("リポジトリを開いてください。");
        await repository.Commit(selected.ToArray(), Message.Text); Message.Clear(); await Refresh();
    });
}
