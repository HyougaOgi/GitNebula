using System.IO;
using System.Windows;
using System.Windows.Controls;
using GitNebula;

internal static class Program
{
    [STAThread]
    private static int Main()
    {
        var app = new GitNebula.App(); app.InitializeComponent(); app.StartupUri = null;
        var root = Path.Combine(Path.GetTempPath(), "gitnebula-ui-" + Guid.NewGuid()); Directory.CreateDirectory(root);
        var code = 0;
        app.Startup += async (_, _) => {
            MainWindow? window = null;
            try
            {
                var repo = new GitRepository(root);
                await repo.Run("init", "-q"); await repo.Run("config", "user.name", "Test"); await repo.Run("config", "user.email", "ui@example.invalid");
                var file = Path.Combine(root, "orbit.txt"); await File.WriteAllTextAsync(file, "base\n"); await repo.Commit(["orbit.txt"], "initial");
                await File.WriteAllTextAsync(file, "updated\n"); await File.WriteAllTextAsync(Path.Combine(root, "other.txt"), "unrelated\n");
                window = new MainWindow(new LaunchRequest("commit", [file])); window.Show();
                T Find<T>(string name) where T : FrameworkElement => (T)window.FindName(name);
                async Task Wait()
                {
                    var deadline = DateTime.UtcNow.AddSeconds(20);
                    do { await Task.Delay(30); } while (Find<ProgressBar>("Progress").Visibility == Visibility.Visible && DateTime.UtcNow < deadline);
                    Check(Find<ProgressBar>("Progress").Visibility != Visibility.Visible, "operation timed out");
                }
                await Wait();
                Check(Find<StackPanel>("CommitPanel").IsVisible, "commit dialog opens directly");
                Check(!Find<StackPanel>("BranchPanel").IsVisible && !Find<TextBox>("History").IsVisible, "unrelated tools hidden");
                Check(Find<TextBlock>("SelectionCount").Text.StartsWith("1 "), "scope preselected");
                Check(Find<TextBox>("DiffView").Text.Contains("+updated"), "initial diff");
                var operations = Find<ComboBox>("OtherActions");
                operations.SelectedItem = operations.Items.Cast<ComboBoxItem>().Single(i => (string)i.Tag == "workspace");
                Check(Find<TextBlock>("FileCount").Text.Contains("2 ファイル"), "advanced view sees full repository");
                operations.SelectedItem = operations.Items.Cast<ComboBoxItem>().Single(i => (string)i.Tag == "commit");
                Check(Find<TextBlock>("FileCount").Text.Contains("1 ファイル"), "return to original file scope");
                Find<TextBox>("Message").Text = "context commit";
                Check(Find<Button>("CommitButton").IsEnabled, "valid commit enabled");
                Find<Button>("CommitButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Wait();
                Check((await repo.Changes()).Select(c => c.Path).SequenceEqual(new[] { "other.txt" }), "commit excludes other files");
                Check(Find<TextBlock>("Status").Text.Contains("コミットしました"), "completion remains visible");
                var choices = Find<ComboBox>("OtherActions");
                choices.SelectedItem = choices.Items.Cast<ComboBoxItem>().Single(i => (string)i.Tag == "log");
                Check(Find<TextBox>("History").IsVisible && !Find<StackPanel>("CommitPanel").IsVisible, "history mode");
                choices.SelectedItem = choices.Items.Cast<ComboBoxItem>().Single(i => (string)i.Tag == "pull");
                Check(Find<Border>("RemotePanel").IsVisible && !Find<Border>("FilePanel").IsVisible, "pull mode");
                Check(!Find<Button>("ExecuteButton").IsEnabled, "no remote prevents execution");
                Find<TextBox>("RepositoryPath").Text = "\"" + root + "\"";
                Check(!Find<TextBox>("RepositoryPath").IsReadOnly && Find<TextBox>("RepositoryPath").IsEnabled, "path is editable");
                Find<Button>("OpenPathButton").RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Wait();
                Check(Find<TextBox>("RepositoryPath").Text == root, "typed path opens repository");
                Console.WriteLine("PASS: WPF action routing, selected-file commit, preview, modes and feedback");
            }
            catch (Exception error) { Console.Error.WriteLine(error); code = 1; }
            finally { window?.Close(); app.Shutdown(); }
        };
        app.Run();
        foreach (var file in Directory.EnumerateFiles(root, "*", SearchOption.AllDirectories)) File.SetAttributes(file, FileAttributes.Normal);
        Directory.Delete(root, true); return code;
    }
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
}
