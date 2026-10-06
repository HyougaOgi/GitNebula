using Microsoft.Win32;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
namespace GitNebula;
public partial class MainWindow
{
    private bool loadingAppearance;
    private readonly List<(DependencyObject Element, DependencyProperty Property, string Source)> labels = new();
    private readonly Random animationRandom = new();
    private void InitializeAppearance()
    {
        void Capture(DependencyObject parent) {
            foreach (var child in LogicalTreeHelper.GetChildren(parent).OfType<DependencyObject>()) {
                if (child is TextBlock text && (text.Name.Length == 0 || text.Name == "RemoteNotice")) labels.Add((text, TextBlock.TextProperty, text.Text));
                if (child is ContentControl control && control.Content is string source && control is not ComboBoxItem && control.Name is not ("ExecuteButton" or "IntegrateButton")) labels.Add((control, ContentControl.ContentProperty, source));
                Capture(child);
            }
        }
        Capture(this); DrawIcon(); ApplyAppearance();
        IsVisibleChanged += (_, _) => AnimateVisible();
        SystemEvents.UserPreferenceChanged += SystemAppearanceChanged;
        Closed += (_, _) => SystemEvents.UserPreferenceChanged -= SystemAppearanceChanged;
    }
    private void SystemAppearanceChanged(object sender, UserPreferenceChangedEventArgs e) => Dispatcher.BeginInvoke(() => { if (AppSettings.Current.Theme == "system") ApplyAppearance(); });
    private void LoadAppearanceControls()
    {
        loadingAppearance = true;
        foreach (var item in ThemeChoice.Items.OfType<ComboBoxItem>()) if ((string)item.Tag == AppSettings.Current.Theme) ThemeChoice.SelectedItem = item;
        foreach (var item in LanguageChoice.Items.OfType<ComboBoxItem>()) if ((string)item.Tag == AppSettings.Current.Language) LanguageChoice.SelectedItem = item;
        TransparencyChoice.Value = Math.Clamp(AppSettings.Current.Transparency, 0, 0.8); loadingAppearance = false;
    }
    private void Appearance_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!initialized || loadingAppearance || ThemeChoice == null || LanguageChoice == null) return;
        if (ThemeChoice.SelectedItem is ComboBoxItem theme) AppSettings.Current.Theme = (string)theme.Tag;
        if (LanguageChoice.SelectedItem is ComboBoxItem language) AppSettings.Current.Language = (string)language.Tag;
        AppSettings.Current.Save(); ApplyAppearance();
    }
    private void Transparency_Changed(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (!initialized || loadingAppearance) return;
        AppSettings.Current.Transparency = Math.Clamp(e.NewValue, 0, 0.8); AppSettings.Current.Save(); ApplyAppearance();
    }
    private void ApplyAppearance()
    {
        var theme = AppSettings.Current.Theme;
        var systemLight = Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is int value && value != 0;
        var light = theme == "light" || theme == "system" && systemLight;
        foreach (var (key, dark, bright) in new[] { ("WindowBrush", "#090D1D", "#F4F4FA"), ("TextBrush", "#E9EAFA", "#202035"), ("MutedBrush", "#9CA8C7", "#55556F"), ("SurfaceBrush", "#12182C", "#FFFFFF"), ("ControlBrush", "#28253F", "#E8E4F5"), ("BorderBrush", "#45405C", "#B7AFCA"), ("AccentBrush", "#B39DFF", "#7551C6"), ("PopupBrush", "#1C2239", "#FFFFFF"), ("SelectedBrush", "#40335F", "#DBD1F4") })
            Application.Current.Resources[key] = new SolidColorBrush((Color)ColorConverter.ConvertFromString(light ? bright : dark));
        Opacity = 1 - Math.Clamp(AppSettings.Current.Transparency, 0, 0.8);
        TransparencyValue.Text = $"{(int)(AppSettings.Current.Transparency * 100)}%";
        foreach (var (element, property, source) in labels) element.SetValue(property, Localization.Text(source));
        foreach (var item in ThemeChoice.Items.OfType<ComboBoxItem>()) item.Content = Localization.Text((string)item.Tag switch { "light" => Localization.Text("ライト"), "dark" => Localization.Text("ダーク"), _ => Localization.Text("システム") });
        foreach (var item in LanguageChoice.Items.OfType<ComboBoxItem>()) item.Content = (string)item.Tag switch { "ja" => Localization.Text("日本語"), "en" => "English", _ => Localization.Text("システム") };
        if (CommitList.View is GridView grid) { grid.Columns[1].Header = Localization.Text("コミット"); grid.Columns[2].Header = Localization.Text("作成者"); }
        OtherActions.Items.Clear(); OtherActions.Items.Add(new ComboBoxItem { Content = Localization.Text("機能を選ぶ…"), Tag = "placeholder" });
        foreach (var group in LaunchRequest.MenuGroups) {
            OtherActions.Items.Add(new ComboBoxItem { Content = group.Title, Tag = "placeholder", IsEnabled = false });
            foreach (var name in group.Actions) OtherActions.Items.Add(new ComboBoxItem { Content = LaunchRequest.Actions[name].Title, Tag = name });
        }
        OtherActions.SelectedIndex = 0;
        Heading.Text = LaunchRequest.Actions[action].Title; Hint.Text = LaunchRequest.Actions[action].Hint;
        Title = action == "open" ? "GitNebula" : Heading.Text + " — GitNebula";
        foreach (var star in Stars.Children.OfType<Ellipse>()) star.Fill = light ? Brushes.MediumPurple : Brushes.White;
        if (Application.Current is App app) app.RefreshTrayLabels();
        if (repository != null && action is not ("open" or "settings" or "clone")) Render(allChanges, currentBranch);
        Controls();
    }
    private void LoadSavedPassphrase()
    {
        if (SshPassphrase == null) return;
        try { SshPassphrase.Password = string.IsNullOrWhiteSpace(SshKeyPath.Text) ? "" : SSHCredentialStore.Read(LaunchRequest.InputPath(SshKeyPath.Text)) ?? ""; }
        catch (Exception error) { SshPassphrase.Clear(); Status.Text = error.Message; }
    }
    private void SshKey_Changed(object sender, TextChangedEventArgs e) { if (initialized) LoadSavedPassphrase(); }
    private void DrawIcon()
    {
        var background = new System.Windows.Shapes.Rectangle { Width = 148, Height = 148, RadiusX = 32, RadiusY = 32, Fill = new LinearGradientBrush(Color.FromRgb(20,26,64), Color.FromRgb(94,61,163), 45) };
        Canvas.SetLeft(background, 6); Canvas.SetTop(background, 6); NebulaIcon.Children.Add(background);
        var orbit = new Ellipse { Width = 116, Height = 105, Stroke = Brushes.Lavender, StrokeThickness = 2, Opacity = .3 }; Canvas.SetLeft(orbit, 22); Canvas.SetTop(orbit, 25); NebulaIcon.Children.Add(orbit);
        NebulaIcon.Children.Add(new Line { X1 = 59, X2 = 59, Y1 = 46, Y2 = 115, Stroke = Brushes.Lavender, StrokeThickness = 9, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round });
        var curve = new PathFigure { StartPoint = new Point(59,89) }; curve.Segments.Add(new BezierSegment(new Point(59,67), new Point(103,83), new Point(103,49), true));
        NebulaIcon.Children.Add(new System.Windows.Shapes.Path { Data = new PathGeometry([curve]), Stroke = Brushes.Lavender, StrokeThickness = 9 });
        foreach (var (x,y) in new[] { (59,115), (59,45), (103,47) }) { var node = new Ellipse { Width = 20, Height = 20, Fill = Brushes.MediumPurple, Stroke = Brushes.White, StrokeThickness = 2 }; Canvas.SetLeft(node,x-10); Canvas.SetTop(node,y-10); NebulaIcon.Children.Add(node); }
        var point = new Ellipse { Width = 7, Height = 7, Fill = Brushes.Cyan }; Canvas.SetLeft(point, 134); Canvas.SetTop(point, 73); NebulaIcon.Children.Add(point);
        point.RenderTransform = new RotateTransform(0, -54, 3.5);
    }
    private void AnimateVisible()
    {
        foreach (var star in Stars.Children.OfType<Ellipse>()) {
            star.BeginAnimation(OpacityProperty, null);
            if (IsVisible && SystemParameters.ClientAreaAnimation) star.BeginAnimation(OpacityProperty, new DoubleAnimation(.12, .7, TimeSpan.FromSeconds(3 + animationRandom.NextDouble() * 9)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, BeginTime = TimeSpan.FromSeconds(animationRandom.NextDouble() * 3) });
        }
        if (NebulaIcon.Children.OfType<Ellipse>().LastOrDefault()?.RenderTransform is RotateTransform rotation) {
            rotation.BeginAnimation(RotateTransform.AngleProperty, null);
            if (IsVisible && SystemParameters.ClientAreaAnimation) rotation.BeginAnimation(RotateTransform.AngleProperty, new DoubleAnimation(0,360,TimeSpan.FromSeconds(16)) { RepeatBehavior = RepeatBehavior.Forever });
        }
    }
}
