using System.Windows;

namespace BleServer;

public enum TutorialMessagePlacement
{
    Auto,
    Left,
    Right,
    Below,
    Above
}

public sealed class TutorialStep
{
    public required FrameworkElement Target { get; init; }
    public required string Message { get; init; }
    /// <summary>Extra space around the target bounds (left, top, right, bottom).</summary>
    public Thickness HighlightPadding { get; init; } = new Thickness(8);
    /// <summary>When the target is inside a ScrollViewer, scroll so the whole target is visible if it fits.</summary>
    public bool ScrollToRevealEntireTarget { get; init; }
    public TutorialMessagePlacement MessagePlacement { get; init; } = TutorialMessagePlacement.Auto;
    /// <summary>Runs before this step is shown (e.g. change selection or scroll).</summary>
    public Action? Prepare { get; init; }
}
