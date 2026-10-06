using System.IO;
using System.Text;
using System.Windows;
using System.Windows.Controls;
namespace GitNebula;

public static class Program
{
    [STAThread] public static int Main(string[] arguments)
    {
        var key = Environment.GetEnvironmentVariable("GITNEBULA_SSH_KEY");
        if (!string.IsNullOrEmpty(key) && arguments.Length == 1) return AskPass(arguments[0], key);
        var app = new App(); app.InitializeComponent(); return app.Run();
    }
    private static int AskPass(string prompt, string key)
    {
        try {
            string value;
            if (SSHConfiguration.IsKeyPassphrasePrompt(prompt, key)) {
                value = SSHCredentialStore.Read(key) ?? ReadPassphrase(key);
            } else if (Environment.GetEnvironmentVariable("SSH_ASKPASS_PROMPT") == "confirm" || prompt.Contains("Are you sure you want to continue connecting")) {
                if (MessageBox.Show(prompt, Localization.Text("SSH 接続先の確認"), MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return 1;
                value = "yes";
            } else return 1;
            using var output = Console.OpenStandardOutput(); var bytes = Encoding.UTF8.GetBytes(value + "\n"); output.Write(bytes); return 0;
        } catch { return 1; }
    }
    private static string ReadPassphrase(string key)
    {
        var field = new PasswordBox { Margin = new Thickness(0, 12, 0, 12) };
        var panel = new StackPanel { Margin = new Thickness(20) };
        var dialog = new Window { Title = Localization.Text("SSH 鍵のパスフレーズ"), Width = 440, SizeToContent = SizeToContent.Height, WindowStartupLocation = WindowStartupLocation.CenterScreen, Content = panel };
        panel.Children.Add(new TextBlock { Text = Path.GetFileName(key) + Localization.Text(" のパスフレーズを入力してください。詳細設定で保存すると次回から自動で使用します。"), TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(field);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        var accept = new Button { Content = Localization.Text("接続"), IsDefault = true, Padding = new Thickness(16, 8, 16, 8) };
        accept.Click += (_, _) => dialog.DialogResult = true;
        buttons.Children.Add(accept); buttons.Children.Add(new Button { Content = Localization.Text("キャンセル"), IsCancel = true, Margin = new Thickness(10, 0, 0, 0) }); panel.Children.Add(buttons);
        dialog.Loaded += (_, _) => field.Focus();
        if (dialog.ShowDialog() != true) throw new OperationCanceledException();
        return field.Password;
    }
}
