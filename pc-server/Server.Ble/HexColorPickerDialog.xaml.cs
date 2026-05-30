#nullable enable

using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace BleServer;

public partial class HexColorPickerDialog : Window
{
    const double SatValWidth = 260;
    const double SatValHeight = 200;
    const double HueHeight = 200;
    const double AlphaWidth = 284;

    double _hue;
    double _saturation;
    double _value;
    byte _alpha;
    bool _draggingSatVal;
    bool _draggingHue;
    bool _draggingAlpha;

    public string SelectedHex { get; private set; } = "";

    public HexColorPickerDialog(string? initialHex, Window? owner)
    {
        InitializeComponent();
        Owner = owner;

        var initial = HexColorPicker.TryParseArgb(initialHex) ?? Color.FromArgb(0xFF, 0xFF, 0xFF, 0xFF);
        _alpha = initial.A;
        (_hue, _saturation, _value) = RgbToHsv(initial);
        UpdateUi();
    }

    void UpdateUi()
    {
        var color = HsvToRgb(_hue, _saturation, _value, _alpha);
        var opaque = HsvToRgb(_hue, _saturation, _value, 0xFF);

        HueBaseFill.Fill = new SolidColorBrush(HsvToRgb(_hue, 1, 1, 0xFF));
        AlphaGradientFill.Fill = new LinearGradientBrush(
            Color.FromArgb(0, opaque.R, opaque.G, opaque.B),
            opaque,
            new Point(0, 0.5),
            new Point(1, 0.5));

        PreviewSwatch.Background = new SolidColorBrush(color);
        SelectedHex = HexColorPicker.FormatArgbHex(color.A, color.R, color.G, color.B);
        HexLabel.Text = SelectedHex;

        SatValMarker.Margin = new Thickness(
            _saturation * SatValWidth - SatValMarker.Width / 2,
            (1 - _value) * SatValHeight - SatValMarker.Height / 2,
            0,
            0);

        HueMarker.Margin = new Thickness(0, _hue / 360 * HueHeight - HueMarker.Height / 2, 0, 0);

        AlphaMarker.Margin = new Thickness(
            _alpha / 255.0 * AlphaWidth - AlphaMarker.Width / 2,
            0,
            0,
            0);
    }

    void SatValHitSurface_OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        _draggingSatVal = true;
        SatValHitSurface.CaptureMouse();
        ApplySatValFromPoint(e.GetPosition(SatValHitSurface));
        e.Handled = true;
    }

    void SatValHitSurface_OnMouseMove(object sender, MouseEventArgs e)
    {
        if (!_draggingSatVal)
            return;
        ApplySatValFromPoint(e.GetPosition(SatValHitSurface));
        e.Handled = true;
    }

    void SatValHitSurface_OnMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        EndSatValDrag();
        e.Handled = true;
    }

    void ApplySatValFromPoint(Point p)
    {
        _saturation = Clamp01(p.X / SatValWidth);
        _value = Clamp01(1 - p.Y / SatValHeight);
        UpdateUi();
    }

    void HueHitSurface_OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        _draggingHue = true;
        HueHitSurface.CaptureMouse();
        ApplyHueFromPoint(e.GetPosition(HueHitSurface));
        e.Handled = true;
    }

    void HueHitSurface_OnMouseMove(object sender, MouseEventArgs e)
    {
        if (!_draggingHue)
            return;
        ApplyHueFromPoint(e.GetPosition(HueHitSurface));
        e.Handled = true;
    }

    void HueHitSurface_OnMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        EndHueDrag();
        e.Handled = true;
    }

    void ApplyHueFromPoint(Point p)
    {
        _hue = Clamp01(p.Y / HueHeight) * 360;
        UpdateUi();
    }

    void AlphaHitSurface_OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        _draggingAlpha = true;
        AlphaHitSurface.CaptureMouse();
        ApplyAlphaFromPoint(e.GetPosition(AlphaHitSurface));
        e.Handled = true;
    }

    void AlphaHitSurface_OnMouseMove(object sender, MouseEventArgs e)
    {
        if (!_draggingAlpha)
            return;
        ApplyAlphaFromPoint(e.GetPosition(AlphaHitSurface));
        e.Handled = true;
    }

    void AlphaHitSurface_OnMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        EndAlphaDrag();
        e.Handled = true;
    }

    void ApplyAlphaFromPoint(Point p)
    {
        _alpha = (byte)Math.Round(Clamp01(p.X / AlphaWidth) * 255);
        UpdateUi();
    }

    void Window_OnPreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        EndSatValDrag();
        EndHueDrag();
        EndAlphaDrag();
    }

    void EndSatValDrag()
    {
        if (!_draggingSatVal)
            return;
        _draggingSatVal = false;
        if (SatValHitSurface.IsMouseCaptured)
            SatValHitSurface.ReleaseMouseCapture();
    }

    void EndHueDrag()
    {
        if (!_draggingHue)
            return;
        _draggingHue = false;
        if (HueHitSurface.IsMouseCaptured)
            HueHitSurface.ReleaseMouseCapture();
    }

    void EndAlphaDrag()
    {
        if (!_draggingAlpha)
            return;
        _draggingAlpha = false;
        if (AlphaHitSurface.IsMouseCaptured)
            AlphaHitSurface.ReleaseMouseCapture();
    }

    void Ok_OnClick(object sender, RoutedEventArgs e)
    {
        DialogResult = true;
        Close();
    }

    static double Clamp01(double v) => Math.Clamp(v, 0, 1);

    static Color HsvToRgb(double h, double s, double v, byte a)
    {
        h = ((h % 360) + 360) % 360;
        if (s <= 0.0001)
        {
            var gray = (byte)Math.Round(v * 255);
            return Color.FromArgb(a, gray, gray, gray);
        }

        var hi = (int)(h / 60) % 6;
        var f = h / 60 - Math.Floor(h / 60);
        var p = v * (1 - s);
        var q = v * (1 - f * s);
        var t = v * (1 - (1 - f) * s);

        double r, g, b;
        switch (hi)
        {
            case 0: r = v; g = t; b = p; break;
            case 1: r = q; g = v; b = p; break;
            case 2: r = p; g = v; b = t; break;
            case 3: r = p; g = q; b = v; break;
            case 4: r = t; g = p; b = v; break;
            default: r = v; g = p; b = q; break;
        }

        return Color.FromArgb(a, (byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));
    }

    static (double h, double s, double v) RgbToHsv(Color c)
    {
        var r = c.R / 255.0;
        var g = c.G / 255.0;
        var b = c.B / 255.0;
        var max = Math.Max(r, Math.Max(g, b));
        var min = Math.Min(r, Math.Min(g, b));
        var v = max;
        var delta = max - min;
        var s = max <= 0 ? 0 : delta / max;

        if (delta <= 0.0001)
            return (0, s, v);

        double h;
        if (max == r)
            h = 60 * (((g - b) / delta) % 6);
        else if (max == g)
            h = 60 * (((b - r) / delta) + 2);
        else
            h = 60 * (((r - g) / delta) + 4);

        if (h < 0)
            h += 360;

        return (h, s, v);
    }
}
