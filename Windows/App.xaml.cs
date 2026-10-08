using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Text.Json;
using System.Windows;
using Forms = System.Windows.Forms;
namespace GitNebula;

public partial class App : Application
{
    public void RefreshTrayLabels() { if (tray?.ContextMenuStrip is { } menu) { menu.Items[0].Text = Localization.Text("GitNebula を開く"); menu.Items[1].Text = Localization.Text("詳細設定…"); if (menu.Items[2] is Forms.ToolStripMenuItem options) { options.Text = Localization.Text("起動オプション"); options.DropDownItems[0].Text = Localization.Text("ログイン時に自動起動"); options.DropDownItems[1].Text = Localization.Text("起動時にアプリ画面を開く"); } menu.Items[menu.Items.Count - 1].Text = Localization.Text("GitNebula を終了"); } }
    public bool ResidentEnabled { get; set; } = true;
    public bool IsExiting { get; private set; }
    private Forms.NotifyIcon? tray;
    private Mutex? instance;
    private readonly CancellationTokenSource stopping = new();
    private string pipeName = "";
    protected override void OnStartup(StartupEventArgs e)
    {
        if (!ResidentEnabled) { base.OnStartup(e); return; }
        ShutdownMode = ShutdownMode.OnExplicitShutdown;
        pipeName = "GitNebula-" + Environment.UserName + "-" + Process.GetCurrentProcess().SessionId;
        instance = new Mutex(true, pipeName, out var first);
        if (!first) { _ = Forward(e.Args); return; }
        LaunchRequest initialRequest;
        try { initialRequest = LaunchRequest.Parse(e.Args); }
        catch (Exception error) { MessageBox.Show(error.Message, "GitNebula", MessageBoxButton.OK, MessageBoxImage.Error); initialRequest = new("open", []); }
        var window = new MainWindow(initialRequest); MainWindow = window;
        window.RouteRequest = request => OpenRequest(window, request);
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add(Localization.Text("GitNebula を開く"), null, (_, _) => Dispatcher.Invoke(window.ShowHome));
        menu.Items.Add(Localization.Text("詳細設定…"), null, (_, _) => Dispatcher.InvokeAsync(() => window.ShowRequest(new LaunchRequest("settings", []))));
        var options = new Forms.ToolStripMenuItem(Localization.Text("起動オプション"));
        var login = new Forms.ToolStripMenuItem(Localization.Text("ログイン時に自動起動")) { Checked = StartupEnabled(), CheckOnClick = true };
        login.Click += (_, _) => { try { SetStartup(login.Checked); } catch (Exception error) { login.Checked = StartupEnabled(); MessageBox.Show(error.Message, "GitNebula"); } };
        var home = new Forms.ToolStripMenuItem(Localization.Text("起動時にアプリ画面を開く")) { Checked = AppSettings.Current.ShowHomeOnLaunch, CheckOnClick = true };
        home.Click += (_, _) => { AppSettings.Current.ShowHomeOnLaunch = home.Checked; AppSettings.Current.Save(); };
        options.DropDownItems.Add(login); options.DropDownItems.Add(home); menu.Items.Add(options);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(Localization.Text("GitNebula を終了"), null, (_, _) => Dispatcher.Invoke(Quit));
        using var iconStream = typeof(App).Assembly.GetManifestResourceStream("GitNebula.icon.ico")!;
        tray = new Forms.NotifyIcon { Icon = new System.Drawing.Icon(iconStream), Text = "GitNebula", ContextMenuStrip = menu, Visible = true };
        tray.MouseClick += (_, click) => { if (click.Button == Forms.MouseButtons.Left) Dispatcher.Invoke(window.ShowHome); };
        if (initialRequest.Action != "open" || initialRequest.Paths.Length > 0 || AppSettings.Current.ShowHomeOnLaunch) window.Show();
        _ = Listen(window);
        base.OnStartup(e);
    }
    private static bool StartupEnabled() {
        using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        return key?.GetValue("GitNebula") is string value && value == "\"" + Environment.ProcessPath + "\"";
    }
    private static void SetStartup(bool enabled) {
        using var key = Microsoft.Win32.Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (enabled) key.SetValue("GitNebula", "\"" + Environment.ProcessPath + "\""); else key.DeleteValue("GitNebula", false);
    }
    private async Task Forward(string[] arguments)
    {
        try {
            using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.Out, PipeOptions.Asynchronous);
            await pipe.ConnectAsync(5000);
            using var writer = new StreamWriter(pipe);
            await writer.WriteLineAsync(JsonSerializer.Serialize(LaunchRequest.Parse(arguments))); await writer.FlushAsync();
        } catch (Exception error) { MessageBox.Show(Localization.Text("起動中の GitNebula に要求を渡せませんでした。\n") + error.Message, "GitNebula", MessageBoxButton.OK, MessageBoxImage.Error); }
        finally { Shutdown(); }
    }
    private async Task Listen(MainWindow window)
    {
        while (!stopping.IsCancellationRequested) {
            try {
                using var pipe = new NamedPipeServerStream(pipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await pipe.WaitForConnectionAsync(stopping.Token);
                using var reader = new StreamReader(pipe);
                var json = await reader.ReadLineAsync(stopping.Token);
                var request = JsonSerializer.Deserialize<LaunchRequest>(json ?? "") ?? throw new ArgumentException(Localization.Text("起動要求が空です。"));
                if (!LaunchRequest.Actions.ContainsKey(request.Action)) throw new ArgumentException(Localization.Text("不明な操作です。"));
                await OpenRequest(window, request);
            } catch (OperationCanceledException) { break; }
            catch (Exception error) { MessageBox.Show(error.Message, "GitNebula", MessageBoxButton.OK, MessageBoxImage.Error); }
        }
    }
    internal async Task OpenRequest(MainWindow home, LaunchRequest request)
    {
        string? directory = request.Paths.FirstOrDefault() is { } entry ? LaunchRequest.DirectoryFor(entry) : null;
        if (directory != null && request.Action is not ("clone" or "init" or "settings")) {
            var candidate = new GitRepository(directory);
            try { await candidate.Open(); directory = candidate.Path; } catch (InvalidOperationException) { }
        }
        var purpose = GitNebula.MainWindow.PurposeFor(request.Action);
        var target = directory == null && purpose == home.WindowPurpose ? home : Windows.OfType<MainWindow>().FirstOrDefault(w => w.WindowPurpose == purpose && string.Equals(w.RepositoryDirectory, directory, StringComparison.OrdinalIgnoreCase));
        if (target == null) {
            target = home.CanReuseLauncher ? home : new MainWindow();
        }
        target.WindowPurpose = purpose;
        target.RouteRequest = value => OpenRequest(home, value);
        await target.ShowRequest(request);
    }
    public void Quit()
    {
        if (IsExiting) return;
        if (Windows.OfType<MainWindow>().Any(window => window.IsBusy)) { MessageBox.Show(Localization.Text("Git の処理が完了してから終了してください。"), "GitNebula"); return; }
        IsExiting = true; stopping.Cancel(); if (tray != null) tray.Visible = false;
        Shutdown();
    }
    protected override void OnExit(ExitEventArgs e)
    {
        stopping.Cancel(); tray?.Icon?.Dispose(); tray?.Dispose(); instance?.Dispose(); stopping.Dispose(); base.OnExit(e);
    }
}
