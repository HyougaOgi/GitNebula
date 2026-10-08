using System.Windows;
using System.Windows.Controls;
namespace GitNebula;
public sealed class RevisionBrowser : UserControl
{
    private readonly ComboBox parents = new();
    private readonly ListBox files = new() { DisplayMemberPath = "Path" };
    private readonly DiffComparisonView comparison = new();
    private readonly TextBlock status = new() { TextWrapping = TextWrapping.Wrap };
    private GitRepository? repository;
    private CommitRecord? record;
    private bool loading;
    private int generation;
    public RevisionBrowser() {
        var root = new DockPanel(); var header = new StackPanel(); header.Children.Add(parents); header.Children.Add(status); DockPanel.SetDock(header, Dock.Top); root.Children.Add(header);
        var columns = new Grid(); columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(200) }); columns.ColumnDefinitions.Add(new ColumnDefinition()); columns.Children.Add(files); Grid.SetColumn(comparison, 1); columns.Children.Add(comparison); root.Children.Add(columns); Content = root;
        parents.SelectionChanged += async (_, _) => { if (!loading) await RefreshFiles(); };
        files.SelectionChanged += async (_, _) => { if (!loading) await Preview(); };
    }
    public async Task SetCommit(GitRepository repo, CommitRecord? value) {
        if (record?.Id == value?.Id && repository == repo) return;
        repository = repo; record = value; generation++; loading = true; parents.ItemsSource = value?.Parents ?? []; parents.SelectedIndex = parents.Items.Count > 0 ? 0 : -1; parents.Visibility = value?.Parents.Length > 1 ? Visibility.Visible : Visibility.Collapsed; loading = false;
        await RefreshFiles();
    }
    private async Task RefreshFiles() {
        var expected = ++generation; var current = record; if (current == null || repository == null) { files.ItemsSource = null; return; }
        try {
            var list = await repository.RevisionFiles(current.Id, parents.SelectedItem as string);
            if (generation != expected) return; loading = true; files.ItemsSource = list; files.SelectedIndex = list.Length > 0 ? 0 : -1; loading = false;
            await Preview();
        } catch (Exception error) { status.Text = error.Message; loading = false; }
    }
    private async Task Preview() {
        var current = record; var selected = files.SelectedItem as RevisionFile; var repo = repository; var expected = ++generation;
        if (current == null || selected == null || repo == null) return;
        try {
            var document = await repo.FileComparison(selected.Path, current.Id, parents.SelectedItem as string, selected.Original);
            if (generation == expected) { comparison.SetDocument(document); status.Text = ""; }
        } catch (Exception error) { if (generation == expected) status.Text = error.Message; }
    }
}
