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
    private void CaptureRoute() => routeHistory.Push(new(action, request, repository, Message.Text, selected.ToArray(), Status.Text, commitCompleted, transferReport, CloneSource.Text, CloneParent.Text));
    private void Navigate(string target)
    {
        if (busy || target == action) return;
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
        var id = (GraphList.SelectedItem as ListBoxItem)?.Tag as string;
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
            panel.Children.Add(new TextBlock { Text = row.Commit.ShortId, Width = 90, VerticalAlignment = VerticalAlignment.Center, FontFamily = new FontFamily("Consolas") });
            panel.Children.Add(new TextBlock { Text = row.Commit.Subject + (row.Commit.Decorations.Length > 0 ? "  [" + row.Commit.Decorations + "]" : ""), MinWidth = 300, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0,0,20,0) });
            panel.Children.Add(new TextBlock { Text = row.Commit.Author + " · " + row.Commit.Date, VerticalAlignment = VerticalAlignment.Center });
            var item = new ListBoxItem { Content = panel, Tag = row.Commit.Id, Padding = new Thickness(0) }; GraphList.Items.Add(item);
            if (row.Commit.Id == id) GraphList.SelectedItem = item;
        }
        if (GraphList.SelectedItem == null && GraphList.Items.Count > 0) GraphList.SelectedIndex = 0;
        if (rows.Length == 0) GraphDetails.Text = Localization.Text("まだコミットはありません。");
    }
    private async void Graph_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!busy && GraphList.SelectedItem is ListBoxItem item && item.Tag is string id) await Act(async () => GraphDetails.Text = await Repo.ShowCommit(id));
    }
    private async void GraphMore_Click(object sender, RoutedEventArgs e)
    {
        graphLimit += 200; await Act(RefreshActionData);
        if (GraphList.SelectedItem is ListBoxItem item && item.Tag is string id) GraphDetails.Text = await Repo.ShowCommit(id);
    }
}
