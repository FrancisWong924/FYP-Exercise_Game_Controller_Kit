#nullable enable

using System.IO;
using System.Linq;
using System.Windows;

namespace BleServer;

public partial class App : Application
{
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
        _serverTask = Program.RunServerAsync(args, _serverCts.Token);

        main.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _serverCts?.Cancel();
        try
        {
            _serverTask?.Wait(TimeSpan.FromSeconds(6));
        }
        catch
        {
            // ignore teardown races
        }

        if (_consoleOutRestore != null)
        {
            try { Console.SetOut(_consoleOutRestore); } catch { /* ignore */ }
        }

        base.OnExit(e);
    }
}
