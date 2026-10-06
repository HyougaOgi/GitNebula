using System.IO;
using System.Windows;
using System.Windows.Controls;
using GitNebula;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        var app = new GitNebula.App { ResidentEnabled = false }; app.InitializeComponent(); app.StartupUri = null;
        var root = Path.Combine(Path.GetTempPath(), "gitnebula-ui-" + Guid.NewGuid()); Directory.CreateDirectory(root);
        Environment.SetEnvironmentVariable("GITNEBULA_SETTINGS_PATH", root + ".settings.json");
        var code = 0;
        app.Startup += async (_, _) => {
            MainWindow? window = null;
            try
            {
                AppSettings.Current.Language = "ja";
                var repo = new GitRepository(root);
                await repo.Run("init", "-q"); await repo.Run("config", "user.name", "Test"); await repo.Run("config", "user.email", "ui@example.invalid");
                var file = Path.Combine(root, "orbit.txt"); await File.WriteAllTextAsync(file, "base\n"); await repo.Commit(["orbit.txt"], "initial");
                await File.WriteAllTextAsync(file, "updated\n"); await File.WriteAllTextAsync(Path.Combine(root, "other.txt"), "unrelated\n");
                window = new MainWindow(new LaunchRequest("open", [])); window.Show();
                T Find<T>(string name) where T : FrameworkElement => (T)window.FindName(name);
                async Task Wait()
                {
                    var deadline = DateTime.UtcNow.AddSeconds(20);
                    do { await Task.Delay(30); } while (Find<ProgressBar>("Progress").Visibility == Visibility.Visible && DateTime.UtcNow < deadline);
                    Check(Find<ProgressBar>("Progress").Visibility != Visibility.Visible, "operation timed out");
                }
                await Wait();
                Check(Find<ScrollViewer>("HomePanel").IsVisible && !Find<Border>("FilePanel").IsVisible, "normal startup displays home without diff");
                Check(Find<ScrollViewer>("SettingsPanel").Visibility == Visibility.Collapsed, "startup displays one screen");
                Check(!Find<DockPanel>("PathPanel").IsVisible && !Find<ComboBox>("OtherActions").IsVisible && !Find<Button>("OpenButton").IsVisible, "app screen contains settings without repository work controls");
                var firstCloneTarget = Path.Combine(root, "Clone 星 first"); Directory.CreateDirectory(firstCloneTarget);
                var secondCloneTarget = Path.Combine(root, "Clone 星 second"); Directory.CreateDirectory(secondCloneTarget);
                await window.ShowRequest(new LaunchRequest("clone", [firstCloneTarget])); await Wait();
                Check(Find<TextBox>("CloneParent").Text == firstCloneTarget, "clone uses the right-clicked directory as parent");
                Find<TextBox>("CloneSource").Text = "https://example.invalid/team/repo.git";
                Check(Find<TextBlock>("CloneDestination").Text.EndsWith(Path.Combine(firstCloneTarget, "repo")), "source automatically supplies repository destination");
                Find<TextBox>("CloneSource").Text = "git@example.invalid:team/other.git";
                Check(Find<TextBlock>("CloneDestination").Text.EndsWith(Path.Combine(firstCloneTarget, "other")), "repository destination follows source automatically");
                Find<TextBox>("CloneParent").Text = Path.Combine(root, "edited clone draft");
                await window.ShowRequest(new LaunchRequest("clone", [secondCloneTarget])); await Wait();
                Check(Find<TextBox>("CloneParent").Text == secondCloneTarget, "a later Explorer request replaces the previous clone parent");
                await window.ShowRequest(new LaunchRequest("open", [])); await Wait();
                await window.ShowRequest(new LaunchRequest("commit", [file])); await Wait();
                Check(Find<StackPanel>("CommitPanel").IsVisible, "commit dialog opens directly");
                Check(!Find<StackPanel>("BranchPanel").IsVisible && !Find<TextBox>("History").IsVisible, "unrelated tools hidden");
                Check(Find<TextBlock>("SelectionCount").Text.StartsWith("1 "), "scope preselected");
                Check(Find<TextBox>("DiffView").Text.Contains("+updated"), "initial diff");
                var operations = Find<ComboBox>("OtherActions");
                operations.SelectedItem = operations.Items.Cast<ComboBoxItem>().Single(i => (string)i.Tag == "files");
                await Wait();
                Check(Find<TextBlock>("FileCount").Text.Contains("2 ファイル"), "advanced view sees full repository");
                operations.SelectedItem = operations.Items.Cast<ComboBoxItem>().Single(i => (string)i.Tag == "commit");
                await Wait();
                Check(Find<TextBlock>("FileCount").Text.Contains("1 ファイル"), "return to original file scope");
                Find<TextBox>("Message").Text = "context commit";
                Check(Find<Button>("CommitButton").IsEnabled, "valid commit enabled");
                Find<Button>("CommitButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Wait();
                Check((await repo.Changes()).Select(c => c.Path).SequenceEqual(new[] { "other.txt" }), "commit excludes other files");
                Check(Find<TextBlock>("Status").Text.Contains("コミットしました"), "completion remains visible");
                var choices = Find<ComboBox>("OtherActions");
                choices.SelectedItem = choices.Items.Cast<ComboBoxItem>().Single(i => (string)i.Tag == "log");
                await Wait();
                Check(Find<TextBox>("History").IsVisible && !Find<StackPanel>("CommitPanel").IsVisible, "history mode");
                choices.SelectedItem = choices.Items.Cast<ComboBoxItem>().Single(i => (string)i.Tag == "pull");
                await Wait();
                Check(Find<Border>("RemotePanel").IsVisible && !Find<Border>("FilePanel").IsVisible, "pull mode");
                Check(!Find<Button>("ExecuteButton").IsEnabled, "no remote prevents execution");
                Find<TextBox>("RepositoryPath").Text = "\"" + root + "\"";
                Check(!Find<TextBox>("RepositoryPath").IsReadOnly && Find<TextBox>("RepositoryPath").IsEnabled, "path is editable");
                Find<Button>("OpenPathButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Wait();
                Check(Find<TextBox>("RepositoryPath").Text == root, "typed path opens repository");
                var panels = new Dictionary<string, string> {
                    ["graph"] = "GraphPanel", ["open"] = "HomePanel", ["workspace"] = "ManagementPanel", ["files"] = "FilePanel", ["commit"] = "FilePanel", ["diff"] = "FilePanel",
                    ["log"] = "HistoryPanel", ["cherry-pick"] = "HistoryPanel", ["revert"] = "HistoryPanel", ["pull"] = "RemotePanel", ["push"] = "RemotePanel", ["fetch"] = "RemotePanel",
                    ["switch"] = "BranchPanel", ["branches"] = "BranchPanel", ["merge"] = "BranchPanel", ["rebase"] = "BranchPanel",
                    ["clone"] = "ClonePanel", ["stash"] = "StashPanel", ["tags"] = "TagsPanel", ["remotes"] = "RemoteSettingsPanel", ["identity"] = "IdentityPanel", ["settings"] = "SettingsPanel", ["conflicts"] = "ConflictPanel"
                };
                foreach (var (action, expectedPanel) in panels) {
                    choices.SelectedItem = choices.Items.Cast<ComboBoxItem>().Single(i => (string)i.Tag == action); await Wait();
                    foreach (var panel in panels.Values.Distinct()) Check(Find<FrameworkElement>(panel).IsVisible == (panel == expectedPanel), $"{action}: exclusive {panel}");
                    Check(Find<StackPanel>("CommitPanel").IsVisible == (action == "commit"), $"{action}: commit form visibility");
                    if (action is "log" or "cherry-pick" or "revert") {
                        Check(Find<Button>("CherryPickButton").IsVisible == (action != "revert"), $"{action}: cherry-pick button visibility");
                        Check(Find<Button>("RevertButton").IsVisible == (action != "cherry-pick"), $"{action}: revert button visibility");
                    }
                }
                await window.ShowRequest(new LaunchRequest("stash", [])); await Wait();
                Check(Find<Button>("SaveStashButton").IsEnabled, "stash can save untracked changes");
                Find<CheckBox>("IncludeUntracked").IsChecked = false;
                Check(!Find<Button>("SaveStashButton").IsEnabled, "untracked-only stash needs include-untracked");
                Find<CheckBox>("IncludeUntracked").IsChecked = true;
                Find<Button>("SaveStashButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Wait();
                Check((await repo.Changes()).Count == 0 && Find<ListBox>("StashList").Items.Count == 1, "stash saves and refreshes its list");
                Check(!Find<Button>("SaveStashButton").IsEnabled && Find<Button>("PopStashButton").IsEnabled, "stash controls reflect clean worktree and selection");
                Find<Button>("PopStashButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Wait();
                Check((await repo.Stashes()).Length == 0 && File.Exists(Path.Combine(root, "other.txt")), "pop restores file and removes stash");
                var gate = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                var act = typeof(MainWindow).GetMethod("Act", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!;
                var running = (Task)act.Invoke(window, [new Func<Task>(() => gate.Task), "operation complete"])!;
                window.ShowHome();
                Check(Find<StackPanel>("StashPanel").IsVisible && window.IsBusy, "tray home request waits for an operation");
                gate.SetResult(); await running; await Wait();
                Check(Find<ScrollViewer>("HomePanel").IsVisible && !Find<StackPanel>("StashPanel").IsVisible, "queued tray request returns home after operation");
                await repo.Commit(["other.txt"], "other");
                var branch = await repo.Branch(); await repo.CreateBranch("conflict-source");
                await File.WriteAllTextAsync(file, "incoming\n"); await repo.Commit(["orbit.txt"], "incoming"); await repo.SwitchBranch(branch);
                await File.WriteAllTextAsync(file, "current\n"); await repo.Commit(["orbit.txt"], "current");
                try { await repo.Merge("conflict-source"); } catch (InvalidOperationException) { }
                await window.ShowRequest(new LaunchRequest("diff", [root])); await Wait();
                Check(Find<Border>("FilePanel").IsVisible && !Find<Border>("ConflictPanel").IsVisible && Find<WrapPanel>("SequenceBanner").IsVisible, "conflicts show a link without a second screen");
                await window.ShowRequest(new LaunchRequest("conflicts", [])); await Wait();
                Check(Find<Border>("ConflictPanel").IsVisible && !Find<Border>("FilePanel").IsVisible, "conflict screen is exclusive");
                Check(Find<ComboBox>("ConflictChoice").Items.Count == 1 && !Find<Button>("FinishMergeButton").IsEnabled, "conflict must be resolved before completing merge");
                await repo.AbortMerge(); Find<Button>("RefreshButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Wait();
                Check(Find<TextBlock>("SequenceNotice").Text.Contains("ありません"), "conflict screen updates after abort");
                window.ShowHome(); await Wait();
                Check(Find<ScrollViewer>("HomePanel").IsVisible && !Find<Border>("FilePanel").IsVisible, "re-show opens home");
                await File.WriteAllTextAsync(file, "new draft change\n");
                await window.ShowRequest(new LaunchRequest("commit", [root])); await Wait();
                Find<TextBox>("Message").Text = "draft to preserve";
                await window.ShowRequest(new LaunchRequest("settings", [])); await Wait();
                Find<Button>("BackButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Wait();
                Check(Find<StackPanel>("CommitPanel").IsVisible && Find<TextBox>("Message").Text == "draft to preserve", "Back returns from settings to the commit draft");
                await window.ShowRequest(new LaunchRequest("graph", [])); await Wait();
                Check(Find<Grid>("GraphPanel").IsVisible && Find<ListBox>("GraphList").Items.Count >= 3 && !Find<Border>("FilePanel").IsVisible, "graph displays commit rows without a diff list");
                await window.ShowRequest(new LaunchRequest("settings", [])); await Wait();
                Find<ComboBox>("ThemeChoice").SelectedIndex = 1;
                Find<Slider>("TransparencyChoice").Value = .4;
                Check(Find<ComboBox>("LanguageChoice").Items.Count == 2, "language has only Japanese and English");
                Find<ComboBox>("LanguageChoice").SelectedIndex = 1;
                Check(AppSettings.Current.Theme == "light" && AppSettings.Current.Language == "en" && Math.Abs(window.Opacity - .6) < .001, "appearance controls apply and persist");
                Check(Find<Button>("BackButton").Content as string == "Back", "language changes apply immediately");
                Console.WriteLine("PASS: WPF action routing, selected-file commit, preview, modes and feedback");
            }
            catch (Exception error) { Console.Error.WriteLine(error); code = 1; }
            finally { window?.Close(); app.Shutdown(); }
        };
        app.Run();
        foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
        Directory.Delete(root, true); File.Delete(root + ".settings.json"); return code;
    }
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
}
