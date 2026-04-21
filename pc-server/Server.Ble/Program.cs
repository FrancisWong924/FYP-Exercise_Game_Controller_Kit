#nullable enable

using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using System.Text;
using System.Text.Json;
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
    public class InputState
    {
        public string Type { get; set; } = "input";
        public int PlayerId { get; set; } = 1;
        public float JoyLX { get; set; } = 0f;
        public float JoyLY { get; set; } = 0f;
        public float JoyRX { get; set; } = 0f;
        public float JoyRY { get; set; } = 0f;
        public uint Buttons { get; set; } = 0;

        public override string ToString()
            => $"Player:{PlayerId} LX:{JoyLX,6:F2} LY:{JoyLY,6:F2} RX:{JoyRX,6:F2} RY:{JoyRY,6:F2} BTN:{Buttons,4}]";
    }

    class Program
    {
        // private static TcpListener? _tcpListener;
        // private static readonly List<TcpClient> _connectedClients = new();
        // private static readonly object _clientsLock = new();
        [DllImport("kernel32.dll")]
        static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        const int SW_HIDE = 0;
        const int SW_SHOW = 5;

        // --- BLE Configuration ---
        private static readonly Guid serviceUuid = Guid.Parse("12345678-1234-5678-1234-56789abcdef0");
        private static readonly Guid notifyUuid  = Guid.Parse("12345678-1234-5678-1234-56789abcdef2"); // PC → Phone
        private static readonly Guid pingUuid    = Guid.Parse("12345678-1234-5678-1234-56789abcdef1"); // Phone → PC (WithResponse)
        private static readonly Guid inputUuid   = Guid.Parse("12345678-1234-5678-1234-56789abcdef3"); // Phone → PC (WithoutResponse)
        static GattServiceProvider? provider = null;
        private static GattLocalCharacteristic? notifyChar = null;

        // --- Session Management ---
        public static ConcurrentDictionary<int, PlayerSession> ConnectedPlayers = new ConcurrentDictionary<int, PlayerSession>();
        private static ConcurrentDictionary<string, int> _playerIdHistory = new ConcurrentDictionary<string, int>();
        private static int _nextPlayerId = 0;

        // --- Game Engine Integration (WebSocket) ---
        static WebSocketServer? wsServer;
        internal static readonly List<WebSocketSharp.WebSocket> wsSessions = new();
        internal static readonly object _wsLock = new object();  // Separate lock for WS

        // Timer for cleaning up stale connections
        private static System.Timers.Timer? disconnectTimer = null;
        private static bool _isCleaningUp = false;
        private static readonly object _cleanupLock = new object();

        // ViGEm Client
        public static bool IsVigemEnabled = true;
        public static ViGEmClient? vigemClient;

        private static int _shutdownDone;

        /// <summary>Stops BLE, WebSocket, and ViGEm without terminating the process. Safe to call multiple times.</summary>
        public static void PerformServerShutdown()
        {
            if (Interlocked.Exchange(ref _shutdownDone, 1) == 1) return;

            disconnectTimer?.Stop();
            try {
                foreach(var player in ConnectedPlayers.Values) {
                    try { player.Controller?.Disconnect(); } catch { }
                }
                vigemClient?.Dispose();
                vigemClient = null;

                if (provider != null) {
                    Console.WriteLine("[BLE] Stopping Advertisement...");
                    provider.StopAdvertising();
                    if (notifyChar != null) {
                        notifyChar.SubscribedClientsChanged -= OnSubscribedClientsChanged;
                    }
                    provider = null;
                    notifyChar = null;
                    ConnectedPlayers.Clear();
                    _playerIdHistory.Clear();
                }
                
                lock (_wsLock)
                {
                    foreach (var ws in wsSessions.ToList()) { try { ws.Close(); } catch { } }
                    wsSessions.Clear();
                }
                wsServer?.Stop();
                wsServer = null;
                Console.WriteLine("[BLE] Cleanup complete.");
            } catch (Exception ex) {
                Console.WriteLine($"[BLE] Error: {ex.Message}");
            }
        }

        /// <summary>
        /// Must be synchronous void Main (not async Task Main): WPF requires an STA thread for windows/controls.
        /// async Task Main runs the body on a thread-pool continuation, which throws when constructing MainWindow.
        /// </summary>
        [STAThread]
        static void Main(string[] args)
        {
            bool isCreatorMode = args.Contains("--edit");
            bool isHiddenMode = args.Contains("--hidden");

            if (isHiddenMode)
            {
                // Hide the console window immediately for players
                ShowWindow(GetConsoleWindow(), SW_HIDE);
                RunServerAsync(args, CancellationToken.None).GetAwaiter().GetResult();
            }

            if (isCreatorMode)
            {
                // Use the custom WPF App so OnStartup can:
                // - redirect Console output to MainWindow via TeeTextWriter
                // - start RunServerAsync with cancellation tied to app shutdown
                var app = new App();
                app.Run();
            }
            else
            {
                RunServerAsync(args, CancellationToken.None).GetAwaiter().GetResult();
            }
        }

        /// <summary>Runs the BLE + WebSocket server until <paramref name="cancellationToken"/> is cancelled.</summary>
        public static async Task RunServerAsync(string[] args, CancellationToken cancellationToken)
        {
            try
            {
            // KILL OLD GHOSTS
            var current = Process.GetCurrentProcess();
            var duplicates = Process.GetProcessesByName(current.ProcessName)
                                .Where(p => p.Id != current.Id);
            if (duplicates.Any()) {
                Console.WriteLine($"[SERVER] Found {duplicates.Count()} other '{current.ProcessName}' process(es); stopping them so this instance owns BLE/WebSocket (game WS will drop until this server is ready).");
                foreach (var duplicate in duplicates) {
                    try { 
                        duplicate.Kill(); 
                        duplicate.WaitForExit(1000); // Wait up to 1s for it to actually die
                    } catch { }
                }
                // Small sleep to let the OS cleanup the WebSocket port
                await Task.Delay(1000);
            }

            // SIGNAL HANDLER: Catches the CTRL_BREAK signal from C++ closeServer()
            Console.CancelKeyPress += (s, e) => {
                Console.WriteLine("[BLE] External Shutdown Signal Received...");
                e.Cancel = true; // Prevent immediate crash
                CleanUp();
            };

            // WATCHDOG: Handles the "X" button/Crashes
            if (args.Length > 0 && int.TryParse(args[0], out int gamePid))
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

            // 1. Create GATT Service
            var createResult = await GattServiceProvider.CreateAsync(serviceUuid);
            if (createResult.ServiceProvider is null)
            {
                Console.WriteLine("Failed to create service (null provider). Check Bluetooth permissions and run as Admin.");
                return;
            }
            provider = createResult.ServiceProvider;

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
                    
                    var request = await args.GetRequestAsync();
                    if (request.Value == null) return;

                    byte[] bytes = request.Value.ToArray();
                    if (bytes.Length >= 16)
                    {
                        session.LastSeen = DateTime.Now;
                        var state = new InputState 
                        { 
                            PlayerId = session.PlayerId,
                            Buttons = BitConverter.ToUInt32(bytes, 0),
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
                        
                        // Optional: Console log with Player ID
                        Console.WriteLine($"[P{state.PlayerId}] BTN: {state.Buttons:X} LX: {state.JoyLX:F2} LY: {state.JoyLY:F2} RX: {state.JoyRX:F2} RY: {state.JoyRY:F2}");
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
                            Console.WriteLine($"[BLE] Late Registration for {deviceId}. Adding to tracking...");
                            int assignedId = GetStickyPlayerId(deviceId);

                            if (!ConnectedPlayers.ContainsKey(assignedId)) 
                            {
                                session = new PlayerSession {
                                    PlayerId = assignedId,
                                    DeviceId = deviceId,
                                    Client = activeSubscriber,
                                    LastSeen = DateTime.Now
                                };
                                ConnectedPlayers.TryAdd(assignedId, session);
                                SendStatusToWSClients("CONNECTED", assignedId);
                                await session.SendMessageViaBle("VIBRATE", notifyChar);
                            }
                        }
                        else
                        {
                            Console.WriteLine($"[BLE] Unauthorized client {deviceId}. Ignoring.");
                            request.Respond();
                            return;
                        }
                    }

                    // Handle Heartbeat (PING)
                    if (text == "PING") 
                    {
                        if (session != null) 
                        {
                            // Update the timestamp (Heartbeat)
                            session.LastSeen = DateTime.Now;
                            await session.SendMessageViaBle("PONG", notifyChar);   
                            request.Respond(); 
                            Console.WriteLine($"[P{session.PlayerId}] PING → PONG");
                        }
                    }
                    // 3. Handle Commands (PAUSE, RESUME, NEED_LAYOUT)
                    if (text == "PAUSE" || text == "RESUME" || text == "NEED_LAYOUT")
                    {
                        if (session != null) 
                        {
                            session.LastSeen = DateTime.Now;
                            Console.WriteLine($"[P{session.PlayerId}] COMMAND RECEIVED: {text}");

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
                                    if (ws.IsAlive) ws.Send(cmdData);
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

            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            }
            catch (OperationCanceledException)
            {
                // normal shutdown when the UI closes or token is cancelled
            }
            finally
            {
                Console.WriteLine("Server stopped.");
                PerformServerShutdown();
                Interlocked.Exchange(ref _shutdownDone, 0);
            }
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

                        if (ConnectedPlayers.TryAdd(assignedId, newSession)) {
                            try {
                                newSession.Controller?.Connect(); // Plug it into Windows
                                Console.WriteLine($"[ViGEm] Player {assignedId} virtual controller connected.");
                                Console.WriteLine($"[BLE] Player {assignedId} Connected ({deviceId})");
                                await Task.Delay(1000);
                                SendStatusToWSClients("CONNECTED", assignedId);
                                await newSession.SendMessageViaBle("VIBRATE", notifyChar);
                            } catch (Exception ex) {
                                Console.WriteLine($"[BLE] Initial failed: {ex.Message}");
                            }
                        }
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
                _nextPlayerId = 0; 
            }
            // 2. If we've seen this phone before, reuse the old ID
            if (_playerIdHistory.TryGetValue(deviceId, out int existingId))
            {
                Console.WriteLine($"[ID] Welcome back! Reassigning ID {existingId} to {deviceId}");
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
                Console.WriteLine($"[ViGEm] Player {playerId} virtual controller removed.");

                Console.WriteLine($"[TIMEOUT] Player {playerId} (Device: {session.DeviceId}) timed out.");
                SendStatusToWSClients("DISCONNECTED", playerId);
                // Check if this was the last person
                if (ConnectedPlayers.IsEmpty)
                {
                    Console.WriteLine("[BLE] All players gone. Clearing history for next session.");
                    _playerIdHistory.Clear();
                    _nextPlayerId = 0;
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
                    if (session.IsAlive) session.Send(statusData);
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

            // 3. Send to Windows Kernel
            controller.SubmitReport();
        }

        // Helper to broadcast input to all games
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
                            if (ws != null && ws.IsAlive)
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
                Console.WriteLine($"[BLE] Target Player {pId} not found in active sessions.");
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
            Console.WriteLine("[WS] Cocos Creator client connected. Disabling ViGEmBus.");
            Program.IsVigemEnabled = false;
            lock (Program._wsLock)
            {
                Program.wsSessions.RemoveAll(s => !s.IsAlive);
                Program.wsSessions.Add(Context.WebSocket);
            }
        }

        protected override void OnClose(WebSocketSharp.CloseEventArgs e)
        {
            Console.WriteLine("[WS] Cocos Creator client disconnected. Re-enabling ViGEmBus.");
            lock (Program._wsLock)
            {
                Program.wsSessions.Remove(Context.WebSocket);
                if (Program.wsSessions.Count == 0)
                {
                    Program.IsVigemEnabled = true;
                }
            }
        }

        protected override void OnError(WebSocketSharp.ErrorEventArgs e)
        {
            Console.WriteLine($"[WS] Error: {e.Message}");
            lock (Program._wsLock)
            {
                Program.wsSessions.Remove(Context.WebSocket);
            }
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
                                    return; 
                                }
                                // DIRECT: Send to specific phone
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
                var writer = new DataWriter();
                writer.WriteString(message + "\n");
                // Use the specific client stored in this session
                await notifyChar.NotifyValueAsync(writer.DetachBuffer(), Client);
                Console.WriteLine($"[PC] → Sent to Player {PlayerId}: {message}");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[PC] Failed to send to Player {PlayerId}: {ex.Message}");
            }
        }
    }
}