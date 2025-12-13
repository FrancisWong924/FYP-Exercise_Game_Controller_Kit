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
        public uint Buttons { get; set; } = 0;
        public float Steering;

        public override string ToString()
            => $"LX:{JoyLX,6:F2} LY:{JoyLY,6:F2} RX:{JoyRX,6:F2} RY:{JoyRY,6:F2} BTN:{Buttons,4} GYRO:[{Steering,6:F1}]";
    }

    class Program
    {
        private static DateTime lastPingTime = DateTime.Now;
        private static System.Timers.Timer? disconnectTimer = null;
        private static bool disconnect = false;
        private static InputState lastLoggedInput = new InputState();
        private static InputState currentInput = new InputState();
        private static readonly object inputLock = new object(); // thread-safe
        private static readonly Guid serviceUuid = Guid.Parse("12345678-1234-5678-1234-56789abcdef0");
        private static readonly Guid notifyUuid  = Guid.Parse("12345678-1234-5678-1234-56789abcdef2"); // PC → Phone
        private static readonly Guid pingUuid    = Guid.Parse("12345678-1234-5678-1234-56789abcdef1"); // Phone → PC (WithResponse)
        private static readonly Guid inputUuid   = Guid.Parse("12345678-1234-5678-1234-56789abcdef3"); // Phone → PC (WithoutResponse)

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
            GattLocalCharacteristic? inputChar = null;
            GattLocalCharacteristic? pingChar = null;

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

                                if (bytes.Length >= 14)
                                {
                                    currentInput.Steering = BitConverter.ToInt16(bytes, 12) / 32767f;
                                }
                                else
                                {
                                    currentInput.Steering = 0f;  // No steering data → neutral
                                }

                                // Console.WriteLine($"INPUT 12B | Btn: 0x{currentInput.Buttons:X8} " +
                                //     $"L({currentInput.JoyLX,6:F2},{currentInput.JoyLY,6:F2}) " +
                                //     $"R({currentInput.JoyRX,6:F2},{currentInput.JoyRY,6:F2})");
                                
                                // var newInput = new InputState
                                // {
                                //     Buttons = BitConverter.ToUInt32(bytes, 0),
                                //     JoyLX   = BitConverter.ToInt16(bytes, 4)  / 32767f,
                                //     JoyLY   = BitConverter.ToInt16(bytes, 6)  / 32767f,
                                //     JoyRX   = BitConverter.ToInt16(bytes, 8)  / 32767f,
                                //     JoyRY   = BitConverter.ToInt16(bytes, 10) / 32767f,
                                //     Steering = currentInput.Steering
                                // };
                                // // Only print if something changed
                                // if (newInput.Buttons != lastLoggedInput.Buttons ||
                                //     Math.Abs(newInput.JoyLX - lastLoggedInput.JoyLX) > 0.01f ||
                                //     Math.Abs(newInput.JoyLY - lastLoggedInput.JoyLY) > 0.01f ||
                                //     Math.Abs(newInput.JoyRX - lastLoggedInput.JoyRX) > 0.01f ||
                                //     Math.Abs(newInput.JoyRY - lastLoggedInput.JoyRY) > 0.01f ||
                                //     Math.Abs(newInput.Steering - lastLoggedInput.Steering) > 0.01f)
                                // {
                                //     Console.WriteLine($"INPUT CHANGED | Btn: 0x{newInput.Buttons:X8} " +
                                //                     $"L({newInput.JoyLX,6:F2},{newInput.JoyLY,6:F2}) " +
                                //                     $"R({newInput.JoyRX,6:F2},{newInput.JoyRY,6:F2})" +
                                //                     $"Steering: {newInput.Steering,6:F2}");

                                //     lastLoggedInput = newInput;
                                // }
                            }
                            lastPingTime = DateTime.Now;
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
            }

            async Task SendCommand(string command)
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
                    writer.WriteString(command + "\n");  // Match your phone's utf8.decode().trim()
                    await notifyChar.NotifyValueAsync(writer.DetachBuffer());
                    Console.WriteLine($"[PC] → Sent command: {command}");
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"[PC] Failed to send '{command}': {ex.Message}");
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
                    Steering = currentInput.Steering
                };
            }
        }
    }
}