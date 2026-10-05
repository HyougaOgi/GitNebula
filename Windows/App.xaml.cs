using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Text.Json;
using System.Windows;
using Forms = System.Windows.Forms;
namespace GitNebula;

public partial class App : Application
{
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
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("ようこそを表示", null, (_, _) => Dispatcher.Invoke(window.ShowHome));
        menu.Items.Add(new Forms.ToolStripSeparator());
        foreach (var (name, metadata) in LaunchRequest.Actions.Where(entry => entry.Key is not ("open" or "settings")))
            menu.Items.Add(metadata.Title + "…", null, (_, _) => Dispatcher.InvokeAsync(() => window.ShowRequest(new LaunchRequest(name, []))));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("設定…", null, (_, _) => Dispatcher.InvokeAsync(() => window.ShowRequest(new LaunchRequest("settings", []))));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("GitNebula を終了", null, (_, _) => Dispatcher.Invoke(Quit));
        tray = new Forms.NotifyIcon { Icon = System.Drawing.SystemIcons.Application, Text = "GitNebula", ContextMenuStrip = menu, Visible = true };
        tray.MouseClick += (_, click) => { if (click.Button == Forms.MouseButtons.Left) Dispatcher.Invoke(window.ShowHome); };
        window.Show();
        _ = Listen(window);
        base.OnStartup(e);
    }
    private async Task Forward(string[] arguments)
    {
        try {
            using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.Out, PipeOptions.Asynchronous);
            await pipe.ConnectAsync(5000);
            using var writer = new StreamWriter(pipe);
            await writer.WriteLineAsync(JsonSerializer.Serialize(LaunchRequest.Parse(arguments))); await writer.FlushAsync();
        } catch (Exception error) { MessageBox.Show("起動中の GitNebula に要求を渡せませんでした。\n" + error.Message, "GitNebula", MessageBoxButton.OK, MessageBoxImage.Error); }
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
                var request = JsonSerializer.Deserialize<LaunchRequest>(json ?? "") ?? throw new ArgumentException("起動要求が空です。");
                if (!LaunchRequest.Actions.ContainsKey(request.Action)) throw new ArgumentException("不明な操作です。");
                while (window.IsBusy) await Task.Delay(100, stopping.Token);
                await window.ShowRequest(request);
            } catch (OperationCanceledException) { break; }
            catch (Exception error) { MessageBox.Show(error.Message, "GitNebula", MessageBoxButton.OK, MessageBoxImage.Error); }
        }
    }
    public void Quit()
    {
        if (IsExiting) return;
        if (MainWindow is MainWindow window && window.IsBusy) { MessageBox.Show("Git の処理が完了してから終了してください。", "GitNebula"); return; }
        IsExiting = true; stopping.Cancel(); if (tray != null) tray.Visible = false;
        Shutdown();
    }
    protected override void OnExit(ExitEventArgs e)
    {
        stopping.Cancel(); tray?.Dispose(); instance?.Dispose(); stopping.Dispose(); base.OnExit(e);
    }
}
