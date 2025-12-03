#nullable enable

using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;
using System;
using System.Text;
using System.Text.Json;
using System.Timers;
using System.Runtime.InteropServices.WindowsRuntime;

namespace BleServer
{
    public class InputState
    {
        public float JoyLX { get; set; } = 0f;
        public float JoyLY { get; set; } = 0f;
        public float JoyRX { get; set; } = 0f;
        public float JoyRY { get; set; } = 0f;
        public int Buttons { get; set; } = 0;
        public float GyroX { get; set; } = 0f;
        public float GyroY { get; set; } = 0f;
        public float GyroZ { get; set; } = 0f;

        public override string ToString()
            => $"LX:{JoyLX,6:F2} LY:{JoyLY,6:F2} RX:{JoyRX,6:F2} RY:{JoyRY,6:F2} BTN:{Buttons,4} GYRO:[{GyroX,6:F1},{GyroY,6:F1},{GyroZ,6:F1}]";
    }

    class Program
    {
        private static DateTime lastPingTime = DateTime.Now;
        private static System.Timers.Timer? disconnectTimer = null;
        private static bool disconnect = false;
        private static InputState currentInput = new InputState();
        private static readonly object inputLock = new object(); // thread-safe
        private static readonly Guid serviceUuid = Guid.Parse("12345678-1234-5678-1234-56789abcdef0");
        private static readonly Guid writeUuid   = Guid.Parse("12345678-1234-5678-1234-56789abcdef1");   // Phone → PC
        private static readonly Guid notifyUuid  = Guid.Parse("12345678-1234-5678-1234-56789abcdef2");   // PC → Phone

        static async Task Main(string[] args)
        {
            // 1. Create GATT Service
            var createResult = await GattServiceProvider.CreateAsync(serviceUuid);
            if (createResult.ServiceProvider is null)
            {
                Console.WriteLine("Failed to create service (null provider). Check Bluetooth permissions and run as Admin.");
                return;
            }
            var provider = createResult.ServiceProvider;
            GattLocalCharacteristic? notifyChar = null;
            GattLocalCharacteristic? writeChar = null;

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
            notifyChar.SubscribedClientsChanged += (sender, args) =>
            {
                int count = notifyChar.SubscribedClients.Count;
                Console.WriteLine($"[PC] Subscribed clients: {count}");

                if (count > 0)
                {
                    Console.WriteLine("Phone connected and subscribed!");
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

            // 3. Write characteristic (Phone → PC)
            var writeParams = new GattLocalCharacteristicParameters
            {
                CharacteristicProperties = GattCharacteristicProperties.Write,
                WriteProtectionLevel = GattProtectionLevel.Plain
            };
            var writeResult = await provider.Service.CreateCharacteristicAsync(writeUuid, writeParams);
            if (writeResult.Characteristic is null)
            {
                Console.WriteLine("Failed to create write characteristic.");
                return;
            }
            writeChar = writeResult.Characteristic;

            // 4. Handle incoming data
            writeChar.WriteRequested += async (sender, args) =>
            {
                var deferral = args.GetDeferral();
                try
                {
                    var request = await args.GetRequestAsync();
                    if (request.Value is null) return;

                    // Convert IBuffer to byte[] (requires the using above)
                    byte[] data = request.Value.ToArray();
                    string text = Encoding.UTF8.GetString(data);

                    Console.WriteLine($"[PC] ← Received from phone: {text}");

                    if (text == "PING\n")
                    {
                        // Reply immediately
                        lastPingTime = DateTime.Now;
                        disconnect = false;
                        using var pongWriter = new DataWriter();
                        pongWriter.WriteString($"PC_ACK: PONG");
                        await notifyChar.NotifyValueAsync(pongWriter.DetachBuffer());
                    } 
                    else
                    {
                        // Check if there are subscribed clients before notifying
                        if (notifyChar.SubscribedClients.Count == 0)
                        {
                            Console.WriteLine("No clients subscribed to notifications - skipping echo.");
                            return;
                        }

                        // Handle joystick / button input (JSON)
                        if (text.StartsWith("{") && text.EndsWith("}"))
                        {
                            try
                            {
                                var jsonDoc = System.Text.Json.JsonDocument.Parse(text);
                                var root = jsonDoc.RootElement;

                                // MUST have "type" field
                                if (!root.TryGetProperty("type", out var typeProp))
                                {
                                    Console.WriteLine($"[PC] Missing 'type' field: {text}");
                                    return;
                                }

                                string type = typeProp.GetString()!;

                                lock (inputLock)
                                {
                                    switch (type)
                                    {
                                        case "joy":
                                            currentInput.JoyLX = root.GetProperty("lx").GetInt32() / 127f;
                                            currentInput.JoyLY = root.GetProperty("ly").GetInt32() / 127f;
                                            currentInput.JoyRX = root.GetProperty("rx").GetInt32() / 127f;
                                            currentInput.JoyRY = root.GetProperty("ry").GetInt32() / 127f;
                                            break;

                                        case "btn":
                                            if (root.TryGetProperty("buttons", out var btn))
                                                currentInput.Buttons = btn.GetInt32();
                                            break;

                                        case "gyro":
                                            if (root.TryGetProperty("x", out var gx)) currentInput.GyroX = gx.GetSingle();
                                            if (root.TryGetProperty("y", out var gy)) currentInput.GyroY = gy.GetSingle();
                                            if (root.TryGetProperty("z", out var gz)) currentInput.GyroZ = gz.GetSingle();
                                            break;

                                        case "full": // optional: all in one packet
                                            if (root.TryGetProperty("lx", out var lx)) currentInput.JoyLX = lx.GetInt32() / 127f;
                                            if (root.TryGetProperty("ly", out var ly)) currentInput.JoyLY = ly.GetInt32() / 127f;
                                            if (root.TryGetProperty("rx", out var rx)) currentInput.JoyRX = rx.GetInt32() / 127f;
                                            if (root.TryGetProperty("ry", out var ry)) currentInput.JoyRY = ry.GetInt32() / 127f;
                                            if (root.TryGetProperty("buttons", out var b)) currentInput.Buttons = b.GetInt32();
                                            if (root.TryGetProperty("gx", out var gx2)) currentInput.GyroX = gx2.GetSingle();
                                            if (root.TryGetProperty("gy", out var gy2)) currentInput.GyroY = gy2.GetSingle();
                                            if (root.TryGetProperty("gz", out var gz2)) currentInput.GyroZ = gz2.GetSingle();
                                            break;

                                        default:
                                            Console.WriteLine($"[PC] Unknown packet type: {type}");
                                            break;
                                    }
                                }

                                lastPingTime = DateTime.Now; // also acts as "alive" signal

                                // Optional: Print at most 30 times per second to avoid spam
                                // Console.WriteLine($"[INPUT] {currentInput}");
                            }
                            catch (Exception jsonEx)
                            {
                                Console.WriteLine($"[PC] JSON parse error: {jsonEx.Message} | Raw: {text}");
                            }
                        }
                        
                            // Echo back via notify
                            // using var writer = new DataWriter();
                            // writer.WriteString($"PC_ACK: {text}");
                            // await notifyChar.NotifyValueAsync(writer.DetachBuffer());
                    }
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"Error handling write: {ex.Message}");
                }
                finally
                {
                    deferral.Complete();
                }
            };

            // 5. Start advertising
            var advParams = new GattServiceProviderAdvertisingParameters
            {
                IsDiscoverable = true,
                IsConnectable = true
            };
            provider.StartAdvertising(advParams);

            Console.WriteLine("✅ PC BLE GATT Server is advertising!");
            Console.WriteLine("Open your Flutter app, scan, and connect now.");
            // Debug timer
            var debugTimer = new System.Timers.Timer(33);
            debugTimer.Elapsed += (s, e) =>
            {
                if (!disconnect && notifyChar.SubscribedClients.Count > 0)
                {
                    var inp = GetCurrentInput();
                    Console.WriteLine($"[LIVE] {inp}");
                }
            };
            debugTimer.AutoReset = true;
            debugTimer.Start();
            Console.WriteLine("Press Enter to stop...");
            Console.ReadLine();

            provider.StopAdvertising();
            debugTimer.Stop();
            Console.WriteLine("Server stopped.");
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
                    GyroX = currentInput.GyroX,
                    GyroY = currentInput.GyroY,
                    GyroZ = currentInput.GyroZ
                };
            }
        }
    }
}