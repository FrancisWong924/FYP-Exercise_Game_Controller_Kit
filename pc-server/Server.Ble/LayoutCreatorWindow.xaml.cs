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
using System.Text.Json;
using Microsoft.Win32;

namespace BleServer;

public partial class LayoutCreatorWindow : Window
{
    /// <summary>Logical width of the preview canvas; scales element sizes like Flutter density.</summary>
    const double PhoneRefWidth = 780.0;
    const double ResizeHitMaxLogical = 36.0;
    const double ResizeHitFraction = 0.35;
    const double ResizeGripVisual = 10.0;
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
    ResizeCorner _previewResizeCorner;
    Point _resizeAnchorCanvas;
    Point _previewPressCanvasPoint;
    LayoutElementModel? _selectedElement;

    /// <summary>Joystick <c>joystickType</c> values accepted by the Flutter controller (dropdown only).</summary>
    public IReadOnlyList<JoystickSideOption> JoystickSideOptions { get; } = new[]
    {
        new JoystickSideOption { DisplayName = "LEFT JOYSTICK", Value = "left" },
        new JoystickSideOption { DisplayName = "RIGHT JOYSTICK", Value = "right" },
    };

    public Array ButtonShapeOptions { get; } = Enum.GetValues(typeof(LayoutButtonShape));

    /// <summary>Joystick index values for <c>tiltTarget</c> / <c>stepTarget</c> (matches Flutter <c>ControllerId</c>).</summary>
    public IReadOnlyList<string> TiltTargetOptions { get; } = new[] { "LEFT JOYSTICK", "RIGHT JOYSTICK" };

    public IReadOnlyList<StepTargetOption> StepTargetOptions { get; } = CreateStepTargetOptions();

    /// <summary>buttonId choices <c>1 &lt;&lt; 0</c> … <c>1 &lt;&lt; 15</c> (input packet only; toolbar uses fixed ids).</summary>
    public IReadOnlyList<ButtonIdMaskOption> ButtonIdMaskOptions { get; } = CreateButtonIdMaskOptions();

    static string ButtonIdMaskDisplayName(int i) => i switch
    {
        0 => $"arrow up",
        1 => $"arrow down",
        2 => $"arrow left",
        3 => $"arrow right",
        4 => $"start",
        5 => $"back",
        6 => $"LS",
        7 => $"RS",
        8 => $"LB - Left Shoulder",
        9 => $"RB - Right Shoulder",
        10 => $"LT - Left Trigger",
        11 => $"RT - Right Trigger",
        12 => $"A",
        13 => $"B",
        14 => $"X",
        15 => $"Y",
        _ => $"custom {i}"
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
        { "arrow_right", Geometry.Parse("M 26,14 L 14,2 V 10 H 2 V 18 H 14 V 26 Z") },
        { "screenshot",  Geometry.Parse(
            "M 7,2 H 2 V 7 " + 
            "M 19,2 H 24 V 7 " + 
            "M 7,26 H 2 V 21 " + 
            "M 19,26 H 24 V 21")
        },
        { "pause",       Geometry.Parse("M 6,4 H 10 V 24 H 6 Z M 18,4 H 22 V 24 H 18 Z") },
        { "play",        Geometry.Parse("M 8,4 L 24,14 L 8,24 Z") },
        { "settings",    Geometry.Parse(
            "M 13,2 L 15,2 L 16,5 A 7,7 0 0,1 18,6 L 21,4 L 23,6 L 21,9 A 7,7 0 0,1 22,11 L 25,12 L 25,14 L 22,15 A 7,7 0 0,1 21,17 L 23,20 L 21,22 L 18,20 A 7,7 0 0,1 16,21 L 15,24 L 13,24 L 12,21 A 7,7 0 0,1 10,20 L 7,22 L 5,20 L 7,17 A 7,7 0 0,1 6,15 L 2,14 L 2,12 L 6,11 A 7,7 0 0,1 7,9 L 5,6 L 7,4 L 10,6 A 7,7 0 0,1 12,5 Z " + 
            "M 14,9 A 4,4 0 1,0 14,17 A 4,4 0 1,0 14,9 Z") 
        },
    };

    static ButtonIdMaskOption[] CreateButtonIdMaskOptions()
    {
        var opts = new ButtonIdMaskOption[17];
        opts[0] = new ButtonIdMaskOption { DisplayName = "— select button mapping —", Value = null };
        for (var i = 0; i < 16; i++)
            opts[i + 1] = new ButtonIdMaskOption { DisplayName = ButtonIdMaskDisplayName(i), Value = 1 << i };
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
            btn.UseSystemIcon = null;
            _elements.Add(joy);
            _elements.Add(btn);
        }

        ToolbarLayoutHelper.EnsureToolbarButtons(_elements);

        foreach (var m in _elements)
            HookModel(m);

        UpdateBackgroundImageSourceHint();
        RefreshPreview();
        if (_elements.Count > 0)
            SetSelectedElement(_elements[0]);
        else
            SetSelectedElement(null);

        Loaded += LayoutCreatorWindow_OnLoaded;
    }

    void LayoutCreatorWindow_OnLoaded(object sender, RoutedEventArgs e)
    {
        if (LayoutCreatorUserSettings.TryConsumeFirstRunTutorial())
            StartTutorial();
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
             e.PropertyName == nameof(LayoutElementModel.ButtonHeight) ||
             e.PropertyName == nameof(LayoutElementModel.X) ||
             e.PropertyName == nameof(LayoutElementModel.Y)))
        {
            return;
        }

        Dispatcher.BeginInvoke(RefreshPreview);
    }

    public List<string> SystemIconOptions { get; } = new() 
    { 
        "None", "square", "triangle", "circle", "cross", "arrow_up", "arrow_down", "arrow_left", "arrow_right",
        "screenshot", "pause", "play", "settings"
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

        var host = new Border
        {
            Tag = el,
            Width = hitW,
            Height = hitH,
            Background = Brushes.Transparent,
            BorderBrush = isSelected ? new SolidColorBrush(Color.FromArgb(0xE6, 0x4F, 0xA3, 0xFF)) : Brushes.Transparent,
            BorderThickness = new Thickness(2),
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
            UpdateEditorFieldVisibility(el);
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

    static double GetCornerHitSize(double hitW, double hitH, double scale)
    {
        var maxHit = ResizeHitMaxLogical * scale;
        var adaptive = Math.Min(hitW, hitH) * ResizeHitFraction;
        var gripHit = ResizeGripVisual * scale;
        return Math.Min(maxHit, Math.Max(adaptive, gripHit));
    }

    static ResizeCorner? TryGetResizeCorner(
        LayoutElementModel el, Point canvasPoint, double canvasW, double canvasH, double scale)
    {
        if (el.Type is not (LayoutElementKind.button or LayoutElementKind.joystick))
            return null;

        var (left, top, hitW, hitH) = GetPreviewHostBounds(el, canvasW, canvasH, scale);
        var localX = canvasPoint.X - left;
        var localY = canvasPoint.Y - top;
        var hit = GetCornerHitSize(hitW, hitH, scale);

        ResizeCorner? best = null;
        var bestDist = double.MaxValue;

        void Consider(ResizeCorner corner, bool inZone, double distToCorner)
        {
            if (!inZone || distToCorner >= bestDist)
                return;
            best = corner;
            bestDist = distToCorner;
        }

        if (localX <= hit && localY <= hit)
            Consider(ResizeCorner.TopLeft, true, Math.Sqrt(localX * localX + localY * localY));
        if (localX >= hitW - hit && localY <= hit)
            Consider(ResizeCorner.TopRight, true,
                Math.Sqrt((hitW - localX) * (hitW - localX) + localY * localY));
        if (localX <= hit && localY >= hitH - hit)
            Consider(ResizeCorner.BottomLeft, true,
                Math.Sqrt(localX * localX + (hitH - localY) * (hitH - localY)));
        if (localX >= hitW - hit && localY >= hitH - hit)
            Consider(ResizeCorner.BottomRight, true,
                Math.Sqrt((hitW - localX) * (hitW - localX) + (hitH - localY) * (hitH - localY)));

        return best;
    }

    static (double minW, double minH) GetMinPreviewHitSize(LayoutElementModel el, double scale)
    {
        if (el.Type == LayoutElementKind.joystick)
            return (JoystickMinRadius * 2 * scale, JoystickMinRadius * 2 * scale);
        if (el.Type == LayoutElementKind.button && el.ButtonShape == LayoutButtonShape.rectangle)
            return (ButtonRectMinWidth * scale, ButtonRectMinHeight * scale);
        return (ButtonSquareMinSize * scale, ButtonSquareMinSize * scale);
    }

    static void EnforceMinRect(
        ref double left, ref double top, ref double right, ref double bottom,
        double minW, double minH, ResizeCorner corner)
    {
        if (right - left < minW)
        {
            if (corner is ResizeCorner.TopLeft or ResizeCorner.BottomLeft)
                left = right - minW;
            else
                right = left + minW;
        }

        if (bottom - top < minH)
        {
            if (corner is ResizeCorner.TopLeft or ResizeCorner.TopRight)
                top = bottom - minH;
            else
                bottom = top + minH;
        }
    }

    static Point GetResizeAnchorCanvas(
        ResizeCorner corner, double left, double top, double hitW, double hitH) =>
        corner switch
        {
            ResizeCorner.TopLeft => new Point(left + hitW, top + hitH),
            ResizeCorner.TopRight => new Point(left, top + hitH),
            ResizeCorner.BottomLeft => new Point(left + hitW, top),
            _ => new Point(left, top)
        };

    static void ApplyResizeFromCanvasPoint(
        LayoutElementModel el,
        Point canvasPoint,
        ResizeCorner corner,
        Point anchorCanvas,
        double canvasW,
        double canvasH,
        double scale,
        double gridSize)
    {
        double newLeft, newTop, newRight, newBottom;
        switch (corner)
        {
            case ResizeCorner.TopLeft:
                newLeft = canvasPoint.X;
                newTop = canvasPoint.Y;
                newRight = anchorCanvas.X;
                newBottom = anchorCanvas.Y;
                break;
            case ResizeCorner.TopRight:
                newLeft = anchorCanvas.X;
                newTop = canvasPoint.Y;
                newRight = canvasPoint.X;
                newBottom = anchorCanvas.Y;
                break;
            case ResizeCorner.BottomLeft:
                newLeft = canvasPoint.X;
                newTop = anchorCanvas.Y;
                newRight = anchorCanvas.X;
                newBottom = canvasPoint.Y;
                break;
            default:
                newLeft = anchorCanvas.X;
                newTop = anchorCanvas.Y;
                newRight = canvasPoint.X;
                newBottom = canvasPoint.Y;
                break;
        }

        var (minW, minH) = GetMinPreviewHitSize(el, scale);
        EnforceMinRect(ref newLeft, ref newTop, ref newRight, ref newBottom, minW, minH, corner);

        var newHitW = newRight - newLeft;
        var newHitH = newBottom - newTop;

        if (el.Type == LayoutElementKind.joystick)
        {
            var next = Math.Max(Math.Max(newHitW, newHitH) / (2 * scale), JoystickMinRadius);
            el.Size = Math.Max(SnapToGrid(next, gridSize), JoystickMinRadius);
        }
        else if (el.Type == LayoutElementKind.button)
        {
            if (el.ButtonShape == LayoutButtonShape.rectangle)
            {
                var nextW = Math.Max(newHitW / scale, ButtonRectMinWidth);
                var nextH = Math.Max(newHitH / scale, ButtonRectMinHeight);
                el.ButtonWidth = Math.Max(SnapToGrid(nextW, gridSize), ButtonRectMinWidth);
                el.ButtonHeight = Math.Max(SnapToGrid(nextH, gridSize), ButtonRectMinHeight);
            }
            else
            {
                var nextSize = Math.Max(Math.Max(newHitW, newHitH) / scale, ButtonSquareMinSize);
                el.Size = Math.Max(SnapToGrid(nextSize, gridSize), ButtonSquareMinSize);
            }
        }

        var (finalW, finalH) = GetPreviewHitSize(el, scale);
        var pinnedLeft = corner is ResizeCorner.TopLeft or ResizeCorner.BottomLeft
            ? anchorCanvas.X - finalW
            : anchorCanvas.X;
        var pinnedTop = corner is ResizeCorner.TopLeft or ResizeCorner.TopRight
            ? anchorCanvas.Y - finalH
            : anchorCanvas.Y;
        el.X = Math.Clamp((pinnedLeft + finalW / 2) / canvasW, 0, 1);
        el.Y = Math.Clamp((pinnedTop + finalH / 2) / canvasH, 0, 1);
    }

    static Cursor GetResizeCursor(ResizeCorner corner) => corner switch
    {
        ResizeCorner.TopLeft or ResizeCorner.BottomRight => Cursors.SizeNWSE,
        _ => Cursors.SizeNESW
    };

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

        var resizeCorner = TryGetResizeCorner(hit, pos, canvasW, canvasH, scale);
        if (resizeCorner != null)
        {
            var (left, top, hitW, hitH) = GetPreviewHostBounds(hit, canvasW, canvasH, scale);
            _previewResizeArmed = true;
            _previewResizeElement = hit;
            _previewResizeCorner = resizeCorner.Value;
            _resizeAnchorCanvas = GetResizeAnchorCanvas(resizeCorner.Value, left, top, hitW, hitH);
            _isPreviewResizing = true;
            PreviewCanvas.Cursor = GetResizeCursor(_previewResizeCorner);
            ApplyResizeFromCanvasPoint(
                hit, pos, _previewResizeCorner, _resizeAnchorCanvas,
                canvasW, canvasH, scale, GetResizeGridSize());
            RefreshPreview();
        }
        else
        {
            _previewDragArmed = true;
            _previewDragElement = hit;
        }

        PreviewCanvas.CaptureMouse();
        e.Handled = true;
    }

    void UpdatePreviewHoverCursor(Point pos)
    {
        var hit = HitTestPreviewElement(pos);
        if (hit == null)
        {
            PreviewCanvas.Cursor = Cursors.Arrow;
            return;
        }

        if (ReferenceEquals(hit, _selectedElement) &&
            hit.Type is LayoutElementKind.button or LayoutElementKind.joystick)
        {
            var scale = GetPreviewScale();
            var corner = TryGetResizeCorner(
                hit, pos, PreviewCanvas.Width, PreviewCanvas.Height, scale);
            if (corner != null)
            {
                PreviewCanvas.Cursor = GetResizeCursor(corner.Value);
                return;
            }
        }

        PreviewCanvas.Cursor = Cursors.Hand;
    }

    void PreviewCanvas_OnMouseMove(object sender, MouseEventArgs e)
    {
        var pos = e.GetPosition(PreviewCanvas);

        if (e.LeftButton != MouseButtonState.Pressed)
        {
            UpdatePreviewHoverCursor(pos);
            return;
        }
        var scale = GetPreviewScale();

        if (_previewResizeArmed && _previewResizeElement != null)
        {
            var canvasW = PreviewCanvas.Width;
            var canvasH = PreviewCanvas.Height;
            ApplyResizeFromCanvasPoint(
                _previewResizeElement,
                pos,
                _previewResizeCorner,
                _resizeAnchorCanvas,
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
    }

    void PreviewCanvas_OnMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        EndPreviewDrag();
        EndPreviewResize();
        ClearPreviewPointerState();
        UpdatePreviewHoverCursor(e.GetPosition(PreviewCanvas));
        e.Handled = true;
    }

    void PreviewCanvas_OnMouseLeave(object sender, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed)
        {
            EndPreviewDrag();
            EndPreviewResize();
            ClearPreviewPointerState();
            PreviewCanvas.Cursor = Cursors.Arrow;
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
        UpdateEditorFieldVisibility(m);
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

    void UpdateEditorFieldVisibility(LayoutElementModel? el)
    {
        var kind = el?.Type ?? LayoutElementKind.button;
        var isToolbar = el != null && ToolbarLayoutHelper.IsToolbarElement(el.Id);
        ElementTypePanel.Visibility = isToolbar ? Visibility.Collapsed : Visibility.Visible;
        ElementIdPanel.Visibility = isToolbar ? Visibility.Collapsed : Visibility.Visible;
        LabelFieldCaption.Text = isToolbar
            ? "Label (editor hint only)"
            : "Label (required)";
        JoystickFieldsPanel.Visibility = kind == LayoutElementKind.joystick ? Visibility.Visible : Visibility.Collapsed;
        ButtonFieldsPanel.Visibility = kind == LayoutElementKind.joystick ? Visibility.Collapsed : Visibility.Visible;
        ButtonMappingPanel.Visibility = kind == LayoutElementKind.button && !isToolbar ? Visibility.Visible : Visibility.Collapsed;
        SystemIconPanel.Visibility = kind == LayoutElementKind.button && !isToolbar ? Visibility.Visible : Visibility.Collapsed;
    }

    void StartTutorial_OnClick(object sender, RoutedEventArgs e) => StartTutorial();

    void StartTutorial()
    {
        if (_selectedElement is null && _elements.Count > 0)
            SetSelectedElement(_elements[0]);

        LayoutTutorialOverlay.Start(new[]
        {
            new TutorialStep
            {
                Target = PreviewSection,
                Message = "This is the layout preview. It mirrors how your controller will appear on the phone. Click an element to select it, drag to move it, and drag a corner to resize (sizes snap to the grid step). Press Backspace to remove the selected element.",
                HighlightPadding = new Thickness(6)
            },
            new TutorialStep
            {
                Target = LayoutPropertiesSection,
                Message = "Layout properties apply to the whole controller layout. Set the layout name, background color or image, and resize grid for better alignment. Steering target chooses which joystick receives phone tilt. Step output chooses which game input receives step-counter data from the phone.",
                HighlightPadding = new Thickness(18, 6, 18, 6)
            },
            new TutorialStep
            {
                Target = ElementSettingsSection,
                Message = "Element settings appear when you select an element in the preview. You can edit its type, id, label, position, colors, and button or joystick specific options here.",
                HighlightPadding = new Thickness(18, 6, 18, 6),
                ScrollToRevealEntireTarget = true,
                MessagePlacement = TutorialMessagePlacement.Left
            },
            new TutorialStep
            {
                Prepare = PrepareButtonMappingTutorialStep,
                Target = ButtonMappingPanel,
                Message = "Each buton has a buttonValueMapping that map to a game input (for example A, B, or a shoulder button). Every gameplay button needs a mapping, it is easy to miss, so check it for each button you add.",
                HighlightPadding = new Thickness(18, 6, 18, 6),
                ScrollToRevealEntireTarget = true,
                MessagePlacement = TutorialMessagePlacement.Left
            },
            new TutorialStep
            {
                Target = SidebarActionButtonsSection,
                Message = "Use these actions to build and share your layout. Add buttons and joysticks, import or export a layout file, and send the finished layout to a connected phone.",
                HighlightPadding = new Thickness(18, 6, 18, 6),
                MessagePlacement = TutorialMessagePlacement.Left
            }
        });
    }

    void PrepareButtonMappingTutorialStep()
    {
        var button = _elements.FirstOrDefault(e =>
            e.Type == LayoutElementKind.button && !ToolbarLayoutHelper.IsToolbarElement(e.Id));
        if (button is not null)
            SetSelectedElement(button);

        SidebarScrollViewer.UpdateLayout();
        ButtonMappingPanel.UpdateLayout();
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

    void ImportLayout_OnClick(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog
        {
            Filter = ControllerLayoutDocument.FileDialogFilter,
            Title = "Import layout"
        };
        if (dlg.ShowDialog(this) != true)
            return;
        try
        {
            var json = File.ReadAllText(dlg.FileName);
            var layout = ControllerLayoutDocument.Deserialize(json);

            // Check if layout and nested Data exist to avoid NullReferenceExceptions
            if (layout == null)
            {
                MessageBox.Show("The layout file is empty or invalid.", "Error", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            LayoutNameBox.Text = layout.LayoutName ?? "New layout";
        
            if (layout.Data != null)
            {
                LayoutBackgroundColorPicker.HexValue = layout.Data.BackgroundColor ?? "";
                LayoutBackgroundImageBox.Text = layout.Data.BackgroundImage ?? "";
                
                // For your ComboBoxes / Dropdowns (e.g., tiltTarget, stepTarget):
                // You may need to map the integers (like 1, 0) to your UI selection items
                TiltTargetCombo.SelectedIndex = layout.Data.TiltTarget;

                var options = StepTargetOptions; // or however you expose your options array
                var matchedOption = options.FirstOrDefault(opt => 
                    opt.StepTarget == layout.Data.StepTarget && 
                    opt.StepButtonBitmask == layout.Data.StepButtonBitmask
                );

                if (matchedOption != null)
                {
                    // If your ComboBox is bound to objects, set the SelectedItem directly
                    StepTargetCombo.SelectedItem = matchedOption;
                }
                else
                {
                    // Fallback: Default to the first item (LEFT JOYSTICK) if no exact match is found
                    StepTargetCombo.SelectedIndex = 0; 
                }
            }
            if (layout.Data?.Elements != null)
            {
                _elements.Clear();
                
                // 2. Map the JSON DTOs back into UI Models and add them
                foreach (var dto in layout.Data.Elements)
                {
                    var model = LayoutElementModel.FromDto(dto); 
                    
                    _elements.Add(model);
                }

                ToolbarLayoutHelper.EnsureToolbarButtons(_elements);
            }
        }
        catch (JsonException ex)
        {
            MessageBox.Show($"Failed to parse JSON file: {ex.Message}", "Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        catch (Exception ex)
        {
            MessageBox.Show($"An error occurred while loading file: {ex.Message}", "Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    void RemoveSelectedElement()
    {
        if (_selectedElement is not LayoutElementModel m)
            return;
        if (ToolbarLayoutHelper.IsToolbarElement(m.Id))
        {
            MessageBox.Show(this,
                "Toolbar buttons (screenshot, pause/resume, settings) cannot be removed.",
                "Layout creator",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            return;
        }
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
            Filter = ControllerLayoutDocument.FileDialogFilter,
            DefaultExt = ControllerLayoutDocument.FileExtension.TrimStart('.'),
            FileName = $"{SanitizeFileName(LayoutNameBox.Text)}{ControllerLayoutDocument.FileExtension}"
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
                error = $"Element '{el.Label}' must have a 'backgroundColor'.";
                return false;
            }
            if (string.IsNullOrWhiteSpace(el.Color))
            {
                error = $"Element '{el.Label}' must have a 'color'.";
                return false;
            }
            if (el.Type == LayoutElementKind.joystick)
            {
                var jt = el.JoystickType?.Trim().ToLowerInvariant();
                if (jt is not ("left" or "right"))
                {
                    error = $"Joystick \"{el.Label}\" must have joystickType \"left\" or \"right\".";
                    return false;
                }
            }
            else if (el.Type == LayoutElementKind.button)
            {
                if (el.ButtonId == 0 || el.ButtonId == null)
                {
                    error = $"Button \"{el.Label}\" must have a 'buttonValueMapping' selected.";
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

enum ResizeCorner
{
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight
}
