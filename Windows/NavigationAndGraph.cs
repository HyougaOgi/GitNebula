using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
namespace GitNebula;
public partial class MainWindow
{
    private sealed record Route(string Action, LaunchRequest Request, GitRepository? Repository, string Message, string[] Selected, string Status, bool CommitCompleted, RemoteOperationReport? Report, string CloneSource, string CloneParent);
    private readonly Stack<Route> routeHistory = new();
    private RemoteOperationReport? transferReport;
    private int graphLimit = 200;
    private int historyLimit = 200;
    private CommitRecord[] historyRecords = [];
    private void EnsureRepositoryReturn() {
        if (repository == null || action is "open" or "menu" or "clone" or "settings" or "init" || request.Paths.Length == 0) return;
        if (routeHistory.Count > 0 && (routeHistory.Peek().Action != "open" || routeHistory.Peek().Repository != null)) return;
        if (routeHistory.Count > 0) routeHistory.Pop();
        routeHistory.Push(new("menu", new("menu", [repository.Path]), repository, "", [], Localization.Text("準備完了"), false, null, "", ""));
    }
    private void FilterHistory() {
        var selected = (CommitList.SelectedItem as CommitRecord)?.Id; var query = HistorySearch.Text;
        var filtered = historyRecords.Where(c => query.Length == 0 || new[] { c.Id, c.Message, c.Author, c.Email, c.Decorations }.Any(value => value.Contains(query, StringComparison.CurrentCultureIgnoreCase))).ToArray();
        CommitList.ItemsSource = filtered; CommitList.SelectedItem = filtered.FirstOrDefault(c => c.Id == selected) ?? filtered.FirstOrDefault();
        HistoryCommitDetails.SetRecord(CommitList.SelectedItem as CommitRecord);
    }
    private void HistorySearch_Changed(object sender, TextChangedEventArgs e) { if (HistoryCommitDetails != null) FilterHistory(); }
    private async void HistoryBranch_Changed(object sender, SelectionChangedEventArgs e) { if (initialized && !busy && repository != null) await Act(RefreshActionData); }
    private async void HistoryMore_Click(object sender, RoutedEventArgs e) { historyLimit += 200; await Act(RefreshActionData); }
    private void CaptureRoute() => routeHistory.Push(new(action, request, repository, Message.Text, selected.ToArray(), Status.Text, commitCompleted, transferReport, CloneSource.Text, CloneParent.Text));
    private async void Navigate(string target)
    {
        if (busy || target == action) return;
        if (RouteRequest != null && PurposeFor(target) != WindowPurpose) {
            await RouteRequest(new LaunchRequest(target, repository != null ? [repository.Path] : request.Paths));
            return;
        }
        if (action == "menu" && repository != null) request = new LaunchRequest(target, [repository.Path]);
        CaptureRoute(); transferReport = null; graphLimit = 200; SetAction(target);
    }
    private async void Back_Click(object sender, RoutedEventArgs e)
    {
        if (busy || routeHistory.Count == 0) return;
        var previous = routeHistory.Pop(); request = previous.Request; repository = previous.Repository;
        Message.Text = previous.Message; selected.Clear(); selected.UnionWith(previous.Selected); initialSelection = false;
        transferReport = previous.Report; CloneSource.Text = previous.CloneSource; CloneParent.Text = previous.CloneParent;
        // Refresh once after restoring the route; SetAction must not start a competing refresh.
        busy = true; SetAction(previous.Action); commitCompleted = previous.CommitCompleted; busy = false;
        if (repository != null && action is not ("open" or "settings" or "clone")) await Act(Refresh, previous.Status);
        else { Status.Text = previous.Status; Controls(); }
        if (transferReport != null) { RemoteResult.Text = transferReport.Summary; RemoteOutput.Text = transferReport.Output; }
    }
    private static readonly Brush[] GraphColors = [Brushes.MediumPurple, Brushes.DarkCyan, Brushes.DarkOrange, Brushes.ForestGreen, Brushes.DeepPink, Brushes.RoyalBlue];
    private void RenderGraph(GraphRow[] rows)
    {
        Graph4D.SetCommits(rows.Select(r => r.Commit).ToArray());
        var id = ((GraphList.SelectedItem as ListBoxItem)?.Tag as CommitRecord)?.Id;
        GraphList.Items.Clear(); var columns = rows.Length == 0 ? 1 : rows.Max(row => row.Width);
        foreach (var row in rows) {
            var canvas = new Canvas { Width = columns * 20 + 20, Height = 48 };
            double X(int lane) => lane * 20 + 14;
            foreach (var edge in row.Incoming) canvas.Children.Add(new Line { X1 = X(edge.From), Y1 = 0, X2 = X(edge.To), Y2 = 24, Stroke = GraphColors[edge.Color % GraphColors.Length], StrokeThickness = 2 });
            foreach (var edge in row.Outgoing) {
                var figure = new PathFigure { StartPoint = new Point(X(edge.From), 24) };
                figure.Segments.Add(new BezierSegment(new Point(X(edge.From), 34), new Point(X(edge.To), 38), new Point(X(edge.To), 48), true));
                canvas.Children.Add(new System.Windows.Shapes.Path { Data = new PathGeometry([figure]), Stroke = GraphColors[edge.Color % GraphColors.Length], StrokeThickness = 2 });
            }
            var node = new Ellipse { Width = 10, Height = 10, Fill = GraphColors[row.Color % GraphColors.Length] };
            Canvas.SetLeft(node, X(row.Lane) - 5); Canvas.SetTop(node, 19); canvas.Children.Add(node);
            var panel = new StackPanel { Orientation = Orientation.Horizontal }; panel.Children.Add(canvas);
            panel.Children.Add(new TextBlock { Text = row.Commit.Id, Width = 340, VerticalAlignment = VerticalAlignment.Center, FontFamily = new FontFamily("Consolas") });
            panel.Children.Add(new TextBlock { Text = row.Commit.Subject + (row.Commit.Decorations.Length > 0 ? "  [" + row.Commit.Decorations + "]" : ""), MinWidth = 300, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0,0,20,0) });
            panel.Children.Add(new TextBlock { Text = row.Commit.Author + " · " + row.Commit.Date, VerticalAlignment = VerticalAlignment.Center });
            var item = new ListBoxItem { Content = panel, Tag = row.Commit, Padding = new Thickness(0) }; GraphList.Items.Add(item);
            if (row.Commit.Id == id) GraphList.SelectedItem = item;
        }
        if (GraphList.SelectedItem == null && GraphList.Items.Count > 0) GraphList.SelectedIndex = 0;
        GraphCommitDetails.SetRecord((GraphList.SelectedItem as ListBoxItem)?.Tag as CommitRecord);
        if (repository != null) _ = GraphFiles.SetCommit(Repo, (GraphList.SelectedItem as ListBoxItem)?.Tag as CommitRecord);
        if (rows.Length == 0) GraphDetails.Text = Localization.Text("まだコミットはありません。");
    }
    private async void Graph_Changed(object sender, SelectionChangedEventArgs e)
    {
        GraphCommitDetails.SetRecord((GraphList.SelectedItem as ListBoxItem)?.Tag as CommitRecord);
        if (repository != null) _ = GraphFiles.SetCommit(Repo, (GraphList.SelectedItem as ListBoxItem)?.Tag as CommitRecord);
        if (!busy && GraphList.SelectedItem is ListBoxItem item && item.Tag is CommitRecord record) await Act(async () => GraphDetails.Text = await Repo.ShowCommit(record.Id));
    }
    private async void GraphMore_Click(object sender, RoutedEventArgs e)
    {
        graphLimit += 200; await Act(RefreshActionData);
        if (GraphList.SelectedItem is ListBoxItem item && item.Tag is CommitRecord record) GraphDetails.Text = await Repo.ShowCommit(record.Id);
    }
    private void GraphMode_Changed(object sender, SelectionChangedEventArgs e) {
        if (GraphList == null || Graph4D == null || GraphMode.SelectedItem is not ComboBoxItem selectedMode) return;
        var mode = (string)selectedMode.Tag; GraphList.Visibility = Show(mode == "normal"); Graph4D.Visibility = Show(mode == "4d");
        AppSettings.Current.GraphMode = mode; AppSettings.Current.Save();
    }
}
