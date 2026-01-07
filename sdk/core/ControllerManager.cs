namespace ControllerSdk.Core;

using System;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

public class ControllerManager
{
    public static ControllerManager Instance { get; } = new();

    public event Action<InputState>? OnInputReceived;
    public event Action? OnConnected;
    public event Action? OnDisconnected;

    public bool IsConnected { get; private set; }
    public InputState CurrentInput { get; private set; } = new();

    private TcpClient? _client;
    private Task? _receiveTask;
    private CancellationTokenSource? _cts;

    // Auto-reconnect settings
    public bool AutoReconnect { get; set; } = true;
    public int InitialReconnectDelayMs { get; set; } = 2000; // 2 seconds
    public int MaxReconnectDelayMs { get; set; } = 10000;   // Cap at 10 seconds
    public int MaxRetryCount { get; set; } = -1;            // -1 = infinite, 0 = disable after first fail

    private Task? _reconnectTask;
    private readonly object _reconnectLock = new();

    private string _host = "127.0.0.1";
    private int _port = 38420;
    private int _currentRetryCount = 0;
    private int _currentDelayMs;

    private ControllerManager()
    {
        ResetReconnectDelay();
    }

    private void ResetReconnectDelay()
    {
        _currentDelayMs = InitialReconnectDelayMs;
        _currentRetryCount = 0;
    }

    public async Task ConnectAsync(string host = "127.0.0.1", int port = 38420)
    {
        _host = host;
        _port = port;

        // Clean up any previous connection
        Disconnect();

        await TryConnectInternal();
    }

    private async Task TryConnectInternal()
    {
        try
        {
            _client = new TcpClient();
            _cts = new CancellationTokenSource();

            await _client.ConnectAsync(_host, _port, _cts.Token);

            IsConnected = true;
            ResetReconnectDelay(); // Success → reset backoff
            OnConnected?.Invoke();

            _receiveTask = Task.Run(() => ReceiveLoop(_cts.Token), _cts.Token);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[ControllerSDK] Connect failed: {ex.Message}");
            HandleConnectionFailed();
        }
    }

    private async void ReceiveLoop(CancellationToken cancellationToken)
    {
        if (_client == null) return;
        
        var stream = _client!.GetStream();
        var buffer = new byte[1024];
        var sb = new StringBuilder();

        try
        {
            while (_client.Connected && !cancellationToken.IsCancellationRequested)
            {
                int bytesRead = await stream.ReadAsync(buffer, cancellationToken);
                if (bytesRead == 0) break; // disconnected

                string data = Encoding.UTF8.GetString(buffer, 0, bytesRead);
                sb.Append(data);

                // Process line-by-line (your server sends \n)
                int newlineIndex;
                while ((newlineIndex = sb.ToString().IndexOf('\n')) >= 0)
                {
                    string line = sb.ToString(0, newlineIndex);
                    sb.Remove(0, newlineIndex + 1);

                    if (string.IsNullOrWhiteSpace(line)) continue;

                    var input = JsonSerializer.Deserialize<InputState>(line);
                    if (input != null)
                    {
                        CurrentInput = input;
                        OnInputReceived?.Invoke(input);
                    }
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Expected when cancelling
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[ControllerSDK] Receive error: {ex.Message}");
        }
        finally
        {
            HandleDisconnection(); // Always ensure cleanup and event
        }
    }

    private void HandleDisconnection()
    {
        bool wasConnected = IsConnected;
        Disconnect(); // Clean up

        if (wasConnected && AutoReconnect)
        {
            StartReconnectTask();
        }
    }

    private void HandleConnectionFailed()
    {
        Disconnect();

        if (AutoReconnect)
        {
            StartReconnectTask();
        }
    }

    private void StartReconnectTask()
    {
        lock (_reconnectLock)
        {
            if (_reconnectTask != null) return; // Already running

            _reconnectTask = Task.Run(async () =>
            {
                while (AutoReconnect)
                {
                    if (MaxRetryCount >= 0 && _currentRetryCount >= MaxRetryCount)
                    {
                        Console.WriteLine("[ControllerSDK] Max reconnect attempts reached. Giving up.");
                        break;
                    }

                    Console.WriteLine($"[ControllerSDK] Attempting reconnect in {_currentDelayMs / 1000}s... (Attempt #{_currentRetryCount + 1})");
                    await Task.Delay(_currentDelayMs);

                    _currentRetryCount++;
                    _currentDelayMs = Math.Min(_currentDelayMs * 2, MaxReconnectDelayMs); // Exponential backoff

                    await TryConnectInternal();

                    if (IsConnected)
                    {
                        Console.WriteLine("[ControllerSDK] Reconnected successfully!");
                        break;
                    }
                }

                _reconnectTask = null;
            });
        }
    }

    private void CancelReconnectTask()
    {
        lock (_reconnectLock)
        {
            _reconnectTask?.Wait(100); // Optional: wait briefly
            _reconnectTask = null;
        }
    }

    public void Disconnect()
    {
        if (!IsConnected && _client == null) return;

        _cts?.Cancel();
        _cts?.Dispose();
        _cts = null;

        try
        {
            _client?.Close();
        }
        catch {}
        _client?.Dispose();
        _client = null;

        bool wasConnected = IsConnected;  // Capture before
        IsConnected = false;
        if (wasConnected)
        {
            OnDisconnected?.Invoke();
        }
    }

    public void StopAutoReconnect()
    {
        AutoReconnect = false;
        CancelReconnectTask();
    }
}
