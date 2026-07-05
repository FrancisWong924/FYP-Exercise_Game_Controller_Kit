#nullable enable

using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Linq;
using System.Threading.Tasks;
using System.Threading;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Timers;
using System.Windows;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Net;
using System.Net.Sockets;
using WebSocketSharp;
using WebSocketSharp.Server;
using WebSocketSharp.Net;
using Nefarius.ViGEm.Client;
using Nefarius.ViGEm.Client.Targets;
using Nefarius.ViGEm.Client.Targets.Xbox360;

namespace BleServer
{
    static class ProgramDiagnostics
    {
        /// <summary>Writes to <see cref="Console"/> (Tee → UI when alive) and <see cref="Trace"/> (not stripped in Release, unlike Debug).</summary>
        internal static void LogDiag(string message)
        {
            try { Console.WriteLine(message); } catch { /* stdout closed */ }
            try { Trace.WriteLine(message); } catch { }
        }
    }

    public class InputState
    {
        public string Type { get; set; } = "input";
        public int PlayerId { get; set; } = 0;
        public float JoyLX { get; set; } = 0f;
        public float JoyLY { get; set; } = 0f;
        public float JoyRX { get; set; } = 0f;
        public float JoyRY { get; set; } = 0f;
        public uint Buttons { get; set; } = 0;
        /// <summary>Left trigger 0–255 (BLE packet byte 2).</summary>
        public byte LeftTrigger { get; set; }
        /// <summary>Right trigger 0–255 (BLE packet byte 3).</summary>
        public byte RightTrigger { get; set; }

        public override string ToString()
            => $"Player:{PlayerId + 1} LX:{JoyLX,6:F2} LY:{JoyLY,6:F2} RX:{JoyRX,6:F2} RY:{JoyRY,6:F2} BTN:{Buttons:X4} LT:{LeftTrigger} RT:{RightTrigger}";
    }

    class Program
    {
        // private static TcpListener? _tcpListener;
        // private static readonly List<TcpClient> _connectedClients = new();
        // private static readonly object _clientsLock = new();

        // --- BLE Configuration ---
        private static readonly Guid serviceUuid = Guid.Parse("12345678-1234-5678-1234-56789abcdef0");
        private static readonly Guid notifyUuid  = Guid.Parse("12345678-1234-5678-1234-56789abcdef2"); // PC → Phone
        private static readonly Guid pingUuid    = Guid.Parse("12345678-1234-5678-1234-56789abcdef1"); // Phone → PC (WithResponse)
        private static readonly Guid inputUuid   = Guid.Parse("12345678-1234-5678-1234-56789abcdef3"); // Phone → PC (WithoutResponse)
        static GattServiceProvider? provider = null;
        private static GattLocalCharacteristic? notifyChar = null;

        // --- Session Management ---
        public static ConcurrentDictionary<int, PlayerSession> ConnectedPlayers = new ConcurrentDictionary<int, PlayerSession>();
        /// <summary>Phone → PC GPX export: UTF-8 chunks reassembled per BLE device id.</summary>
        private static readonly ConcurrentDictionary<string, StringBuilder> _phoneGpxBuffers = new();
        private static ConcurrentDictionary<string, int> _playerIdHistory = new ConcurrentDictionary<string, int>();
        private static int _nextPlayerId = -1;

        /// <summary>1-based player number for console output (internal IDs are 0-based).</summary>
        internal static int PlayerIdForLog(int playerId) => playerId + 1;

        // --- Game Engine Integration (WebSocket) ---
        static WebSocketServer? wsServer;
        internal static readonly List<WebSocketSharp.WebSocket> wsSessions = new();
        internal static readonly object _wsLock = new object();  // Separate lock for WS
        /// <summary>True while at least one game WebSocket client is connected.</summary>
        private static volatile bool _gameWsClientConnected;

        /// <summary>
        /// WebSocketSharp <see cref="WebSocket.IsAlive"/> requires a completed ping/pong round-trip.
        /// Godot (and some other clients) are connected and can send commands before that, so track Open state instead.
        /// </summary>
        internal static bool IsGameWsSessionOpen(WebSocketSharp.WebSocket? ws) =>
            ws != null && ws.ReadyState == WebSocketState.Open;

        // Timer for cleaning up stale connections
        private static System.Timers.Timer? disconnectTimer = null;
        private static bool _isCleaningUp = false;
        private static readonly object _cleanupLock = new object();

        // ViGEm Client
        public static bool IsVigemEnabled = true;
        public static ViGEmClient? vigemClient;

        private static int _shutdownDone;

        /// <summary>
        /// Set when the main window is closing (or <see cref="PerformServerShutdown"/> runs) before the GATT stack is fully gone.
        /// PING still ACKs the write, but we skip sending PONG over notify so the phone does not treat the server as alive during teardown.
        /// </summary>
        static int _bleUiTeardownRequested;

        /// <summary>Wall-clock from UI close to end of <see cref="PerformServerShutdown"/> (for diagnosing “ghost” perception).</summary>
        static Stopwatch? _uiCloseToCleanupDoneSw;

        /// <summary>Call from <see cref="MainWindow"/> as soon as the UI begins closing (before <see cref="App.OnExit"/>).</summary>
        public static void SignalBleUiClosing()
        {
            Volatile.Write(ref _bleUiTeardownRequested, 1);
            _uiCloseToCleanupDoneSw = Stopwatch.StartNew();
        }

        /// <summary>
        /// Ensures no other <see cref="Process.ProcessName"/> copy is alive so Windows releases BLE + WebSocket port.
        /// Previous 1s wait + single kill round was too weak after heavier server shutdown paths.
        /// </summary>
        static async Task EnsureExclusiveBleServerProcessAsync()
        {
            var swAll = Stopwatch.StartNew();
            var current = Process.GetCurrentProcess();
            var processName = current.ProcessName;
            var killedAny = false;

            for (var round = 0; round < 12; round++)
            {
                var others = Process.GetProcessesByName(processName)
                    .Where(p => p.Id != current.Id)
                    .ToList();
                if (others.Count == 0)
                    break;

                killedAny = true;
                Console.WriteLine($"[SERVER] Exclusive mode: round {round + 1} — terminating {others.Count} other '{processName}' instance(s).");
                foreach (var p in others)
                {
                    try
                    {
                        try
                        {
                            p.Kill(entireProcessTree: true);
                        }
                        catch (InvalidOperationException)
                        {
                            try { p.Kill(); } catch { /* already exiting */ }
                        }
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine($"[SERVER] Kill PID {p.Id}: {ex.Message}");
                    }
                }

                foreach (var p in others)
                {
                    try
                    {
                        if (!p.WaitForExit(20000))
                            Console.WriteLine($"[SERVER] Warning: PID {p.Id} did not exit within 20s.");
                    }
                    catch { /* process object may be stale */ }
                    finally
                    {
                        try { p.Dispose(); } catch { }
                    }
                }

                await Task.Delay(600);
                if (Process.GetProcessesByName(processName).All(p => p.Id == current.Id))
                    break;
            }

            var survivors = Process.GetProcessesByName(processName).Count(p => p.Id != current.Id);
            if (survivors > 0)
                Console.WriteLine($"[SERVER] Warning: {survivors} '{processName}' process(es) still running; BLE may be unstable.");

            if (killedAny)
            {
                await Task.Delay(1800);
                Console.WriteLine("[SERVER] Post-kill settle delay complete — continuing startup.");
            }
        }

        /// <summary>Stops BLE, WebSocket, and ViGEm without terminating the process. Safe to call multiple times.</summary>
        public static void PerformServerShutdown()
        {
            if (Interlocked.Exchange(ref _shutdownDone, 1) == 1) return;

            var sw = Stopwatch.StartNew();
            ProgramDiagnostics.LogDiag($"[BLE][Timing] PerformServerShutdown started");

            Volatile.Write(ref _bleUiTeardownRequested, 1);
            disconnectTimer?.Stop();
            try {
                long t = sw.ElapsedMilliseconds;
                foreach(var player in ConnectedPlayers.Values) {
                    try { player.Controller?.Disconnect(); } catch { }
                }
                ProgramDiagnostics.LogDiag($"[BLE][Timing]   ViGEm per-controller Disconnect: {sw.ElapsedMilliseconds - t} ms");

                t = sw.ElapsedMilliseconds;
                vigemClient?.Dispose();
                vigemClient = null;
                ProgramDiagnostics.LogDiag($"[BLE][Timing]   ViGEmClient.Dispose: {sw.ElapsedMilliseconds - t} ms");

                if (provider != null) {
                    Console.WriteLine("[BLE] Stopping Advertisement...");
                    t = sw.ElapsedMilliseconds;
                    provider.StopAdvertising();
                    ProgramDiagnostics.LogDiag($"[BLE][Timing]   Gatt StopAdvertising: {sw.ElapsedMilliseconds - t} ms");

                    t = sw.ElapsedMilliseconds;
                    if (notifyChar != null) {
                        notifyChar.SubscribedClientsChanged -= OnSubscribedClientsChanged;
                    }
                    provider = null;
                    notifyChar = null;
                    ConnectedPlayers.Clear();
                    _playerIdHistory.Clear();
                    ProgramDiagnostics.LogDiag($"[BLE][Timing]   Unhook notify + null provider + clear players: {sw.ElapsedMilliseconds - t} ms");
                }
                
                t = sw.ElapsedMilliseconds;
                lock (_wsLock)
                {
                    foreach (var ws in wsSessions.ToList()) { try { ws.Close(); } catch { } }
                    wsSessions.Clear();
                    _gameWsClientConnected = false;
                }
                ProgramDiagnostics.LogDiag($"[BLE][Timing]   WebSocket session Close loop: {sw.ElapsedMilliseconds - t} ms");

                t = sw.ElapsedMilliseconds;
                wsServer?.Stop();
                wsServer = null;
                ProgramDiagnostics.LogDiag($"[BLE][Timing]   WebSocketServer.Stop: {sw.ElapsedMilliseconds - t} ms");

                if (_uiCloseToCleanupDoneSw is { } uiSw)
                {
                    ProgramDiagnostics.LogDiag($"[BLE][Timing]   Wall MainWindow.OnClosing -> end of synchronous cleanup: {uiSw.ElapsedMilliseconds} ms");
                    _uiCloseToCleanupDoneSw = null;
                }

                ProgramDiagnostics.LogDiag($"[BLE][Timing] PerformServerShutdown TOTAL (sync part): {sw.ElapsedMilliseconds} ms");
                Console.WriteLine("[BLE] Cleanup complete.");
            } catch (Exception ex) {
                ProgramDiagnostics.LogDiag($"[BLE] Error after {sw.ElapsedMilliseconds} ms: {ex.Message}");
            }
        }

        static bool TryGetGamePidFromArgs(string[] args, out int gamePid)
        {
            foreach (var arg in args)
            {
                if (int.TryParse(arg, out gamePid))
                    return true;
            }

            gamePid = 0;
            return false;
        }

        /// <summary>
        /// Must be synchronous void Main (not async Task Main): WPF requires an STA thread for windows/controls.
        /// Always hosts the WPF UI (layout creator + log); <see cref="App"/> starts <see cref="RunServerAsync"/> on startup.
        /// </summary>
        [STAThread]
        static void Main(string[] args)
        {
            var app = new App();
            app.Run();
        }

        /// <summary>Runs the BLE + WebSocket server until <paramref name="cancellationToken"/> is cancelled.</summary>
        public static async Task RunServerAsync(string[] args, CancellationToken cancellationToken)
        {
            try
            {
            Volatile.Write(ref _bleUiTeardownRequested, 0);
            _uiCloseToCleanupDoneSw = null;
            await EnsureExclusiveBleServerProcessAsync();

            // SIGNAL HANDLER: Catches the CTRL_BREAK signal from C++ closeServer()
            Console.CancelKeyPress += (s, e) => {
                Console.WriteLine("[BLE] External Shutdown Signal Received...");
                e.Cancel = true; // Prevent immediate crash
                CleanUp();
            };

            // WATCHDOG: Handles the "X" button/Crashes
            if (TryGetGamePidFromArgs(args, out int gamePid))
            {
                _ = Task.Run(async () =>
                {
                    while (true)
                    {
                        await Task.Delay(1000);
                        try
                        {
                            var gameProcess = Process.GetProcessById(gamePid);
                            if (gameProcess == null || gameProcess.HasExited)
                            {
                                CleanUp();
                            }
                        }
                        catch
                        {
                            // IF THE GAME IS GONE, CLEAN UP AND KILL SELF
                            Console.WriteLine("[WATCHDOG] Game is gone. Initiating auto-cleanup...");
                            CleanUp();
                        }
                    }
                });
            }

            try 
            {
                vigemClient = new ViGEmClient();
                Console.WriteLine("[PC] ViGEmBus initialized.");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[!] ViGEmBus Error: {ex.Message}. Make sure drivers are installed.");
            }

            // 1. Create GATT Service (retry: null provider is common if the previous process just released the radio)
            GattServiceProvider? newProvider = null;
            for (var attempt = 1; attempt <= 10; attempt++)
            {
                var createResult = await GattServiceProvider.CreateAsync(serviceUuid);
                if (createResult.ServiceProvider is not null)
                {
                    newProvider = createResult.ServiceProvider;
                    break;
                }
                Console.WriteLine($"[BLE] GattServiceProvider.CreateAsync returned null (attempt {attempt}/10). Waiting for stack…");
                await Task.Delay(2500);
            }
            if (newProvider is null)
            {
                Console.WriteLine("Failed to create GATT service after retries. Check Bluetooth, admin rights, and stray ExerSyncKitServer processes.");
                return;
            }
            provider = newProvider;

            // 2. Notify characteristic
            var notifyResult = await provider.Service.CreateCharacteristicAsync(notifyUuid, 
                new GattLocalCharacteristicParameters { CharacteristicProperties = GattCharacteristicProperties.Notify });
            notifyChar = notifyResult.Characteristic;
            notifyChar.SubscribedClientsChanged -= OnSubscribedClientsChanged; 
            notifyChar.SubscribedClientsChanged += OnSubscribedClientsChanged;

            // 3. INPUT & PING characteristic (Phone → PC)
            // 3.1 INPUT characteristic – FAST, no response (buttons + joysticks)
            var inputResult = await provider.Service.CreateCharacteristicAsync(inputUuid,
                new GattLocalCharacteristicParameters
                {
                    CharacteristicProperties = GattCharacteristicProperties.WriteWithoutResponse,
                    WriteProtectionLevel = GattProtectionLevel.Plain
                });
            inputResult.Characteristic.WriteRequested += async (sender, args) =>
            {
                var deferral = args.GetDeferral();
                try
                {
                    // Identify which player sent this based on DeviceId
                    string deviceId = args.Session.DeviceId.Id;
                    var session = ConnectedPlayers.Values.FirstOrDefault(p => p.DeviceId == deviceId);
                    if (session == null) return; // Ignore input from untracked devices

                    if (!IsDeviceIdPresentOnNotifySubscriptions(deviceId))
                    {
                        RemovePlayerIfDeviceIdPresent(deviceId);
                        return;
                    }

                    var request = await args.GetRequestAsync();
                    if (request.Value == null) return;

                    byte[] bytes = request.Value.ToArray();
                    if (bytes.Length >= 16)
                    {
                        session.LastSeen = DateTime.Now;
                        var state = new InputState 
                        { 
                            PlayerId = session.PlayerId,
                            Buttons = BitConverter.ToUInt16(bytes, 0),
                            LeftTrigger = bytes[2],
                            RightTrigger = bytes[3],
                            JoyLX = BitConverter.ToInt16(bytes, 4) / 32767f,
                            JoyLY = BitConverter.ToInt16(bytes, 6) / 32767f,
                            JoyRX = BitConverter.ToInt16(bytes, 8) / 32767f,
                            JoyRY = BitConverter.ToInt16(bytes, 10) / 32767f
                        };

                        // --- BRIDGE TO VIRTUAL CONTROLLER START ---
                        if (IsVigemEnabled && session.Controller != null) 
                        {
                            UpdateViGEmController(session.Controller, state);
                        }

                        // Broadcast the specific player's data
                        _ = BroadcastInputAsync(state);

                        Console.WriteLine($"[P{PlayerIdForLog(state.PlayerId)}] BTN: {state.Buttons:X4} LT:{state.LeftTrigger} RT:{state.RightTrigger} LX:{state.JoyLX:F2} LY:{state.JoyLY:F2} RX:{state.JoyRX:F2} RY:{state.JoyRY:F2}");
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Write error: {ex.Message}");
                }
                finally
                {
                    deferral.Complete();  // Always complete!
                }
            };

            // 3.2 PING characteristic – reliable, with response (for heartbeat only)
            var pingResult = await provider.Service.CreateCharacteristicAsync(pingUuid,
                new GattLocalCharacteristicParameters
                {
                    CharacteristicProperties = GattCharacteristicProperties.Write,  // WithResponse!
                    WriteProtectionLevel = GattProtectionLevel.Plain
                }
            );
            pingResult.Characteristic.WriteRequested += async (sender, args) =>
            {
                var deferral = args.GetDeferral();
                try
                {
                    var request = await args.GetRequestAsync();  // This is correct 
                    if (request.Value == null) return;

                    byte[] bytes = request.Value.ToArray();
                    string text = Encoding.UTF8.GetString(bytes).Trim();
                    string deviceId = args.Session.DeviceId.Id;

                    // 1. Identify the PlayerSession by DeviceId
                    var session = ConnectedPlayers.Values.FirstOrDefault(p => p.DeviceId == deviceId);
                    if (session == null) 
                    {
                        var activeSubscriber = notifyChar.SubscribedClients
                            .FirstOrDefault(c => c.Session.DeviceId.Id == deviceId);

                        if (activeSubscriber != null) {
                            int assignedId = GetStickyPlayerId(deviceId);
                            var lateSession = new PlayerSession {
                                PlayerId = assignedId,
                                DeviceId = deviceId,
                                Client = activeSubscriber,
                                LastSeen = DateTime.Now,
                                Controller = vigemClient?.CreateXbox360Controller()
                            };
                            if (ConnectedPlayers.TryAdd(assignedId, lateSession))
                            {
                                Console.WriteLine($"[BLE] Late Registration for {deviceId}. Adding to tracking...");
                                session = lateSession;
                                await CompleteNewPlayerAttachmentAsync(session, assignedId, deviceId);
                            }
                            else
                            {
                                session = ConnectedPlayers.TryGetValue(assignedId, out var existing)
                                    ? existing
                                    : ConnectedPlayers.Values.FirstOrDefault(p => p.DeviceId == deviceId);
                            }
                        }
                        else
                        {
                            Console.WriteLine($"[BLE] Unauthorized client {deviceId}. Ignoring.");
                            request.Respond();
                            return;
                        }
                    }

                    // GPX export from phone (chunked UTF-8, base64 per line)
                    if (text.StartsWith("STEP_COUNT:", StringComparison.Ordinal))
                    {
                        if (session != null)
                        {
                            session.LastSeen = DateTime.Now;
                            var rest = text["STEP_COUNT:".Length..];
                            string? requestId = null;
                            int value;
                            var colon = rest.LastIndexOf(':');
                            if (colon > 0 && int.TryParse(rest[(colon + 1)..], out value))
                            {
                                requestId = rest[..colon];
                            }
                            else if (!int.TryParse(rest, out value))
                            {
                                request.Respond();
                                return;
                            }

                            BroadcastStepCountToGame(session.PlayerId, value, requestId);
                        }
                        request.Respond();
                        return;
                    }
                    if (text == "GPX_EXPORT_START")
                    {
                        _phoneGpxBuffers[deviceId] = new StringBuilder();
                        if (session != null) session.LastSeen = DateTime.Now;
                        request.Respond();
                        return;
                    }
                    if (text.StartsWith("GPX_CHUNK:", StringComparison.Ordinal))
                    {
                        try
                        {
                            var b64 = text["GPX_CHUNK:".Length..];
                            var chunkBytes = Convert.FromBase64String(b64);
                            var chunk = Encoding.UTF8.GetString(chunkBytes);
                            _phoneGpxBuffers.AddOrUpdate(
                                deviceId,
                                _ => new StringBuilder(chunk),
                                (_, sb) =>
                                {
                                    sb.Append(chunk);
                                    return sb;
                                });
                        }
                        catch (Exception ex)
                        {
                            Console.WriteLine($"[GPX] Chunk decode error: {ex.Message}");
                        }
                        if (session != null) session.LastSeen = DateTime.Now;
                        request.Respond();
                        return;
                    }
                    if (text == "GPX_EXPORT_END")
                    {
                        if (_phoneGpxBuffers.TryRemove(deviceId, out var sb))
                        {
                            var gpxXml = sb.ToString();
                            var gpxCharCount = sb.Length;
                            var playerLabel = session?.PlayerId.ToString() ?? "unknown";
                            _ = Task.Run(async () =>
                            {
                                try
                                {
                                    var tempDir = Path.Combine(
                                        Path.GetTempPath(),
                                        "ControllerExerciseGpx",
                                        Guid.NewGuid().ToString("N"));
                                    Directory.CreateDirectory(tempDir);
                                    var stamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
                                    var path = Path.Combine(tempDir, $"exercise_{stamp}_player{playerLabel}.gpx");
                                    await File.WriteAllTextAsync(path, gpxXml).ConfigureAwait(false);
                                    var geotagged = GpxRecordingPhotoProcessor.TryGeotagScreenshotsAndAugmentGpx(path, gpxXml);
                                    if (geotagged > 0)
                                        Console.WriteLine($"[GPX] Geotagged {geotagged} screenshot(s) (EXIF + GPX waypoints) for recording window.");

                                    var destFolder = GpxExportDestinationPicker.TryPickFolder();
                                    if (destFolder == null)
                                    {
                                        Console.WriteLine($"[GPX] Export cancelled; prepared files remain in: {tempDir}");
                                    }
                                    else
                                    {
                                        var exportedPath = GpxExportDestinationPicker.CopyBundle(path, destFolder);
                                        Console.WriteLine($"[GPX] Exported from phone to: {exportedPath} ({gpxCharCount} chars)");
                                        try
                                        {
                                            Directory.Delete(tempDir, recursive: true);
                                        }
                                        catch
                                        {
                                            // ignore temp cleanup failures
                                        }
                                    }
                                }
                                catch (Exception ex)
                                {
                                    Console.WriteLine($"[GPX] Save failed: {ex.Message}");
                                }
                            });
                        }
                        if (session != null) session.LastSeen = DateTime.Now;
                        request.Respond();
                        return;
                    }
                    if (text == "SCREENSHOT")
                    {
                        _ = Task.Run(async () =>
                        {
                            try
                            {
                                var captured = await GeotaggedImageExporter.CaptureLatestScreenshotAsync().ConfigureAwait(false);
                                if (captured == null)
                                {
                                    Console.WriteLine("[SCREENSHOT] No new image found (check Pictures/Screenshots and delay).");
                                    return;
                                }

                                var t = File.GetLastWriteTimeUtc(captured);
                                Console.WriteLine($"[SCREENSHOT] Capture: {captured} @ {t:O} (matched to GPX by time when you save the activity)");
                            }
                            catch (Exception ex)
                            {
                                Console.WriteLine($"[SCREENSHOT] {ex.Message}");
                            }
                        });

                        request.Respond();
                    }

                    // Handle Heartbeat (PING)
                    if (text == "PING") 
                    {
                        if (session != null) 
                        {
                            session.LastSeen = DateTime.Now;
                            if (Volatile.Read(ref _bleUiTeardownRequested) == 0)
                            {
                                await session.SendMessageViaBle("PONG", notifyChar);
                                // Console.WriteLine($"[P{session.PlayerId}] PING → PONG");
                            }
                            else
                            {
                                Console.WriteLine($"[P{PlayerIdForLog(session.PlayerId)}] PING → ACK only (UI / server teardown — no PONG)");
                            }
                            request.Respond();
                        }
                        else
                        {
                            request.Respond();
                        }
                    }
                    // 3. Handle Commands (PAUSE, RESUME, NEED_LAYOUT)
                    if (text == "PAUSE" || text == "RESUME" || text == "NEED_LAYOUT")
                    {
                        if (session != null) 
                        {
                            session.LastSeen = DateTime.Now;
                            Console.WriteLine($"[P{PlayerIdForLog(session.PlayerId)}] COMMAND RECEIVED: {text}");

                            if (IsVigemEnabled && session.Controller != null && (text == "PAUSE" || text == "RESUME"))
                            {
                                // Press the Menu/Start button
                                session.Controller.SetButtonState(Xbox360Button.Start, true);
                                session.Controller.SubmitReport();

                                // Small delay or immediate release to simulate a physical click
                                // If you don't release it, the game thinks you are holding Start down forever
                                _ = Task.Run(async () => {
                                    await Task.Delay(100); 
                                    session.Controller.SetButtonState(Xbox360Button.Start, false);
                                    session.Controller.SubmitReport();
                                });
                            }

                            // Include the PlayerId in the JSON so Cocos knows who sent it
                            var cmdObj = new { 
                                type = "command", 
                                value = text, 
                                playerId = session.PlayerId
                            };
                            
                            string cmdJson = JsonSerializer.Serialize(cmdObj);
                            byte[] cmdData = Encoding.UTF8.GetBytes(cmdJson + "\n");

                            // Broadcast to WebSocket clients (Cocos Creator)
                            lock (_wsLock)
                            {
                                foreach (var ws in wsSessions.ToList())
                                {
                                    if (IsGameWsSessionOpen(ws)) ws.Send(cmdData);
                                }
                            }

                            request.Respond(); // Always ACK the write
                        }
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Write error: {ex.Message}");
                }
                finally
                {
                    deferral.Complete();  // Always complete!
                }
            };

            // 4. Start WebSocket Server for Game Engine
            wsServer = new WebSocketServer(IPAddress.Parse("127.0.0.1"), 38421);
            wsServer.AllowForwardedRequest = true;
            wsServer.AddWebSocketService<ControllerWsBehavior>("/controller");
            wsServer.Start();
            Console.WriteLine("[WS] WebSocket server started on ws://127.0.0.1:38421/controller");

            // 5. Start advertising
            var advParams = new GattServiceProviderAdvertisingParameters
            {
                IsDiscoverable = true,
                IsConnectable = true
            };
            try 
            {
                provider.StartAdvertising(advParams);
                Console.WriteLine("✅ PC BLE GATT Server is advertising!");
                Console.WriteLine("Open your Flutter app, scan, and connect now.");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"❌ CRASH during StartAdvertising: {ex.Message}");
            }

            // _tcpListener = new TcpListener(IPAddress.Loopback, 38420);
            // _tcpListener.Start();
            // Console.WriteLine("[TCP] Listening on 127.0.0.1:38420 for game connections");

            // _ = Task.Run(async () =>
            // {
            //     while (true)
            //     {
            //         try
            //         {
            //             TcpClient client = await _tcpListener.AcceptTcpClientAsync();
            //             lock (_clientsLock)
            //             {
            //                 _connectedClients.Add(client);
            //             }
            //             Console.WriteLine($"[TCP] Game client connected ({_connectedClients.Count} total)");

            //             // Handle client disconnect
            //             _ = Task.Run(async () =>
            //             {
            //                 try
            //                 {
            //                     // Wait until the client socket is closed/disconnected
            //                     var buffer = new byte[1];
            //                     #pragma warning disable CA2022 // Intentional use of ReadAsync with count=0 to detect disconnect
            //                     await client.GetStream().ReadAsync(buffer, 0, 0);
            //                     #pragma warning restore CA2022
            //                 }
            //                 catch { } // Client disconnected
            //                 finally
            //                 {
            //                     lock (_clientsLock)
            //                     {
            //                         _connectedClients.Remove(client);
            //                         client.Close();
            //                     }
            //                     Console.WriteLine($"[TCP] Game client disconnected ({_connectedClients.Count} left)");
            //                 }
            //             });
            //         }
            //         catch (Exception ex)
            //         {
            //             Console.WriteLine($"[TCP] Accept error: {ex.Message}");
            //         }
            //     }
            // });

            // Wait for shutdown without throwing (Task.Delay+cancel raises TaskCanceledException and clutters first-chance debugging).
            if (!cancellationToken.IsCancellationRequested)
            {
                var shutdownWait = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                using (cancellationToken.Register(() => shutdownWait.TrySetResult()))
                    await shutdownWait.Task.ConfigureAwait(false);
            }
            }
            catch (OperationCanceledException)
            {
                // normal shutdown when the UI closes or token is cancelled
            }
            finally
            {
                var swFinally = Stopwatch.StartNew();
                Console.WriteLine("Server stopped.");
                PerformServerShutdown();
                Interlocked.Exchange(ref _shutdownDone, 0);
                ProgramDiagnostics.LogDiag($"[BLE][Timing] RunServerAsync finally (after PerformServerShutdown): {swFinally.ElapsedMilliseconds} ms");
            }
        }

        /// <summary>
        /// INPUT writes must match an active notify (CCCD) subscriber. Otherwise we can keep a
        /// <see cref="PlayerSession"/> while the central dropped notify, or show INPUT logs after the
        /// user considers the link dead — <see cref="GattSubscribedClient"/> reference equality in
        /// stale checks is not always reliable across callbacks.
        /// </summary>
        private static bool IsDeviceIdPresentOnNotifySubscriptions(string deviceId)
        {
            if (notifyChar is null || string.IsNullOrEmpty(deviceId)) return false;
            foreach (var sub in notifyChar.SubscribedClients)
            {
                if (sub.Session.DeviceId.Id == deviceId) return true;
            }
            return false;
        }

        private static void RemovePlayerIfDeviceIdPresent(string deviceId)
        {
            foreach (var kvp in ConnectedPlayers)
            {
                if (kvp.Value.DeviceId != deviceId) continue;
                RemovePlayer(kvp.Key);
                return;
            }
        }

        private static async Task CompleteNewPlayerAttachmentAsync(PlayerSession session, int assignedId, string deviceId)
        {
            try
            {
                session.Controller?.Connect();
                Console.WriteLine($"[ViGEm] Player {PlayerIdForLog(assignedId)} virtual controller connected.");
                Console.WriteLine($"[BLE] Player {PlayerIdForLog(assignedId)} Connected ({deviceId})");
                await Task.Delay(1000);
                SendStatusToWSClients("CONNECTED", assignedId);
                await session.SendMessageViaBle("VIBRATE", notifyChar);
                TrySyncStepCountArm();
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[BLE] Initial attachment failed: {ex.Message}");
            }
        }

        /// <summary>
        /// Arms phone-side game step counting once both a game WebSocket client and at least one phone are connected.
        /// Fixes the race where STEP_COUNT_ARM was only sent on WS OnOpen before the phone had subscribed.
        /// </summary>
        internal static void TrySyncStepCountArm()
        {
            if (!_gameWsClientConnected)
            {
                Console.WriteLine("[BLE] STEP_COUNT_ARM deferred — game WebSocket not connected yet.");
                return;
            }
            if (ConnectedPlayers.IsEmpty)
            {
                Console.WriteLine("[BLE] STEP_COUNT_ARM deferred — no phone controller connected yet.");
                return;
            }
            Console.WriteLine($"[BLE] Game WS + {ConnectedPlayers.Count} phone(s) ready — sending STEP_COUNT_ARM.");
            _ = BroadcastToAllPlayers("STEP_COUNT_ARM");
        }

        internal static void UpdateGameWsClientConnectedFlag()
        {
            lock (_wsLock)
            {
                wsSessions.RemoveAll(s => !IsGameWsSessionOpen(s));
                _gameWsClientConnected = wsSessions.Count > 0;
            }
        }

        internal static void OnGameWsSessionOpened()
        {
            UpdateGameWsClientConnectedFlag();
            foreach (var playerId in ConnectedPlayers.Keys)
            {
                SendStatusToWSClients("CONNECTED", playerId);
            }
            TrySyncStepCountArm();
        }

        internal static void OnGameWsSessionEnded()
        {
            UpdateGameWsClientConnectedFlag();
            if (_gameWsClientConnected) return;
            IsVigemEnabled = true;
            _ = BroadcastToAllPlayers("STEP_COUNT_DISARM");
        }

        private static async void OnSubscribedClientsChanged(GattLocalCharacteristic sender, object args) {
            if (notifyChar != null) 
            {
                var currentSubscribers = notifyChar.SubscribedClients;
                // A. REMOVE DISCONNECTED CLIENTS
                // If a player in our dictionary is no longer in the system's subscriber list, remove them.
                var stalePlayers = ConnectedPlayers
                    .Where(kvp => !currentSubscribers.Contains(kvp.Value.Client))
                    .ToList();
                foreach (var stale in stalePlayers) {
                    RemovePlayer(stale.Key);
                }

                // B. ADD NEW SESSIONS + GHOST FILTERING
                foreach (var client in currentSubscribers) {
                    string deviceId = client.Session.DeviceId.Id;
                    // Check if this device is already in our dictionary
                    if (!ConnectedPlayers.Values.Any(p => p.DeviceId == deviceId)) {
                        int assignedId = GetStickyPlayerId(deviceId);

                        var newSession = new PlayerSession {
                            PlayerId = assignedId,
                            DeviceId = deviceId,
                            Client = client,
                            LastSeen = DateTime.Now,
                            Controller = vigemClient?.CreateXbox360Controller()
                        };

                        if (ConnectedPlayers.TryAdd(assignedId, newSession))
                            await CompleteNewPlayerAttachmentAsync(newSession, assignedId, deviceId);
                    }
                }
                StartHeartbeatWatcher();
            }
        }

        private static void OnHeartbeatElapsed(object? sender, System.Timers.ElapsedEventArgs e) {
            var now = DateTime.Now;
            
            // Identify players who haven't been seen in over 5 seconds
            var timedOutPlayers = ConnectedPlayers
                .Where(kvp => (now - kvp.Value.LastSeen).TotalSeconds > 5)
                .ToList();

            foreach (var timedOut in timedOutPlayers) {
                RemovePlayer(timedOut.Key);
            }

            if (ConnectedPlayers.IsEmpty) {
                Console.WriteLine("[WATCHER] No players remaining. Idling...");
            }
        }

        private static void StartHeartbeatWatcher() {
            if (disconnectTimer != null) return;
            disconnectTimer = new System.Timers.Timer(2000);
            disconnectTimer.AutoReset = true;
            disconnectTimer.Elapsed += OnHeartbeatElapsed;
            disconnectTimer.Start();
        }

        private static int GetStickyPlayerId(string deviceId)
        {
            // 1. If the room is currently totally empty, reset the sequence
            if (ConnectedPlayers.IsEmpty)
            {
                Console.WriteLine("[ID] Room is empty. Resetting Player ID sequence.");
                _playerIdHistory.Clear();
                _nextPlayerId = -1; 
            }
            // 2. If we've seen this phone before, reuse the old ID
            if (_playerIdHistory.TryGetValue(deviceId, out int existingId))
            {
                Console.WriteLine($"[ID] Welcome back! Reassigning ID {PlayerIdForLog(existingId)} to {deviceId}");
                return existingId;
            }
            // 3. If it's a brand new phone, generate a new ID
            int newId = Interlocked.Increment(ref _nextPlayerId);
            _playerIdHistory.TryAdd(deviceId, newId);
            return newId;
        }

        private static void RemovePlayer(int playerId)
        {
            if (ConnectedPlayers.TryRemove(playerId, out var session)) {
                // DISCONNECT THE CONTROLLER
                session.Controller?.Disconnect();
                Console.WriteLine($"[ViGEm] Player {PlayerIdForLog(playerId)} virtual controller removed.");

                Console.WriteLine($"[BLE] Player {PlayerIdForLog(playerId)} removed (Device: {session.DeviceId}).");
                SendStatusToWSClients("DISCONNECTED", playerId);
                // Check if this was the last person
                if (ConnectedPlayers.IsEmpty)
                {
                    Console.WriteLine("[BLE] All players gone. Clearing history for next session.");
                    _playerIdHistory.Clear();
                    _nextPlayerId = -1;
                }
            }
        }

        public static void CleanUp() 
        {
            lock (_cleanupLock)
            {
                if (_isCleaningUp) return;
                _isCleaningUp = true;
            }
            Console.WriteLine("[SERVER] Cleaning up resources...");
            PerformServerShutdown();
            Thread.Sleep(500);
            // GC.Collect();
            // GC.WaitForPendingFinalizers();
            // Task.Delay(500).Wait();
            Environment.Exit(0);
        }

        private static void SendStatusToWSClients(string status, int pId)
        {
            var statusObj = new 
            { 
                type = "status", 
                value = status, 
                playerId = pId 
            };
            string statusMsg = JsonSerializer.Serialize(statusObj);
            byte[] statusData = Encoding.UTF8.GetBytes(statusMsg + "\n");
            
            lock (_wsLock) {
                foreach (var session in wsSessions.ToList()) {
                    if (IsGameWsSessionOpen(session)) session.Send(statusData);
                }
            }
        }

        private static void UpdateViGEmController(IXbox360Controller controller, InputState state)
        {
            if (controller == null) return;

            // 1. Direct Mapping (Since Flutter now sends XInput bits)
            // Cast the uint from Flutter to ushort for ViGEm
            controller.SetButtonsFull((ushort)state.Buttons);

            // 2. Map Joysticks
            // Convert -1.0 -> 1.0 back to -32768 -> 32767
            // NOTE: Windows Y-axis is inverted (Positive is UP). 
            // If your character walks backwards, change state.JoyLY to -state.JoyLY
            controller.SetAxisValue(Xbox360Axis.LeftThumbX, (short)(state.JoyLX * 32767));
            controller.SetAxisValue(Xbox360Axis.LeftThumbY, (short)(-state.JoyLY * 32767));
            
            controller.SetAxisValue(Xbox360Axis.RightThumbX, (short)(state.JoyRX * 32767));
            controller.SetAxisValue(Xbox360Axis.RightThumbY, (short)(-state.JoyRY * 32767));

            controller.SetSliderValue(Xbox360Slider.LeftTrigger, state.LeftTrigger);
            controller.SetSliderValue(Xbox360Slider.RightTrigger, state.RightTrigger);

            // 3. Send to Windows Kernel
            controller.SubmitReport();
        }

        // Helper to broadcast input to all games
        internal static void BroadcastGeotagImageToGame(
            string? requestId,
            bool success,
            string? exportPath,
            string? error)
        {
            var cmdObj = new Dictionary<string, object?>
            {
                ["type"] = "geotagImage",
                ["success"] = success,
            };
            if (!string.IsNullOrEmpty(requestId))
                cmdObj["requestId"] = requestId;
            if (!string.IsNullOrEmpty(exportPath))
                cmdObj["exportPath"] = exportPath;
            if (!string.IsNullOrEmpty(error))
                cmdObj["error"] = error;

            string cmdJson = JsonSerializer.Serialize(cmdObj);
            byte[] cmdData = Encoding.UTF8.GetBytes(cmdJson + "\n");
            lock (_wsLock)
            {
                foreach (var ws in wsSessions.ToList())
                {
                    if (IsGameWsSessionOpen(ws)) ws.Send(cmdData);
                }
            }
        }

        internal static void BroadcastStepCountToGame(int playerId, int value, string? requestId = null)
        {
            var cmdObj = new Dictionary<string, object?>
            {
                ["type"] = "stepCount",
                ["playerId"] = playerId,
                ["value"] = value,
            };
            if (!string.IsNullOrEmpty(requestId))
                cmdObj["requestId"] = requestId;

            string cmdJson = JsonSerializer.Serialize(cmdObj);
            byte[] cmdData = Encoding.UTF8.GetBytes(cmdJson + "\n");
            lock (_wsLock)
            {
                foreach (var ws in wsSessions.ToList())
                {
                    if (IsGameWsSessionOpen(ws)) ws.Send(cmdData);
                }
            }
        }

        private static Task BroadcastInputAsync(InputState input)
        {
            return Task.Run(() =>
            {
                string json = JsonSerializer.Serialize(input) + "\n";
                byte[] data = Encoding.UTF8.GetBytes(json);

                lock (_wsLock)
                {
                    for (int i = wsSessions.Count - 1; i >= 0; i--)
                    {
                        try
                        {
                            var ws = wsSessions[i];
                            if (ws != null && IsGameWsSessionOpen(ws))
                            {
                                ws.Send(data);
                            }
                            else
                            {
                                wsSessions.RemoveAt(i);
                            }
                        }
                        catch
                        {
                            wsSessions.RemoveAt(i);
                        }
                    }
                }
            });
        }

        public static async Task SendToPlayer(int pId, string message)
        {
            // notifyChar is your global GattLocalCharacteristic
            if (ConnectedPlayers.TryGetValue(pId, out var session))
            {
                await session.SendMessageViaBle(message, notifyChar);
            }
            else
            {
                Console.WriteLine($"[BLE] Target Player {PlayerIdForLog(pId)} not found in active sessions.");
            }
        }

        public static async Task BroadcastToAllPlayers(string message)
        {
            var uniqueSessions = ConnectedPlayers.Values
                .GroupBy(s => s.DeviceId)
                .Select(g => g.First());

            var tasks = uniqueSessions.Select(player => player.SendMessageViaBle(message, notifyChar));
            await Task.WhenAll(tasks);
        }

        /// <summary>Default <c>gameId</c> when <c>layoutName</c> is missing from the export.</summary>
        public const string LayoutCreatorPhoneGameId = "layout_creator";

        /// <summary>Version number paired with <c>gameId</c> for phone storage key.</summary>
        public const int LayoutCreatorPhoneVersion = 1;

        /// <summary>BLE notify payloads above this size are split (START_MSG / CHUNK / END_MSG). Typical ATT MTU ≈ 512 bytes.</summary>
        public const int BleMaxSingleNotifyUtf8Bytes = 480;

        public const int BleLayoutChunkCharSize = 400;
        public const int BleLayoutChunkDelayMs = 50;

        /// <summary>
        /// Wraps JSON from <see cref="ControllerLayoutDocument.Serialize"/> with <c>gameId</c> and <c>version</c> as required by the Flutter app.
        /// </summary>
        public static string BuildPhoneLayoutJsonFromExportedLayout(string exportedLayoutJson)
        {
            var root = JsonNode.Parse(exportedLayoutJson)!.AsObject();
            // Cannot assign root["layoutName"] directly: that node already belongs to this object under "layoutName".
            root["gameId"] = root["layoutName"]?.DeepClone() ?? JsonValue.Create(LayoutCreatorPhoneGameId);
            root["version"] = LayoutCreatorPhoneVersion;
            return root.ToJsonString();
        }

        /// <summary>
        /// Sends layout JSON to every connected phone using the same protocol as Cocos <c>sendLayout</c> (LAYOUT: or START_MSG / CHUNK / END_MSG).
        /// </summary>
        /// <returns><c>true</c> if at least one session existed and sending was attempted; <c>false</c> if no phones are connected.</returns>
        public static async Task<bool> TryBroadcastLayoutToPhonesAsync(string fullLayoutJson)
        {
            if (ConnectedPlayers.IsEmpty)
                return false;

            var inlineLayout = $"LAYOUT:{fullLayoutJson}";
            if (Encoding.UTF8.GetByteCount(inlineLayout + "\n") <= BleMaxSingleNotifyUtf8Bytes)
            {
                await BroadcastToAllPlayers(inlineLayout);
            }
            else
            {
                await BroadcastToAllPlayers("START_MSG");
                for (int i = 0; i < fullLayoutJson.Length; i += BleLayoutChunkCharSize)
                {
                    var len = Math.Min(BleLayoutChunkCharSize, fullLayoutJson.Length - i);
                    var chunk = fullLayoutJson.Substring(i, len);
                    await BroadcastToAllPlayers($"CHUNK:{chunk}");
                    await Task.Delay(BleLayoutChunkDelayMs);
                }
                await BroadcastToAllPlayers("END_MSG");
            }

            return true;
        }
    }

    public class ControllerWsBehavior : WebSocketBehavior
    {
        private static readonly System.Threading.SemaphoreSlim _sendLock = new System.Threading.SemaphoreSlim(1, 1);
        public ControllerWsBehavior()
        {
            this.Protocol = ""; 
            this.IgnoreExtensions = true;
            this.EmitOnPing = true;
        }
        protected override void OnOpen()
        {
            Console.WriteLine("[WS] websocket client connected. Disabling ViGEmBus.");
            Program.IsVigemEnabled = false;
            lock (Program._wsLock)
            {
                Program.wsSessions.RemoveAll(s => !Program.IsGameWsSessionOpen(s));
                Program.wsSessions.Add(Context.WebSocket);
            }
            Program.OnGameWsSessionOpened();
        }

        protected override void OnClose(WebSocketSharp.CloseEventArgs e)
        {
            Console.WriteLine("[WS] websocket client disconnected. Re-enabling ViGEmBus.");
            lock (Program._wsLock)
            {
                Program.wsSessions.Remove(Context.WebSocket);
            }
            Program.OnGameWsSessionEnded();
        }

        protected override void OnError(WebSocketSharp.ErrorEventArgs e)
        {
            Console.WriteLine($"[WS] Error: {e.Message}");
            lock (Program._wsLock)
            {
                Program.wsSessions.Remove(Context.WebSocket);
            }
            Program.OnGameWsSessionEnded();
        }

        protected override void OnMessage(MessageEventArgs e)
        {
            if (e.IsText)
            {
                string rawData = e.Data.Trim();
                // 1. Handle SYSTEM Commands (pId: -2)
                if (rawData.StartsWith("SYSTEM:")) 
                {
                    string sysCmd = rawData.Substring(7); // Remove "SYSTEM:"
                    if (sysCmd == "SHUTDOWN") 
                    {
                        Console.WriteLine("[WS] Shutdown command received from game.");
                        Program.CleanUp();
                    }
                    else if (sysCmd.StartsWith("GEOTAG_IMAGE:", StringComparison.Ordinal))
                    {
                        var json = sysCmd["GEOTAG_IMAGE:".Length..];
                        _ = Task.Run(async () =>
                        {
                            string? requestId = null;
                            try
                            {
                                var req = JsonSerializer.Deserialize<GeotagImageRequest>(json, new JsonSerializerOptions
                                {
                                    PropertyNameCaseInsensitive = true
                                });
                                if (req == null || string.IsNullOrWhiteSpace(req.ExportPath))
                                {
                                    Program.BroadcastGeotagImageToGame(requestId, false, null, "Invalid GEOTAG_IMAGE request.");
                                    return;
                                }

                                requestId = req.RequestId;
                                var (success, error, outputPath) = await GeotaggedImageExporter.ExportAsync(
                                    req.SourcePath,
                                    req.Lat,
                                    req.Lon,
                                    req.ExportPath).ConfigureAwait(false);
                                Program.BroadcastGeotagImageToGame(requestId, success, outputPath, error);
                            }
                            catch (Exception ex)
                            {
                                Program.BroadcastGeotagImageToGame(requestId, false, null, ex.Message);
                            }
                        });
                    }
                    return;
                }

                // 2. Handle TARGET Commands (Direct or Broadcast)
                if (rawData.StartsWith("TARGET:")) 
                {
                    // Forward to phone via BLE Notify
                    _ = Task.Run(async () => {
                        await _sendLock.WaitAsync(); // Wait for the previous message to finish
                        try 
                        {
                            // Format: TARGET:pId:actualCommand
                            // Split by ':' but only into 3 parts to preserve colons inside JSON/Base64
                            string[] parts = rawData.Split(':', 3);
                            if (parts.Length < 3) return;

                            int pId = int.Parse(parts[1]);
                            string actualCmd = parts[2];

                            if (pId == -1) 
                            {
                                // BROADCAST: Send to everyone
                                await Program.BroadcastToAllPlayers(actualCmd);
                            } 
                            else 
                            {
                                if (!Program.ConnectedPlayers.ContainsKey(pId))
                                {
                                    var connected = string.Join(", ", Program.ConnectedPlayers.Keys.OrderBy(k => k).Select(k => Program.PlayerIdForLog(k)));
                                    Console.WriteLine($"[WS] Target Player {Program.PlayerIdForLog(pId)} not found (connected: [{connected}]). Dropping: {actualCmd}");
                                    return;
                                }
                                // DIRECT: Send to specific phone
                                Console.WriteLine($"[WS] Sending to Player {Program.PlayerIdForLog(pId)}: {actualCmd}");
                                await Program.SendToPlayer(pId, actualCmd);
                            }

                            // Adaptive delay for large data transfers (Chunks)
                            if (actualCmd.StartsWith("CHUNK:")) 
                            {
                                await Task.Delay(50); 
                            }
                        }
                        catch (Exception ex) 
                        {
                            Console.WriteLine($"[WS] Error parsing target command: {ex.Message}");
                        }
                        finally {
                            _sendLock.Release(); // Let the next message proceed
                        }
                    });
                }
            }
        }
    }

    internal static class NativeInput
    {
        [DllImport("user32.dll")]
        private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);

        private const byte VK_LWIN = 0x5B;
        private const byte VK_SNAPSHOT = 0x2C;
        private const uint KEYEVENTF_KEYUP = 0x02;

        public static void TriggerWinPrintScreen()
        {
            keybd_event(VK_LWIN, 0, 0, 0);
            keybd_event(VK_SNAPSHOT, 0, 0, 0);
            keybd_event(VK_SNAPSHOT, 0, KEYEVENTF_KEYUP, 0);
            keybd_event(VK_LWIN, 0, KEYEVENTF_KEYUP, 0);
        }
    }

    internal sealed class GeotagImageRequest
    {
        public string? RequestId { get; set; }
        public double Lat { get; set; }
        public double Lon { get; set; }
        public string ExportPath { get; set; } = "";
        public string? SourcePath { get; set; }
    }

    public class PlayerSession
    {
        public int PlayerId { get; set; }
        public required string DeviceId { get; set; }
        public required GattSubscribedClient Client { get; set; }
        public IXbox360Controller? Controller { get; set; }
        public DateTime LastSeen { get; set; } = DateTime.Now;

        public async Task SendMessageViaBle(string message, GattLocalCharacteristic? notifyChar)
        {
            if (notifyChar == null || Client == null) return;

            try
            {
                if (message.StartsWith("LAYOUT:", StringComparison.Ordinal))
                {
                    var json = message.Substring(7);
                    var inline = message + "\n";
                    if (Encoding.UTF8.GetByteCount(inline) > Program.BleMaxSingleNotifyUtf8Bytes)
                    {
                        await SendLayoutJsonChunkedAsync(json, notifyChar);
                        return;
                    }
                }

                var writer = new DataWriter();
                writer.WriteString(message + "\n");
                await notifyChar.NotifyValueAsync(writer.DetachBuffer(), Client);
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[PC] Failed to send to Player {Program.PlayerIdForLog(PlayerId)}: {ex.Message}");
            }
        }

        async Task SendLayoutJsonChunkedAsync(string layoutJson, GattLocalCharacteristic notifyChar)
        {
            await SendNotifyLineAsync("START_MSG", notifyChar);
            for (int i = 0; i < layoutJson.Length; i += Program.BleLayoutChunkCharSize)
            {
                var len = Math.Min(Program.BleLayoutChunkCharSize, layoutJson.Length - i);
                await SendNotifyLineAsync($"CHUNK:{layoutJson.Substring(i, len)}", notifyChar);
                await Task.Delay(Program.BleLayoutChunkDelayMs);
            }
            await SendNotifyLineAsync("END_MSG", notifyChar);
        }

        async Task SendNotifyLineAsync(string message, GattLocalCharacteristic notifyChar)
        {
            var writer = new DataWriter();
            writer.WriteString(message + "\n");
            await notifyChar.NotifyValueAsync(writer.DetachBuffer(), Client);
        }
    }
}