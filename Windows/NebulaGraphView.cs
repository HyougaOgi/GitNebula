using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
namespace GitNebula;

public sealed class NebulaGraphView : UserControl
{
    private readonly SpaceCanvas space = new();
    private readonly ListBox logs = new();
    private readonly Slider timeline = new() { Minimum = 1, Maximum = 2, IsSnapToTickEnabled = true, TickFrequency = 1, MinWidth = 120, Margin = new Thickness(8, 0, 8, 0) };
    private readonly TextBlock count = new() { VerticalAlignment = VerticalAlignment.Center };
    private CommitRecord[] commits = [];
    private bool playing, updating;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(350) };
    public Action<CommitRecord>? SelectCommit { get; set; }
    public NebulaGraphView()
    {
        var root = new DockPanel(); var controls = new DockPanel { LastChildFill = true };
        var buttons = new WrapPanel(); var reset = new Button { Content = Localization.Text("全体を表示") }; reset.Click += (_, _) => { space.Camera.Reset(); space.Refresh(); }; buttons.Children.Add(reset);
        var play = new Button { Content = Localization.Text("履歴を再生") }; play.Click += (_, _) => { if (!SystemParameters.ClientAreaAnimation) return; playing = !playing; play.Content = Localization.Text(playing ? "一時停止" : "履歴を再生"); if (playing && timeline.Value >= commits.Length) timeline.Value = 1; }; buttons.Children.Add(play);
        DockPanel.SetDock(buttons, Dock.Left); controls.Children.Add(buttons); DockPanel.SetDock(count, Dock.Right); controls.Children.Add(count); controls.Children.Add(timeline);
        DockPanel.SetDock(controls, Dock.Bottom); root.Children.Add(controls);
        var grid = new Grid(); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(240) });
        grid.Children.Add(space); Grid.SetColumn(logs, 1); grid.Children.Add(logs); root.Children.Add(grid); Content = root;
        space.SelectBranch = ShowLogs; logs.SelectionChanged += (_, _) => { if (logs.SelectedItem is ListBoxItem item && item.Tag is CommitRecord record) { space.Selected = record.Id; space.InvalidateVisual(); SelectCommit?.Invoke(record); } };
        timeline.ValueChanged += (_, _) => { if (updating) return; space.Visible = Math.Min(commits.Length, (int)timeline.Value); count.Text = $"{space.Visible} / {commits.Length}"; ShowLogs(space.Branches.FirstOrDefault(b => b.Commits.Any(c => c.Id == space.Selected)) ?? space.Branches.FirstOrDefault()); space.InvalidateVisual(); };
        timer.Tick += async (_, _) => {
            if (!IsVisible) { playing = false; return; }
            if (!SystemParameters.ClientAreaAnimation) playing = false;
            if (playing) { timeline.Value = Math.Min(commits.Length, timeline.Value + Math.Max(1, commits.Length / 80)); if (timeline.Value >= commits.Length) playing = false; }
            if (SystemParameters.ClientAreaAnimation) await space.RenderVolume(DateTime.UtcNow.TimeOfDay.TotalSeconds);
        };
        IsVisibleChanged += async (_, _) => { if (IsVisible) { timer.Start(); await space.RenderVolume(0); } else { timer.Stop(); playing = false; } };
    }
    public void SetCommits(CommitRecord[] records)
    {
        var firstDataset = commits.Length == 0;
        commits = records; space.Commits = records; space.Branches = NebulaBranch.Group(records); space.Links = NebulaBranch.Links(space.Branches); space.Visible = records.Length;
        if (firstDataset && space.Branches.Length > 0) space.Camera.BaseDistance = Math.Max(32, space.Branches.Max(b => b.Position.Length() + b.Radius) * 3);
        updating = true; timeline.Maximum = Math.Max(2, records.Length); timeline.Value = Math.Max(1, records.Length); updating = false; count.Text = $"{records.Length} / {records.Length}";
        ShowLogs(space.Branches.FirstOrDefault(b => b.Commits.Any(c => c.Id == space.Selected)) ?? space.Branches.FirstOrDefault()); space.Refresh();
    }
    private void ShowLogs(NebulaBranch? branch)
    {
        var selected = space.Selected; logs.Items.Clear(); if (branch == null) return;
        var visible = commits.TakeLast(space.Visible).Select(c => c.Id).ToHashSet();
        foreach (var record in branch.Commits.Where(c => visible.Contains(c.Id))) {
            var item = new ListBoxItem { Tag = record, Content = new TextBlock { Text = record.Subject + "\n" + record.Id + "\n" + record.Date, TextWrapping = TextWrapping.Wrap, FontSize = 13, Margin = new Thickness(6) } };
            logs.Items.Add(item); if (record.Id == selected) logs.SelectedItem = item;
        }
        if (logs.SelectedItem == null && logs.Items.Count > 0) logs.SelectedIndex = 0;
    }
    private sealed class SpaceCanvas : FrameworkElement
    {
        public OrbitCamera Camera { get; } = new();
        public CommitRecord[] Commits = [];
        public NebulaBranch[] Branches = [];
        public Dictionary<(int A, int B), List<(string Child, string Parent)>> Links = new();
        public string? Selected;
        public int Visible;
        public Action<NebulaBranch?>? SelectBranch;
        private BitmapSource? volume;
        private bool rendering, dragged;
        private int clicks;
        private Point previous, start;
        private int revision;
        private double elapsed;
        private static readonly Color[] Colors = [Color.FromRgb(145, 77, 255), Color.FromRgb(51, 178, 255), Color.FromRgb(255, 77, 158), Color.FromRgb(77, 242, 186), Color.FromRgb(255, 166, 64)];
        public SpaceCanvas()
        {
            ClipToBounds = true; Focusable = true;
            MouseWheel += (_, e) => { Camera.Zoom(-e.Delta / 120.0); Refresh(); e.Handled = true; };
            MouseLeftButtonDown += (_, e) => { previous = start = e.GetPosition(this); dragged = false; clicks = e.ClickCount; CaptureMouse(); };
            MouseMove += (_, e) => { if (!IsMouseCaptured) return; var point = e.GetPosition(this); if ((point - start).Length > 4) dragged = true; if (dragged) { Camera.Rotate(point.X - previous.X, point.Y - previous.Y); Refresh(); } previous = point; };
            MouseLeftButtonUp += (_, e) => {
                ReleaseMouseCapture(); if (dragged) return; var point = e.GetPosition(this); var visible = Commits.TakeLast(Visible).Select(c => c.Id).ToHashSet();
                var selected = Branches.Where(b => b.Commits.Any(c => visible.Contains(c.Id))).Select(b => (Branch: b, Point: Camera.Project(b.Position, ActualWidth, ActualHeight)))
                    .Where(p => p.Point.HasValue && (point - new Point(p.Point.Value.X, p.Point.Value.Y)).Length < Math.Max(12, p.Branch.Radius * p.Point.Value.Scale)).OrderByDescending(p => p.Point!.Value.Scale).FirstOrDefault();
                if (selected.Branch != null) { SelectBranch?.Invoke(selected.Branch); if (clicks == 2) { Camera.Target = selected.Branch.Position; Camera.Scroll = -10; Refresh(); } }
            };
            SizeChanged += (_, _) => Refresh();
        }
        public async void Refresh() { revision++; InvalidateVisual(); await RenderVolume(0); }
        public async Task RenderVolume(double time)
        {
            if (rendering || ActualWidth < 1 || ActualHeight < 1) return;
            rendering = true; elapsed = time; var snapshot = Camera.Copy(); var expected = revision; var aspect = ActualWidth / ActualHeight;
            try {
                var bytes = await Task.Run(() => NebulaVolume.Pixels(snapshot, time: time, aspectRatio: aspect));
                if (expected != revision) return;
                volume = BitmapSource.Create(128, 80, 96, 96, PixelFormats.Bgra32, null, bytes, 128 * 4); volume.Freeze(); InvalidateVisual();
            } finally {
                rendering = false;
                if (expected != revision && IsVisible) _ = RenderVolume(0);
            }
        }
        protected override void OnRender(DrawingContext drawing)
        {
            base.OnRender(drawing); drawing.DrawRectangle(new SolidColorBrush(Color.FromRgb(6, 8, 17)), null, new Rect(RenderSize));
            if (volume != null) drawing.DrawImage(volume, new Rect(RenderSize));
            for (var i = 0; i < 70; i++) {
                var x = ((i * 137 + 31) % 997) / 997.0 * ActualWidth; var y = ((i * 251 + 73) % 991) / 991.0 * ActualHeight;
                var alpha = (byte)(50 + 115 * (.5 + .5 * Math.Sin(elapsed * .7 + i * 1.73)));
                drawing.DrawEllipse(new SolidColorBrush(Color.FromArgb(alpha, 255, 255, 255)), null, new Point(x, y), i % 7 == 0 ? 1.8 : 1, i % 7 == 0 ? 1.8 : 1);
            }
            var visible = Commits.TakeLast(Visible).Select(c => c.Id).ToHashSet(); var projected = Branches.ToDictionary(b => b.Id, b => Camera.Project(b.Position, ActualWidth, ActualHeight));
            foreach (var (pair, relations) in Links) if (relations.Any(r => visible.Contains(r.Child) && visible.Contains(r.Parent)) && projected[pair.A] is { } a && projected[pair.B] is { } b)
                drawing.DrawLine(new Pen(new SolidColorBrush(Color.FromArgb(170, 150, 150, 255)), 1.5), new Point(a.X, a.Y), new Point(b.X, b.Y));
            foreach (var branch in Branches.OrderBy(b => projected[b.Id]?.Scale ?? -1)) {
                var count = branch.Commits.Count(c => visible.Contains(c.Id)); if (count == 0 || projected[branch.Id] is not { } p) continue;
                var radius = Math.Max(3, (.22 + .16 * Math.Sqrt(count)) * p.Scale); var color = Colors[branch.Id % Colors.Length];
                drawing.DrawEllipse(new RadialGradientBrush(Color.FromArgb(190, color.R, color.G, color.B), System.Windows.Media.Colors.Transparent), null, new Point(p.X, p.Y), radius * 2.5, radius * 2.5);
                var sphere = new RadialGradientBrush { GradientOrigin = new Point(.35, .35) }; sphere.GradientStops.Add(new GradientStop(System.Windows.Media.Colors.White, 0)); sphere.GradientStops.Add(new GradientStop(color, .45)); sphere.GradientStops.Add(new GradientStop(Color.FromRgb((byte)(color.R / 5), (byte)(color.G / 5), (byte)(color.B / 5)), 1));
                drawing.DrawEllipse(sphere, null, new Point(p.X, p.Y), radius, radius);
                if (branch.Commits.Any(c => c.Id == Selected)) drawing.DrawEllipse(null, new Pen(Brushes.White, 1), new Point(p.X, p.Y), radius + 3, radius + 3);
                var title = new FormattedText(branch.Title, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight, new Typeface("Segoe UI"), 12, Brushes.White, VisualTreeHelper.GetDpi(this).PixelsPerDip);
                drawing.DrawText(title, new Point(p.X + radius + 5, p.Y));
            }
        }
    }
}
