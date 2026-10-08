using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
namespace GitNebula;
public sealed class DiffComparisonView : UserControl
{
    private readonly RichTextBox left = Editor(), right = Editor();
    private readonly TextBlock titles = new() { TextWrapping = TextWrapping.Wrap }, notice = new() { TextWrapping = TextWrapping.Wrap };
    private DiffDocument? document;
    private int hunk = -1;
    private bool syncing;
    public DiffComparisonView() {
        var root = new DockPanel(); var header = new StackPanel(); var controls = new WrapPanel();
        foreach (var (label, direction) in new[] { ("前の変更", -1), ("次の変更", 1) }) { var button = new Button { Content = Localization.Text(label) }; button.Click += (_, _) => Jump(direction); controls.Children.Add(button); }
        header.Children.Add(titles); header.Children.Add(controls); header.Children.Add(notice); DockPanel.SetDock(header, Dock.Top); root.Children.Add(header);
        var columns = new Grid(); columns.ColumnDefinitions.Add(new ColumnDefinition()); columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(5) }); columns.ColumnDefinitions.Add(new ColumnDefinition());
        columns.Children.Add(left); var splitter = new GridSplitter { Width = 5, HorizontalAlignment = HorizontalAlignment.Stretch }; Grid.SetColumn(splitter, 1); columns.Children.Add(splitter); Grid.SetColumn(right, 2); columns.Children.Add(right); root.Children.Add(columns); Content = root;
        void Sync(RichTextBox source, RichTextBox target, ScrollChangedEventArgs e) {
            if (syncing || e.VerticalChange == 0) return; syncing = true; target.ScrollToVerticalOffset(source.VerticalOffset); syncing = false;
        }
        left.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler((_, e) => Sync(left, right, e)));
        right.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler((_, e) => Sync(right, left, e)));
    }
    private static RichTextBox Editor() {
        var view = new RichTextBox { IsReadOnly = true, FontFamily = new FontFamily("Consolas"), FontSize = 14, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
        view.SetResourceReference(ForegroundProperty, "TextBrush"); view.SetResourceReference(BackgroundProperty, "SurfaceBrush"); return view;
    }
    public void SetDocument(DiffDocument value) {
        document = value; hunk = -1; titles.Text = value.Path + "\n" + value.OldTitle + "  →  " + value.NewTitle; notice.Text = value.Notice;
        foreach (var (editor, before) in new[] { (left, true), (right, false) }) {
            var longest = value.Rows.Select(r => (before ? r.Old : r.New).Length).DefaultIfEmpty(0).Max();
            var body = new FlowDocument { PagePadding = new Thickness(4), PageWidth = Math.Max(800, (longest + 10) * 9), FontFamily = editor.FontFamily, FontSize = 14 };
            foreach (var row in value.Rows) {
                var number = before ? row.OldNumber : row.NewNumber; var text = before ? row.Old : row.New;
                var paragraph = new Paragraph(new Run((number?.ToString() ?? "").PadLeft(6) + "  " + text)) { Margin = new Thickness(0), LineHeight = 20, LineStackingStrategy = LineStackingStrategy.BlockLineHeight };
                if (row.Kind != "unchanged") { paragraph.Background = new SolidColorBrush((Color)ColorConverter.ConvertFromString(number == null ? "#22283C" : before ? "#552D38" : "#214734")); paragraph.Foreground = Brushes.White; }
                body.Blocks.Add(paragraph);
            }
            editor.Document = body; editor.ScrollToHome();
        }
    }
    private void Jump(int direction) {
        if (document == null || document.Hunks.Length == 0) return; hunk = Math.Clamp(hunk + direction, 0, document.Hunks.Length - 1); left.ScrollToVerticalOffset(document.Hunks[hunk] * 20); right.ScrollToVerticalOffset(document.Hunks[hunk] * 20);
    }
}
