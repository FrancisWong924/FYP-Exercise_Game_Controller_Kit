using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net.WebSockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Fyp.ExerSyncKit
{
    public struct InputState
    {
        public int PlayerId;
        public float JoyLX;
        public float JoyLY;
        public float JoyRX;
        public float JoyRY;
        public uint Buttons;
    }

    public static class DefaultButtonMasks
    {
        public const uint Up = 1u << 0;
        public const uint Down = 1u << 1;
        public const uint Left = 1u << 2;
        public const uint Right = 1u << 3;
        public const uint Custom1 = 1u << 4;
        public const uint Custom2 = 1u << 5;
        public const uint LS = 1u << 6;
        public const uint RS = 1u << 7;
        public const uint LB = 1u << 8;
        public const uint RB = 1u << 9;
        public const uint LT = 1u << 10;
        public const uint RT = 1u << 11;
        public const uint A = 1u << 12;
        public const uint B = 1u << 13;
        public const uint X = 1u << 14;
        public const uint Y = 1u << 15;
    }

    public enum ControllerServerState
    {
        Stopped,
        Starting,
        Running,
        Stopping,
        Cooldown
    }

    public struct GeotagImageExportResult
    {
        public bool Success;
        public string ExportPath;
        public string Error;
    }

    public sealed class ExerSyncKitEnableOptions
    {
        public string GameId;
        public int Version = 1;
        public string LayoutJson;
        /// <summary>Optional game hooks (wired automatically on <see cref="ExerSyncKit.EnableAsync"/>).</summary>
        public Action<ControllerServerState, int> OnStateChanged;
        public Action OnConnected;
        public Action OnDisconnected;
        public Action<string> OnServerUnavailable;
        public Action<int> OnControllerConnected;
        public Action<int> OnControllerDisconnected;
        public Action OnPause;
        public Action OnResume;
        public Action<int, InputState> OnInput;
    }

    /// <summary>
    /// WebSocket client + optional Windows process launch for ExerSyncKitServer.exe.
    /// </summary>
    public sealed class ExerSyncKit : IDisposable
    {
        const string ServerName = "ExerSyncKitServer.exe";
        const int MinRestartDelayMs = 5000;
        const int ChunkSize = 400;
        static long s_cooldownUntilUtcMs;

        readonly ConcurrentQueue<string> _lineQueue = new ConcurrentQueue<string>();
        readonly object _socketLock = new object();

        ClientWebSocket _socket;
        CancellationTokenSource _receiveCts;
        Task _receiveTask;
        Process _serverProcess;

        string _buffer = "";
        string _gameId = "";
        int _version = 1;
        string _layoutJson;
        string _url = "ws://127.0.0.1:38421/controller";

        bool _serverStarted;
        bool _processLaunchOk;
        bool _isManualDisconnect;
        bool _suppressConnectionLossNotifications;
        int _connectGeneration;
        volatile bool _isSendingLargeData;
        int _currentTransferId;

        TaskCompletionSource<int> _pendingStepCount;
        string _pendingStepRequestId;
        TaskCompletionSource<GeotagImageExportResult> _pendingGeotagImage;
        string _pendingGeotagRequestId;

        ControllerServerState _lifecycle = ControllerServerState.Stopped;
        Task _reconnectTask;

        Action<ControllerServerState, int> _boundOnStateChanged;
        Action _boundOnConnected;
        Action _boundOnDisconnected;
        Action<int> _boundOnControllerConnected;
        Action<int> _boundOnControllerDisconnected;
        Action _boundOnPause;
        Action _boundOnResume;
        Action<int, InputState> _boundOnInput;
        Action<string> _boundOnServerUnavailable;

        public List<int> ConnectedControllers { get; } = new List<int>();

        public event Action<ControllerServerState, int> StateChanged;
        public event Action<int> Cooldown;
        public event Action OnConnected;
        public event Action OnDisconnected;
        public event Action<int> OnControllerConnected;
        public event Action<int> OnControllerDisconnected;
        public event Action OnPause;
        public event Action OnResume;
        public event Action<int, InputState> Input;
        public event Action<Exception> Error;
        public event Action<string> ServerUnavailable;

        public ExerSyncKit()
        {
            ExerSyncKitMainThreadPump.Register(this);
        }

        bool ShouldReportConnectionLoss =>
            !_isManualDisconnect && !_suppressConnectionLossNotifications;

        void DiscardPendingSocketEvents()
        {
            while (_lineQueue.TryDequeue(out _)) { }
            lock (_buffer)
            {
                _buffer = "";
            }
        }

        public ControllerServerState GetState() => _lifecycle;

        public int GetRemainingCooldownMs()
        {
            var remaining = s_cooldownUntilUtcMs - DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            if (remaining <= 0)
                return 0;
            if (remaining > int.MaxValue)
                return int.MaxValue;
            return (int)remaining;
        }

        public bool IsInCooldown => GetRemainingCooldownMs() > 0;

        public async Task<bool> EnableAsync(ExerSyncKitEnableOptions options)
        {
            if (options == null) throw new ArgumentNullException(nameof(options));
            if (string.IsNullOrWhiteSpace(options.GameId))
                throw new ArgumentException("GameId is required to enable the ExerSyncKit.", nameof(options));

            BindOptionsCallbacks(options);

            if (_lifecycle == ControllerServerState.Running || _lifecycle == ControllerServerState.Starting)
                return true;

            if (!LaunchServer())
            {
                var cooldownMs = GetRemainingCooldownMs();
                if (cooldownMs > 0)
                    Cooldown?.Invoke(cooldownMs);
                return false;
            }

            var version = options.Version <= 0 ? 1 : options.Version;
            await ConnectAsync(options.GameId, version, options.LayoutJson);
            return true;
        }

        void SetState(ControllerServerState s, int remainingCooldownMs = 0)
        {
            if (_lifecycle == s) return;
            _lifecycle = s;
            UnityEngine.Debug.Log(remainingCooldownMs > 0
                ? $"[ExerSyncKit] State: {s} (retry in {remainingCooldownMs} ms)"
                : $"[ExerSyncKit] State: {s}");
            StateChanged?.Invoke(s, remainingCooldownMs);
        }

        void BindOptionsCallbacks(ExerSyncKitEnableOptions options)
        {
            UnbindOptionsCallbacks();
            if (options.OnStateChanged != null)
            {
                _boundOnStateChanged = options.OnStateChanged;
                StateChanged += _boundOnStateChanged;
            }
            if (options.OnConnected != null)
            {
                _boundOnConnected = options.OnConnected;
                OnConnected += _boundOnConnected;
            }
            if (options.OnDisconnected != null)
            {
                _boundOnDisconnected = options.OnDisconnected;
                OnDisconnected += _boundOnDisconnected;
            }
            if (options.OnControllerConnected != null)
            {
                _boundOnControllerConnected = options.OnControllerConnected;
                OnControllerConnected += _boundOnControllerConnected;
            }
            if (options.OnControllerDisconnected != null)
            {
                _boundOnControllerDisconnected = options.OnControllerDisconnected;
                OnControllerDisconnected += _boundOnControllerDisconnected;
            }
            if (options.OnPause != null)
            {
                _boundOnPause = options.OnPause;
                OnPause += _boundOnPause;
            }
            if (options.OnResume != null)
            {
                _boundOnResume = options.OnResume;
                OnResume += _boundOnResume;
            }
            if (options.OnServerUnavailable != null)
            {
                _boundOnServerUnavailable = options.OnServerUnavailable;
                ServerUnavailable += _boundOnServerUnavailable;
            }
            if (options.OnInput != null)
            {
                _boundOnInput = options.OnInput;
                Input += _boundOnInput;
            }
        }

        void UnbindOptionsCallbacks()
        {
            if (_boundOnStateChanged != null)
            {
                StateChanged -= _boundOnStateChanged;
                _boundOnStateChanged = null;
            }
            if (_boundOnConnected != null)
            {
                OnConnected -= _boundOnConnected;
                _boundOnConnected = null;
            }
            if (_boundOnDisconnected != null)
            {
                OnDisconnected -= _boundOnDisconnected;
                _boundOnDisconnected = null;
            }
            if (_boundOnControllerConnected != null)
            {
                OnControllerConnected -= _boundOnControllerConnected;
                _boundOnControllerConnected = null;
            }
            if (_boundOnControllerDisconnected != null)
            {
                OnControllerDisconnected -= _boundOnControllerDisconnected;
                _boundOnControllerDisconnected = null;
            }
            if (_boundOnPause != null)
            {
                OnPause -= _boundOnPause;
                _boundOnPause = null;
            }
            if (_boundOnResume != null)
            {
                OnResume -= _boundOnResume;
                _boundOnResume = null;
            }
            if (_boundOnServerUnavailable != null)
            {
                ServerUnavailable -= _boundOnServerUnavailable;
                _boundOnServerUnavailable = null;
            }
            if (_boundOnInput != null)
            {
                Input -= _boundOnInput;
                _boundOnInput = null;
            }
        }

        void StartRestartCooldown()
        {
            s_cooldownUntilUtcMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + MinRestartDelayMs;
            var rem = GetRemainingCooldownMs();
            Cooldown?.Invoke(rem);
            SetState(ControllerServerState.Cooldown, rem);
        }

        /// <summary>Launch ExerSyncKitServer.exe (Windows only). See <see cref="ServerExeDirectory"/> and editor search paths.</summary>
        public bool LaunchServer()
        {
            if (_lifecycle == ControllerServerState.Starting || _lifecycle == ControllerServerState.Running)
                return true;
            if (_lifecycle == ControllerServerState.Stopping)
                return false;

            var cooldownMs = GetRemainingCooldownMs();
            if (cooldownMs > 0)
            {
                Cooldown?.Invoke(cooldownMs);
                SetState(ControllerServerState.Cooldown, cooldownMs);
                _processLaunchOk = false;
                return false;
            }

            SetState(ControllerServerState.Starting);

            if (Application.platform != RuntimePlatform.WindowsPlayer &&
                Application.platform != RuntimePlatform.WindowsEditor)
            {
                UnityEngine.Debug.LogWarning("[ExerSyncKit] LaunchServer: only supported on Windows.");
                _processLaunchOk = false;
                SetState(ControllerServerState.Stopped);
                return false;
            }

            try
            {
                string dir;
        
                // --- AUTOMATIC PATH HANDLING REGION ---
                #if UNITY_EDITOR
                        // Inside the Unity Editor, look directly inside the project's asset plugin directory
                        var rawDir = Path.Combine(Application.dataPath, "ExerSyncKit", "Server", "Windows");
                        dir = Path.GetFullPath(rawDir);
                #else
                        // In a built game (.exe), look directly next to the game executable
                        var gameExe = Process.GetCurrentProcess().MainModule?.FileName;
                        dir = string.IsNullOrEmpty(gameExe) ? Directory.GetCurrentDirectory() : Path.GetDirectoryName(gameExe);
                #endif
                // ---------------------------------------

                var fullPath = Path.Combine(dir ?? ".", ServerName);
                if (!File.Exists(fullPath))
                {
                    UnityEngine.Debug.LogError($"[ExerSyncKit] Server not found");
                    _processLaunchOk = false;
                    SetState(ControllerServerState.Stopped);
                    return false;
                }

                var psi = new ProcessStartInfo
                {
                    FileName = fullPath,
                    Arguments = $"{Process.GetCurrentProcess().Id} --no-activate",
                    WorkingDirectory = dir,
                    UseShellExecute = true,
                };
                _serverProcess = Process.Start(psi);
                if (_serverProcess == null || _serverProcess.HasExited)
                {
                    UnityEngine.Debug.LogError("[ExerSyncKit] Server process did not start.");
                    _processLaunchOk = false;
                    SetState(ControllerServerState.Stopped);
                    return false;
                }

                _processLaunchOk = true;
                SetState(ControllerServerState.Running);
                return true;
            }
            catch (Exception ex)
            {
                UnityEngine.Debug.LogException(ex);
                _processLaunchOk = false;
                SetState(ControllerServerState.Stopped);
                return false;
            }
        }

        public void Connect(string gameId, int version = 1, string layoutJson = null, string url = null)
        {
            _ = ConnectAsync(gameId, version, layoutJson, url);
        }

        public async Task ConnectAsync(string gameId, int version = 1, string layoutJson = null, string url = null)
        {
            _gameId = gameId;
            _version = version;
            _layoutJson = layoutJson;
            if (!string.IsNullOrEmpty(url))
                _url = url;
            _isManualDisconnect = false;
            _suppressConnectionLossNotifications = false;
            ExerSyncKitMainThreadPump.Register(this);

            var cooldownMs = GetRemainingCooldownMs();
            if (cooldownMs > 0)
            {
                Cooldown?.Invoke(cooldownMs);
                SetState(ControllerServerState.Cooldown, cooldownMs);
                return;
            }

            Interlocked.Increment(ref _connectGeneration);
            var generation = _connectGeneration;

            if (_reconnectTask != null && !_reconnectTask.IsCompleted)
            {
                try { await _reconnectTask; } catch { /* ignore */ }
                _reconnectTask = null;
            }

            var delayMs = _processLaunchOk ? 500 : 0;
            if (delayMs > 0)
                await Task.Delay(delayMs);

            if (generation != _connectGeneration) return;
            await EstablishConnectionCoreAsync(generation);
        }

        async Task TeardownSocketAsync()
        {
            ClientWebSocket ws;
            CancellationTokenSource cts;
            Task recv;
            lock (_socketLock)
            {
                ws = _socket;
                cts = _receiveCts;
                recv = _receiveTask;
                _socket = null;
                _receiveCts = null;
                _receiveTask = null;
            }

            cts?.Cancel();
            if (recv != null)
            {
                try { await recv.ConfigureAwait(false); } catch { /* ignore */ }
            }

            if (ws != null)
            {
                try
                {
                    if (ws.State == WebSocketState.Open)
                        await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None)
                            .ConfigureAwait(false);
                }
                catch { /* ignore */ }
                try { ws.Dispose(); } catch { /* ignore */ }
            }

            lock (_buffer)
            {
                _buffer = "";
            }
        }

        async Task EstablishConnectionCoreAsync(int receiveGeneration)
        {
            await TeardownSocketAsync();

            UnityEngine.Debug.Log($"[ExerSyncKit] Connecting {_url}…");
            var ws = new ClientWebSocket();
            try
            {
                await ws.ConnectAsync(new Uri(_url), CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                UnityEngine.Debug.LogWarning($"[ExerSyncKit] Connect failed: {ex.Message}");
                ws.Dispose();
                UnityEngine.Debug.LogError($"[ExerSyncKit] {ex.Message}");
                Error?.Invoke(ex);
                if (ShouldReportConnectionLoss)
                {
                    if (IsServerStillRunning())
                        ScheduleReconnect();
                    else
                        NotifyServerUnavailable("Unable to connect because server is not running.");
                }
                return;
            }

            lock (_socketLock)
            {
                _socket = ws;
                _receiveCts = new CancellationTokenSource();
                _receiveTask = Task.Run(() => ReceiveLoop(ws, _receiveCts.Token, receiveGeneration));
            }

            _serverStarted = true;
            SetState(ControllerServerState.Running);
            UnityEngine.Debug.Log("[ExerSyncKit] WebSocket connected to PC server.");
            OnConnected?.Invoke();
        }

        async Task ReceiveLoop(ClientWebSocket ws, CancellationToken ct, int generation)
        {
            var ms = new MemoryStream(4096);
            var chunk = new byte[8192];
            try
            {
                while (!ct.IsCancellationRequested && ws.State == WebSocketState.Open)
                {
                    var r = await ws.ReceiveAsync(new ArraySegment<byte>(chunk), ct).ConfigureAwait(false);
                    if (r.MessageType == WebSocketMessageType.Close)
                        break;
                    if (r.Count > 0)
                        ms.Write(chunk, 0, r.Count);
                    if (!r.EndOfMessage)
                        continue;
                    var text = Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length);
                    ms.SetLength(0);
                    EnqueueLines(text);
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                UnityEngine.Debug.LogWarning($"[ExerSyncKit] Receive ended: {ex.Message}");
            }
            finally
            {
                try { ms.Dispose(); } catch { /* ignore */ }
            }

            if (generation != Volatile.Read(ref _connectGeneration))
                return;
            if (!ct.IsCancellationRequested)
                _lineQueue.Enqueue("__CLOSED__");
        }

        void EnqueueLines(string text)
        {
            if (string.IsNullOrEmpty(text)) return;
            lock (_buffer)
            {
                _buffer += text;
                int idx;
                while ((idx = _buffer.IndexOf('\n')) >= 0)
                {
                    var line = _buffer.Substring(0, idx).Trim();
                    _buffer = _buffer.Substring(idx + 1);
                    if (line.Length > 0)
                        _lineQueue.Enqueue(line);
                }
            }
        }

        /// <summary>Called from <see cref="ExerSyncKitMainThreadPump"/> on the Unity main thread.</summary>
        public void ProcessPendingLines()
        {
            while (_lineQueue.TryDequeue(out var line))
            {
                if (line == "__CLOSED__")
                {
                    if (ShouldReportConnectionLoss)
                        HandleSocketClosed();
                    continue;
                }
                ProcessOneLine(line);
            }
        }

        void HandleSocketClosed()
        {
            AbortOngoingTransfer();
            lock (_socketLock)
            {
                _socket = null;
                _receiveCts?.Cancel();
                _receiveCts = null;
                _receiveTask = null;
            }
            ConnectedControllers.Clear();
            if (_lifecycle != ControllerServerState.Cooldown && _lifecycle != ControllerServerState.Stopping)
                SetState(ControllerServerState.Stopped);

            if (!ShouldReportConnectionLoss)
                return;

            UnityEngine.Debug.LogWarning("[ExerSyncKit] WebSocket disconnected.");
            OnDisconnected?.Invoke();
            if (IsServerStillRunning())
                ScheduleReconnect();
            else
                NotifyServerUnavailable("Server process is not running.");
        }

        void ScheduleReconnect()
        {
            if (_reconnectTask != null && !_reconnectTask.IsCompleted) return;
            if (!ShouldReportConnectionLoss) return;
            if (!IsServerStillRunning()) return;

            _reconnectTask = Task.Run(async () =>
            {
                await Task.Delay(3000).ConfigureAwait(false);
                if (!ShouldReportConnectionLoss) return;
                if (!IsServerStillRunning())
                {
                    NotifyServerUnavailable("Server process is not running.");
                    return;
                }
                Interlocked.Increment(ref _connectGeneration);
                var gen = _connectGeneration;
                await EstablishConnectionCoreAsync(gen);
            });
        }

        bool IsServerStillRunning()
        {
            if (_serverProcess != null)
            {
                try
                {
                    if (_serverProcess.HasExited)
                    {
                        _processLaunchOk = false;
                        _serverStarted = false;
                        return false;
                    }
                    return true;
                }
                catch
                {
                    _processLaunchOk = false;
                    _serverStarted = false;
                    return false;
                }
            }

            if (!_processLaunchOk)
                return false;

            var procName = Path.GetFileNameWithoutExtension(ServerName);
            try
            {
                var list = Process.GetProcessesByName(procName);
                for (var i = 0; i < list.Length; i++)
                {
                    if (!list[i].HasExited)
                        return true;
                }
            }
            catch
            {
                // if process query fails, keep existing behavior and allow reconnect attempts
                return true;
            }

            _processLaunchOk = false;
            _serverStarted = false;
            return false;
        }

        void NotifyServerUnavailable(string reason)
        {
            if (!ShouldReportConnectionLoss)
                return;

            _processLaunchOk = false;
            _serverStarted = false;
            UnityEngine.Debug.LogWarning($"[ExerSyncKit] Server unavailable. {reason}");
            ServerUnavailable?.Invoke(reason);
        }

        void ProcessOneLine(string line)
        {
            try
            {
                var o = JObject.Parse(line);
                var msgType = (string)(o["type"] ?? o["Type"]);
                var pId = ReadInt(o, "playerId", "PlayerId") ?? -1;

                if (msgType == "status")
                {
                    var value = (string)(o["value"] ?? o["Value"]);
                    if (value == "DISCONNECTED")
                    {
                        ConnectedControllers.RemoveAll(x => x == pId);
                        AbortOngoingTransfer();
                        OnControllerDisconnected?.Invoke(pId);
                    }
                    else if (value == "CONNECTED")
                    {
                        if (!ConnectedControllers.Contains(pId))
                            ConnectedControllers.Add(pId);
                        UnityEngine.Debug.Log($"[ExerSyncKit] Phone player {pId + 1} connected.");
                        if (!string.IsNullOrEmpty(_layoutJson))
                            SendCommand(pId, $"CONNECT_GAME:{_gameId}:{_version}");
                        OnControllerConnected?.Invoke(pId);
                    }
                }
                else if (msgType == "command")
                {
                    var value = (string)(o["value"] ?? o["Value"]);
                    if (value == "PAUSE") OnPause?.Invoke();
                    else if (value == "RESUME") OnResume?.Invoke();
                    else if (value == "NEED_LAYOUT" && !string.IsNullOrEmpty(_layoutJson))
                        _ = SendLayoutAsync(pId, _layoutJson);
                }
                else if (msgType == "stepCount")
                {
                    var value = ReadInt(o, "value", "Value") ?? 0;
                    var rid = (string)(o["requestId"] ?? o["RequestId"]);
                    if (_pendingStepCount != null &&
                        (string.IsNullOrEmpty(rid) || rid == _pendingStepRequestId))
                    {
                        _pendingStepCount.TrySetResult(value);
                        _pendingStepCount = null;
                        _pendingStepRequestId = null;
                    }
                }
                else if (msgType == "geotagImage")
                {
                    var rid = (string)(o["requestId"] ?? o["RequestId"]);
                    if (_pendingGeotagImage != null &&
                        (string.IsNullOrEmpty(rid) || rid == _pendingGeotagRequestId))
                    {
                        var result = new GeotagImageExportResult
                        {
                            Success = o["success"]?.Value<bool?>() ?? o["Success"]?.Value<bool?>() ?? false,
                            ExportPath = (string)(o["exportPath"] ?? o["ExportPath"] ?? ""),
                            Error = (string)(o["error"] ?? o["Error"] ?? ""),
                        };
                        _pendingGeotagImage.TrySetResult(result);
                        _pendingGeotagImage = null;
                        _pendingGeotagRequestId = null;
                    }
                }
                else if (msgType == "input")
                {
                    var st = new InputState
                    {
                        PlayerId = pId,
                        JoyLX = ReadFloat(o, "joyLX", "JoyLX"),
                        JoyLY = ReadFloat(o, "joyLY", "JoyLY"),
                        JoyRX = ReadFloat(o, "joyRX", "JoyRX"),
                        JoyRY = ReadFloat(o, "joyRY", "JoyRY"),
                        Buttons = ReadUInt(o, "buttons", "Buttons"),
                    };
                    Input?.Invoke(pId, st);
                }
            }
            catch (Exception ex)
            {
                UnityEngine.Debug.LogWarning($"[ExerSyncKit] JSON line error: {ex.Message}");
            }
        }

        static int? ReadInt(JObject o, string a, string b) =>
            o[a]?.Value<int?>() ?? o[b]?.Value<int?>();

        static float ReadFloat(JObject o, string a, string b) =>
            o[a]?.Value<float?>() ?? o[b]?.Value<float?>() ?? 0f;

        static uint ReadUInt(JObject o, string a, string b)
        {
            var v = o[a] ?? o[b];
            if (v == null) return 0;
            if (v.Type == JTokenType.Integer)
                return unchecked((uint)v.Value<long>());
            return uint.TryParse(v.ToString(), out var u) ? u : 0;
        }

        async Task SendCommandAsync(int playerId, string command)
        {
            ClientWebSocket ws;
            lock (_socketLock)
            {
                ws = _socket;
            }

            if (ws == null || ws.State != WebSocketState.Open) return;

            string payload;
            if (playerId == -2)
                payload = $"SYSTEM:{command}";
            else
                payload = $"TARGET:{playerId}:{command}";

            var bytes = Encoding.UTF8.GetBytes(payload);
            await ws.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None)
                .ConfigureAwait(false);
        }

        public void SendCommand(int playerId, string command)
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    await SendCommandAsync(playerId, command).ConfigureAwait(false);
                }
                catch (Exception ex)
                {
                    UnityEngine.Debug.LogWarning($"[ExerSyncKit] Send failed: {ex.Message}");
                }
            });
        }

        public void BroadcastCommand(string command) => SendCommand(-1, command);

        public void EnableStep(int playerId = -1) => SendCommand(playerId, "ENABLE_STEP");
        public void DisableStep(int playerId = -1) => SendCommand(playerId, "DISABLE_STEP");
        public void EnableSteering(int playerId = -1) => SendCommand(playerId, "ENABLE_STEERING");
        public void DisableSteering(int playerId = -1) => SendCommand(playerId, "DISABLE_STEERING");
        public void TriggerVibration(int playerId = -1) => SendCommand(playerId, "TRIGGER_VIBRATION");

        /// <summary>Requests the hardware step count from the phone (pedometer). Returns null on timeout.</summary>
        public async Task<int?> GetStepCounterAsync(int playerId = -1, int timeoutMs = 3000)
        {
            if (_pendingStepCount != null)
            {
                UnityEngine.Debug.LogWarning("[ExerSyncKit] GetStepCounterAsync: request already in flight.");
                return null;
            }

            var reqId = Guid.NewGuid().ToString("N")[..8];
            var tcs = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
            _pendingStepCount = tcs;
            _pendingStepRequestId = reqId;
            SendCommand(playerId, $"GET_STEP_COUNT:{reqId}");

            var completed = await Task.WhenAny(tcs.Task, Task.Delay(timeoutMs)).ConfigureAwait(false);
            if (completed != tcs.Task)
            {
                _pendingStepCount = null;
                _pendingStepRequestId = null;
                return null;
            }

            _pendingStepCount = null;
            _pendingStepRequestId = null;
            return await tcs.Task.ConfigureAwait(false);
        }

        /// <summary>Resets the phone-side game step counter (does not affect GPX recording).</summary>
        public void ResetStepCounter(int playerId = -1) => SendCommand(playerId, "RESET_STEP_COUNT");

        /// <summary>
        /// Copies or captures an image, writes GPS EXIF (lat/lon), and saves to <paramref name="exportPath"/>.
        /// When <paramref name="sourceImagePath"/> is null/empty, triggers Win+PrintScreen on the PC server.
        /// Requires the Phone Controller server (ExerSyncKitServer) to be running. Windows only.
        /// </summary>
        /// <param name="sourceImagePath">Optional existing image path on the PC. Null/empty captures a screenshot.</param>
        /// <param name="latitude">GPS latitude (-90 to 90).</param>
        /// <param name="longitude">GPS longitude (-180 to 180).</param>
        /// <param name="exportPath">Destination file path on the PC (extension optional).</param>
        /// <param name="timeoutMs">Wait for server response (screenshot capture may take several seconds).</param>
        /// <returns>Result, or null on timeout / if another export is in flight.</returns>
        public async Task<GeotagImageExportResult?> ExportGeotaggedImageAsync(
            double latitude,
            double longitude,
            string exportPath,
            string sourceImagePath = null,
            int timeoutMs = 15000)
        {
            if (_pendingGeotagImage != null)
            {
                UnityEngine.Debug.LogWarning("[ExerSyncKit] ExportGeotaggedImageAsync: request already in flight.");
                return null;
            }

            if (string.IsNullOrWhiteSpace(exportPath))
            {
                UnityEngine.Debug.LogWarning("[ExerSyncKit] ExportGeotaggedImageAsync: exportPath is required.");
                return new GeotagImageExportResult { Success = false, Error = "exportPath is required." };
            }

            var reqId = Guid.NewGuid().ToString("N")[..8];
            var payload = JsonConvert.SerializeObject(new
            {
                requestId = reqId,
                lat = latitude,
                lon = longitude,
                exportPath,
                sourcePath = string.IsNullOrWhiteSpace(sourceImagePath) ? null : sourceImagePath,
            });

            var tcs = new TaskCompletionSource<GeotagImageExportResult>(TaskCreationOptions.RunContinuationsAsynchronously);
            _pendingGeotagImage = tcs;
            _pendingGeotagRequestId = reqId;

            try
            {
                await SendCommandAsync(-2, $"GEOTAG_IMAGE:{payload}").ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                _pendingGeotagImage = null;
                _pendingGeotagRequestId = null;
                UnityEngine.Debug.LogWarning($"[ExerSyncKit] ExportGeotaggedImageAsync send failed: {ex.Message}");
                return new GeotagImageExportResult { Success = false, Error = ex.Message };
            }

            var completed = await Task.WhenAny(tcs.Task, Task.Delay(timeoutMs)).ConfigureAwait(false);
            if (completed != tcs.Task)
            {
                _pendingGeotagImage = null;
                _pendingGeotagRequestId = null;
                UnityEngine.Debug.LogWarning("[ExerSyncKit] ExportGeotaggedImageAsync timed out.");
                return null;
            }

            _pendingGeotagImage = null;
            _pendingGeotagRequestId = null;
            return await tcs.Task.ConfigureAwait(false);
        }

        public async Task SendLayoutAsync(int targetPlayerId, string layoutJson)
        {
            if (_isSendingLargeData || string.IsNullOrEmpty(layoutJson)) return;
            var merged = JObject.Parse(layoutJson);
            merged["gameId"] = _gameId;
            merged["version"] = _version;
            var jsonString = merged.ToString(Formatting.None);
            if (jsonString.Length > 1000)
                await SendLargeDataAsync(targetPlayerId, jsonString).ConfigureAwait(false);
            else
                SendCommand(targetPlayerId, $"LAYOUT:{jsonString}");
        }

        public async Task SendLargeDataAsync(int targetPlayerId, string fullString)
        {
            if (_isSendingLargeData) return;
            Interlocked.Increment(ref _currentTransferId);
            var sessionId = _currentTransferId;
            _isSendingLargeData = true;
            try
            {
                SendCommand(targetPlayerId, "START_MSG");
                for (var i = 0; i < fullString.Length; i += ChunkSize)
                {
                    if (sessionId != Volatile.Read(ref _currentTransferId)) return;
                    var len = Math.Min(ChunkSize, fullString.Length - i);
                    var chunk = fullString.Substring(i, len);
                    SendCommand(targetPlayerId, $"CHUNK:{chunk}");
                    await Task.Delay(50).ConfigureAwait(false);
                }
                if (sessionId == Volatile.Read(ref _currentTransferId))
                    SendCommand(targetPlayerId, "END_MSG");
            }
            finally
            {
                if (sessionId == Volatile.Read(ref _currentTransferId))
                    _isSendingLargeData = false;
            }
        }

        void AbortOngoingTransfer()
        {
            Interlocked.Increment(ref _currentTransferId);
            _isSendingLargeData = false;
        }

        async Task DisconnectAsync()
        {
            Interlocked.Increment(ref _connectGeneration);
            await TeardownSocketAsync();
            if (_lifecycle != ControllerServerState.Cooldown && _lifecycle != ControllerServerState.Stopping)
                SetState(ControllerServerState.Stopped);
        }

        public void Disconnect() => _ = DisconnectAsync();

        public async Task ShutdownServerAsync()
        {
            _suppressConnectionLossNotifications = true;
            _isManualDisconnect = true;
            Interlocked.Increment(ref _connectGeneration);
            ExerSyncKitMainThreadPump.Unregister(this);
            DiscardPendingSocketEvents();

            try
            {
            if (_serverStarted || _processLaunchOk)
            {
                SetState(ControllerServerState.Stopping);
                _processLaunchOk = false;
                StartRestartCooldown();

                try
                {
                    await SendCommandAsync(-2, "SHUTDOWN").ConfigureAwait(false);
                    await Task.Delay(100).ConfigureAwait(false);
                }
                catch (Exception ex)
                {
                    UnityEngine.Debug.LogWarning($"[ExerSyncKit] Send failed: {ex.Message}");
                }

                await DisconnectAsync().ConfigureAwait(false);

                _serverStarted = false;
            }
            else
            {
                var rem = GetRemainingCooldownMs();
                if (rem > 0)
                {
                    SetState(ControllerServerState.Cooldown, rem);
                    Cooldown?.Invoke(rem);
                }
                else
                    SetState(ControllerServerState.Stopped);
            }
            }
            finally
            {
                UnbindOptionsCallbacks();
            }
        }

        public int GetControllerCount() => ConnectedControllers.Count;

        public bool IsPlayerConnected(int playerId) => ConnectedControllers.Contains(playerId);

        public async Task DisableAsync()
        {
            UnbindOptionsCallbacks();
            await ShutdownServerAsync().ConfigureAwait(false);
        }

        public void Dispose()
        {
            ExerSyncKitMainThreadPump.Unregister(this);
            DisableAsync().GetAwaiter().GetResult();
        }
    }
}
