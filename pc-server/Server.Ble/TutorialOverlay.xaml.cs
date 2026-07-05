using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

namespace BleServer;

public partial class TutorialOverlay : UserControl
{
    IReadOnlyList<TutorialStep> _steps = Array.Empty<TutorialStep>();
    int _stepIndex;

    public event EventHandler? Completed;

    public TutorialOverlay()
    {
        InitializeComponent();
        SizeChanged += (_, _) => RefreshCurrentStep();
    }

    public void Start(IReadOnlyList<TutorialStep> steps)
    {
        if (steps.Count == 0)
            return;

        _steps = steps;
        _stepIndex = 0;
        Visibility = Visibility.Visible;
        RefreshCurrentStep();
    }

    public void Stop()
    {
        Visibility = Visibility.Collapsed;
        _steps = Array.Empty<TutorialStep>();
        _stepIndex = 0;
    }

    void RefreshCurrentStep()
    {
        if (Visibility != Visibility.Visible || _stepIndex >= _steps.Count)
            return;

        var step = _steps[_stepIndex];
        step.Prepare?.Invoke();
        PrepareTargetForHighlight(step.Target, step.ScrollToRevealEntireTarget);
        step.Target.UpdateLayout();
        UpdateLayout();

        var highlight = GetHighlightRect(step.Target, this, step.HighlightPadding);
        highlight = ClipToNearestScrollViewerViewport(step.Target, this, highlight);
        UpdateSpotlight(highlight);
        MessageText.Text = step.Message;
        PositionMessagePanel(highlight, step.MessagePlacement);
    }

    static Rect GetHighlightRect(FrameworkElement target, Visual overlay, Thickness padding)
    {
        var topLeft = target.TransformToVisual(overlay).Transform(new Point(0, 0));
        var size = target.RenderSize;
        if (size.Width <= 0 || size.Height <= 0)
            size = new Size(target.ActualWidth, target.ActualHeight);

        return new Rect(
            topLeft.X - padding.Left,
            topLeft.Y - padding.Top,
            size.Width + padding.Left + padding.Right,
            size.Height + padding.Top + padding.Bottom);
    }

    static void PrepareTargetForHighlight(FrameworkElement target, bool revealEntireTarget)
    {
        if (!revealEntireTarget)
        {
            target.BringIntoView();
            return;
        }

        var scrollViewer = FindAncestor<ScrollViewer>(target);
        if (scrollViewer?.Content is not FrameworkElement scrollContent)
        {
            target.BringIntoView();
            return;
        }

        scrollContent.UpdateLayout();
        target.UpdateLayout();

        var targetTop = target.TransformToVisual(scrollContent).Transform(new Point(0, 0)).Y;
        var targetHeight = target.RenderSize.Height;
        if (targetHeight <= 0)
            targetHeight = target.ActualHeight;

        var viewportHeight = scrollViewer.ViewportHeight;
        if (viewportHeight <= 0 || targetHeight <= 0)
        {
            target.BringIntoView();
            return;
        }

        double offset;
        if (targetHeight <= viewportHeight)
        {
            offset = targetTop + targetHeight - viewportHeight;
            offset = Math.Clamp(offset, 0, scrollViewer.ScrollableHeight);
        }
        else
        {
            offset = Math.Clamp(targetTop, 0, scrollViewer.ScrollableHeight);
        }

        scrollViewer.ScrollToVerticalOffset(offset);
    }

    static Rect ClipToNearestScrollViewerViewport(FrameworkElement target, Visual overlay, Rect highlight)
    {
        var scrollViewer = FindAncestor<ScrollViewer>(target);
        if (scrollViewer is null)
            return highlight;

        var viewerOrigin = scrollViewer.TransformToVisual(overlay).Transform(new Point(0, 0));
        var viewport = new Rect(viewerOrigin.X, viewerOrigin.Y, scrollViewer.ActualWidth, scrollViewer.ActualHeight);
        highlight.Intersect(viewport);
        return highlight.IsEmpty ? viewport : highlight;
    }

    static T? FindAncestor<T>(DependencyObject child) where T : DependencyObject
    {
        for (var parent = VisualTreeHelper.GetParent(child); parent != null; parent = VisualTreeHelper.GetParent(parent))
        {
            if (parent is T match)
                return match;
        }

        return null;
    }

    void UpdateSpotlight(Rect highlight)
    {
        var bounds = new Rect(0, 0, ActualWidth, ActualHeight);
        if (bounds.Width <= 0 || bounds.Height <= 0)
            return;

        var outer = new RectangleGeometry(bounds);
        var inner = new RectangleGeometry(highlight, 6, 6);
        SpotlightPath.Data = new CombinedGeometry(GeometryCombineMode.Exclude, outer, inner);
    }

    void PositionMessagePanel(Rect highlight, TutorialMessagePlacement placement)
    {
        MessagePanel.Measure(new Size(Math.Min(380, ActualWidth - 16), double.PositiveInfinity));
        var messageSize = MessagePanel.DesiredSize;

        const double gap = 12;
        double left;
        double top;

        switch (placement)
        {
            case TutorialMessagePlacement.Left:
                left = highlight.Left - gap - messageSize.Width;
                top = highlight.Top + (highlight.Height - messageSize.Height) / 2;
                break;
            case TutorialMessagePlacement.Right:
                left = highlight.Right + gap;
                top = highlight.Top + (highlight.Height - messageSize.Height) / 2;
                break;
            case TutorialMessagePlacement.Above:
                left = highlight.Left + (highlight.Width - messageSize.Width) / 2;
                top = highlight.Top - gap - messageSize.Height;
                break;
            case TutorialMessagePlacement.Below:
                left = highlight.Left + (highlight.Width - messageSize.Width) / 2;
                top = highlight.Bottom + gap;
                break;
            default:
                left = highlight.Left + (highlight.Width - messageSize.Width) / 2;
                top = highlight.Bottom + gap;
                if (top + messageSize.Height > ActualHeight - 8)
                    top = highlight.Top - gap - messageSize.Height;
                break;
        }

        left = Math.Clamp(left, 8, Math.Max(8, ActualWidth - messageSize.Width - 8));
        top = Math.Clamp(top, 8, Math.Max(8, ActualHeight - messageSize.Height - 8));

        Canvas.SetLeft(MessagePanel, left);
        Canvas.SetTop(MessagePanel, top);
    }

    void Overlay_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        _stepIndex++;
        if (_stepIndex >= _steps.Count)
        {
            Stop();
            Completed?.Invoke(this, EventArgs.Empty);
        }
        else
            RefreshCurrentStep();

        e.Handled = true;
    }
}
