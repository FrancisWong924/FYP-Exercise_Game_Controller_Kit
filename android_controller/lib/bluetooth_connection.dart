import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'models/controller_element.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';

/// Bits 0–15 are sent in the 16-byte input packet; 16–18 are app-side commands only.
class ControllerButtonIds {
  static const int inputPacketMask = 0xFFFF;
  static const int pauseResume = 1 << 16;
  static const int screenshot = 1 << 17;
  static const int settings = 1 << 18;

  static bool isInputPacketButton(int buttonId) =>
      buttonId != 0 && (buttonId & inputPacketMask) == buttonId;
}

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

  bool _isConnecting = false;
  bool _reconnectBusy = false;
  int _connectSession = 0;
  Timer? _heartbeatTimer;
  Timer? _disconnectWatcher;
  Timer? _inputTimer;
  
  DateTime _lastPongTime = DateTime.now();

  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<List<int>>? _lastValueSubscription;

  // Public stream for status updates
  final _statusController = StreamController<BleConnectionStatus>.broadcast();
  Stream<BleConnectionStatus> get statusStream => _statusController.stream;

  // Public stream for received data
  final _dataController = StreamController<List<int>>.broadcast();
  Stream<List<int>> get receivedDataStream => _dataController.stream;

  int currentButtons = 0;           // Live button state
  InputState currentJoy = InputState();  // Live joystick state
  double currentStep = 0.0;  // -1.0 to 0.0

  int _lastSentSequence = 0;
  Uint8List? _lastSentPacket;
  int _lastSentButtons = -1;
  DateTime? _lastButtonHoldResendTime;
  bool _isPausedForLargeData = false;

  static const double _joystickNeutralEpsilon = 0.001;
  /// Hold refresh while a button stays down (joysticks neutral) — avoids menu double-fires at 60 Hz.
  static const Duration _buttonHoldResendInterval = Duration(milliseconds: 200);

  /// Matches <c>buttonBitmasks</c> in main.dart — sent as analog bytes 2–3, not in the 16-bit mask.
  static const int _bitLt = 1 << 10;
  static const int _bitRt = 1 << 11;

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _lastPongTime = DateTime.now();

    _heartbeatTimer = Timer.periodic(const Duration(seconds: 1), (_) {
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
    _disconnectWatcher = Timer.periodic(const Duration(seconds: 1), (_) {
      if (DateTime.now().difference(_lastPongTime) > const Duration(milliseconds: 2500)) {
        print("[BLE] HEARTBEAT TIMEOUT - PC is gone!");
        _stopHeartbeat();
        _disconnectWatcher?.cancel();
        _statusController.add(BleConnectionStatus.disconnected);
        pcDevice?.disconnect();  // Force disconnect → triggers connectionState listener
      }
    });
  }

  bool get _isFullyConnected =>
      pingCharacteristic != null &&
      pcDevice != null &&
      pcDevice!.isConnected;

  Future<void> startScanningAndConnect() async {
    if (_isConnecting || _isFullyConnected) return;
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    // Turn on Bluetooth if needed
    if (await FlutterBluePlus.isSupported == false) {
      print("Bluetooth not supported on this device");
      _statusController.add(BleConnectionStatus.bluetoothOff);
      return;
    }

    var adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      await FlutterBluePlus.turnOn();
    }

    try {
      // Clear out ALL old subscriptions to prevent multiple listeners
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      // Ensure no ongoing scan
      await FlutterBluePlus.stopScan();
      print("[BLE] Starting scan...");
      _statusController.add(BleConnectionStatus.scanning);
      // Start scanning
      FlutterBluePlus.startScan(withServices: [Guid(BleUuids.service)]);
      // Listen to scan results
      _scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult r in results) {
          if (r.advertisementData.serviceUuids.contains(Guid(BleUuids.service))) {
            await FlutterBluePlus.stopScan();
            await Future.delayed(const Duration(milliseconds: 500));
            if (_isConnecting) return;
            print("[BLE] Found PC: ${r.device.platformName}");
            _isConnecting = true;
            pcDevice = r.device;
            _statusController.add(BleConnectionStatus.connecting);
            await connectToDevice(pcDevice!);
            await _scanSubscription?.cancel();  // Stop listening after connect
            _scanSubscription = null;
            _isConnecting = false;
            return;
          }
        }
      });
    } catch (e) {
      print("[BLE] Scan error: $e");
      _isConnecting = false;
    }
  }

  bool _connectSessionAlive(int session, BluetoothDevice device) =>
      session == _connectSession && device.isConnected;

  Future<void> connectToDevice(BluetoothDevice device) async {
    final session = ++_connectSession;
    try {
      await _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;
      pingCharacteristic = null;
      inputCharacteristic = null;

      await device.connect(license: License.free);
      if (!_connectSessionAlive(session, device)) return;
      print("[BLE] Connected to ${device.platformName}");

      _connectionStateSubscription = device.connectionState.listen((BluetoothConnectionState state) async {
        print("[BLE] Connection state changed: $state");
        if (state == BluetoothConnectionState.disconnected) {
          print("[BLE] Disconnected from PC!");
          _connectSession++;
          _statusController.add(BleConnectionStatus.disconnected);
          _handleCleanupAndReconnect();
        }
      }, onError: (e) {
        print("[BLE] Connection error: $e");
        _connectSession++;
        _handleCleanupAndReconnect();
      });

      await Future.delayed(const Duration(seconds: 2));
      if (!_connectSessionAlive(session, device)) return;

      if (Platform.isAndroid) {
        print("[BLE] Clearing Android GATT Cache...");
        await device.clearGattCache();
        await Future.delayed(const Duration(seconds: 3));
        if (!_connectSessionAlive(session, device)) return;
      }

      List<BluetoothService> services = [];
      for (int i = 0; i < 3; i++) {
        if (!_connectSessionAlive(session, device)) return;
        services = await device.discoverServices();
        if (services.isNotEmpty) break;

        print("[BLE] Services empty, waiting and retrying ($i)...");
        await Future.delayed(const Duration(seconds: 1));
      }
      if (!_connectSessionAlive(session, device)) return;
      if (services.isEmpty) {
        print("[BLE] Fatal: Could not find services after 3 tries.");
        await _handleCleanupAndReconnect();
        return;
      }
      print("[BLE] Discovered ${services.length} services");

      for (var service in services) {
        if (service.uuid.str.toLowerCase() == BleUuids.service.toLowerCase()) {
          print("[BLE] Found our service!");
          for (var char in service.characteristics) {
            final uuidStr = char.uuid.str.toLowerCase();
            if (uuidStr == BleUuids.notifyChar.toLowerCase()) {
              await _lastValueSubscription?.cancel();
              _lastValueSubscription = null;
              await char.setNotifyValue(true);
              await Future.delayed(const Duration(milliseconds: 200));
              if (!_connectSessionAlive(session, device)) return;

              _lastValueSubscription = char.lastValueStream.listen((value) {
                String text = utf8.decode(value, allowMalformed: true).trim();
                // print("[BLE] ← From PC: $text");
                if (text.contains("PONG")) {
                  _lastPongTime = DateTime.now();
                  return;
                }
                _dataController.add(value);
              });
              print("[BLE] Notify enabled on ${char.uuid.str}");
            } else if (uuidStr == BleUuids.pingChar.toLowerCase()) {
              pingCharacteristic = char;
              print("[BLE] PING characteristic ready: $uuidStr");
            } else if (uuidStr == BleUuids.inputChar.toLowerCase()) {
              inputCharacteristic = char;
              print("[BLE] INPUT characteristic ready (fast): $uuidStr");
            }
          }
        }
      }

      if (!_connectSessionAlive(session, device)) return;
      if (pingCharacteristic != null) {
        _statusController.add(BleConnectionStatus.connected);
        _startHeartbeat();
        _startDisconnectWatcher();
        startInputSending();
        print("[BLE] Setup complete! Ready to send input + heartbeat.");
      } else {
        print("[BLE] ERROR: PING characteristic not found — incomplete GATT, reconnecting");
        await _handleCleanupAndReconnect();
      }
    } catch (e) {
      print("[BLE] Connect failed: $e");
      _connectSession++;
      try {
        await device.disconnect();
      } catch (_) {}
      await _handleCleanupAndReconnect();
    }
  }

  Future<void> _handleCleanupAndReconnect() async {
    if (_reconnectBusy) return;
    _reconnectBusy = true;
    _connectSession++;
    try {
      stopInputSending();
      _stopHeartbeat();
      _disconnectWatcher?.cancel();
      await _lastValueSubscription?.cancel();
      _lastValueSubscription = null;
      await _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;

      final device = pcDevice;
      pcDevice = null;
      pingCharacteristic = null;
      inputCharacteristic = null;
      _isConnecting = false;

      try {
        await FlutterBluePlus.stopScan();
      } catch (_) {}
      if (device != null) {
        try {
          await device.disconnect();
        } catch (e) {
          print("[BLE] disconnect during cleanup: $e");
        }
      }

      _statusController.add(BleConnectionStatus.failed);
      await Future.delayed(const Duration(milliseconds: 900));
      if (!_statusController.isClosed) {
        print("[BLE] Attempting to reconnect...");
        startScanningAndConnect();
      }
    } finally {
      _reconnectBusy = false;
    }
  }

  Future<void> sendPing() async {
    try {
      final bytes = utf8.encode("PING\n");
      // print("[BLE] → Sending PING (${bytes.length} bytes)");
      await pingCharacteristic!.write(bytes, withoutResponse: false); // ← MUST be false!
    } catch (e) {
      print("[BLE] PING send failed: $e — forcing disconnect");
      _stopHeartbeat();
      _disconnectWatcher?.cancel();
      try {
        final d = pcDevice;
        if (d != null) await d.disconnect();
      } catch (e2) {
        print("[BLE] disconnect after ping failure: $e2");
        await _handleCleanupAndReconnect();
      }
    }
  }

  Future<bool> sendMessage(String command, {
    ControllerId tiltTarget = ControllerId.rightJoystick,
    ControllerId stepTarget = ControllerId.leftJoystick,
    int stepBitmask = 0,
  }) async {
    if (pingCharacteristic == null) {
      print("[BLE] Cannot send $command — PING characteristic not available");
      return false;
    }

    try {
      final bytes = utf8.encode("$command\n");
      await pingCharacteristic!.write(bytes, withoutResponse: false);
      print("[BLE] → Sent command: $command");
      if (command == "PAUSE") {
        resetTiltAndStepInputs(
          tiltTarget: tiltTarget,
          stepTarget: stepTarget,
          stepBitmask: stepBitmask,
        );
      }
      return true;
    } catch (e) {
      print("[BLE] Failed to send $command: $e");
      return false;
    }
  }

  /// Sends full GPX XML to the PC server (chunked base64 on the reliable ping characteristic).
  Future<bool> sendGpxExportToPc(String gpxXml) async {
    if (pingCharacteristic == null) {
      print('[BLE] Cannot send GPX — ping characteristic not available');
      return false;
    }
    try {
      if (!await sendMessage('GPX_EXPORT_START')) return false;
      final bytes = utf8.encode(gpxXml);
      const rawChunk = 240;
      for (var i = 0; i < bytes.length; i += rawChunk) {
        final end = i + rawChunk > bytes.length ? bytes.length : i + rawChunk;
        final slice = bytes.sublist(i, end);
        final line = 'GPX_CHUNK:${base64Encode(slice)}';
        if (!await sendMessage(line)) return false;
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      return await sendMessage('GPX_EXPORT_END');
    } catch (e) {
      print('[BLE] GPX export to PC failed: $e');
      return false;
    }
  }

  void updateButton(int buttonBit, bool pressed) {
    if (!ControllerButtonIds.isInputPacketButton(buttonBit)) return;
    if (pressed) {
      currentButtons |= buttonBit;
    } else {
      currentButtons &= ~buttonBit;
    }
  }

  void updateJoystick(String type, double x, double y) {
    if (type == "left") {
      currentJoy = currentJoy.copyWith(joyLX: x, joyLY: y);
    } else {
      currentJoy = currentJoy.copyWith(joyRX: x, joyRY: y);
    }
  }

  void resetTiltAndStepInputs({
    required ControllerId tiltTarget,
    required ControllerId stepTarget,
    required int stepBitmask,
  }) {
    updateSteering(0.0, tiltTarget);
    updateStep(0.0, jid: stepTarget, bitmask: stepBitmask);
    updateSteering(
      0.0,
      tiltTarget == ControllerId.leftJoystick
          ? ControllerId.rightJoystick
          : ControllerId.leftJoystick,
    );
  }

  void forceTransmitInputPacket() {
    _resetInputSendState();
    sendCombinedInputPacket();
  }

  void updateSteering(double steering, ControllerId target) {
    if (target == ControllerId.leftJoystick) {
      // Update the Left Joystick X-axis
      currentJoy = currentJoy.copyWith(joyLX: steering);
    } else {
      // Update the Right Joystick X-axis (Default)
      currentJoy = currentJoy.copyWith(joyRX: steering);
    }
  }

  void updateStep(double y, {ControllerId? jid, int? bitmask}) {
    // 1. Handle Joystick Mapping
    if (bitmask == null || bitmask == 0) {
      if (jid == ControllerId.leftJoystick) {
        currentJoy = currentJoy.copyWith(joyLY: y);
      } else {
        currentJoy = currentJoy.copyWith(joyRY: y);
      }
    } 
    // 2. Handle Button Mapping
    else {
      // If y is -1.0, the "button" is pressed. If 0.0, it is released.
      bool isPressed = (y != 0.0);
      // You would call your bitmask update logic here
      updateButton(bitmask, isPressed);
    }
  }

  void sendCombinedInputPacket() async {
    if (inputCharacteristic == null || pcDevice == null) return;
    if (_isPausedForLargeData) return;
    // Only attempt write if Flutter thinks we are connected
    if (FlutterBluePlus.connectedDevices.contains(pcDevice) == false) {
      print("[BLE] Guard: Device not in connected list. Stopping loop.");
      stopInputSending();
      return;
    }

    final packet = Uint8List(16);
    final bd = packet.buffer.asByteData();
    final bool isLtPressed = (currentButtons & _bitLt) != 0;
    final bool isRtPressed = (currentButtons & _bitRt) != 0;
    final int leftTriggerValue = isLtPressed ? 255 : 0;
    final int rightTriggerValue = isRtPressed ? 255 : 0;
    final int buttonsMask =
        (currentButtons & ControllerButtonIds.inputPacketMask) & ~(_bitLt | _bitRt);

    // Bytes 0–1: Buttons (16-bit mask)
    bd.setUint16(0, buttonsMask, Endian.little);
    
    // Bytes 2–3: Triggers (2 × Uint8)
    bd.setUint8(2, leftTriggerValue);
    bd.setUint8(3, rightTriggerValue);

    // Bytes 4–11: Joysticks (4 × Int16)
    bd.setInt16(4, (currentJoy.joyLX * 32767).round(), Endian.little);
    bd.setInt16(6, (currentJoy.joyLY * 32767).round(), Endian.little);
    bd.setInt16(8, (currentJoy.joyRX * 32767).round(), Endian.little);
    bd.setInt16(10, (currentJoy.joyRY * 32767).round(), Endian.little);

    if (!_shouldTransmitPacket(packet)) {
      return;
    }

    _lastSentButtons = currentButtons;
    _lastSentPacket = Uint8List.fromList(packet);
    try {
      if (pcDevice!.isConnected) {
        // print("→ Button: ${currentButtons.toString()} LX:${currentJoy.joyLX.toStringAsFixed(2)} LY:${currentJoy.joyLY.toStringAsFixed(2)} RX:${currentJoy.joyRX.toStringAsFixed(2)} RY:${currentJoy.joyRY.toStringAsFixed(2)}");
        // Fast path: no response
        inputCharacteristic!.write(packet, withoutResponse: true);
      }
    } catch (e) {
      // If a write fails, the link is dead. Kill the loop immediately.
      print("[BLE] Write Error: $e");
      stopInputSending();
      _stopHeartbeat();
      _disconnectWatcher?.cancel();
      try {
        if (pcDevice != null) await pcDevice!.disconnect();
      } catch (_) {
        await _handleCleanupAndReconnect();
      }
    }
  }

  bool _arePacketsEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  bool _areJoysticksNeutral() {
    return currentJoy.joyLX.abs() < _joystickNeutralEpsilon &&
        currentJoy.joyLY.abs() < _joystickNeutralEpsilon &&
        currentJoy.joyRX.abs() < _joystickNeutralEpsilon &&
        currentJoy.joyRY.abs() < _joystickNeutralEpsilon;
  }

  bool _joystickSliceChanged(Uint8List packet) {
    final prev = _lastSentPacket;
    if (prev == null || prev.length < 12 || packet.length < 12) return true;
    for (var i = 4; i <= 10; i += 2) {
      if (packet[i] != prev[i] || packet[i + 1] != prev[i + 1]) return true;
    }
    return false;
  }

  bool _buttonHoldResendDue() {
    final now = DateTime.now();
    if (_lastButtonHoldResendTime == null ||
        now.difference(_lastButtonHoldResendTime!) >= _buttonHoldResendInterval) {
      _lastButtonHoldResendTime = now;
      return true;
    }
    return false;
  }

  /// Press/release sends immediately; steady hold resends at ~10 Hz; joysticks stay at 60 Hz when moving.
  bool _shouldTransmitPacket(Uint8List packet) {
    final buttonsChanged = currentButtons != _lastSentButtons;
    if (buttonsChanged) {
      _lastButtonHoldResendTime = DateTime.now();
      _lastSentSequence = 0;
      return true;
    }

    final joysticksNeutral = _areJoysticksNeutral();

    if (!joysticksNeutral) {
        _lastSentSequence = 0;
        return true;
    }

    if (currentButtons != 0) {
      if (_buttonHoldResendDue()) {
        _lastSentSequence = 0;
        return true;
      }
      return false;
    }

    final stateChanged = _lastSentPacket == null || !_arePacketsEqual(_lastSentPacket!, packet);
    if (!stateChanged) {
      if (_lastSentSequence > 2) return false;
      _lastSentSequence++;
      return true;
    }
    _lastSentSequence = 0;
    return true;
  }

  void _resetInputSendState() {
    _lastSentSequence = 0;
    _lastSentPacket = null;
    _lastSentButtons = -1;
    _lastButtonHoldResendTime = null;
  }

  void startInputSending() {
    print("[BLE] 60Hz input loop started");
    _resetInputSendState();
    _inputTimer?.cancel();
    _inputTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (inputCharacteristic != null) {
        sendCombinedInputPacket();
      }
    });
  }

  void setInputPause(bool pause) {
    _isPausedForLargeData = pause;
    _resetInputSendState();
    if (pause) {
      print("[BLE] Input loop throttled for incoming data...");
    } else {
      print("[BLE] Input loop resumed.");
    }
  }

  // Call this when app pauses or disconnects
  void stopInputSending() {
    _inputTimer?.cancel();
    _inputTimer = null;
    _resetInputSendState();
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
    _lastValueSubscription?.cancel();
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