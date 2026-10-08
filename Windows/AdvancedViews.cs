using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
namespace GitNebula;

public partial class MainWindow
{
    private static readonly string[] AdvancedActions = ["compare", "file-history", "blame", "reflog", "reset", "patch", "worktrees", "submodules"];
    private TextBox? advancedOutput;
    private void BuildAdvancedView() {
        ToolsPanel.Children.Clear(); advancedOutput = null;
        if (!AdvancedActions.Contains(action)) return;
        var fields = new StackPanel(); DockPanel.SetDock(fields, Dock.Top); ToolsPanel.Children.Add(fields);
        TextBox Input(string title, string value = "") {
            fields.Children.Add(new TextBlock { Text = Localization.Text(title), TextWrapping = TextWrapping.Wrap });
            var input = new TextBox { Text = value, Margin = new Thickness(0, 4, 0, 8) }; fields.Children.Add(input); return input;
        }
        void Control(string title, Func<Task> work, bool mutation = false, Func<string>? confirmation = null) {
            var control = new Button { Content = Localization.Text(title), HorizontalAlignment = HorizontalAlignment.Left };
            control.Click += async (_, _) => {
                if (busy || repository == null || confirmation != null && !Confirm(confirmation())) return;
                await Act(mutation ? () => Operate(work) : work, Localization.Text(mutation ? "完了" : "準備完了"));
            }; fields.Children.Add(control);
        }
        switch (action) {
            case "compare": {
                var first = Input("比較元のコミット", "HEAD~1"); var second = Input("比較先のコミット", "HEAD");
                Control("比較", async () => advancedOutput!.Text = await Repo.Compare(first.Text, second.Text)); break;
            }
            case "file-history": case "blame": {
                var file = Input("リポジトリ内のファイル", request.Paths.FirstOrDefault(p => System.IO.File.Exists(p)) is string path && repository != null ? System.IO.Path.GetRelativePath(repository.Path, path) : "");
                var reference = action == "blame" ? Input("対象コミット / ブランチ（例: HEAD）", "HEAD") : null;
                Control("表示", async () => advancedOutput!.Text = action == "blame" ? await Repo.Blame(file.Text, reference!.Text) : await Repo.FileHistory(file.Text)); break;
            }
            case "reset": {
                var reference = Input("対象コミット / ブランチ（例: HEAD）", "HEAD");
                var mode = new ComboBox { ItemsSource = new[] { "soft", "mixed", "hard" }, SelectedIndex = 0, Margin = new Thickness(0, 4, 0, 8) }; fields.Children.Add(mode);
                Control("Reset", () => Repo.Reset(reference.Text, (string)mode.SelectedItem), true,
                    () => Localization.Text("現在のブランチを指定したコミットへ移動します。") + "\n" + reference.Text + " · " + mode.SelectedItem); break;
            }
            case "patch": {
                var file = Input("パッチファイルの絶対パス");
                var pick = new Button { Content = Localization.Text("ファイルを選択"), HorizontalAlignment = HorizontalAlignment.Left };
                pick.Click += (_, _) => { var dialog = new Microsoft.Win32.OpenFileDialog(); if (dialog.ShowDialog(this) == true) file.Text = dialog.FileName; }; fields.Children.Add(pick);
                Control("パッチを保存", () => Repo.ExportPatch(file.Text));
                Control("適用できるか確認", () => Repo.ApplyPatch(file.Text, true));
                Control("パッチを適用", () => Repo.ApplyPatch(file.Text), true, () => Localization.Text("作業ファイルへパッチを適用します。") + "\n" + file.Text); break;
            }
            case "worktrees": {
                var path = Input("作成先の絶対パス"); var branch = Input("新しいブランチ名");
                Control("Worktree を作成", () => Repo.AddWorktree(path.Text, branch.Text), true); break;
            }
            case "submodules": {
                var source = Input("取得元 URL / パス"); var path = Input("リポジトリ内の作成先");
                Control("Submodule を追加", () => Repo.AddSubmodule(source.Text, path.Text), true);
                Control("Submodule を更新", () => Repo.UpdateSubmodules(), true); break;
            }
        }
        advancedOutput = new TextBox { IsReadOnly = true, AcceptsReturn = true, FontFamily = new FontFamily("Consolas"), FontSize = 14, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto };
        ToolsPanel.Children.Add(advancedOutput);
    }
    private async Task RefreshAdvancedData() {
        if (advancedOutput == null) return;
        if (action == "reflog") advancedOutput.Text = await Repo.Reflog();
        else if (action == "worktrees") advancedOutput.Text = await Repo.Worktrees();
        else if (action == "submodules") advancedOutput.Text = await Repo.Submodules();
    }
    private async void Ignore_Click(object sender, RoutedEventArgs e) => await Act(() => Operate(() => Repo.Ignore(selected.ToArray())), Localization.Text("完了"));
    private async void Discard_Click(object sender, RoutedEventArgs e) {
        if (Confirm(Localization.Text("選択したファイルの変更を破棄します。") + "\n" + string.Join("\n", selected)))
            await Act(() => Operate(() => Repo.Discard(selected.ToArray())), Localization.Text("完了"));
    }
}
