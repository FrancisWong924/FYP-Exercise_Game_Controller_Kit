#nullable enable

using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace BleServer;

public partial class HexColorPicker : UserControl
{
    public static readonly DependencyProperty HexValueProperty =
        DependencyProperty.Register(
            nameof(HexValue),
            typeof(string),
            typeof(HexColorPicker),
            new FrameworkPropertyMetadata(
                "",
                FrameworkPropertyMetadataOptions.BindsTwoWayByDefault,
                OnHexValueChanged));

    public string HexValue
    {
        get => (string)GetValue(HexValueProperty);
        set => SetValue(HexValueProperty, value);
    }

    public event EventHandler? HexValueChanged;

    public HexColorPicker()
    {
        InitializeComponent();
        UpdateSwatch();
    }

    static void OnHexValueChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        var picker = (HexColorPicker)d;
        picker.SyncHexDisplay();
        picker.UpdateSwatch();
        picker.HexValueChanged?.Invoke(picker, EventArgs.Empty);
    }

    void SyncHexDisplay()
    {
        if (HexDisplay == null)
            return;
        HexDisplay.Text = HexValue ?? "";
    }

    void UpdateSwatch()
    {
        if (Swatch == null)
            return;
        var parsed = TryParseArgb(HexValue);
        Swatch.Background = parsed.HasValue
            ? new SolidColorBrush(parsed.Value)
            : new SolidColorBrush(Color.FromArgb(0xFF, 0x80, 0x80, 0x80));
    }

    void PickColor_OnClick(object sender, RoutedEventArgs e)
    {
        var owner = Window.GetWindow(this);
        var dlg = new HexColorPickerDialog(HexValue, owner);
        if (dlg.ShowDialog() != true)
            return;

        HexValue = dlg.SelectedHex;
    }

    public static string FormatArgbHex(byte a, byte r, byte g, byte b) =>
        $"{a:X2}{r:X2}{g:X2}{b:X2}";

    public static Color? TryParseArgb(string? hex)
    {
        if (string.IsNullOrWhiteSpace(hex))
            return null;

        var s = hex.Trim();
        var hasHashPrefix = s.StartsWith("#", StringComparison.Ordinal);
        if (hasHashPrefix)
            s = s[1..];

        if (s.Length == 6)
            s = "FF" + s;
        else if (s.Length == 8 && hasHashPrefix)
            s = s[6..] + s[..6];

        if (s.Length != 8 ||
            !uint.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var raw))
            return null;

        return Color.FromArgb(
            (byte)((raw >> 24) & 0xFF),
            (byte)((raw >> 16) & 0xFF),
            (byte)((raw >> 8) & 0xFF),
            (byte)(raw & 0xFF));
    }
}
