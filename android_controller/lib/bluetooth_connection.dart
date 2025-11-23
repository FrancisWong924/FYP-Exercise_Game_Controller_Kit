import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:async';
import 'dart:convert';

class BleUuids {
  static const String service     = "12345678-1234-5678-1234-56789abcdef0";
  static const String writeChar   = "12345678-1234-5678-1234-56789abcdef1"; // PC writes → phone
  static const String notifyChar  = "12345678-1234-5678-1234-56789abcdef2"; // phone writes → PC
}

enum BleConnectionStatus {
  disconnected,
  scanning,
  connecting,
  connected,
  failed,
  bluetoothOff,
}

class BleManager {
  BluetoothDevice? pcDevice;
  BluetoothCharacteristic? writeCharacteristic;  // Phone → PC
  Timer? _scanTimer;

  // Public stream for status updates
  final _statusController = StreamController<BleConnectionStatus>.broadcast();
  Stream<BleConnectionStatus> get statusStream => _statusController.stream;

  // Public stream for received data
  final _dataController = StreamController<List<int>>.broadcast();
  Stream<List<int>> get receivedDataStream => _dataController.stream;

  Future<void> startScanningAndConnect() async {
    // Turn on Bluetooth if needed
    if (await FlutterBluePlus.isSupported == false) {
      print("Bluetooth not supported on this device");
      _statusController.add(BleConnectionStatus.failed);
      return;
    }

    var adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      await FlutterBluePlus.turnOn();
    }

    print("[BLE] Starting scan...");

    // Start scanning
    FlutterBluePlus.startScan(timeout: Duration(seconds: 60), withServices: [Guid(BleUuids.service)]);

    // auto-cleanup if nothing found
    _scanTimer = Timer(const Duration(seconds: 62), () async {
      if (pcDevice == null) {
        print("[BLE] Scan timeout (60s) reached – no PC found");
        FlutterBluePlus.stopScan();
        _statusController.add(BleConnectionStatus.failed);
        await Future.delayed(Duration(seconds: 1)); startScanningAndConnect();
      }
    });

    late StreamSubscription<List<ScanResult>> subscription;
    // Listen to scan results
    subscription = FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        if (r.advertisementData.serviceUuids.contains(Guid(BleUuids.service))) {
          
          print("[BLE] Found PC: ${r.device.platformName}");
          FlutterBluePlus.stopScan();

          pcDevice = r.device;
          _statusController.add(BleConnectionStatus.connecting);
          await connectToDevice(pcDevice!);
          subscription.cancel();  // Stop listening after connect
          return;
        }
      }
    });
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect(license: License.free);
      print("[BLE] Connected to ${device.platformName}");
      _statusController.add(BleConnectionStatus.connected);
      _scanTimer?.cancel();

      // Discover services
      List<BluetoothService> services = await device.discoverServices();
      print("[BLE] Discovered ${services.length} services");

      for (var service in services) {
        if (service.uuid.str.toLowerCase() == BleUuids.service.toLowerCase()) {
          print("[BLE] Found our service!");

          for (var char in service.characteristics) {
            // Setup notify (PC → Phone)
            if (char.uuid.str.toLowerCase() == BleUuids.notifyChar.toLowerCase()) {
              await char.setNotifyValue(true);
              char.lastValueStream.listen((value) {
                String text = utf8.decode(value).trim();
                print("[BLE] ← From PC: $text");
                _dataController.add(value);
              });
              print("[BLE] Notify enabled on ${char.uuid.str}");
            }

            // Save write characteristic (Phone → PC)
            if (char.uuid.str.toLowerCase() == BleUuids.writeChar.toLowerCase()) {
              writeCharacteristic = char;
              print("[BLE] Write characteristic ready: ${char.uuid.str}");
            }
          }
        }
      }
      print("[BLE] Setup complete! Ready to send/receive data.");
      // Monitor disconnection
      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _statusController.add(BleConnectionStatus.disconnected);
          pcDevice = null;
          writeCharacteristic = null;
        }
      });
    } catch (e) {
      print("[BLE] Connect failed: $e");
      await device.disconnect();
      _statusController.add(BleConnectionStatus.failed);
      await Future.delayed(Duration(seconds: 3)); startScanningAndConnect();
    }
  }

  void _cancelScanTimer() {
    _scanTimer?.cancel();
    _scanTimer = null;
  }

  Future<void> sendToPc(String message) async {
    if (writeCharacteristic == null) {
      print("[BLE] Not connected - can't send");
      return;
    }
    try {
      List<int> data = utf8.encode(message + "\n");
      await writeCharacteristic!.write(data, withoutResponse: false);
      print("[BLE] → Sent to PC: $message");
    } catch (e) {
      print("[BLE] Send failed: $e");
    }
  }

  // For high-frequency input (60Hz)
  // Future<void> sendInput(InputState state) async {
  //   final json = jsonEncode(state.toJson()) + "\n";
  //   // Use withoutResponse: true for high frequency
  //   await writeCharacteristic?.write(utf8.encode(json), withoutResponse: true);
  // }

  // // Or go full binary for ultra-low latency
  // Future<void> sendBinaryInput(InputState state) async {
  //   final bytes = state.toBytes();
  //   await writeCharacteristic?.write(bytes, withoutResponse: true);
  // }

  Future<void> disconnect() async {
    if (pcDevice != null) {
      await pcDevice!.disconnect();
      print("[BLE] Disconnected");
      pcDevice = null;
      writeCharacteristic = null;
    }
  }

  void dispose() {
    FlutterBluePlus.stopScan();  // FIX: Stop any ongoing scan
    if (pcDevice != null) disconnect();
    _statusController.close();
    _dataController.close();
  }
}