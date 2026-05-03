#nullable enable

using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Windows;

namespace BleServer;

public partial class App : Application
{
    static void LogAppTiming(string message)
    {
        try { Console.WriteLine(message); } catch { }
        try { Trace.WriteLine(message); } catch { }
    }

    CancellationTokenSource? _serverCts;
    Task? _serverTask;
    TextWriter? _consoleOutRestore;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnMainWindowClose;

        var main = new MainWindow();
        MainWindow = main;

        _consoleOutRestore = Console.Out;
        Console.SetOut(new TeeTextWriter(_consoleOutRestore, line => main.AppendLog(line)));

        _serverCts = new CancellationTokenSource();
        var args = e.Args.Length > 0 ? e.Args : Environment.GetCommandLineArgs().Skip(1).ToArray();
        // Run off the UI thread so continuations do not marshal to the Dispatcher. Otherwise OnExit's
        // Wait() on this task blocks the UI thread and deadlocks with the cancellation/finally path.
        _serverTask = Task.Run(() => Program.RunServerAsync(args, _serverCts.Token));

        main.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        var sw = Stopwatch.StartNew();
        _serverCts?.Cancel();
        LogAppTiming($"[App][Timing] Cancellation requested (+{sw.ElapsedMilliseconds} ms)");
        var finished = true;
        try
        {
            if (_serverTask != null)
                finished = _serverTask.Wait(TimeSpan.FromSeconds(6));
        }
        catch
        {
            // ignore teardown races
        }

        LogAppTiming(_serverTask == null
            ? $"[App][Timing] OnExit: no server task (+{sw.ElapsedMilliseconds} ms)"
            : finished
                ? $"[App][Timing] OnExit: server task finished after {sw.ElapsedMilliseconds} ms"
                : $"[App][Timing] OnExit: server task did not finish within 6s (elapsed {sw.ElapsedMilliseconds} ms) - process exit may truncate BLE teardown");

        if (_consoleOutRestore != null)
        {
            try { Console.SetOut(_consoleOutRestore); } catch { /* ignore */ }
        }

        base.OnExit(e);
    }
}
