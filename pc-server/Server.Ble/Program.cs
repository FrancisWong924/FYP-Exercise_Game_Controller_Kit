#nullable enable

using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;
using System;
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
        public float JoyLX { get; set; } = 0f;
        public float JoyLY { get; set; } = 0f;
        public float JoyRX { get; set; } = 0f;
        public float JoyRY { get; set; } = 0f;
        public uint Buttons { get; set; } = 0;
        public float Stepping { get; set; } = 0f;
        public float Steering { get; set; } = 0f;

        public override string ToString()
            => $"LX:{JoyLX,6:F2} LY:{JoyLY,6:F2} RX:{JoyRX,6:F2} RY:{JoyRY,6:F2} BTN:{Buttons,4} GYRO:[{Steering,6:F1}]";
    }

    class Program
    {
        private static DateTime lastPingTime = DateTime.Now;
        private static System.Timers.Timer? disconnectTimer = null;
        private static bool disconnect = false;
        private static InputState currentInput = new InputState();
        private static readonly object inputLock = new object(); // thread-safe
        private static readonly Guid serviceUuid = Guid.Parse("12345678-1234-5678-1234-56789abcdef0");
        private static readonly Guid notifyUuid  = Guid.Parse("12345678-1234-5678-1234-56789abcdef2"); // PC → Phone
        private static readonly Guid pingUuid    = Guid.Parse("12345678-1234-5678-1234-56789abcdef1"); // Phone → PC (WithResponse)
        private static readonly Guid inputUuid   = Guid.Parse("12345678-1234-5678-1234-56789abcdef3"); // Phone → PC (WithoutResponse)
        private static TcpListener? _tcpListener;
        private static readonly List<TcpClient> _connectedClients = new();
        private static readonly object _clientsLock = new();
        static WebSocketServer? wsServer;
        internal static readonly List<WebSocketSharp.WebSocket> wsSessions = new();
        internal static readonly object _wsLock = new();  // Separate lock for WS
        private static GattLocalCharacteristic? notifyChar = null;
        private static GattLocalCharacteristic? inputChar = null;
        private static GattLocalCharacteristic? pingChar = null;
        static GattServiceProvider? provider = null;

        static async Task Main(string[] args)
        {
            // KILL OLD GHOSTS
            var current = Process.GetCurrentProcess();
            var duplicates = Process.GetProcessesByName(current.ProcessName)
                                .Where(p => p.Id != current.Id);
            foreach (var duplicate in duplicates) {
                try { duplicate.Kill(); } catch { }
            }

            // Define a cleanup function
            Action cleanUp = () => {
                if (provider != null) {
                    try {
                        Console.WriteLine("[BLE] Stopping Advertisement...");
                        provider.StopAdvertising();
                        provider = null;
                        Console.WriteLine("[BLE] Cleanup complete.");
                    } catch (Exception ex) {
                        Console.WriteLine($"[BLE] Error: {ex.Message}");
                    }
                }
                Environment.Exit(0);
            };

            // SIGNAL HANDLER: Catches the CTRL_BREAK signal from C++ closeServer()
            Console.CancelKeyPress += (s, e) => {
                Console.WriteLine("[BLE] External Shutdown Signal Received...");
                e.Cancel = true; // Prevent immediate crash
                cleanUp();
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
                                throw new Exception("Game Exited");
                            }
                        }
                        catch
                        {
                            // IF THE GAME IS GONE, CLEAN UP AND KILL SELF
                            Console.WriteLine("[WATCHDOG] Game is gone. Initiating auto-cleanup...");
                            cleanUp();
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
            var notifyParams = new GattLocalCharacteristicParameters
            {
                CharacteristicProperties = GattCharacteristicProperties.Notify
            };
            var notifyResult = await provider.Service.CreateCharacteristicAsync(notifyUuid, notifyParams);
            if (notifyResult.Characteristic is null)
            {
                Console.WriteLine("Failed to create notify characteristic.");
                return;
            }
            notifyChar = notifyResult.Characteristic;
            notifyChar.SubscribedClientsChanged += async (sender, args) =>
            {
                int count = notifyChar.SubscribedClients.Count;
                Console.WriteLine($"[PC] Subscribed clients: {count}");

                if (count > 0)
                {
                    Console.WriteLine("Phone connected and subscribed!");
                    await SendCommand("VIBRATE");
                    lastPingTime = DateTime.Now;
                    disconnect = false;
                    if (disconnectTimer == null)
                    {
                        disconnectTimer = new System.Timers.Timer(2000); // check every 2s
                        disconnectTimer.Elapsed += (s, e) =>
                        {
                            if (DateTime.Now - lastPingTime > TimeSpan.FromSeconds(3))
                            {
                                Console.WriteLine("HEARTBEAT TIMEOUT → Phone is DEAD or app was force-killed!");
                                Console.WriteLine("   (SubscribedClients may still show 1 — normal on Windows)");
                                disconnect = true;
                                disconnectTimer?.Stop();
                            }
                        };
                        disconnectTimer.AutoReset = true;
                    }

                    disconnectTimer.Start();
                    Console.WriteLine("[PC] Heartbeat watcher STARTED (phone connected)");
                }
            };

            // 3. INPUT & PING characteristic (Phone → PC)
            // 3.1 INPUT characteristic – FAST, no response (buttons + joysticks)
            var inputResult = await provider.Service.CreateCharacteristicAsync(
                inputUuid,
                new GattLocalCharacteristicParameters
                {
                    CharacteristicProperties = GattCharacteristicProperties.WriteWithoutResponse,
                    WriteProtectionLevel = GattProtectionLevel.Plain
                });

            if (inputResult.Characteristic is null)
            {
                Console.WriteLine("Failed to create INPUT characteristic!");
                return;
            }
            inputChar = inputResult.Characteristic;

            // 3.2 PING characteristic – reliable, with response (for heartbeat only)
            var pingResult = await provider.Service.CreateCharacteristicAsync(
                pingUuid,
                new GattLocalCharacteristicParameters
                {
                    CharacteristicProperties = GattCharacteristicProperties.Write,  // WithResponse!
                    WriteProtectionLevel = GattProtectionLevel.Plain
                }
            );
            if (pingResult.Characteristic is null)
            {
                Console.WriteLine("Failed to create PING characteristic!");
                return;
            }
            pingChar = pingResult.Characteristic;
            // SINGLE EVENT HANDLER FOR ALL WRITES
            pingChar!.WriteRequested += WriteRequestedHandler;
            inputChar!.WriteRequested += WriteRequestedHandler;

            // 4. Handle incoming data
            async void WriteRequestedHandler(object sender, GattWriteRequestedEventArgs args)
            {
                var deferral = args.GetDeferral();  // Always get deferral
                try
                {
                    var request = await args.GetRequestAsync();  // This is correct
                    if (request.Value == null) return;

                    byte[] bytes = request.Value.ToArray();
                    var characteristic = sender as GattLocalCharacteristic;

                    // Determine which characteristic was written
                    if (characteristic == pingChar)
                    {
                        string text = Encoding.UTF8.GetString(bytes).Trim();
                        // PING characteristic
                        if (bytes.Length == 5 && 
                            bytes[0] == 'P' && bytes[1] == 'I' && 
                            bytes[2] == 'N' && bytes[3] == 'G' && bytes[4] == 0x0A)
                        {
                            lastPingTime = DateTime.Now;
                            disconnect = false;

                            var writer = new DataWriter();
                            writer.WriteString("PONG");
                            await notifyChar!.NotifyValueAsync(writer.DetachBuffer());

                            request.Respond();  // ACK the write
                            Console.WriteLine("PING received → PONG sent");
                        }
                        if (text == "PAUSE" || text == "RESUME")
                        {
                            bool shouldPause = text == "PAUSE";
                            Console.WriteLine($"COMMAND RECEIVED: {text}");

                            // TODO: Pause/resume your game here!
                            // Example:
                            // GameInstance.PauseGame(shouldPause);
                            // or send to Unity/Unreal: SendMessage("Pause(shouldPause);

                            lastPingTime = DateTime.Now;  // Also acts as heartbeat
                            request.Respond();  // ACK!
                        } 
                    }
                    else if (characteristic == inputChar)
                    {
                        // INPUT characteristic (fast data)
                        InputState localInput;  // Capture a snapshot to broadcast safely

                        lock (inputLock)
                        {
                            if (bytes.Length == 4)
                                currentInput.Buttons = BitConverter.ToUInt32(bytes, 0);
                            else if (bytes.Length == 8)
                            {
                                currentInput.JoyLX = BitConverter.ToInt16(bytes, 0) / 32767f;
                                currentInput.JoyLY = BitConverter.ToInt16(bytes, 2) / 32767f;
                                currentInput.JoyRX = BitConverter.ToInt16(bytes, 4) / 32767f;
                                currentInput.JoyRY = BitConverter.ToInt16(bytes, 6) / 32767f;
                            }
                            else if (bytes.Length >= 12)
                            {
                                // Parse buttons (bytes 0–3) — little-endian
                                currentInput.Buttons = BitConverter.ToUInt32(bytes, 0);

                                // Parse joysticks (bytes 4–11) — 4 × Int16, little-endian
                                currentInput.JoyLX = BitConverter.ToInt16(bytes, 4) / 32767f;
                                currentInput.JoyLY = BitConverter.ToInt16(bytes, 6) / 32767f;
                                currentInput.JoyRX = BitConverter.ToInt16(bytes, 8) / 32767f;
                                currentInput.JoyRY = BitConverter.ToInt16(bytes, 10) / 32767f;

                                // Parse steering (bytes 12–13) — Int16, little-endian
                                currentInput.Steering = BitConverter.ToInt16(bytes, 12) / 32767f;

                                // Parse Stepping (bytes 14–15) — Int16, little-endian
                                currentInput.Stepping = BitConverter.ToInt16(bytes, 14) / 32767f;

                                Console.WriteLine($"INPUT 12B | Btn: 0x{currentInput.Buttons:X8} " +
                                    $"L({currentInput.JoyLX,6:F2},{currentInput.JoyLY,6:F2}) " +
                                    $"R({currentInput.JoyRX,6:F2},{currentInput.JoyRY,6:F2})" +
                                    $" Stepping: {currentInput.Stepping,6:F2}" +
                                    $" Steering: {currentInput.Steering,6:F2}");
                            }

                            lastPingTime = DateTime.Now;

                            // Capture a safe copy for broadcasting (outside lock)
                            localInput = GetCurrentInput();
                        }

                        await BroadcastInputAsync(localInput);
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
            }

            // Helper to broadcast input to all games
            async Task BroadcastInputAsync(InputState input)
            {
                string json = JsonSerializer.Serialize(input) + "\n";
                byte[] data = Encoding.UTF8.GetBytes(json);

                var writeTasks = new List<ValueTask>();
                var disconnected = new List<TcpClient>();

                lock (_clientsLock)
                {
                    foreach (var client in _connectedClients)
                    {
                        try
                        {
                            NetworkStream stream = client.GetStream();
                            if (stream.CanWrite)
                            {
                                writeTasks.Add(stream.WriteAsync(data));
                            }
                        }
                        catch
                        {
                            disconnected.Add(client);
                        }
                    }

                    foreach (var dead in disconnected)
                    {
                        _connectedClients.Remove(dead);
                        dead.Close();
                    }
                }

                if (writeTasks.Count > 0)
                {
                    await Task.WhenAll(writeTasks.Select(vt => vt.AsTask()));
                }

                // WebSocket clients
                lock (_wsLock)
                {
                    for (int i = wsSessions.Count - 1; i >= 0; i--)
                    {
                        var session = wsSessions[i];
                        if (session.IsAlive)
                        {
                            session.Send(data);
                        }
                        else
                        {
                            wsSessions.RemoveAt(i);
                        }
                    }
                }
            }

            // 5. Start advertising
            var advParams = new GattServiceProviderAdvertisingParameters
            {
                IsDiscoverable = true,
                IsConnectable = true
            };
            provider.StartAdvertising(advParams);

            Console.WriteLine("✅ PC BLE GATT Server is advertising!");
            Console.WriteLine("Open your Flutter app, scan, and connect now.");

            _tcpListener = new TcpListener(IPAddress.Loopback, 38420);
            _tcpListener.Start();
            Console.WriteLine("[TCP] Listening on 127.0.0.1:38420 for game connections");

            _ = Task.Run(async () =>
            {
                while (true)
                {
                    try
                    {
                        TcpClient client = await _tcpListener.AcceptTcpClientAsync();
                        lock (_clientsLock)
                        {
                            _connectedClients.Add(client);
                        }
                        Console.WriteLine($"[TCP] Game client connected ({_connectedClients.Count} total)");

                        // Handle client disconnect
                        _ = Task.Run(async () =>
                        {
                            try
                            {
                                // Wait until the client socket is closed/disconnected
                                var buffer = new byte[1];
                                #pragma warning disable CA2022 // Intentional use of ReadAsync with count=0 to detect disconnect
                                await client.GetStream().ReadAsync(buffer, 0, 0);
                                #pragma warning restore CA2022
                            }
                            catch { } // Client disconnected
                            finally
                            {
                                lock (_clientsLock)
                                {
                                    _connectedClients.Remove(client);
                                    client.Close();
                                }
                                Console.WriteLine($"[TCP] Game client disconnected ({_connectedClients.Count} left)");
                            }
                        });
                    }
                    catch (Exception ex)
                    {
                        Console.WriteLine($"[TCP] Accept error: {ex.Message}");
                    }
                }
            });

            wsServer = new WebSocketServer(IPAddress.Parse("127.0.0.1"), 38421);
            wsServer.AllowForwardedRequest = true;
            wsServer.AddWebSocketService<ControllerWsBehavior>("/controller");
            wsServer.Start();
            Console.WriteLine("[WS] WebSocket server started on ws://127.0.0.1:38421/controller");

            // Debug timer
            var debugTimer = new System.Timers.Timer(33);
            debugTimer.Elapsed += (s, e) =>
            {
                if (!disconnect && notifyChar.SubscribedClients.Count > 0)
                {
                    // var inp = GetCurrentInput();
                    // Console.WriteLine($"[LIVE] {inp}");
                }
            };
            debugTimer.AutoReset = true;
            debugTimer.Start();
            Console.WriteLine("Press Enter to stop...");
            Console.ReadLine();

            provider.StopAdvertising();
            debugTimer.Stop();
            Console.WriteLine("Server stopped.");

            // Keep the app alive
            await Task.Delay(-1);
        }

        internal static async Task SendCommand(string command)
        {
            if (notifyChar == null)
            {
                Console.WriteLine($"[PC] Cannot send '{command}' — notify characteristic not ready");
                return;
            }

            if (notifyChar.SubscribedClients.Count == 0)
            {
                Console.WriteLine($"[PC] Cannot send '{command}' — no phone subscribed (not connected)");
                return;
            }

            try
            {
                var writer = new DataWriter();
                writer.WriteString(command + "\n");
                await notifyChar.NotifyValueAsync(writer.DetachBuffer());
                Console.WriteLine($"[PC] → Sent command to phone: {command}");
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[PC] Failed to send '{command}': {ex.Message}");
            }
        }

        public static InputState GetCurrentInput()
        {
            lock (inputLock)
            {
                return new InputState
                {
                    JoyLX = currentInput.JoyLX,
                    JoyLY = currentInput.JoyLY,
                    JoyRX = currentInput.JoyRX,
                    JoyRY = currentInput.JoyRY,
                    Buttons = currentInput.Buttons,
                    Stepping = currentInput.Stepping,
                    Steering = currentInput.Steering
                };
            }
        }
    }

    public class ControllerWsBehavior : WebSocketBehavior
    {
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
                string command = e.Data.Trim();
                Console.WriteLine($"[WS] Command from game: {command}");

                if (command == "SHUTDOWN_SERVER") 
                {
                    Console.WriteLine("[WS] Shutdown command received from game.");
                    // This will trigger the ProcessExit/Cleanup logic naturally
                    Environment.Exit(0); 
                    return;
                }

                // Forward to phone via BLE Notify
                Task.Run(async () => await Program.SendCommand(command));
            }
        }
    }
}