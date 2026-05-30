#nullable enable

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace BleServer;

public enum LayoutElementKind
{
    joystick,
    button,
    // dpad,
    // trigger
}

/// <summary>Matches Flutter <c>ButtonShape</c>.</summary>
public enum LayoutButtonShape
{
    circle,
    square,
    rectangle,
}

/// <summary>Dropdown entry for <c>buttonId</c> bitmask (<c>1 &lt;&lt; n</c>).</summary>
public sealed class ButtonIdMaskOption
{
    public string DisplayName { get; init; } = "";
    public int Value { get; init; }
}

/// <summary>Dropdown entry for layout <c>stepTarget</c> / <c>stepButtonBitmask</c>.</summary>
public sealed class StepTargetOption
{
    public string DisplayName { get; init; } = "";
    public int StepTarget { get; init; }
    public int StepButtonBitmask { get; init; }
}

/// <summary>Editable element; mirrors Flutter <c>ControllerElement</c> JSON fields.</summary>
public sealed class LayoutElementModel : INotifyPropertyChanged
{
    string _id = "";
    LayoutElementKind _type = LayoutElementKind.button;
    double _x = 0.5;
    double _y = 0.5;
    double _size = 80;
    int? _buttonId = null;
    string? _joystickType = "left";
    string _label = "";
    string _backgroundColor = "33FFFFFF";
    string _color = "FFFFFFFF";
    string? _image;
    string? _buttonImageUrl;
    string? _buttonImageUploadedDataUri;
    string? _buttonImageUploadedFileName;
    string? _useSystemIcon;
    double _opacity = 1.0;
    LayoutButtonShape _buttonShape = LayoutButtonShape.circle;
    double? _buttonWidth;
    double? _buttonHeight;

    public const double RectangleWidthFactor = 2.0;
    public const double RectangleHeightFactor = 0.75;

    public string Summary => $"{Label} ({Type})";

    /// <summary>http(s) image URL typed in the layout editor (not shown: uploaded base64).</summary>
    public string? ButtonImageUrl
    {
        get => _buttonImageUrl;
        set
        {
            if (EqualityComparer<string?>.Default.Equals(_buttonImageUrl, value)) return;
            _buttonImageUrl = value;
            if (!string.IsNullOrWhiteSpace(value) && !value.StartsWith("data:image"))
            {
                _buttonImageUploadedDataUri = null;
                _buttonImageUploadedFileName = null;
                _image = null;
            }
            OnPropertyChanged(nameof(ButtonImageUrl));
            OnPropertyChanged(nameof(ButtonImageHint));
        }
    }

    /// <summary>Status line for the image row (URL / upload / legacy import).</summary>
    public string ButtonImageHint
    {
        get
        {
            if (!string.IsNullOrEmpty(_buttonImageUploadedFileName))
                return $"Using uploaded file: {_buttonImageUploadedFileName}";
            if (!string.IsNullOrWhiteSpace(_buttonImageUrl))
            {
                return IsAbsoluteHttpUrl(_buttonImageUrl)
                    ? "Using URL from field."
                    : "Enter a valid http/https image URL, or click Clear.";
            }
            if (!string.IsNullOrEmpty(_image) && Type == LayoutElementKind.button)
                return "Using custom image from layout (data URI / etc.).";
            return "No image selected (optional).";
        }
    }

    public static bool IsAbsoluteHttpUrl(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri))
            return false;
        return uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps;
    }

    public string Id
    {
        get => _id;
        set
        {
            if (!SetField(ref _id, value)) return;
            OnPropertyChanged(nameof(Summary));
        }
    }

    public LayoutElementKind Type
    {
        get => _type;
        set
        {
            if (!SetField(ref _type, value)) return;
            OnPropertyChanged(nameof(Summary));
            OnPropertyChanged(nameof(ButtonImageHint));
            OnPropertyChanged(nameof(IsRectangleButton));
        }
    }

    public double X
    {
        get => _x;
        set => SetField(ref _x, value);
    }

    public double Y
    {
        get => _y;
        set => SetField(ref _y, value);
    }

    public double Size
    {
        get => _size;
        set
        {
            if (EqualityComparer<double>.Default.Equals(_size, value)) return;
            var previousSize = _size;
            _size = value;
            if (previousSize > 0 && value > 0)
            {
                var ratio = value / previousSize;
                if (_buttonWidth is > 0)
                    _buttonWidth *= ratio;
                if (_buttonHeight is > 0)
                    _buttonHeight *= ratio;
            }
            OnPropertyChanged();
            OnPropertyChanged(nameof(ButtonWidth));
            OnPropertyChanged(nameof(ButtonHeight));
        }
    }

    public int? ButtonId
    {
        get => _buttonId;
        set {
            if (SetField(ref _buttonId, value))
            {
                OnPropertyChanged(nameof(ButtonId));
            }
        }
    }

    public string? JoystickType
    {
        get => _joystickType;
        set => SetField(ref _joystickType, value);
    }

    public string Label
    {
        get => _label;
        set
        {
            if (!SetField(ref _label, value)) return;
            OnPropertyChanged(nameof(Summary));
        }
    }

    public string BackgroundColor
    {
        get => _backgroundColor;
        set => SetField(ref _backgroundColor, value);
    }

    public string Color
    {
        get => _color;
        set => SetField(ref _color, value);
    }

    public string? Image
    {
        get => _image;
        set
        {
            if (!SetField(ref _image, value)) return;
            OnPropertyChanged(nameof(ButtonImageHint));
        }
    }

    /// <summary>Applies a user-uploaded raster image as a data URI; clears URL and legacy <see cref="Image"/>.</summary>
    public void ApplyUploadedButtonImage(string dataUri, string fileName)
    {
        _buttonImageUploadedDataUri = dataUri;
        _buttonImageUploadedFileName = fileName;
        _image = null;
        _buttonImageUrl = dataUri;
        OnPropertyChanged(nameof(ButtonImageUrl));
        OnPropertyChanged(nameof(ButtonImageHint));
    }

    /// <summary>Clears URL, upload, and legacy image (editor + export).</summary>
    public void ClearButtonImageForEditor()
    {
        _buttonImageUploadedDataUri = null;
        _buttonImageUploadedFileName = null;
        _buttonImageUrl = null;
        _image = null;
        OnPropertyChanged(nameof(ButtonImageUrl));
        OnPropertyChanged(nameof(Image));
        OnPropertyChanged(nameof(ButtonImageHint));
    }

    /// <summary>Resolves <c>image</c> for JSON export; invalid typed URL returns <c>false</c>.</summary>
    public bool TryGetButtonImageForExport(out string? image, out string? error)
    {
        image = null;
        error = null;
        if (Type != LayoutElementKind.button)
            return true;

        var text = _buttonImageUrl?.Trim();
        if (!string.IsNullOrEmpty(text))
        {
            if (IsAbsoluteHttpUrl(text) || text.StartsWith("data:image", StringComparison.OrdinalIgnoreCase))
            {
                image = text;
                return true;
            }

            error = $"Button \"{Id}\": image field must be a valid http/https URL or an uploaded file.";
            return false;
        }
        if (!string.IsNullOrEmpty(_buttonImageUploadedDataUri))
        {
            image = _buttonImageUploadedDataUri;
            return true;
        }
        image = string.IsNullOrWhiteSpace(_image) ? null : _image.Trim();
        return true;
    }

    internal static void ApplyImportedButtonImage(LayoutElementModel m, string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return;
        var t = raw.Trim();
        if (IsAbsoluteHttpUrl(t))
            m.ButtonImageUrl = t;
        else if (t.StartsWith("data:image/", StringComparison.OrdinalIgnoreCase))
            m.ApplyUploadedButtonImage(t, "(imported)");
        else
            m.Image = t;
    }

    public string? UseSystemIcon 
    {
        get => _useSystemIcon;
        set {
            if (SetField(ref _useSystemIcon, value))
            {
                // This is crucial: it tells the Window to call RefreshPreview()
                OnPropertyChanged(nameof(UseSystemIcon)); 
            }
        }
    }

    public double Opacity
    {
        get => _opacity;
        set => SetField(ref _opacity, value);
    }

    public LayoutButtonShape ButtonShape
    {
        get => _buttonShape;
        set
        {
            if (!SetField(ref _buttonShape, value)) return;
            OnPropertyChanged(nameof(IsRectangleButton));
            OnPropertyChanged(nameof(ButtonWidth));
            OnPropertyChanged(nameof(ButtonHeight));
        }
    }

    public bool IsRectangleButton => Type == LayoutElementKind.button && ButtonShape == LayoutButtonShape.rectangle;

    public double ButtonWidth
    {
        get
        {
            if (_buttonWidth is > 0)
                return _buttonWidth.Value;
            return Size * RectangleWidthFactor;
        }
        set => SetField(ref _buttonWidth, value > 0 ? value : null);
    }

    public double ButtonHeight
    {
        get
        {
            if (_buttonHeight is > 0)
                return _buttonHeight.Value;
            return Size * RectangleHeightFactor;
        }
        set => SetField(ref _buttonHeight, value > 0 ? value : null);
    }

    /// <summary>Preview / phone layout size in logical pixels (before canvas scale).</summary>
    public (double width, double height) GetButtonLayoutSize()
    {
        return ButtonShape switch
        {
            LayoutButtonShape.rectangle => (ButtonWidth, ButtonHeight),
            _ => (Size, Size),
        };
    }

    public double GetButtonVisualScale()
    {
        var (w, h) = GetButtonLayoutSize();
        return Math.Min(w, h);
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public static LayoutElementModel CreateButton(string id)
    {
        return new LayoutElementModel
        {
            Id = id,
            Type = LayoutElementKind.button,
            Label = "A",
            ButtonId = 1 << 0
        };
    }

    public static LayoutElementModel CreateJoystick(string id, string joystickType)
    {
        return new LayoutElementModel
        {
            Id = id,
            Type = LayoutElementKind.joystick,
            JoystickType = joystickType,
            Label = joystickType,
            Size = 100
        };
    }

    public LayoutElementDto ToDto()
    {
        var dto = new LayoutElementDto
        {
            Id = Id,
            Type = Type.ToString(),
            X = X,
            Y = Y,
            Size = Size,
            ButtonId = ButtonId,
            Label = Label,
            BackgroundColor = BackgroundColor,
            Color = Color,
            UseSystemIcon = UseSystemIcon,
            Opacity = Opacity
        };

        // Match Flutter app: only joysticks use joystickType; only buttons use image.
        if (Type == LayoutElementKind.joystick)
        {
            dto.JoystickType = JoystickType;
            dto.Image = null;
            dto.UseSystemIcon = null;
        }
        else
        {
            dto.JoystickType = null;
            if (Type == LayoutElementKind.button)
            {
                TryGetButtonImageForExport(out var img, out _);
                dto.Image = string.IsNullOrEmpty(img) ? null : img;
                dto.ButtonShape = ButtonShape.ToString();
                dto.ButtonWidth = _buttonWidth;
                dto.ButtonHeight = _buttonHeight;
            }
            else
            {
                dto.Image = null;
            }
            if (Type != LayoutElementKind.button)
            {
                dto.UseSystemIcon = null;
            }
        }

        return dto;
    }

    void OnPropertyChanged([CallerMemberName] string? name = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    bool SetField<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }
}

public sealed class LayoutElementDto
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("type")]
    public string Type { get; set; } = "button";

    [JsonPropertyName("x")]
    public double X { get; set; }

    [JsonPropertyName("y")]
    public double Y { get; set; }

    [JsonPropertyName("size")]
    public double Size { get; set; }

    [JsonPropertyName("buttonId")]
    public int? ButtonId { get; set; }

    [JsonPropertyName("joystickType")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? JoystickType { get; set; }

    [JsonPropertyName("label")]
    public string Label { get; set; } = "";

    [JsonPropertyName("backgroundColor")]
    public string BackgroundColor { get; set; } = "33FFFFFF";

    [JsonPropertyName("color")]
    public string Color { get; set; } = "FFFFFFFF";

    [JsonPropertyName("image")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Image { get; set; }

    [JsonPropertyName("useSystemIcon")]
    public string? UseSystemIcon { get; set; }

    [JsonPropertyName("opacity")]
    public double Opacity { get; set; } = 1.0;

    [JsonPropertyName("buttonShape")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? ButtonShape { get; set; }

    [JsonPropertyName("buttonWidth")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? ButtonWidth { get; set; }

    [JsonPropertyName("buttonHeight")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double? ButtonHeight { get; set; }

    public static LayoutElementModel ToModel(LayoutElementDto d)
    {
        var kind = Enum.TryParse<LayoutElementKind>(d.Type, true, out var k) ? k : LayoutElementKind.button;
        var model = new LayoutElementModel
        {
            Id = d.Id,
            Type = kind,
            X = d.X,
            Y = d.Y,
            Size = d.Size,
            ButtonId = d.ButtonId,
            JoystickType = d.JoystickType,
            Label = d.Label,
            BackgroundColor = d.BackgroundColor,
            Color = d.Color,
            UseSystemIcon = d.UseSystemIcon,
            Opacity = d.Opacity
        };
        if (kind == LayoutElementKind.button)
        {
            LayoutElementModel.ApplyImportedButtonImage(model, d.Image);
            if (!string.IsNullOrWhiteSpace(d.ButtonShape) &&
                Enum.TryParse<LayoutButtonShape>(d.ButtonShape, true, out var shape))
                model.ButtonShape = shape;
            if (d.ButtonWidth is > 0)
                model.ButtonWidth = d.ButtonWidth.Value;
            if (d.ButtonHeight is > 0)
                model.ButtonHeight = d.ButtonHeight.Value;
        }
        else
            model.Image = d.Image;
        return model;
    }
}

public sealed class ControllerLayoutDocument
{
    [JsonPropertyName("layoutName")]
    public string LayoutName { get; set; } = "New layout";

    [JsonPropertyName("favorite")]
    public bool Favorite { get; set; }

    [JsonPropertyName("data")]
    public ControllerLayoutData Data { get; set; } = new();

    public static string Serialize(
        ObservableCollection<LayoutElementModel> elements,
        string layoutName,
        string? backgroundColor,
        string? backgroundImage,
        int tiltTarget = 1,
        int stepTarget = 0,
        int stepButtonBitmask = 0)
    {
        var doc = new ControllerLayoutDocument
        {
            LayoutName = layoutName,
            Favorite = false,
            Data = new ControllerLayoutData
            {
                BackgroundColor = NormalizeOptionalColor(backgroundColor),
                BackgroundImage = NormalizeOptionalString(backgroundImage),
                TiltTarget = tiltTarget,
                StepTarget = stepTarget,
                StepButtonBitmask = stepButtonBitmask,
                Elements = elements.Select(e => e.ToDto()).ToList()
            }
        };
        return JsonSerializer.Serialize(doc, new JsonSerializerOptions { WriteIndented = true });
    }

    static string? NormalizeOptionalString(string? s)
    {
        var t = s?.Trim();
        return string.IsNullOrEmpty(t) ? null : t;
    }

    /// <summary>
    /// Matches Flutter <c>ControllerLayout.fromJson</c> rules: bare values are left as-is (ARGB hex);
    /// <c>#RRGGBB</c> becomes <c>FFRRGGBB</c>; <c>#RRGGBBAA</c> becomes <c>AARRGGBB</c>.
    /// </summary>
    static string? NormalizeOptionalColor(string? s)
    {
        var t = s?.Trim();
        if (string.IsNullOrEmpty(t))
            return null;
        if (!t.StartsWith("#", StringComparison.Ordinal))
            return t.ToUpperInvariant();
        var hex = t[1..].ToUpperInvariant();
        if (!IsHex(hex))
            return t;
        if (hex.Length == 6)
            return "FF" + hex;
        if (hex.Length == 8)
        {
            var alpha = hex.Substring(6, 2);
            return alpha + hex.Substring(0, 6);
        }
        return t;
    }

    static bool IsHex(string value)
    {
        foreach (var c in value)
        {
            if (c is >= '0' and <= '9' or >= 'a' and <= 'f' or >= 'A' and <= 'F')
                continue;
            return false;
        }
        return value.Length > 0;
    }
}

public sealed class ControllerLayoutData
{
    [JsonPropertyName("backgroundImage")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? BackgroundImage { get; set; }

    [JsonPropertyName("backgroundColor")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? BackgroundColor { get; set; }

    [JsonPropertyName("tiltTarget")]
    public int TiltTarget { get; set; } = 1;

    [JsonPropertyName("stepTarget")]
    public int StepTarget { get; set; }

    [JsonPropertyName("stepButtonBitmask")]
    public int StepButtonBitmask { get; set; }

    [JsonPropertyName("elements")]
    public List<LayoutElementDto> Elements { get; set; } = new();
}
