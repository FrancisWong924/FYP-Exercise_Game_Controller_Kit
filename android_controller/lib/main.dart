import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'bluetooth_connection.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

Future<bool> requestBlePermissions() async {
  Map<Permission, PermissionStatus> statuses = await [
    Permission.bluetoothScan,
    Permission.bluetoothConnect,
    Permission.bluetoothAdvertise,
    Permission.locationWhenInUse, // fallback for older Android
  ].request();

  bool allGranted = statuses.values.every((status) => status.isGranted);

  if (!allGranted) {
    // Show explanation and open settings
    await openAppSettings();
    return false;
  }
  return true;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const MaterialApp(home: BluetoothTestScreen()));
}

class BluetoothTestScreen extends StatefulWidget {
  const BluetoothTestScreen({super.key});

  @override
  State<BluetoothTestScreen> createState() => _BluetoothTestScreenState();
}

class _BluetoothTestScreenState extends State<BluetoothTestScreen> {
  final BleManager bleManager = BleManager();
  String _status = 'Initializing...';

  // Helper: Log to console + update UI
  void _logAndUpdate(String message) {
    final timestamp = DateTime.now().toIso8601String().split('.').first;
    final log = '[$timestamp] $message';
    print(log); // This shows in Android Studio Logcat / VS Code terminal
    setState(() => _status = message);
  }

  @override
  void initState() {
    super.initState();
    // initBluetooth();
    // Listen to connection status
    bleManager.statusStream.listen((status) {
      String text = _statusToString(status);
      setState(() {
        _status = text;
      });
      print("[UI] Status: $text");
    });

    // Listen to incoming data
    bleManager.receivedDataStream.listen((data) {
      String message = utf8.decode(data).trim();
      print("[UI] ← From PC: $message");
    });
    // Start Bluetooth connection
    bleManager.startScanningAndConnect();
  }

  @override
  void dispose() {
    bleManager.dispose();
    super.dispose();
  }

  String _statusToString(BleConnectionStatus status) {
    switch (status) {
      case BleConnectionStatus.scanning:
        return "Scanning for PC...";
      case BleConnectionStatus.connecting:
        return "Connecting...";
      case BleConnectionStatus.connected:
        return "Connected to PC!";
      case BleConnectionStatus.disconnected:
        return "Disconnected";
      case BleConnectionStatus.failed:
        return "Connection failed";
      case BleConnectionStatus.bluetoothOff:
        return "Turning on Bluetooth...";
      default:
        return "Unknown";
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black87,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // status icon
            Icon(
              _status.contains('failed')
                  ? Icons.bluetooth_disabled
                  : Icons.bluetooth,
              color: _status.contains('failed')
                  ? Colors.red
                  : Colors.green,
              size: 48,
            ),
            const SizedBox(height: 20),
            // status text
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                _status,
                style: TextStyle(
                  color: _status.contains('failed')
                      ? Colors.red
                      : Colors.green,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 40),
            // test button
            if (_status.contains('Connected to PC!'))
              ElevatedButton.icon(
                onPressed: () => bleManager.sendToPc("HELLO_FROM_PHONE"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                ),
                icon: const Icon(Icons.send, color: Colors.white),
                label: const Text(
                  'Tap to Send Test',
                  style: TextStyle(color: Colors.white, fontSize: 18),
                ),
              ),
          ],
        ),
      ),
    );
  }
}