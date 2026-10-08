using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
namespace GitNebula;

/// A pinned full ID and one scrollable body; no screen-size-dependent field clipping.
public sealed class CommitDetailsView : UserControl
{
    private readonly StackPanel body = new();
    private readonly TextBox hash = Text("", true);
    private readonly TextBlock feedback = new() { Margin = new Thickness(8), MaxWidth = 180, TextTrimming = TextTrimming.CharacterEllipsis };
    private readonly ScrollViewer scroll;
    private readonly Action<string> copy;
    private readonly List<(Button Button, string Title)> copyControls = new();
    public CommitRecord? Record { get; private set; }
    public CommitDetailsView() : this(Clipboard.SetText) { }
    public CommitDetailsView(Action<string> copy)
    {
        this.copy = copy;
        var root = new DockPanel { LastChildFill = true };
        var toolbar = new WrapPanel();
        foreach (var (id, title) in new[] { ("id", "コミット ID をコピー"), ("message", "メッセージをコピー"), ("all", "全体をコピー") }) {
            var button = new Button { Content = Localization.Text(title), Padding = new Thickness(8, 4, 8, 4), FontSize = 13 }; AutomationProperties.SetAutomationId(button, "copyCommit:" + id);
            copyControls.Add((button, title));
            button.Click += (_, _) => { if (Record != null) Copy(id == "id" ? Record.Id : id == "message" ? Record.Message : Record.DetailsText); }; toolbar.Children.Add(button);
        }
        toolbar.Children.Add(feedback); DockPanel.SetDock(toolbar, Dock.Top); root.Children.Add(toolbar);
        hash.FontSize = 14; hash.FontWeight = FontWeights.SemiBold; AutomationProperties.SetAutomationId(hash, "commitField:id");
        DockPanel.SetDock(hash, Dock.Top); root.Children.Add(hash);
        scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        AutomationProperties.SetAutomationId(scroll, "commitDetailsScroll"); root.Children.Add(scroll); Content = root;
    }
    private static TextBox Text(string value, bool mono = false) => new() {
        Text = value, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true,
        FontSize = 15, BorderThickness = new Thickness(0), Background = Brushes.Transparent,
        Padding = new Thickness(4),
        FontFamily = new FontFamily(mono ? "Consolas" : "Segoe UI"), Margin = new Thickness(4, 2, 4, 8),
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled
    };
    public void SetRecord(CommitRecord? record)
    {
        Record = record; hash.Text = record?.Id ?? ""; feedback.Text = ""; body.Children.Clear(); scroll.ScrollToTop();
        foreach (var (button, title) in copyControls) button.Content = Localization.Text(title);
        if (record == null) { body.Children.Add(new TextBlock { Text = Localization.Text("コミットを選択") }); return; }
        foreach (var field in record.DetailFields.Where(f => f.Id != "id")) {
            var heading = new DockPanel { Margin = new Thickness(4, 8, 4, 0) };
            var button = new Button { Content = Localization.Text("コピー"), ToolTip = field.Title };
            AutomationProperties.SetAutomationId(button, "copyCommitField:" + field.Id);
            button.Click += (_, _) => Copy(field.Value); DockPanel.SetDock(button, Dock.Right); heading.Children.Add(button);
            heading.Children.Add(new TextBlock { Text = field.Title, VerticalAlignment = VerticalAlignment.Center, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap }); body.Children.Add(heading);
            var value = Text(field.Value, field.Id is "tree" or "parents"); AutomationProperties.SetAutomationId(value, "commitField:" + field.Id); body.Children.Add(value);
        }
    }
    public void RefreshLanguage() => SetRecord(Record);
    private void Copy(string value)
    {
        try { copy(value); feedback.Text = Localization.Text("コピーしました"); }
        catch (Exception) { feedback.Text = Localization.Text("コピーできませんでした。再度お試しください。"); }
        feedback.ToolTip = feedback.Text;
    }
}
