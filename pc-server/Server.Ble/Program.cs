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
using System.Runtime.InteropServices.WindowsRuntime;
using System.Net;
using System.Net.Sockets;
using WebSocketSharp;
using WebSocketSharp.Server;
using WebSocketSharp.Net;

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
        public float Stepping { get; set; } = 0f;
        public float Steering { get; set; } = 0f;

        public override string ToString()
            => $"Player:{PlayerId} LX:{JoyLX,6:F2} LY:{JoyLY,6:F2} RX:{JoyRX,6:F2} RY:{JoyRY,6:F2} BTN:{Buttons,4} GYRO:[{Steering,6:F1}]";
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
        private static ConcurrentDictionary<string, int> _playerIdHistory = new ConcurrentDictionary<string, int>();
        private static int _nextPlayerId = 0;

        // --- Game Engine Integration (WebSocket) ---
        static WebSocketServer? wsServer;
        internal static readonly List<WebSocketSharp.WebSocket> wsSessions = new();
        internal static readonly object _wsLock = new object();  // Separate lock for WS

        // Timer for cleaning up stale connections
        private static System.Timers.Timer? disconnectTimer = null;

        static async Task Main(string[] args)
        {
            // KILL OLD GHOSTS
            var current = Process.GetCurrentProcess();
            var duplicates = Process.GetProcessesByName(current.ProcessName)
                                .Where(p => p.Id != current.Id);
            if (duplicates.Any()) {
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
                            JoyRY = BitConverter.ToInt16(bytes, 10) / 32767f,
                            Steering = BitConverter.ToInt16(bytes, 12) / 32767f,
                            Stepping = BitConverter.ToInt16(bytes, 14) / 32767f
                        };

                        // Broadcast the specific player's data
                        _ = BroadcastInputAsync(state);
                        
                        // Optional: Console log with Player ID
                        Console.WriteLine($"[P{state.PlayerId}] BTN: {state.Buttons:X} LX: {state.JoyLX:F2} LY: {state.JoyLY:F2} RX: {state.JoyRX:F2} RY: {state.JoyRY:F2} STR: {state.Steering:F2} STP: {state.Stepping:F2}");
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

            wsServer = new WebSocketServer(IPAddress.Parse("127.0.0.1"), 38421);
            wsServer.AllowForwardedRequest = true;
            wsServer.AddWebSocketService<ControllerWsBehavior>("/controller");
            wsServer.Start();
            Console.WriteLine("[WS] WebSocket server started on ws://127.0.0.1:38421/controller");

            Console.WriteLine("Press Enter to stop...");
            Console.ReadLine();

            provider.StopAdvertising();
            Console.WriteLine("Server stopped.");

            // Keep the app alive
            await Task.Delay(-1);
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
                    if (ConnectedPlayers.TryRemove(stale.Key, out _)) {
                        Console.WriteLine($"[BLE] Subscriber dropped: Player {stale.Key}");
                        SendStatusToWSClients("DISCONNECTED", stale.Key);
                    }
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
                            LastSeen = DateTime.Now
                        };

                        if (ConnectedPlayers.TryAdd(assignedId, newSession)) {
                            try {
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
            
            // Identify players who haven't been seen in over 3 seconds
            var timedOutPlayers = ConnectedPlayers
                .Where(kvp => (now - kvp.Value.LastSeen).TotalSeconds > 3)
                .ToList();

            foreach (var timedOut in timedOutPlayers) {
                if (ConnectedPlayers.TryRemove(timedOut.Key, out var session)) {
                    Console.WriteLine($"[TIMEOUT] Player {timedOut.Key} (Device: {session.DeviceId}) timed out.");
                    SendStatusToWSClients("DISCONNECTED", timedOut.Key);
                }
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
            // 1. If we've seen this phone before, reuse the old ID
            if (_playerIdHistory.TryGetValue(deviceId, out int existingId))
            {
                Console.WriteLine($"[ID] Welcome back! Reassigning ID {existingId} to {deviceId}");
                return existingId;
            }

            // 2. If it's a brand new phone, generate a new ID
            int newId = Interlocked.Increment(ref _nextPlayerId);
            _playerIdHistory.TryAdd(deviceId, newId);
            return newId;
        }

        public static void CleanUp() 
        {
            disconnectTimer?.Stop();
            if (provider != null) {
                try {
                    Console.WriteLine("[BLE] Stopping Advertisement...");
                    provider.StopAdvertising();
                    if (notifyChar != null) {
                        notifyChar.SubscribedClientsChanged -= OnSubscribedClientsChanged;
                    }
                    provider = null;
                    notifyChar = null;
                    ConnectedPlayers.Clear();
                    _playerIdHistory.Clear();
                    lock (_wsLock)
                    {
                        foreach (var ws in wsSessions) { try { ws.Close(); } catch { } }
                        wsSessions.Clear();
                    }
                    Console.WriteLine("[BLE] Cleanup complete.");
                } catch (Exception ex) {
                    Console.WriteLine($"[BLE] Error: {ex.Message}");
                }
            }
            System.Threading.Thread.Sleep(1500);
            GC.Collect();
            GC.WaitForPendingFinalizers();
            Task.Delay(500).Wait();
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
            Console.WriteLine("[WS] Cocos Creator client connected");
            lock (Program._wsLock)
            {
                Program.wsSessions.RemoveAll(s => !s.IsAlive);
                Program.wsSessions.Add(Context.WebSocket);
            }
        }

        protected override void OnClose(WebSocketSharp.CloseEventArgs e)
        {
            Console.WriteLine("[WS] Cocos Creator client disconnected");
            lock (Program._wsLock)
            {
                Program.wsSessions.Remove(Context.WebSocket);
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