using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
namespace GitNebula;
public sealed class NebulaHomeView : UserControl
{
    private readonly Image image = new() { Stretch = Stretch.Fill };
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(350) };
    private bool rendering;
    public NebulaHomeView()
    {
        Content = image;
        timer.Tick += async (_, _) => { if (IsVisible && SystemParameters.ClientAreaAnimation) await Render(DateTime.UtcNow.TimeOfDay.TotalSeconds); };
        IsVisibleChanged += async (_, _) => { if (IsVisible) { timer.Start(); await Render(0); } else timer.Stop(); };
        SizeChanged += async (_, _) => { if (IsVisible) await Render(0); };
    }
    private async Task Render(double time)
    {
        if (rendering || ActualWidth < 1 || ActualHeight < 1) return; rendering = true; var aspect = ActualWidth / ActualHeight;
        try {
            var bytes = await Task.Run(() => NebulaVolume.Pixels(new OrbitCamera(), time: time, aspectRatio: aspect));
            var bitmap = BitmapSource.Create(128, 80, 96, 96, PixelFormats.Bgra32, null, bytes, 128 * 4); bitmap.Freeze(); image.Source = bitmap;
        } finally { rendering = false; }
    }
}
