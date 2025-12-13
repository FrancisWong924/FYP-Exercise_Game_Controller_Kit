import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'models/controller_element.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

class BleUuids {
  static const String service     = "12345678-1234-5678-1234-56789abcdef0";
  static const String notifyChar  = "12345678-1234-5678-1234-56789abcdef2"; // phone writes → PC
  static const String pingChar   = "12345678-1234-5678-1234-56789abcdef1"; // Write-With-Response → PING
  static const String inputChar  = "12345678-1234-5678-1234-56789abcdef3"; // Write-Without-Response → fast input
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
  BluetoothCharacteristic? pingCharacteristic;   // For PING (WithResponse)
  BluetoothCharacteristic? inputCharacteristic;  // For fast input (WithoutResponse)

  Timer? _heartbeatTimer;
  Timer? _disconnectWatcher;
  Timer? _inputTimer;
  
  DateTime _lastPongTime = DateTime.now();

  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  // Public stream for status updates
  final _statusController = StreamController<BleConnectionStatus>.broadcast();
  Stream<BleConnectionStatus> get statusStream => _statusController.stream;

  // Public stream for received data
  final _dataController = StreamController<List<int>>.broadcast();
  Stream<List<int>> get receivedDataStream => _dataController.stream;

  int currentButtons = 0;           // Live button state
  InputState currentJoy = InputState();  // Live joystick state
  double currentSteering = 0.0;  // -1.0 to +1.0

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _lastPongTime = DateTime.now();

    _heartbeatTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (pingCharacteristic != null) {
        sendPing();  // silent ping
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _startDisconnectWatcher() {
    _disconnectWatcher?.cancel();
    _disconnectWatcher = Timer.periodic(const Duration(seconds: 2), (_) {
      if (DateTime.now().difference(_lastPongTime) > const Duration(seconds: 3)) {
        print("[BLE] HEARTBEAT TIMEOUT - PC is gone!");
        _disconnectWatcher?.cancel();
        pcDevice?.disconnect();  // Force disconnect → triggers connectionState listener
      }
    });
  }

  Future<void> startScanningAndConnect() async {
    await _scanSubscription?.cancel();
    _scanSubscription = null;
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

    // Ensure no ongoing scan
    await FlutterBluePlus.stopScan();

    // Start scanning
    FlutterBluePlus.startScan(withServices: [Guid(BleUuids.service)]);

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

      // Discover services
      List<BluetoothService> services = await device.discoverServices();
      print("[BLE] Discovered ${services.length} services");

      for (var service in services) {
        if (service.uuid.str.toLowerCase() == BleUuids.service.toLowerCase()) {
          print("[BLE] Found our service!");

          for (var char in service.characteristics) {
            final uuidStr = char.uuid.str.toLowerCase();
            // Setup notify (PC → Phone)
            if (uuidStr == BleUuids.notifyChar.toLowerCase()) {
              await char.setNotifyValue(true);
              char.lastValueStream.listen((value) {
                String text = utf8.decode(value, allowMalformed: true).trim();
                print("[BLE] ← From PC: $text");
                if (text.contains("PONG")) {
                  _lastPongTime = DateTime.now();  // We are alive!
                  return;
                }
                _dataController.add(value);
              });
              print("[BLE] Notify enabled on ${char.uuid.str}");
            }

            // 2. PING characteristic (Write With Response)
            else if (uuidStr == BleUuids.pingChar.toLowerCase()) {
              pingCharacteristic = char;
              print("[BLE] PING characteristic ready: $uuidStr");
            }

            // 3. INPUT characteristic (Write Without Response) – for buttons & joysticks
            else if (uuidStr == BleUuids.inputChar.toLowerCase()) {
              inputCharacteristic = char;
              print("[BLE] INPUT characteristic ready (fast): $uuidStr");
            }
          }
        }
      }
      // Start heartbeat only if PING char exists
      if (pingCharacteristic != null) {
        _startHeartbeat();
        _startDisconnectWatcher();
        startInputSending();
        print("[BLE] Setup complete! Ready to send input + heartbeat.");
      } else {
        print("[BLE] ERROR: PING characteristic not found!");
      }
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
          pingCharacteristic = null;
          inputCharacteristic = null;
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
        startScanningAndConnect();
      });
    } catch (e) {
      print("[BLE] Connect failed: $e");
      await device.disconnect();
      _statusController.add(BleConnectionStatus.failed);
      await Future.delayed(const Duration(seconds: 3));
      startScanningAndConnect();
    }
  }

  Future<void> sendPing() async {
    try {
      final bytes = utf8.encode("PING\n");
      print("[BLE] → Sending PING (${bytes.length} bytes)");
      await pingCharacteristic!.write(bytes, withoutResponse: false); // ← MUST be false!
    } catch (e) {
      print("[BLE] PING send failed: $e");
    }
  }

  Future<bool> togglePause(String command) async {
    if (pingCharacteristic == null) {
      print("[BLE] Cannot send $command — PING characteristic not available");
      return false;
    }

    try {
      final bytes = utf8.encode("$command\n");  // e.g., "PAUSE\n" or "RESUME\n"
      await pingCharacteristic!.write(bytes, withoutResponse: false);  // MUST be false!
      print("[BLE] → Sent command: $command");
      return true;
    } catch (e) {
      print("[BLE] Failed to send $command: $e");
      return false;
    }
  }

  void updateButton(int buttonBit, bool pressed) {
    if (pressed) {
      currentButtons |= buttonBit;
    } else {
      currentButtons &= ~buttonBit;
    }
  }

  // Send ONLY when buttons actually change
  void sendButtons() {
    if (inputCharacteristic == null) return;

    final packet = Uint8List(4);
    packet.buffer.asByteData().setUint32(0, currentButtons, Endian.little);
    // packet[0] = currentButtons & 0xFF;
    // packet[1] = (currentButtons >> 8) & 0xFF;
    // packet[2] = (currentButtons >> 16) & 0xFF;
    // packet[3] = (currentButtons >> 24) & 0xFF;

    inputCharacteristic!.write(packet, withoutResponse: true);
    // print("→ Buttons: 0x${currentButtons.toRadixString(16)}");
  }

  void updateJoystick(ControllerId id, double x, double y) {
    final bool isLeft = id == ControllerId.leftJoystick;
    if (isLeft) {
      currentJoy = currentJoy.copyWith(joyLX: x, joyLY: y);
    } else {
      currentJoy = currentJoy.copyWith(joyRX: x, joyRY: y);
    }
  }

  // Send ONLY when joysticks actually change
  void sendJoysticks() {
    if (inputCharacteristic == null) return;

    final packet = Uint8List(8);
    final bd = packet.buffer.asByteData();

    bd.setInt16(0, (currentJoy.joyLX * 32767).round(), Endian.little);
    bd.setInt16(2, (currentJoy.joyLY * 32767).round(), Endian.little);
    bd.setInt16(4, (currentJoy.joyRX * 32767).round(), Endian.little);
    bd.setInt16(6, (currentJoy.joyRY * 32767).round(), Endian.little);
    print("→ Joy L:${currentJoy.joyLX.toStringAsFixed(2)},${currentJoy.joyLY.toStringAsFixed(2)} R:${currentJoy.joyRX.toStringAsFixed(2)},${currentJoy.joyRY.toStringAsFixed(2)}");
    inputCharacteristic!.write(packet, withoutResponse: true);
    // print("→ Joy L(${currentJoy.joyLX.toStringAsFixed(2)}, ${currentJoy.joyLY.toStringAsFixed(2)})");
  }

  void updateSteering(double steering) {
    currentSteering = steering;
  }

  void sendCombinedInputPacket() {
    if (inputCharacteristic == null) return;

    final packet = Uint8List(14);
    final bd = packet.buffer.asByteData();

    // Bytes 0–3: Buttons (32 little-endian
    bd.setUint32(0, currentButtons, Endian.little);

    // Bytes 4–11: Joysticks (4 × Int16)
    bd.setInt16(4, (currentJoy.joyLX * 32767).round(), Endian.little);
    bd.setInt16(6, (currentJoy.joyLY * 32767).round(), Endian.little);
    bd.setInt16(8, (currentJoy.joyRX * 32767).round(), Endian.little);
    bd.setInt16(10, (currentJoy.joyRY * 32767).round(), Endian.little);

    // Bytes 12–13: Steering (Int16)
    bd.setInt16(12, (currentSteering * 32767).round(), Endian.little);

    // print("→ Joy L:${currentJoy.joyLX.toStringAsFixed(2)},${currentJoy.joyLY.toStringAsFixed(2)} R:${currentJoy.joyRX.toStringAsFixed(2)},${currentJoy.joyRY.toStringAsFixed(2)}");
    // print("→ Steering: ${currentSteering.toStringAsFixed(3)}");
    // Fast path: no response
    inputCharacteristic!.write(packet, withoutResponse: true);
  }

  void startInputSending() {
    print("[BLE] 60Hz input loop started");
    _inputTimer?.cancel();
    _inputTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (inputCharacteristic != null) {
        sendCombinedInputPacket();
      }
    });
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
      pingCharacteristic = null;
      inputCharacteristic = null;
    }
  }

  void dispose() {
    _scanSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    stopInputSending();
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

  InputState copyWith({
    double? joyLX, double? joyLY,
    double? joyRX, double? joyRY,
    int? buttons,
  }) => InputState(
    joyLX: joyLX ?? this.joyLX,
    joyLY: joyLY ?? this.joyLY,
    joyRX: joyRX ?? this.joyRX,
    joyRY: joyRY ?? this.joyRY,
    buttons: buttons ?? this.buttons,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InputState &&
      joyLX == other.joyLX && joyLY == other.joyLY &&
      joyRX == other.joyRX && joyRY == other.joyRY &&
      buttons == other.buttons;

  @override
  int get hashCode => Object.hash(joyLX, joyLY, joyRX, joyRY, buttons);
}