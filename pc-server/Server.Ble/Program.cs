#nullable enable

using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;
using System.Text;
using System.Runtime.InteropServices.WindowsRuntime;

var serviceUuid = Guid.Parse("12345678-1234-5678-1234-56789abcdef0");
var writeUuid   = Guid.Parse("12345678-1234-5678-1234-56789abcdef1"); // Phone → PC
var notifyUuid  = Guid.Parse("12345678-1234-5678-1234-56789abcdef2"); // PC → Phone

// 1. Create GATT Service
var createResult = await GattServiceProvider.CreateAsync(serviceUuid);
if (createResult.ServiceProvider is null)
{
    Console.WriteLine("Failed to create service (null provider). Check Bluetooth permissions and run as Admin.");
    return;
}
var provider = createResult.ServiceProvider;

// 2. Notify characteristic (PC → Phone)
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
var notifyChar = notifyResult.Characteristic;
notifyChar.SubscribedClientsChanged += (sender, args) =>
{
    Console.WriteLine($"Subscribed clients changed: {notifyChar.SubscribedClients.Count}");
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
var writeChar = writeResult.Characteristic;

// 4. Handle writes from phone
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

        // Check if there are subscribed clients before notifying
        if (notifyChar.SubscribedClients.Count == 0)
        {
            Console.WriteLine("No clients subscribed to notifications - skipping echo.");
            return;
        }
        
        // Echo back via notify
        using var writer = new DataWriter();
        writer.WriteString($"PC_ACK: {text}");
        await notifyChar.NotifyValueAsync(writer.DetachBuffer());
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
Console.WriteLine("Press Enter to stop...");
Console.ReadLine();

provider.StopAdvertising();
Console.WriteLine("Server stopped.");