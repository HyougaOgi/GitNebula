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
        HomeBrand.Foreground = new LinearGradientBrush(new GradientStopCollection { new GradientStop(Color.FromRgb(61, 160, 255), 0), new GradientStop(Color.FromRgb(160, 87, 232), .5), new GradientStop(Color.FromRgb(238, 102, 176), 1) }, new Point(0, 0), new Point(1, 1));
        Capture(this); DrawNebula(); ApplyAppearance();
        IsVisibleChanged += (_, _) => AnimateVisible();
        HomePanel.IsVisibleChanged += (_, _) => AnimateVisible();
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
        foreach (var item in LanguageChoice.Items.OfType<ComboBoxItem>()) item.Content = (string)item.Tag == "en" ? "English" : Localization.Text("日本語");
        if (CommitList.View is GridView grid) { grid.Columns[1].Header = Localization.Text("コミット"); grid.Columns[2].Header = Localization.Text("作成者"); }
        HistoryCommitDetails.RefreshLanguage(); GraphCommitDetails.RefreshLanguage();
        foreach (var item in GraphMode.Items.OfType<ComboBoxItem>()) item.Content = (string)item.Tag == "normal" ? Localization.Text("通常") : "4D";
        OtherActions.Items.Clear(); OtherActions.Items.Add(new ComboBoxItem { Content = Localization.Text("機能を選ぶ…"), Tag = "placeholder" });
        foreach (var group in LaunchRequest.MenuGroups) {
            OtherActions.Items.Add(new ComboBoxItem { Content = group.Title, Tag = "placeholder", IsEnabled = false });
            foreach (var name in group.Actions) OtherActions.Items.Add(new ComboBoxItem { Content = LaunchRequest.Actions[name].Title, Tag = name });
        }
        OtherActions.Items.Add(new ComboBoxItem { Content = Localization.Text("アプリ"), Tag = "placeholder", IsEnabled = false });
        foreach (var name in new[] { "open", "settings" }) OtherActions.Items.Add(new ComboBoxItem { Content = LaunchRequest.Actions[name].Title, Tag = name });
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
    private void DrawNebula()
    {
        var palette = new[] { Color.FromArgb(75, 122, 59, 230), Color.FromArgb(75, 51, 156, 219), Color.FromArgb(75, 235, 77, 130) };
        for (var index = 0; index < 84; index++) {
            var phase = index * 2.39996; var spread = Math.Sqrt(index / 84.0); var radius = 12 + index % 9 * 3;
            var cloud = new Ellipse { Width = radius * 2.6, Height = radius * 2, Fill = new RadialGradientBrush(palette[index % 3], Colors.Transparent), RenderTransform = new TranslateTransform(), Tag = index };
            Canvas.SetLeft(cloud, 180 + Math.Cos(phase) * spread * 360 * .32 - radius * 1.3); Canvas.SetTop(cloud, 210 * .48 + Math.Sin(phase) * spread * 210 * .28 - radius);
            NebulaScene.Children.Add(cloud);
        }
        for (var index = 0; index < 42; index++) {
            var star = new Ellipse { Width = index % 11 == 0 ? 2.8 : 1.3, Height = index % 11 == 0 ? 2.8 : 1.3, Fill = Brushes.White, Opacity = .65 };
            Canvas.SetLeft(star, (index * 137 + 23) % 997 / 997.0 * 360); Canvas.SetTop(star, (index * 239 + 67) % 991 / 991.0 * 210); NebulaScene.Children.Add(star);
        }
    }
    private void AnimateVisible()
    {
        if (HomeBrand.Foreground is LinearGradientBrush title) {
            foreach (var stop in title.GradientStops) {
                stop.BeginAnimation(GradientStop.ColorProperty, null);
                if (IsVisible && HomePanel.IsVisible && SystemParameters.ClientAreaAnimation) stop.BeginAnimation(GradientStop.ColorProperty, new ColorAnimation(stop.Color, Color.FromRgb((byte)(stop.Offset < .5 ? 225 : 65), 100, (byte)(stop.Offset < .5 ? 182 : 255)), TimeSpan.FromSeconds(8)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever });
            }
        }
        foreach (var star in Stars.Children.OfType<Ellipse>()) {
            star.BeginAnimation(OpacityProperty, null);
            if (IsVisible && SystemParameters.ClientAreaAnimation) star.BeginAnimation(OpacityProperty, new DoubleAnimation(.12, .7, TimeSpan.FromSeconds(3 + animationRandom.NextDouble() * 9)) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, BeginTime = TimeSpan.FromSeconds(animationRandom.NextDouble() * 3) });
        }
        foreach (var cloud in NebulaScene.Children.OfType<Ellipse>()) {
            cloud.BeginAnimation(OpacityProperty, null);
            if (cloud.RenderTransform is not TranslateTransform drift) continue;
            drift.BeginAnimation(TranslateTransform.XProperty, null); drift.BeginAnimation(TranslateTransform.YProperty, null);
            if (!IsVisible || !HomePanel.IsVisible || !SystemParameters.ClientAreaAnimation) continue;
            var period = TimeSpan.FromSeconds(10 + (int)cloud.Tag % 7);
            var delay = TimeSpan.FromSeconds((int)cloud.Tag % 9 * .4);
            drift.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(-9, 9, period) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, BeginTime = delay });
            drift.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(-8, 8, period) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, BeginTime = delay });
            cloud.BeginAnimation(OpacityProperty, new DoubleAnimation(.6, 1, period) { AutoReverse = true, RepeatBehavior = RepeatBehavior.Forever, BeginTime = delay });
        }
    }
}
