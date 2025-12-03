import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' show pi;

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
  Timer? _heartbeatTimer;
  Timer? _disconnectWatcher;
  Timer? _inputTimer;
  
  DateTime _lastPongTime = DateTime.now();
  InputState _lastSentInput = InputState(); // default zero

  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  // Public stream for status updates
  final _statusController = StreamController<BleConnectionStatus>.broadcast();
  Stream<BleConnectionStatus> get statusStream => _statusController.stream;

  // Public stream for received data
  final _dataController = StreamController<List<int>>.broadcast();
  Stream<List<int>> get receivedDataStream => _dataController.stream;

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _lastPongTime = DateTime.now();

    _heartbeatTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (writeCharacteristic != null) {
        sendToPc("PING");  // silent ping
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _startDisconnectWatcher() {
    _disconnectWatcher?.cancel();
    _disconnectWatcher = Timer.periodic(const Duration(seconds: 3), (_) {
      if (DateTime.now().difference(_lastPongTime) > const Duration(seconds: 4)) {
        print("[BLE] HEARTBEAT TIMEOUT - PC is gone!");
        _disconnectWatcher?.cancel();
        pcDevice?.disconnect();  // Force disconnect → triggers connectionState listener
      }
    });
  }

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
        await Future.delayed(Duration(seconds: 1));
        startScanningAndConnect();
      }
    });

    await _scanSubscription?.cancel();
    // Listen to scan results
    _scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        if (r.advertisementData.serviceUuids.contains(Guid(BleUuids.service))) {
          
          print("[BLE] Found PC: ${r.device.platformName}");
          FlutterBluePlus.stopScan();

          pcDevice = r.device;
          _statusController.add(BleConnectionStatus.connecting);
          await connectToDevice(pcDevice!);
          await _scanSubscription?.cancel();  // Stop listening after connect
           _scanSubscription = null;
          return;
        }
      }
    });
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      // Cancel any previous connection state listener
      await _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;
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
                if (text == "PC_ACK: PONG") {
                  _lastPongTime = DateTime.now();  // We are alive!
                  return;
                }
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
      _startHeartbeat();
      _startDisconnectWatcher();
      print("[BLE] Setup complete! Ready to send/receive data.");
      await _connectionStateSubscription?.cancel();
      // Monitor disconnection
      _connectionStateSubscription = device.connectionState.listen((BluetoothConnectionState state) async {
        print("[BLE] Connection state changed: $state");
        if (state == BluetoothConnectionState.disconnected) {
          print("[BLE] Disconnected from PC!");
          stopInputSending();
          _stopHeartbeat();
          _disconnectWatcher?.cancel();
          _statusController.add(BleConnectionStatus.disconnected);
          pcDevice = null;
          writeCharacteristic = null;
          await _connectionStateSubscription?.cancel();
          _connectionStateSubscription = null;
          await Future.delayed(const Duration(seconds: 1));
          if (!_statusController.isClosed) {
            print("[BLE] Attempting to reconnect...");
            startScanningAndConnect();
          }
        }
      },
      onError: (e) {
        print("[BLE] Connection error: $e");
        _statusController.add(BleConnectionStatus.failed);
      });
    } catch (e) {
      print("[BLE] Connect failed: $e");
      await device.disconnect();
      _statusController.add(BleConnectionStatus.failed);
      await Future.delayed(const Duration(seconds: 3));
      startScanningAndConnect();
    }
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

  // Call this from joystick/buttons at 60 FPS
  void movementInput(InputState newState) {
    _lastSentInput = newState;

    // If timer not running → start sending loop
    _inputTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      _sendCurrentInput();
    });
  }

  /// Sends the latest input state ~60 times per second
  Future<void> _sendCurrentInput() async {
    if (writeCharacteristic == null || pcDevice == null) {
      _inputTimer?.cancel();
      _inputTimer = null;
      return;
    }

    try {
      // Option A: Compact JSON (easy to debug on PC side)
      final json = jsonEncode(_lastSentInput.toJson()) + "\n";
      await writeCharacteristic!.write(
        utf8.encode(json),
        withoutResponse: true, // Critical for 60 Hz!
      );

      // Option B: Ultra-low latency binary (uncomment if you implement toBytes())
      // final bytes = _lastSentInput.toBytes();
      // await writeCharacteristic!.write(bytes, withoutResponse: true);
    } catch (e) {
      print("[BLE] Failed to send input: $e");
      // If write fails repeatedly, connection might be bad
    }
  }

  // Call this when app pauses or disconnects
  void stopInputSending() {
    _inputTimer?.cancel();
    _inputTimer = null;
  }

  Future<void> disconnect() async {
    if (pcDevice != null) {
      await pcDevice!.disconnect();
      print("[BLE] Disconnected");
      pcDevice = null;
      writeCharacteristic = null;
    }
  }

  void dispose() {
    _scanTimer?.cancel();
    _scanSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _stopHeartbeat();
    _disconnectWatcher?.cancel();
    FlutterBluePlus.stopScan();  // FIX: Stop any ongoing scan
    if (pcDevice != null) disconnect();
    _statusController.close();
    _dataController.close();
  }
}

class InputState {
  final double joyLX;
  final double joyLY;
  final double joyRX;
  final double joyRY;
  final int buttons; // bitmask or whatever

  InputState({
    this.joyLX = 0,
    this.joyLY = 0,
    this.joyRX = 0,
    this.joyRY = 0,
    this.buttons = 0,
  });

  Map<String, dynamic> toJson() => {
        'lx': (joyLX * 127).round(),     // -127..127
        'ly': (joyLY * 127).round(),
        'rx': (joyRX * 127).round(),
        'ry': (joyRY * 127).round(),
        'btn': buttons,
      };

  // Optional: binary version for even lower latency
  // List<int> toBytes() { ... }
}