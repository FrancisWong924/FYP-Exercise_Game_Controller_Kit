// Program.cs
using InTheHand.Net;
using InTheHand.Net.Bluetooth;
using InTheHand.Net.Sockets;
using System.Text;

class Program
{
    // === SAME UUID AS ANDROID ===
    private static readonly Guid UUID_SPP = new Guid("00001101-0000-1000-8000-00805F9B34FB");
    private static BluetoothClient? client;

    static async Task Main(string[] args)
    {
        Console.WriteLine("[PC Server] Starting Bluetooth client with AUTO DISCOVERY...");
        Console.WriteLine($"[PC Server] Looking for phone with SPP service (UUID: {UUID_SPP})");
        Console.WriteLine();

        while (true)
        {
            try
            {
                BluetoothAddress? phoneAddress = await DiscoverPhoneAsync();
                if (phoneAddress == null)
                {
                    Console.WriteLine("[PC Server] No phone found. Retrying in 1s...");
                    await Task.Delay(1000);
                    continue;
                }

                Console.WriteLine($"[PC Server] Found phone: {phoneAddress}");
                await ConnectAndListen(phoneAddress);
            }
            catch (Exception ex)
            {
                if (ex.Message.Contains("refused"))
                    Console.WriteLine("[ERROR] Phone not listening or not paired.");
                else if (ex.Message.Contains("host"))
                    Console.WriteLine("[ERROR] Bluetooth OFF or out of range.");
                else
                    Console.WriteLine($"[ERROR] {ex.Message}");
            }

            Console.WriteLine("[PC Server] Reconnecting in 5 seconds...");
            await Task.Delay(5000);
        }
    }

    // ————————————————————————————————————————
    // 1. DISCOVER PHONE (by SPP service)
    // ————————————————————————————————————————
    static async Task<BluetoothAddress?> DiscoverPhoneAsync()
    {
        using var discoverer = new BluetoothClient();

        Console.WriteLine("[Discovery] Scanning for devices...");

        // Step 1: Discover nearby devices
        var devices = discoverer.DiscoverDevices(20);

        Console.WriteLine($"[Discovery] Found {devices.Count} device(s). Checking for SPP service...");

        foreach (var device in devices)
        {
            Console.WriteLine($"[Discovery] Trying {device.DeviceName} ({device.DeviceAddress})...");

            var testClient = new BluetoothClient();
            try
            {
                await testClient.ConnectAsync(device.DeviceAddress, UUID_SPP);
                Console.WriteLine($"[Discovery] SUCCESS! {device.DeviceName} is your phone.");

                // DO NOT CLOSE — return the OPEN client for real use
                client = testClient;
                return device.DeviceAddress;
            }
            catch (Exception ex)
            {
                testClient.Close();
                Console.WriteLine($"[Discovery] Failed: {ex.Message}");
            }
        }

        return null;
    }

    // ————————————————————————————————————————
    // 2. CONNECT & LISTEN
    // ————————————————————————————————————————
    static async Task ConnectAndListen(BluetoothAddress address)
    {
        // client is ALREADY CONNECTED from discovery!
        Console.WriteLine("[PC Server] Already connected! Starting data stream...");

        using var stream = client!.GetStream();
        using var reader = new StreamReader(stream, Encoding.UTF8);

        while (client.Connected)
        {
            string? data = await reader.ReadLineAsync();
            if (data == null) break;

            Console.WriteLine($"[PC Server] Received: {data}");
            await stream.WriteAsync(Encoding.UTF8.GetBytes("ACK_FROM_PC\n"));
        }

        Console.WriteLine("[PC Server] Disconnected.");
    }
}