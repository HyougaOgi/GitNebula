using Microsoft.Win32;
using System.Windows;
using System.Windows.Controls;
namespace GitNebula;
public partial class MainWindow : Window
{
    private GitRepository? repository;
    private readonly HashSet<string> selected = [];
    private bool busy;
    public MainWindow() => InitializeComponent();
    private async Task Act(Func<Task> work)
    {
        if (busy) return;
        busy = true; Workspace.IsEnabled = false; Status.Text = "処理中…";
        try { await work(); Status.Text = "準備完了"; }
        catch (Exception error) { Status.Text = error.Message; }
        finally { busy = false; Workspace.IsEnabled = true; }
    }
    private async void Open_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Git リポジトリを選択" };
        if (dialog.ShowDialog(this) != true) return;
        await Act(async () => {
            var candidate = new GitRepository(dialog.FolderName); await candidate.Open();
            var changes = await candidate.Changes(); var branch = await candidate.Branch();
            repository = candidate; Render(changes, branch);
        });
    }
    private async Task Refresh()
    {
        if (repository == null) throw new InvalidOperationException("リポジトリを開いてください。");
        Render(await repository.Changes(), await repository.Branch());
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
