#nullable enable

using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Microsoft.Win32;

namespace BleServer;

public partial class LayoutCreatorWindow : Window
{
    /// <summary>Logical width of the preview canvas; scales element sizes like Flutter density.</summary>
    const double PhoneRefWidth = 780.0;
    static readonly HttpClient Http = new();
    readonly ObservableCollection<LayoutElementModel> _elements = new();
    bool _suppressTypeCombo;
    string? _lastBackgroundImageRaw;
    ImageBrush? _cachedBackgroundImageBrush;
    string? _uploadedBackgroundImageDataUri;
    string? _uploadedBackgroundImageDisplayName;
    bool _suppressBackgroundImageInputEvents;

    /// <summary>Joystick <c>joystickType</c> values accepted by the Flutter controller (dropdown only).</summary>
    public IReadOnlyList<string> JoystickSideOptions { get; } = new[] { "left", "right" };

    /// <summary>buttonId choices <c>1 &lt;&lt; 0</c> … <c>1 &lt;&lt; 15</c> for the layout editor.</summary>
    public IReadOnlyList<ButtonIdMaskOption> ButtonIdMaskOptions { get; } = CreateButtonIdMaskOptions();

    static string ButtonIdMaskDisplayName(int i) => i switch
    {
        0 => $"1 << {i} (arrow up)",
        1 => $"1 << {i} (arrow down)",
        2 => $"1 << {i} (arrow left)",
        3 => $"1 << {i} (arrow right)",
        12 => $"1 << {i} (cross / A)",
        13 => $"1 << {i} (circle / B)",
        14 => $"1 << {i} (square / X)",
        15 => $"1 << {i} (triangle / Y)",
        _ => $"1 << {i}"
    };

    private static readonly Dictionary<string, Geometry> SystemIconGeometries = new()
    {
        { "square", Geometry.Parse("M 0,0 H 28 V 28 H 0 Z") },
        { "triangle", Geometry.Parse("M 14,2 L 26,24 H 2 Z") },
        { "circle", new EllipseGeometry(new Point(14, 14), 12, 12) },
        { "cross", Geometry.Parse("M 7,7 L 21,21 M 7,21 L 21,7") },
        { "arrow_up",    Geometry.Parse("M 14,2 L 26,14 H 18 V 26 H 10 V 14 H 2 Z") },
        { "arrow_down",  Geometry.Parse("M 14,26 L 2,14 H 10 V 2 H 18 V 14 H 26 Z") },
        { "arrow_left",  Geometry.Parse("M 2,14 L 14,2 V 10 H 26 V 18 H 14 V 26 Z") },
        { "arrow_right", Geometry.Parse("M 26,14 L 14,2 V 10 H 2 V 18 H 14 V 26 Z") }
    };

    static ButtonIdMaskOption[] CreateButtonIdMaskOptions()
    {
        var opts = new ButtonIdMaskOption[16];
        for (var i = 0; i < 16; i++)
            opts[i] = new ButtonIdMaskOption { DisplayName = ButtonIdMaskDisplayName(i), Value = 1 << i };
        return opts;
    }

    public LayoutCreatorWindow()
    {
        InitializeComponent();
        TypeCombo.ItemsSource = Enum.GetValues(typeof(LayoutElementKind));
        ElementsList.ItemsSource = _elements;
        _elements.CollectionChanged += Elements_CollectionChanged;

        if (_elements.Count == 0)
        {
            var joy = LayoutElementModel.CreateJoystick("joy_l", "left");
            joy.X = 0.18;
            joy.Y = 0.55;
            var btn = LayoutElementModel.CreateButton("btn_a");
            btn.X = 0.82;
            btn.Y = 0.52;
            btn.Label = "cross";
            btn.ButtonId = null;
            btn.UseSystemIcon = null;
            _elements.Add(joy);
            _elements.Add(btn);
        }

        foreach (var m in _elements)
            HookModel(m);

        UpdateBackgroundImageSourceHint();
        RefreshPreview();
        if (ElementsList.SelectedItem is LayoutElementModel sel)
            UpdateEditorFieldVisibility(sel.Type);
        else if (_elements.Count > 0)
            UpdateEditorFieldVisibility(_elements[0].Type);
    }

    void Elements_CollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.NewItems != null)
        {
            foreach (LayoutElementModel m in e.NewItems)
                HookModel(m);
        }

        if (e.OldItems != null)
        {
            foreach (LayoutElementModel m in e.OldItems)
                UnhookModel(m);
        }

        RefreshPreview();
    }

    void HookModel(LayoutElementModel m)
    {
        m.PropertyChanged += Model_OnPropertyChanged;
    }

    void UnhookModel(LayoutElementModel m)
    {
        m.PropertyChanged -= Model_OnPropertyChanged;
    }

    void Model_OnPropertyChanged(object? sender, PropertyChangedEventArgs e)
    {
        Dispatcher.BeginInvoke(RefreshPreview);
    }

    public List<string> SystemIconOptions { get; } = new() 
    { 
        "None", "square", "triangle", "circle", "cross", "arrow_up", "arrow_down", "arrow_left", "arrow_right" 
    };

    void RefreshPreview()
    {
        PreviewCanvas.Background = ToBrush(LayoutBackgroundColorBox.Text, Color.FromArgb(0xFF, 0x1A, 0x1A, 0x1C));
        ApplyBackgroundImagePreview();
        PreviewCanvas.Children.Clear();
        var w = PreviewCanvas.Width;
        var h = PreviewCanvas.Height;
        var scale = w / PhoneRefWidth;

        foreach (var el in _elements)
        {
            var cx = el.X * w;
            var cy = el.Y * h;
            var size = el.Size * scale;

            var fill = ToBrush(el.BackgroundColor, Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF));
            var stroke = ToBrush(el.Color, Colors.White);
            var op = Math.Clamp(el.Opacity, 0, 1);

            if (el.Type == LayoutElementKind.joystick)
            {
                var outer = new Ellipse
                {
                    Width = size * 2,
                    Height = size * 2,
                    Fill = fill,
                    Stroke = stroke,
                    StrokeThickness = 2,
                    Opacity = op
                };
                Canvas.SetLeft(outer, cx - size);
                Canvas.SetTop(outer, cy - size);
                PreviewCanvas.Children.Add(outer);

                var knob = new Ellipse
                {
                    Width = size * 0.55,
                    Height = size * 0.55,
                    Fill = stroke,
                    Opacity = op * 0.95
                };
                Canvas.SetLeft(knob, cx - size * 0.275);
                Canvas.SetTop(knob, cy - size * 0.275);
                PreviewCanvas.Children.Add(knob);
            }
            else
            {
                string? imageInput = null;
                bool hasImage = el.Type == LayoutElementKind.button && 
                    el.TryGetButtonImageForExport(out imageInput, out _) && 
                    !string.IsNullOrEmpty(imageInput);

                bool hasSystemIcon = !string.IsNullOrEmpty(el.UseSystemIcon) && el.UseSystemIcon != "None";
                Brush iconBrush = Brushes.White; 
                try {
                    var color = (Color)ColorConverter.ConvertFromString("#" + el.Color);
                    iconBrush = new SolidColorBrush(color);
                } catch { /* Fallback to white if hex is invalid */ }

                var circle = new Ellipse
                {
                    Width = size,
                    Height = size,
                    Fill = hasImage ? Brushes.Transparent : fill,
                    Stroke = hasImage ? Brushes.Transparent : stroke,
                    StrokeThickness = 2,
                    Opacity = op
                };
                Canvas.SetLeft(circle, cx - size / 2);
                Canvas.SetTop(circle, cy - size / 2);
                PreviewCanvas.Children.Add(circle);

                if (hasSystemIcon && !hasImage)
                {
                    if (SystemIconGeometries.TryGetValue(el.UseSystemIcon!, out var geom))
                    {
                        var iconPath = new System.Windows.Shapes.Path
                        {
                            Data = geom,
                            Stroke = iconBrush, // Determine color from el.Color
                            StrokeThickness = 2.5,
                            Stretch = Stretch.Uniform,
                            Width = size * 0.5,
                            Height = size * 0.5,
                            Opacity = op,
                            StrokeEndLineCap = PenLineCap.Round,
                            StrokeStartLineCap = PenLineCap.Round
                        };
                        
                        // Center the icon in the button
                        Canvas.SetLeft(iconPath, cx - (size * 0.5) / 2);
                        Canvas.SetTop(iconPath, cy - (size * 0.5) / 2);
                        PreviewCanvas.Children.Add(iconPath);
                    }
                }

                var label = new TextBlock
                {
                    Text = string.IsNullOrEmpty(el.Label) ? el.Type.ToString() : el.Label,
                    Foreground = iconBrush,
                    FontSize = Math.Clamp(size * 0.35, 10, 32),
                    Opacity = op,
                    Visibility = (hasImage || hasSystemIcon) ? Visibility.Collapsed : Visibility.Visible
                };
                label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
                Canvas.SetLeft(label, cx - label.DesiredSize.Width / 2);
                Canvas.SetTop(label, cy - label.DesiredSize.Height / 2);
                PreviewCanvas.Children.Add(label);

                if (hasImage)
                {
                    var targetCircle = circle;
                    string capturedInput = imageInput!;
                    _ = Task.Run(async () =>
                    {
                        var brush = await CreateImageBrushAsync(capturedInput);
                        if (brush != null)
                        {
                            Dispatcher.Invoke(() => targetCircle.Fill = brush);
                        }
                        else
                        {
                            // FALLBACK: If the image failed to load, show the label and border again
                            Dispatcher.Invoke(() => {
                                targetCircle.Stroke = stroke;
                                label.Visibility = Visibility.Visible;
                            });
                        }
                    });
                }
            }
        }
    }

    private void ComboBox_PreviewMouseWheel(object sender, System.Windows.Input.MouseWheelEventArgs e)
    {
        // If the ComboBox is not open, ignore the scroll event so it doesn't change the value.
        // This allows the user to still scroll the Sidebar's ScrollViewer instead.
        if (sender is ComboBox comboBox && !comboBox.IsDropDownOpen)
        {
            e.Handled = true;

            // Optional: Forward the scroll event to the parent ScrollViewer 
            // so the sidebar still scrolls even if the mouse is over the ComboBox.
            var eventArg = new System.Windows.Input.MouseWheelEventArgs(e.MouseDevice, e.Timestamp, e.Delta)
            {
                RoutedEvent = UIElement.MouseWheelEvent,
                Source = sender
            };
            var parent = VisualTreeHelper.GetParent(comboBox) as UIElement;
            parent?.RaiseEvent(eventArg);
        }
    }

    void ApplyBackgroundImagePreview()
    {
        var raw = GetEffectiveBackgroundImageInput();
        if (string.IsNullOrWhiteSpace(raw))
        {
            _lastBackgroundImageRaw = null;
            _cachedBackgroundImageBrush = null;
            return;
        }

        if (string.Equals(raw, _lastBackgroundImageRaw, StringComparison.Ordinal))
        {
            if (_cachedBackgroundImageBrush != null)
                PreviewCanvas.Background = _cachedBackgroundImageBrush;
            return;
        }

        _lastBackgroundImageRaw = raw;
        _cachedBackgroundImageBrush = null;
        _ = LoadBackgroundImageBrushAsync(raw);
    }

    async Task LoadBackgroundImageBrushAsync(string rawInput)
    {
        try
        {
            var brush = await CreateImageBrushAsync(rawInput);
            if (!string.Equals(GetEffectiveBackgroundImageInput(), rawInput, StringComparison.Ordinal))
                return;
            if (brush == null)
                return;
            _cachedBackgroundImageBrush = brush;
            PreviewCanvas.Background = brush;
        }
        catch
        {
            // Keep color-only preview when image input cannot be decoded.
        }
    }

    static async Task<ImageBrush?> CreateImageBrushAsync(string imageInput)
    {
        var bytes = await ResolveImageBytesAsync(imageInput);
        if (bytes == null || bytes.Length == 0)
            return null;

        using var stream = new MemoryStream(bytes);
        var bitmap = new BitmapImage();
        bitmap.BeginInit();
        bitmap.CacheOption = BitmapCacheOption.OnLoad;
        bitmap.StreamSource = stream;
        bitmap.EndInit();
        bitmap.Freeze();

        var brush = new ImageBrush(bitmap)
        {
            Stretch = Stretch.UniformToFill,
            AlignmentX = AlignmentX.Center,
            AlignmentY = AlignmentY.Center
        };
        brush.Freeze();
        return brush;
    }

    static async Task<byte[]?> ResolveImageBytesAsync(string imageInput)
    {
        var value = imageInput.Trim();
        if (value.StartsWith("data:image/", StringComparison.OrdinalIgnoreCase))
        {
            var commaIndex = value.IndexOf(',');
            if (commaIndex <= 0)
                return null;
            var metadata = value[..commaIndex];
            if (!metadata.Contains(";base64", StringComparison.OrdinalIgnoreCase))
                return null;
            var encoded = value[(commaIndex + 1)..];
            try
            {
                return Convert.FromBase64String(encoded.Trim());
            }
            catch
            {
                return null;
            }
        }

        if (Uri.TryCreate(value, UriKind.Absolute, out var uri)
            && (uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps))
        {
            return await Http.GetByteArrayAsync(uri);
        }

        return null;
    }

    static Brush ToBrush(string? hex, Color fallback)
    {
        var c = ParseArgb(hex);
        return new SolidColorBrush(c ?? fallback);
    }

    static Color? ParseArgb(string? hex)
    {
        if (string.IsNullOrWhiteSpace(hex)) return null;
        var s = hex.Trim();
        var hasHashPrefix = s.StartsWith("#", StringComparison.Ordinal);
        if (hasHashPrefix)
            s = s[1..];
        if (s.Length == 6)
            s = "FF" + s;
        else if (s.Length == 8 && hasHashPrefix)
        {
            // Accept web-style #RRGGBBAA by converting to ARGB.
            s = s[6..] + s[..6];
        }
        if (s.Length != 8 || !uint.TryParse(s, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var raw))
            return null;

        var a = (byte)((raw >> 24) & 0xFF);
        var r = (byte)((raw >> 16) & 0xFF);
        var g = (byte)((raw >> 8) & 0xFF);
        var b = (byte)(raw & 0xFF);
        return Color.FromArgb(a, r, g, b);
    }

    void LayoutBackgroundColorBox_OnTextChanged(object sender, TextChangedEventArgs e)
    {
        RefreshPreview();
    }

    void LayoutBackgroundImageBox_OnTextChanged(object sender, TextChangedEventArgs e)
    {
        if (_suppressBackgroundImageInputEvents)
            return;

        if (!string.IsNullOrWhiteSpace(LayoutBackgroundImageBox.Text))
        {
            _uploadedBackgroundImageDataUri = null;
            _uploadedBackgroundImageDisplayName = null;
        }
        UpdateBackgroundImageSourceHint();
        RefreshPreview();
    }

    void ElementsList_OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ElementsList.SelectedItem is not LayoutElementModel m)
            return;

        _suppressTypeCombo = true;
        TypeCombo.SelectedItem = m.Type;
        _suppressTypeCombo = false;
        UpdateEditorFieldVisibility(m.Type);
    }

    void TypeCombo_OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressTypeCombo || ElementsList.SelectedItem is not LayoutElementModel m)
            return;
        if (TypeCombo.SelectedItem is not LayoutElementKind kind)
            return;
        m.Type = kind;
        ApplyTypeSpecificDefaults(m);
        UpdateEditorFieldVisibility(kind);
    }

    static void ApplyTypeSpecificDefaults(LayoutElementModel m)
    {
        if (m.Type == LayoutElementKind.joystick)
        {
            m.ClearButtonImageForEditor();
            m.UseSystemIcon = null;
            if (string.IsNullOrWhiteSpace(m.JoystickType))
                m.JoystickType = "left";
        }
        else if (m.Type == LayoutElementKind.button)
        {
            m.JoystickType = null;
        }
    }

    void UpdateEditorFieldVisibility(LayoutElementKind kind)
    {
        JoystickFieldsPanel.Visibility = kind == LayoutElementKind.joystick ? Visibility.Visible : Visibility.Collapsed;
        ButtonFieldsPanel.Visibility = kind == LayoutElementKind.joystick ? Visibility.Collapsed : Visibility.Visible;
    }

    void AddButton_OnClick(object sender, RoutedEventArgs e)
    {
        var id = $"btn_{Guid.NewGuid().ToString("N")[..6]}";
        _elements.Add(LayoutElementModel.CreateButton(id));
        ElementsList.SelectedIndex = _elements.Count - 1;
    }

    void AddJoystick_OnClick(object sender, RoutedEventArgs e)
    {
        var id = $"joy_{Guid.NewGuid().ToString("N")[..6]}";
        _elements.Add(LayoutElementModel.CreateJoystick(id, "left"));
        ElementsList.SelectedIndex = _elements.Count - 1;
    }

    void RemoveSelected_OnClick(object sender, RoutedEventArgs e)
    {
        if (ElementsList.SelectedItem is not LayoutElementModel m)
            return;
        _elements.Remove(m);
    }

    void ExportJson_OnClick(object sender, RoutedEventArgs e)
    {
        if (!ValidateElementsForExport(_elements, out var err))
        {
            MessageBox.Show(this, err, "Cannot export", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        if (!TryGetBackgroundImageForExport(out var backgroundImage, out var backgroundErr))
        {
            MessageBox.Show(this, backgroundErr, "Cannot export", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var dlg = new SaveFileDialog
        {
            Filter = "JSON (*.json)|*.json|All files (*.*)|*.*",
            FileName = $"{SanitizeFileName(LayoutNameBox.Text)}.json"
        };
        if (dlg.ShowDialog(this) != true)
            return;

        var json = ControllerLayoutDocument.Serialize(
            _elements,
            LayoutNameBox.Text.Trim(),
            LayoutBackgroundColorBox.Text,
            backgroundImage);
        File.WriteAllText(dlg.FileName, json);
        MessageBox.Show(this, $"Saved to:\n{dlg.FileName}", "Export", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    void PickBackgroundImage_OnClick(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog
        {
            Filter = "Image files (*.png;*.jpg;*.jpeg)|*.png;*.jpg;*.jpeg",
            CheckFileExists = true,
            Multiselect = false,
            Title = "Select a background image"
        };
        if (dlg.ShowDialog(this) != true)
            return;

        var mime = GetMimeTypeFromExtension(System.IO.Path.GetExtension(dlg.FileName));
        if (mime == null)
        {
            MessageBox.Show(this, "Only PNG and JPG images are supported.", "Unsupported format", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        try
        {
            var bytes = File.ReadAllBytes(dlg.FileName);
            var encoded = Convert.ToBase64String(bytes);
            _uploadedBackgroundImageDataUri = $"data:{mime};base64,{encoded}";
            _uploadedBackgroundImageDisplayName = System.IO.Path.GetFileName(dlg.FileName);
            _suppressBackgroundImageInputEvents = true;
            LayoutBackgroundImageBox.Text = _uploadedBackgroundImageDataUri;
            _suppressBackgroundImageInputEvents = false;
            UpdateBackgroundImageSourceHint();
            RefreshPreview();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"Failed to read image:\n{ex.Message}", "Upload failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    void ClearBackgroundImage_OnClick(object sender, RoutedEventArgs e)
    {
        _uploadedBackgroundImageDataUri = null;
        _uploadedBackgroundImageDisplayName = null;
        _lastBackgroundImageRaw = null;
        _cachedBackgroundImageBrush = null;

        _suppressBackgroundImageInputEvents = true;
        LayoutBackgroundImageBox.Text = "";
        _suppressBackgroundImageInputEvents = false;

        UpdateBackgroundImageSourceHint();
        RefreshPreview();
    }

    void PickSelectedButtonImage_OnClick(object sender, RoutedEventArgs e)
    {
        if (ElementsList.SelectedItem is not LayoutElementModel m || m.Type != LayoutElementKind.button)
            return;

        var dlg = new OpenFileDialog
        {
            Filter = "Image files (*.png;*.jpg;*.jpeg)|*.png;*.jpg;*.jpeg",
            CheckFileExists = true,
            Multiselect = false,
            Title = "Select a button image"
        };
        if (dlg.ShowDialog(this) != true)
            return;

        var mime = GetMimeTypeFromExtension(System.IO.Path.GetExtension(dlg.FileName));
        if (mime == null)
        {
            MessageBox.Show(this, "Only PNG and JPG images are supported.", "Unsupported format", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        try
        {
            var bytes = File.ReadAllBytes(dlg.FileName);
            var encoded = Convert.ToBase64String(bytes);
            string dataUri = $"data:{mime};base64,{encoded}";
            m.ApplyUploadedButtonImage(dataUri, System.IO.Path.GetFileName(dlg.FileName));
            RefreshPreview();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, $"Failed to read image:\n{ex.Message}", "Upload failed", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    void ClearSelectedButtonImage_OnClick(object sender, RoutedEventArgs e)
    {
        if (ElementsList.SelectedItem is not LayoutElementModel m || m.Type != LayoutElementKind.button)
            return;
        m.ClearButtonImageForEditor();
        RefreshPreview();
    }

    static string? GetMimeTypeFromExtension(string extension)
    {
        return extension.ToLowerInvariant() switch
        {
            ".png" => "image/png",
            ".jpg" => "image/jpeg",
            ".jpeg" => "image/jpeg",
            _ => null
        };
    }

    string? GetEffectiveBackgroundImageInput()
    {
        if (!string.IsNullOrEmpty(_uploadedBackgroundImageDataUri))
        {
            return _uploadedBackgroundImageDataUri;
        }
        var text = LayoutBackgroundImageBox.Text?.Trim();
        if (!string.IsNullOrEmpty(text))
        {
            if (LayoutElementModel.IsAbsoluteHttpUrl(text))
                return text;
            return null;
        }
        return null;
    }

    bool TryGetBackgroundImageForExport(out string? backgroundImage, out string error)
    {
        var text = LayoutBackgroundImageBox.Text?.Trim();
        if (!string.IsNullOrEmpty(text))
        {
            if (!LayoutElementModel.IsAbsoluteHttpUrl(text))
            {
                backgroundImage = null;
                error = "backgroundImage must be a valid http/https URL when typed in the field.";
                return false;
            }

            backgroundImage = text;
            error = "";
            return true;
        }

        backgroundImage = _uploadedBackgroundImageDataUri;
        error = "";
        return true;
    }

    void UpdateBackgroundImageSourceHint()
    {
        var text = LayoutBackgroundImageBox.Text?.Trim();
        if (!string.IsNullOrEmpty(_uploadedBackgroundImageDisplayName))
        {
            BackgroundImageSourceHint.Text = $"Using uploaded file: {_uploadedBackgroundImageDisplayName}";
            return;
        }
        if (!string.IsNullOrEmpty(text))
        {
            BackgroundImageSourceHint.Text = LayoutElementModel.IsAbsoluteHttpUrl(text)
                ? "Using URL from field."
                : "Enter a valid http/https image URL, or click Clear and use Upload...";
            return;
        }

        BackgroundImageSourceHint.Text = "No background image selected.";
    }

    static string SanitizeFileName(string name)
    {
        foreach (var c in System.IO.Path.GetInvalidFileNameChars())
            name = name.Replace(c, '_');
        return string.IsNullOrWhiteSpace(name) ? "layout" : name.Trim();
    }

    /// <summary>
    /// UI constrains joystick side to a dropdown; this still guards export if types are edited elsewhere.
    /// Other fields are not validated here.
    /// </summary>
    static bool ValidateElementsForExport(IEnumerable<LayoutElementModel> elements, out string error)
    {
        foreach (var el in elements)
        {
            if (string.IsNullOrWhiteSpace(el.Id))
            {
                error = "All elements must have an 'Id'.";
                return false;
            }
            if (string.IsNullOrWhiteSpace(el.Label))
            {
                error = $"Element '{el.Id}' must have a 'Label'.";
                return false;
            }
            if (string.IsNullOrWhiteSpace(el.BackgroundColor))
            {
                error = $"Element '{el.Id}' must have a 'backgroundColor'.";
                return false;
            }
            if (string.IsNullOrWhiteSpace(el.Color))
            {
                error = $"Element '{el.Id}' must have a 'color'.";
                return false;
            }
            if (el.Type == LayoutElementKind.joystick)
            {
                var jt = el.JoystickType?.Trim().ToLowerInvariant();
                if (jt is not ("left" or "right"))
                {
                    error = $"Joystick \"{el.Id}\" must have joystickType \"left\" or \"right\".";
                    return false;
                }
            }
            else if (el.Type == LayoutElementKind.button)
            {
                if (el.ButtonId == 0 || el.ButtonId == null)
                {
                    error = $"Button \"{el.Id}\" must have a 'buttonId' selected.";
                    return false;
                }
                if (!el.TryGetButtonImageForExport(out _, out var imgErr))
                {
                    error = imgErr ?? "Invalid button image.";
                    return false;
                }
            }
        }

        error = "";
        return true;
    }
}
