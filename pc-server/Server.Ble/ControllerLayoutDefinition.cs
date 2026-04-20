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

/// <summary>Dropdown entry for <c>buttonId</c> bitmask (<c>1 &lt;&lt; n</c>).</summary>
public sealed class ButtonIdMaskOption
{
    public string DisplayName { get; init; } = "";
    public int Value { get; init; }
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
        set => SetField(ref _size, value);
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
            LayoutElementModel.ApplyImportedButtonImage(model, d.Image);
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
        string? backgroundImage)
    {
        var doc = new ControllerLayoutDocument
        {
            LayoutName = layoutName,
            Favorite = false,
            Data = new ControllerLayoutData
            {
                BackgroundColor = NormalizeOptionalColor(backgroundColor),
                BackgroundImage = NormalizeOptionalString(backgroundImage),
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

    [JsonPropertyName("elements")]
    public List<LayoutElementDto> Elements { get; set; } = new();
}
