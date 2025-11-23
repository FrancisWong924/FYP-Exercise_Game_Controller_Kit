import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'bluetooth_connection.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
  bool paused = false;

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
      body: Stack(
        children: [
          // Top-center button
          if (_status.contains('Connected to PC!'))
            Positioned(
              top: 5, // Adjust this value to move it higher or lower
              left: 0,
              right: 0,
              child: Center(
                child: GestureDetector(
                  onTap: () => {
                    setState(() => paused = !paused),
                    bleManager.sendToPc(paused ? "PAUSE" : "RESUME"),
                  },
                  child: Container(
                    width: 36, height: 26,
                    decoration: const BoxDecoration(
                      color: Colors.white24,
                      shape: BoxShape.rectangle,
                      borderRadius: BorderRadius.all(Radius.circular(4)),
                    ),
                    child: Icon(paused ? Icons.play_arrow : Icons.pause, color: Colors.white, size: 18),
                  ),
                ),
              ),
            ),

          // Main centered content (status icon + text)
          Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _status.contains('failed')
                      ? Icons.bluetooth_disabled
                      : Icons.bluetooth,
                  color: _status.contains('failed') ? Colors.red : Colors.green,
                  size: 48,
                ),
                const SizedBox(height: 20),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    _status,
                    style: TextStyle(
                      color: _status.contains('failed') ? Colors.red : Colors.green,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}