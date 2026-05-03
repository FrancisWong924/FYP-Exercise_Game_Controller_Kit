#nullable enable

using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using System.Windows;
using System.Windows.Threading;

namespace BleServer;

public partial class MainWindow : Window
{
    const int MaxLogChars = 400_000;
    /// <summary>Drain at most this many queued lines per timer tick so one tick cannot freeze the UI.</summary>
    const int MaxLogLinesPerTick = 500;
    static readonly TimeSpan LogBatchInterval = TimeSpan.FromMilliseconds(100);

    readonly object _logPendingLock = new();
    readonly List<string> _logPending = new();
    DispatcherTimer? _logBatchTimer;

    public MainWindow()
    {
        InitializeComponent();
        _logBatchTimer = new DispatcherTimer { Interval = LogBatchInterval };
        _logBatchTimer.Tick += (_, _) => FlushLogPending();
        _logBatchTimer.Start();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        // Before App.OnExit cancels the server task, stop advertising "alive" via PONG so the phone can drop quickly.
        Program.SignalBleUiClosing();
        _logBatchTimer?.Stop();
        DrainAllPendingLogLines();
        base.OnClosing(e);
    }

    /// <summary>Enqueue a line from any thread; the UI timer applies batches so high-rate BLE logs do not flood the dispatcher.</summary>
    public void AppendLog(string line)
    {
        try
        {
            lock (_logPendingLock)
                _logPending.Add(line);
        }
        catch
        {
            Trace.WriteLine(line);
        }
    }

    void FlushLogPending()
    {
        try
        {
            List<string> batch;
            lock (_logPendingLock)
            {
                if (_logPending.Count == 0) return;
                var n = System.Math.Min(_logPending.Count, MaxLogLinesPerTick);
                batch = _logPending.GetRange(0, n);
                _logPending.RemoveRange(0, n);
            }

            var sb = new StringBuilder(batch.Count * 80);
            foreach (var line in batch)
                sb.Append(line).AppendLine();

            LogText.AppendText(sb.ToString());

            if (LogText.Text.Length > MaxLogChars)
                LogText.Text = LogText.Text.Substring(LogText.Text.Length - MaxLogChars / 2);

            LogScroll.ScrollToEnd();
        }
        catch
        {
            // ignore UI failures during shutdown
        }
    }

    void DrainAllPendingLogLines()
    {
        try
        {
            while (true)
            {
                List<string> batch;
                lock (_logPendingLock)
                {
                    if (_logPending.Count == 0) break;
                    batch = new List<string>(_logPending);
                    _logPending.Clear();
                }

                var sb = new StringBuilder(batch.Count * 80);
                foreach (var line in batch)
                    sb.Append(line).AppendLine();
                LogText.AppendText(sb.ToString());
            }

            if (LogText.Text.Length > MaxLogChars)
                LogText.Text = LogText.Text.Substring(LogText.Text.Length - MaxLogChars / 2);
            LogScroll.ScrollToEnd();
        }
        catch
        {
            // ignore
        }
    }

    void LayoutCreatorButton_OnClick(object sender, RoutedEventArgs e)
    {
        var win = new LayoutCreatorWindow { Owner = this };
        win.ShowDialog();
    }
}
