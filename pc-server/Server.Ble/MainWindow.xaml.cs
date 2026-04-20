#nullable enable

using System.Text;
using System.Windows;

namespace BleServer;

public partial class MainWindow : Window
{
    const int MaxLogChars = 400_000;

    public MainWindow()
    {
        InitializeComponent();
    }

    public void AppendLog(string line)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(() => AppendLog(line));
            return;
        }

        var sb = new StringBuilder(LogText.Text.Length + line.Length + 4);
        sb.Append(LogText.Text);
        if (sb.Length > 0 && !line.StartsWith('\n'))
            sb.AppendLine();
        sb.Append(line);
        if (sb.Length > MaxLogChars)
            sb.Remove(0, sb.Length - MaxLogChars / 2);

        LogText.Text = sb.ToString();
        LogScroll.ScrollToEnd();
    }

    void LayoutCreatorButton_OnClick(object sender, RoutedEventArgs e)
    {
        var win = new LayoutCreatorWindow { Owner = this };
        win.ShowDialog();
    }
}
