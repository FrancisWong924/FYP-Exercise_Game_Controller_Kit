#nullable enable

using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Collections.Specialized;
using System.ComponentModel;
using System.IO;
using System.Net.Http;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using Microsoft.Win32;

namespace BleServer;

public partial class LayoutCreatorWindow : Window
{
    /// <summary>Logical width of the preview canvas; scales element sizes like Flutter density.</summary>
    const double PhoneRefWidth = 780.0;
    const double ResizeHitLogical = 36.0;
    const double JoystickMinRadius = 40.0;
    const double ButtonSquareMinSize = 40.0;
    const double ButtonRectMinWidth = 24.0;
    const double ButtonRectMinHeight = 24.0;
    static readonly HttpClient Http = new();
    readonly ObservableCollection<LayoutElementModel> _elements = new();
    bool _suppressTypeCombo;
    string? _lastBackgroundImageRaw;
    ImageBrush? _cachedBackgroundImageBrush;
    string? _uploadedBackgroundImageDataUri;
    string? _uploadedBackgroundImageDisplayName;
    bool _suppressBackgroundImageInputEvents;
    const double PreviewDragActivateDistance = 4.0;
    bool _isPreviewDragging;
    bool _isPreviewResizing;
    bool _previewDragArmed;
    bool _previewResizeArmed;
    LayoutElementModel? _previewDragElement;
    LayoutElementModel? _previewResizeElement;
    Point _previewPressCanvasPoint;
    LayoutElementModel? _selectedElement;

    /// <summary>Joystick <c>joystickType</c> values accepted by the Flutter controller (dropdown only).</summary>
    public IReadOnlyList<string> JoystickSideOptions { get; } = new[] { "left", "right" };

    public Array ButtonShapeOptions { get; } = Enum.GetValues(typeof(LayoutButtonShape));

    /// <summary>Joystick index values for <c>tiltTarget</c> / <c>stepTarget</c> (matches Flutter <c>ControllerId</c>).</summary>
    public IReadOnlyList<string> TiltTargetOptions { get; } = new[] { "LEFT JOYSTICK", "RIGHT JOYSTICK" };

    public IReadOnlyList<StepTargetOption> StepTargetOptions { get; } = CreateStepTargetOptions();

    /// <summary>buttonId choices <c>1 &lt;&lt; 0</c> … <c>1 &lt;&lt; 15</c> for the layout editor.</summary>
    public IReadOnlyList<ButtonIdMaskOption> ButtonIdMaskOptions { get; } = CreateButtonIdMaskOptions();

    static string ButtonIdMaskDisplayName(int i) => i switch
    {
        0 => $"1 << {i} (arrow up)",
        1 => $"1 << {i} (arrow down)",
        2 => $"1 << {i} (arrow left)",
        3 => $"1 << {i} (arrow right)",
        6 => $"1 << {i} (LS)",
        7 => $"1 << {i} (RS)",
        8 => $"1 << {i} (LB)",
        9 => $"1 << {i} (RB)",
        10 => $"1 << {i} (LT)",
        11 => $"1 << {i} (RT)",
        12 => $"1 << {i} (A)",
        13 => $"1 << {i} (B)",
        14 => $"1 << {i} (X)",
        15 => $"1 << {i} (Y)",
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

    static StepTargetOption[] CreateStepTargetOptions()
    {
        var options = new List<StepTargetOption>
        {
            new() { DisplayName = "LEFT JOYSTICK (LY)", StepTarget = 0, StepButtonBitmask = 0 },
            new() { DisplayName = "RIGHT JOYSTICK (RY)", StepTarget = 1, StepButtonBitmask = 0 },
        };
        ReadOnlySpan<string> buttons = ["UP", "DOWN", "LEFT", "RIGHT", "START", "BACK", "LS", "RS", "LB", "RB", "LT", "RT", "A", "B", "X", "Y"];
        for (var i = 0; i < buttons.Length; i++)
            options.Add(new() { DisplayName = buttons[i], StepTarget = 0, StepButtonBitmask = 1 << i });
        return options.ToArray();
    }

    public LayoutCreatorWindow()
    {
        InitializeComponent();
        LayoutBackgroundColorPicker.HexValueChanged += LayoutBackgroundColorPicker_OnHexValueChanged;
        TypeCombo.ItemsSource = Enum.GetValues(typeof(LayoutElementKind));
        TiltTargetCombo.ItemsSource = TiltTargetOptions;
        TiltTargetCombo.SelectedIndex = 1;
        StepTargetCombo.ItemsSource = StepTargetOptions;
        StepTargetCombo.DisplayMemberPath = "DisplayName";
        StepTargetCombo.SelectedIndex = 0;
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
        if (_elements.Count > 0)
            SetSelectedElement(_elements[0]);
        else
            SetSelectedElement(null);
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
        if (_isPreviewDragging && sender is LayoutElementModel &&
            (e.PropertyName == nameof(LayoutElementModel.X) || e.PropertyName == nameof(LayoutElementModel.Y)))
        {
            UpdatePreviewElementPosition((LayoutElementModel)sender);
            return;
        }

        if (_isPreviewResizing && sender is LayoutElementModel &&
            (e.PropertyName == nameof(LayoutElementModel.Size) ||
             e.PropertyName == nameof(LayoutElementModel.ButtonWidth) ||
             e.PropertyName == nameof(LayoutElementModel.ButtonHeight)))
        {
            return;
        }

        Dispatcher.BeginInvoke(RefreshPreview);
    }

    public List<string> SystemIconOptions { get; } = new() 
    { 
        "None", "square", "triangle", "circle", "cross", "arrow_up", "arrow_down", "arrow_left", "arrow_right" 
    };

    void RefreshPreview()
    {
        PreviewCanvas.Background = ToBrush(LayoutBackgroundColorPicker.HexValue, Color.FromArgb(0xFF, 0x1A, 0x1A, 0x1C));
        ApplyBackgroundImagePreview();
        PreviewCanvas.Children.Clear();
        var w = PreviewCanvas.Width;
        var h = PreviewCanvas.Height;
        var scale = w / PhoneRefWidth;
        var selected = _selectedElement;

        foreach (var el in _elements)
            PreviewCanvas.Children.Add(BuildPreviewElementHost(el, ReferenceEquals(el, selected), w, h, scale));
    }

    static (double hitW, double hitH) GetPreviewHitSize(LayoutElementModel el, double scale)
    {
        if (el.Type == LayoutElementKind.joystick)
        {
            var size = el.Size * scale;
            return (size * 2, size * 2);
        }

        if (el.Type == LayoutElementKind.button)
        {
            var (w, h) = el.GetButtonLayoutSize();
            return (w * scale, h * scale);
        }

        var s = el.Size * scale;
        return (s, s);
    }

    static (double faceW, double faceH, double visualScale) GetButtonPreviewMetrics(LayoutElementModel el, double scale)
    {
        var (w, h) = el.GetButtonLayoutSize();
        var faceW = w * scale;
        var faceH = h * scale;
        return (faceW, faceH, Math.Min(faceW, faceH));
    }

    static FrameworkElement CreateButtonFaceShape(
        LayoutElementModel el,
        double faceW,
        double faceH,
        Brush fill,
        Brush stroke,
        double opacity,
        bool hideDecoration)
    {
        if (el.ButtonShape == LayoutButtonShape.circle)
        {
            return new Ellipse
            {
                Width = faceW,
                Height = faceH,
                Fill = hideDecoration ? Brushes.Transparent : fill,
                Stroke = hideDecoration ? Brushes.Transparent : stroke,
                StrokeThickness = 2,
                Opacity = opacity
            };
        }

        var corner = Math.Min(faceW, faceH) * (el.ButtonShape == LayoutButtonShape.square ? 0.14 : 0.22);
        return new Border
        {
            Width = faceW,
            Height = faceH,
            CornerRadius = new CornerRadius(corner),
            Background = hideDecoration ? Brushes.Transparent : fill,
            BorderBrush = hideDecoration ? Brushes.Transparent : stroke,
            BorderThickness = new Thickness(2),
            Opacity = opacity
        };
    }

    void UpdatePreviewElementPosition(LayoutElementModel el)
    {
        var w = PreviewCanvas.Width;
        var h = PreviewCanvas.Height;
        var scale = w / PhoneRefWidth;
        var (hitW, hitH) = GetPreviewHitSize(el, scale);
        var cx = el.X * w;
        var cy = el.Y * h;

        foreach (UIElement child in PreviewCanvas.Children)
        {
            if (child is FrameworkElement fe && ReferenceEquals(fe.Tag, el))
            {
                Canvas.SetLeft(fe, cx - hitW / 2);
                Canvas.SetTop(fe, cy - hitH / 2);
                break;
            }
        }
    }

    Border BuildPreviewElementHost(LayoutElementModel el, bool isSelected, double canvasW, double canvasH, double scale)
    {
        var (hitW, hitH) = GetPreviewHitSize(el, scale);
        var cx = el.X * canvasW;
        var cy = el.Y * canvasH;
        var size = el.Size * scale;

        var fill = ToBrush(el.BackgroundColor, Color.FromArgb(0x33, 0xFF, 0xFF, 0xFF));
        var stroke = ToBrush(el.Color, Colors.White);
        var op = Math.Clamp(el.Opacity, 0, 1);

        var inner = new Canvas { Width = hitW, Height = hitH, IsHitTestVisible = false };
        var centerX = hitW / 2;
        var centerY = hitH / 2;

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
            Canvas.SetLeft(outer, centerX - size);
            Canvas.SetTop(outer, centerY - size);
            inner.Children.Add(outer);

            var knob = new Ellipse
            {
                Width = size * 0.55,
                Height = size * 0.55,
                Fill = stroke,
                Opacity = op * 0.95
            };
            Canvas.SetLeft(knob, centerX - size * 0.275);
            Canvas.SetTop(knob, centerY - size * 0.275);
            inner.Children.Add(knob);
        }
        else
        {
            string? imageInput = null;
            bool hasImage = el.Type == LayoutElementKind.button &&
                el.TryGetButtonImageForExport(out imageInput, out _) &&
                !string.IsNullOrEmpty(imageInput);

            bool hasSystemIcon = !string.IsNullOrEmpty(el.UseSystemIcon) && el.UseSystemIcon != "None";
            Brush iconBrush = Brushes.White;
            try
            {
                var color = (Color)ColorConverter.ConvertFromString("#" + el.Color);
                iconBrush = new SolidColorBrush(color);
            }
            catch { /* invalid hex */ }

            var (faceW, faceH, visualScale) = GetButtonPreviewMetrics(el, scale);
            var hideDecoration = hasImage;
            var buttonBorder = GetButtonFaceBorderBrush(el.BackgroundColor);
            var face = CreateButtonFaceShape(el, faceW, faceH, fill, buttonBorder, op, hideDecoration);
            Canvas.SetLeft(face, centerX - faceW / 2);
            Canvas.SetTop(face, centerY - faceH / 2);
            inner.Children.Add(face);

            if (hasSystemIcon && !hasImage)
            {
                if (SystemIconGeometries.TryGetValue(el.UseSystemIcon!, out var geom))
                {
                    var iconSize = visualScale * 0.5;
                    var iconPath = new System.Windows.Shapes.Path
                    {
                        Data = geom,
                        Stroke = iconBrush,
                        StrokeThickness = 2.5,
                        Stretch = Stretch.Uniform,
                        Width = iconSize,
                        Height = iconSize,
                        Opacity = op,
                        StrokeEndLineCap = PenLineCap.Round,
                        StrokeStartLineCap = PenLineCap.Round
                    };
                    Canvas.SetLeft(iconPath, centerX - iconSize / 2);
                    Canvas.SetTop(iconPath, centerY - iconSize / 2);
                    inner.Children.Add(iconPath);
                }
            }

            var label = new TextBlock
            {
                Text = string.IsNullOrEmpty(el.Label) ? el.Type.ToString() : el.Label,
                Foreground = iconBrush,
                FontSize = Math.Clamp(visualScale * 0.35, 10, 32),
                Opacity = op,
                Visibility = (hasImage || hasSystemIcon) ? Visibility.Collapsed : Visibility.Visible
            };
            label.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            Canvas.SetLeft(label, centerX - label.DesiredSize.Width / 2);
            Canvas.SetTop(label, centerY - label.DesiredSize.Height / 2);
            inner.Children.Add(label);

            if (hasImage)
            {
                var targetFace = face;
                var capturedBorder = buttonBorder;
                string capturedInput = imageInput!;
                _ = Task.Run(async () =>
                {
                    var brush = await CreateImageBrushAsync(capturedInput);
                    if (brush != null)
                    {
                        Dispatcher.Invoke(() =>
                        {
                            if (targetFace is Ellipse ellipse)
                                ellipse.Fill = brush;
                            else if (targetFace is Border border)
                                border.Background = brush;
                        });
                    }
                    else
                    {
                        Dispatcher.Invoke(() =>
                        {
                            if (targetFace is Ellipse ellipse)
                                ellipse.Stroke = capturedBorder;
                            else if (targetFace is Border border)
                                border.BorderBrush = capturedBorder;
                            label.Visibility = Visibility.Visible;
                        });
                    }
                });
            }
        }

        if (isSelected && (el.Type == LayoutElementKind.button || el.Type == LayoutElementKind.joystick))
        {
            const double grip = 10;
            var gripFill = new SolidColorBrush(Color.FromArgb(0xE6, 0x4F, 0xA3, 0xFF));
            var gripBorder = new SolidColorBrush(Color.FromArgb(0xFF, 0xF3, 0xF3, 0xF3));
            var resizeGrip = new Border
            {
                Width = grip,
                Height = grip,
                Background = gripFill,
                BorderBrush = gripBorder,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(2),
                Cursor = Cursors.SizeNWSE,
                IsHitTestVisible = false
            };
            Canvas.SetLeft(resizeGrip, hitW - grip);
            Canvas.SetTop(resizeGrip, hitH - grip);
            inner.Children.Add(resizeGrip);
        }

        var host = new Border
        {
            Tag = el,
            Width = hitW,
            Height = hitH,
            Background = Brushes.Transparent,
            BorderBrush = isSelected ? new SolidColorBrush(Color.FromArgb(0xE6, 0x4F, 0xA3, 0xFF)) : Brushes.Transparent,
            BorderThickness = new Thickness(2),
            Cursor = Cursors.Hand,
            Child = inner
        };
        Canvas.SetLeft(host, cx - hitW / 2);
        Canvas.SetTop(host, cy - hitH / 2);
        return host;
    }

    LayoutElementModel? HitTestPreviewElement(Point canvasPoint)
    {
        for (var i = PreviewCanvas.Children.Count - 1; i >= 0; i--)
        {
            if (PreviewCanvas.Children[i] is not FrameworkElement fe || fe.Tag is not LayoutElementModel el)
                continue;

            var left = Canvas.GetLeft(fe);
            var top = Canvas.GetTop(fe);
            if (double.IsNaN(left)) left = 0;
            if (double.IsNaN(top)) top = 0;
            var width = fe.ActualWidth > 0 ? fe.ActualWidth : fe.Width;
            var height = fe.ActualHeight > 0 ? fe.ActualHeight : fe.Height;
            if (canvasPoint.X >= left && canvasPoint.X <= left + width &&
                canvasPoint.Y >= top && canvasPoint.Y <= top + height)
                return el;
        }

        return null;
    }

    void SelectPreviewElement(LayoutElementModel el) => SetSelectedElement(el);

    void SetSelectedElement(LayoutElementModel? el)
    {
        _selectedElement = el;
        EditorPanel.DataContext = el;
        EditorPanel.Visibility = el == null ? Visibility.Collapsed : Visibility.Visible;
        NoSelectionHint.Visibility = el == null ? Visibility.Visible : Visibility.Collapsed;

        if (el != null)
        {
            _suppressTypeCombo = true;
            TypeCombo.SelectedItem = el.Type;
            _suppressTypeCombo = false;
            UpdateEditorFieldVisibility(el.Type);
        }

        if (!_isPreviewDragging && !_isPreviewResizing)
            RefreshPreview();
    }

    double GetPreviewScale() => PreviewCanvas.Width / PhoneRefWidth;

    static (double left, double top, double hitW, double hitH) GetPreviewHostBounds(
        LayoutElementModel el, double canvasW, double canvasH, double scale)
    {
        var (hitW, hitH) = GetPreviewHitSize(el, scale);
        var cx = el.X * canvasW;
        var cy = el.Y * canvasH;
        return (cx - hitW / 2, cy - hitH / 2, hitW, hitH);
    }

    static bool IsInResizeZone(LayoutElementModel el, Point canvasPoint, double canvasW, double canvasH, double scale)
    {
        if (el.Type is not (LayoutElementKind.button or LayoutElementKind.joystick))
            return false;

        var (left, top, hitW, hitH) = GetPreviewHostBounds(el, canvasW, canvasH, scale);
        var localX = canvasPoint.X - left;
        var localY = canvasPoint.Y - top;
        var resizeSize = ResizeHitLogical * scale;
        return localX >= hitW - resizeSize && localY >= hitH - resizeSize;
    }

    static void ApplyResizeFromCanvasPoint(
        LayoutElementModel el,
        Point canvasPoint,
        double canvasW,
        double canvasH,
        double scale,
        double gridSize)
    {
        var cx = el.X * canvasW;
        var cy = el.Y * canvasH;
        var logicalDx = Math.Max((canvasPoint.X - cx) / scale, 0);
        var logicalDy = Math.Max((canvasPoint.Y - cy) / scale, 0);

        if (el.Type == LayoutElementKind.joystick)
        {
            var next = Math.Max(Math.Max(logicalDx, logicalDy), JoystickMinRadius);
            el.Size = Math.Max(SnapToGrid(next, gridSize), JoystickMinRadius);
            return;
        }

        if (el.Type != LayoutElementKind.button)
            return;

        if (el.ButtonShape == LayoutButtonShape.rectangle)
        {
            var nextW = Math.Max(logicalDx * 2, ButtonRectMinWidth);
            var nextH = Math.Max(logicalDy * 2, ButtonRectMinHeight);
            el.ButtonWidth = Math.Max(SnapToGrid(nextW, gridSize), ButtonRectMinWidth);
            el.ButtonHeight = Math.Max(SnapToGrid(nextH, gridSize), ButtonRectMinHeight);
            return;
        }

        var nextSize = Math.Max(Math.Max(logicalDx, logicalDy) * 2, ButtonSquareMinSize);
        el.Size = Math.Max(SnapToGrid(nextSize, gridSize), ButtonSquareMinSize);
    }

    double GetResizeGridSize()
    {
        if (double.TryParse(ResizeGridSizeBox.Text, System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var grid) && grid >= 0)
            return grid;
        if (double.TryParse(ResizeGridSizeBox.Text, out grid) && grid >= 0)
            return grid;
        return 8;
    }

    static int GetJoystickTargetIndex(ComboBox combo) => combo.SelectedIndex <= 0 ? 0 : 1;

    int GetTiltTargetIndex() => GetJoystickTargetIndex(TiltTargetCombo);

    StepTargetOption GetSelectedStepTargetOption() =>
        StepTargetCombo.SelectedItem as StepTargetOption ?? StepTargetOptions[0];

    static double SnapToGrid(double value, double gridSize)
    {
        if (gridSize <= 0)
            return value;
        return Math.Round(value / gridSize) * gridSize;
    }

    void PreviewCanvas_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        var pos = e.GetPosition(PreviewCanvas);
        var hit = HitTestPreviewElement(pos);
        if (hit == null)
            return;

        SelectPreviewElement(hit);
        _previewPressCanvasPoint = pos;
        _previewDragArmed = false;
        _previewResizeArmed = false;

        var canvasW = PreviewCanvas.Width;
        var canvasH = PreviewCanvas.Height;
        var scale = GetPreviewScale();

        if (IsInResizeZone(hit, pos, canvasW, canvasH, scale))
        {
            _previewResizeArmed = true;
            _previewResizeElement = hit;
        }
        else
        {
            _previewDragArmed = true;
            _previewDragElement = hit;
        }

        PreviewCanvas.CaptureMouse();
        e.Handled = true;
    }

    void PreviewCanvas_OnMouseMove(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed)
            return;

        var pos = e.GetPosition(PreviewCanvas);
        var scale = GetPreviewScale();

        if (_previewResizeArmed && _previewResizeElement != null)
        {
            if (!_isPreviewResizing && !HasExceededDragThreshold(pos))
                return;

            _isPreviewResizing = true;
            PreviewCanvas.Cursor = Cursors.SizeNWSE;
            var canvasW = PreviewCanvas.Width;
            var canvasH = PreviewCanvas.Height;
            ApplyResizeFromCanvasPoint(
                _previewResizeElement,
                pos,
                canvasW,
                canvasH,
                scale,
                GetResizeGridSize());
            RefreshPreview();
            e.Handled = true;
            return;
        }

        if (!_previewDragArmed || _previewDragElement == null)
            return;

        if (!_isPreviewDragging && !HasExceededDragThreshold(pos))
            return;

        _isPreviewDragging = true;
        PreviewCanvas.Cursor = Cursors.SizeAll;
        SetNormalizedPositionFromCanvasPoint(_previewDragElement, pos);
        e.Handled = true;
    }

    bool HasExceededDragThreshold(Point currentCanvasPoint)
    {
        var dx = currentCanvasPoint.X - _previewPressCanvasPoint.X;
        var dy = currentCanvasPoint.Y - _previewPressCanvasPoint.Y;
        return dx * dx + dy * dy >= PreviewDragActivateDistance * PreviewDragActivateDistance;
    }

    void ClearPreviewPointerState()
    {
        _previewDragArmed = false;
        _previewResizeArmed = false;
        _previewDragElement = null;
        _previewResizeElement = null;
        if (PreviewCanvas.IsMouseCaptured)
            PreviewCanvas.ReleaseMouseCapture();
        PreviewCanvas.Cursor = Cursors.Arrow;
    }

    void PreviewCanvas_OnMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        EndPreviewDrag();
        EndPreviewResize();
        ClearPreviewPointerState();
        e.Handled = true;
    }

    void PreviewCanvas_OnMouseLeave(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed)
        {
            EndPreviewDrag();
            EndPreviewResize();
            ClearPreviewPointerState();
        }
    }

    void EndPreviewDrag()
    {
        if (!_isPreviewDragging)
            return;

        _isPreviewDragging = false;
        RefreshPreview();
    }

    void EndPreviewResize()
    {
        if (!_isPreviewResizing)
            return;

        _isPreviewResizing = false;
        RefreshPreview();
    }

    void SetNormalizedPositionFromCanvasPoint(LayoutElementModel el, Point canvasPoint)
    {
        var w = PreviewCanvas.Width;
        var h = PreviewCanvas.Height;
        if (w <= 0 || h <= 0)
            return;

        el.X = Math.Clamp(canvasPoint.X / w, 0, 1);
        el.Y = Math.Clamp(canvasPoint.Y / h, 0, 1);
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
        var c = HexColorPicker.TryParseArgb(hex);
        return new SolidColorBrush(c ?? fallback);
    }

    /// <summary>Matches Flutter <c>_buttonFaceDecoration</c>: border from backgroundColor, or white54 for default.</summary>
    static Brush GetButtonFaceBorderBrush(string? backgroundColor)
    {
        const string defaultBackground = "33FFFFFF";
        if (string.IsNullOrWhiteSpace(backgroundColor) ||
            string.Equals(backgroundColor.Trim(), defaultBackground, StringComparison.OrdinalIgnoreCase))
        {
            return new SolidColorBrush(Color.FromArgb(0x8A, 0xFF, 0xFF, 0xFF));
        }

        return ToBrush(backgroundColor, Color.FromArgb(0x8A, 0xFF, 0xFF, 0xFF));
    }

    void LayoutBackgroundColorPicker_OnHexValueChanged(object? sender, EventArgs e)
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

    void TypeCombo_OnSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_suppressTypeCombo || _selectedElement is not LayoutElementModel m)
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
        var added = LayoutElementModel.CreateButton(id);
        _elements.Add(added);
        SetSelectedElement(added);
    }

    void AddJoystick_OnClick(object sender, RoutedEventArgs e)
    {
        var id = $"joy_{Guid.NewGuid().ToString("N")[..6]}";
        var added = LayoutElementModel.CreateJoystick(id, "left");
        _elements.Add(added);
        SetSelectedElement(added);
    }

    void RemoveSelected_OnClick(object sender, RoutedEventArgs e) => RemoveSelectedElement();

    void RemoveSelectedElement()
    {
        if (_selectedElement is not LayoutElementModel m)
            return;
        _elements.Remove(m);
        SetSelectedElement(null);
    }

    void LayoutCreatorWindow_OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Back || _selectedElement is null)
            return;
        if (Keyboard.FocusedElement is TextBoxBase)
            return;

        e.Handled = true;
        RemoveSelectedElement();
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
            LayoutBackgroundColorPicker.HexValue,
            backgroundImage,
            GetTiltTargetIndex(),
            GetSelectedStepTargetOption().StepTarget,
            GetSelectedStepTargetOption().StepButtonBitmask);
        File.WriteAllText(dlg.FileName, json);
        MessageBox.Show(this, $"Saved to:\n{dlg.FileName}", "Export", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    async void SendLayoutToPhone_OnClick(object sender, RoutedEventArgs e)
    {
        if (!ValidateElementsForExport(_elements, out var err))
        {
            MessageBox.Show(this, err, "Cannot send layout", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        if (!TryGetBackgroundImageForExport(out var backgroundImage, out var backgroundErr))
        {
            MessageBox.Show(this, backgroundErr, "Cannot send layout", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        try
        {
            var exported = ControllerLayoutDocument.Serialize(
                _elements,
                LayoutNameBox.Text.Trim(),
                LayoutBackgroundColorPicker.HexValue,
                backgroundImage,
                GetTiltTargetIndex(),
                GetSelectedStepTargetOption().StepTarget,
                GetSelectedStepTargetOption().StepButtonBitmask);
            var wireJson = Program.BuildPhoneLayoutJsonFromExportedLayout(exported);
            var sent = await Program.TryBroadcastLayoutToPhonesAsync(wireJson);
            if (!sent)
            {
                MessageBox.Show(this,
                    "No phone is connected right now. Connect your device over Bluetooth to this PC server, then try again.",
                    "Send layout to phone",
                    MessageBoxButton.OK,
                    MessageBoxImage.Information);
                return;
            }

            MessageBox.Show(this,
                "Layout sent to connected phone(s).",
                "Send layout to phone",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Failed to send layout", MessageBoxButton.OK, MessageBoxImage.Error);
        }
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
        if (_selectedElement is not LayoutElementModel m || m.Type != LayoutElementKind.button)
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
        if (_selectedElement is not LayoutElementModel m || m.Type != LayoutElementKind.button)
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
