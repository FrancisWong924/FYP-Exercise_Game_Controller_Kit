import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math'as math;
import 'bluetooth_connection.dart';
import 'models/controller_element.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterBluePlus.setLogLevel(LogLevel.error, color: false);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  runApp(const MaterialApp(home: ControllerApp()));
}

class ControllerApp extends StatefulWidget {
  const ControllerApp({super.key});

  @override
  State<ControllerApp> createState() => _ControllerAppState();
}

class _ControllerAppState extends State<ControllerApp> {
  final BleManager bleManager = BleManager();
  late SharedPreferences prefs;
  String _status = 'Connecting...';
  bool showStatusBanner = true;
  Timer? bannerTimer;
  bool isLoading = true;
  bool paused = false;

  double neutralRoll = 1.55;
  double maxDeviation = 1.1;
  double filteredSteering = 0.0;
  double smoothedZ = 0.0;
  double steeringValue = 0.0; // -1.0 (left) to +1.0 (right)
  Timer? sendTimer;

  StreamSubscription<AccelerometerEvent>? accelSubscription;
  double accelZ = 0.0;  // Current Z-axis accel
  double stepThreshold = 1.5;  // Tune this: higher = needs stronger shake/step
  double lastAccelZ = 0.0;
  bool isWalking = false;  // True if forward motion detected
  Timer? stepTimer;  // Debounce steps

  // Customizable layout!
  List<ControllerElement> controllerElements = [];

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    initializeApp();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    accelSubscription?.cancel();
    sendTimer?.cancel();
    stepTimer?.cancel();
    bleManager.stopInputSending();
    bleManager.dispose();
    super.dispose();
  }

  Future<void> initializeApp() async {
    await initPrefs();

    // Listen to connection status
    bleManager.statusStream.listen((status) {
      String text = statusToString(status);
      updateStatusAndBanner(text);
      setState(() {
        _status = text;
      });
      print("[UI] Status: $text");

      // React to disconnection
      if (status == BleConnectionStatus.disconnected ||
          status == BleConnectionStatus.failed ||
          status == BleConnectionStatus.bluetoothOff) {
        accelSubscription?.cancel();
        // Stop tilt steering
        sendTimer?.cancel();
        setState(() {
          steeringValue = 0.0;
        });

        // Stop step detection
        stepTimer?.cancel();
        setState(() {
          isWalking = false;
        });
      }

      // When reconnecting and previously enabled, restart sensors
      if (status == BleConnectionStatus.connected) {
        // Restart features if they were enabled before disconnect
        startAccelerometerListening();
      }
    });

    // Listen to incoming data
    bleManager.receivedDataStream.listen((data) {
      String message = utf8.decode(data).trim();
      print("[UI] ← From PC: $message");

      // Handle vibration command
      if (message == "VIBRATE") {
        triggerVibration();
      }
    });
    // Start Bluetooth connection
    bleManager.startScanningAndConnect();
  }

  // Helper: Log to console + update UI
  String statusToString(BleConnectionStatus status) {
    switch (status) {
      case BleConnectionStatus.scanning:
        return "Scanning for PC...";
      case BleConnectionStatus.connecting:
        return "Connecting...";
      case BleConnectionStatus.connected:
        return "Connected";
      case BleConnectionStatus.disconnected:
        return "Disconnected";
      case BleConnectionStatus.failed:
        return "Reconnecting...";
      case BleConnectionStatus.bluetoothOff:
        return "Turning on Bluetooth...";
    }
  }

  void updateStatusAndBanner(String newStatus) {
    setState(() {
      _status = newStatus;
    });

    final bool isConnected = newStatus == "Connected";

    // Cancel previous timer
    bannerTimer?.cancel();

    setState(() {
      showStatusBanner = true;
    });

    if (isConnected) {
      // Auto-hide after 3 seconds when connected
      bannerTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            showStatusBanner = false;
          });
        }
      });
    } else {
      // Always show if not connected
      showStatusBanner = true;
    }
  }

  // Call this once when you need both features
  void startAccelerometerListening() {
    accelSubscription?.cancel();
    sendTimer?.cancel();

    accelSubscription = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval)
      .listen((AccelerometerEvent event) {
        if (paused) return;

        // ── STEERING (landscape left/right tilt) ───────────────────────────────
        double roll = math.atan2(event.z, event.y);
        // print("Raw roll: ${roll.toStringAsFixed(3)}");
        double deviation = neutralRoll - roll;
        double rawSteering = deviation / maxDeviation;
        rawSteering = rawSteering.clamp(-1.0, 1.0);
        // print("rawSteering: ${rawSteering.toStringAsFixed(3)}");
        const double smoothing = 0.2;
        filteredSteering = filteredSteering * (1 - smoothing) + rawSteering * smoothing;

        double steering = filteredSteering;
        if (steering.abs() < 0.08) steering = 0.0;
        // print("steering: ${steering.toStringAsFixed(3)}");
        if ((steering - steeringValue).abs() > 0.01) {
          setState(() => steeringValue = steering);
        }

        // ── WALKING DETECTION ──────────────────────────────────────────────────
        smoothedZ = 0.8 * smoothedZ + 0.2 * event.z;
        double deltaZ = (smoothedZ - lastAccelZ).abs();
        lastAccelZ = smoothedZ;

        if (deltaZ > stepThreshold) {
          isWalking = true;
          stepTimer?.cancel();
          stepTimer = Timer(const Duration(milliseconds: 300), () {
            isWalking = false;
          });
        }

        if (isWalking) {
          bleManager.updateStep(ControllerId.leftJoystick, 0.0, -1.0);
        } else {
          bleManager.updateStep(ControllerId.leftJoystick, 0.0, 0.0);
        }
    });

    sendTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
        bleManager.updateSteering(
          steeringValue,  // left = negative, right = positive
        );
    });
  }

  // NEW: Vibration function
  Future<void> triggerVibration() async {
    // Check if device supports vibration
    bool? hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator != true) {
      print("[VIBRATION] Device does not support vibration");
      return;
    }

    // Simple single buzz (500ms)
    Vibration.vibrate(duration: 500);
  }

  Future<void> initPrefs() async {
    prefs = await SharedPreferences.getInstance();   // ← initialize here
    await loadLayout();                              // ← then load saved layout
    setState(() => isLoading = false);
  }

  Future<void> saveLayout() async {
    final json = controllerElements.map((e) => e.toJson()).toList();
    await prefs.setString('custom_controller', jsonEncode(json));
  }

  Future<void> loadLayout() async {
    final jsonString = prefs.getString('custom_controller');
    if (jsonString != null) {
      final List<dynamic> jsonList = jsonDecode(jsonString);
      controllerElements = jsonList
          .map((json) => ControllerElement.fromJson(json))
          .toList();
      setState(() {});
    }
  }

  List<ControllerElement> getDefaultLayout(double screenWidth, double screenHeight) {
    return [
      ControllerElement(
        id: ControllerId.leftJoystick,
        type: ControllerElementType.joystick,
        position: Offset(screenWidth - 590, screenHeight - 90),
        size: 55,
      ),
      ControllerElement(
        id: ControllerId.rightJoystick,
        type: ControllerElementType.joystick,
        position: Offset(screenWidth - 200, screenHeight - 90),
        size: 55,
      ),
      ControllerElement(
        id: ControllerId.buttonSquare,
        type: ControllerElementType.button,
        position: Offset(screenWidth - 160, screenHeight - 180),
        size: 65,
        buttonId: 1 << 2,
        label: "square",
      ),
      ControllerElement(
        id: ControllerId.buttonCross,
        type: ControllerElementType.button,
        position: Offset(screenWidth - 105, screenHeight - 125),
        size: 65,
        buttonId: 1 << 0,
        label: "cross",
      ),
      ControllerElement(
        id: ControllerId.buttonCircle,
        type: ControllerElementType.button,
        position: Offset(screenWidth - 50, screenHeight - 180),
        size: 65,
        buttonId: 1 << 1,
        label: "circle",
      ),
      ControllerElement(
        id: ControllerId.buttonTriangle,
        type: ControllerElementType.button,
        position: Offset(screenWidth - 105, screenHeight - 235),
        size: 65,
        buttonId: 1 << 3,
        label: "triangle",
      ),
      ControllerElement(
        id: ControllerId.buttonUp,
        type: ControllerElementType.button,
        position: Offset(screenWidth - 685, screenHeight - 235),
        size: 65,
        buttonId: 1 << 12,
        label: "arrow_up",
      ),
      ControllerElement(
        id: ControllerId.buttonDown,
        type: ControllerElementType.button,
        position: Offset(screenWidth - 685, screenHeight - 125),
        size: 65,
        buttonId: 1 << 13,
        label: "arrow_down",
      ),
      ControllerElement(
        id: ControllerId.buttonLeft,
        type: ControllerElementType.button,
        position: Offset(screenWidth - 740, screenHeight - 180),
        size: 65,
        buttonId: 1 << 14,
        label: "arrow_left",
      ),
      ControllerElement(
        id: ControllerId.buttonRight,
        type: ControllerElementType.button,
        position: Offset(screenWidth - 630, screenHeight - 180),
        size: 65,
        buttonId: 1 << 15,
        label: "arrow_right",
      ),
    ];
  }

  // Helper method to keep your buttons consistent
  Widget _buildMenuButton(Widget iconWidget, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            SizedBox(
            width: 24, 
              height: 24, 
              child: Center(child: iconWidget)
            ),
            const SizedBox(width: 15),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      backgroundColor: Colors.black87,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final double screenWidth = constraints.maxWidth;
          final double screenHeight = constraints.maxHeight;
          return Stack(
            children: [
              // Top-center button
              Positioned(
                top: 5, // Adjust this value to move it higher or lower
                left: 16,
                right: 0,
                child: Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min, // Keep buttons tightly packed
                    children: [
                      GestureDetector(
                        onTap: () async {
                          setState(() => paused = !paused);
                          final sent = await bleManager.togglePause(paused ? "PAUSE" : "RESUME");
                          if (!sent) {
                            setState(() => paused = !paused);
                          }
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
                      const SizedBox(width: 4),
                      GestureDetector(
                        onTap: () {
                          showDialog(
                            context: context,
                            barrierColor: Colors.black54, // Darkens the background
                            builder: (BuildContext context) {
                              return Center(
                                child: Material(
                                  color: Colors.transparent,
                                  child: Container(
                                    // Set your desired width/height for the center box
                                    width: MediaQuery.of(context).size.width * 0.4,
                                    padding: const EdgeInsets.all(20),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1A1A1A), // Dark charcoal
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: Colors.white10),
                                      boxShadow: [
                                        BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 10)
                                      ],
                                    ),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text(
                                          "SETTINGS",
                                          style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                                        ),
                                        const SizedBox(height: 20),
                                        // Button 1: Layout Customization
                                        _buildMenuButton(const Icon(Icons.tune, color: Colors.white54, size: 20), "Customize Layout", () {}),
                                        const SizedBox(height: 10),
                                        // Close Button
                                        TextButton(
                                          onPressed: () => Navigator.pop(context),
                                          child: const Text("CLOSE", style: TextStyle(color: Colors.blueAccent)),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        },
                        child: Container(
                          width: 36, height: 26,
                          decoration: const BoxDecoration(
                            color: Colors.white24,
                            shape: BoxShape.rectangle,
                            borderRadius: BorderRadius.all(Radius.circular(4)),
                          ),
                          child: Icon(Icons.settings, color: Colors.white, size: 18),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Connection status banner
              Positioned(
                bottom: 10, // Adjust as needed
                left: 10,
                right: 16,
                child: Center(
                  child: ConnectionStatusBanner(
                    status: _status,
                    isError: _status.contains('Disconnected'),
                    show: showStatusBanner,
                  ),
                ),
              ),
              // Render all customizable elements
              ...controllerElements.map((element) {
                if (element.type == ControllerElementType.button) {
                  return CustomButton(
                    element: element,
                    onPressed: (id, pressed) {
                      // send button press/release to PC
                      final bit = element.buttonId;
                      bleManager.updateButton(bit, pressed);
                    },
                  );
                } else if (element.type == ControllerElementType.joystick) {
                  return CustomJoystick(
                    element: element,
                    deadzone: 0.20,
                    onChange: (id, x, y) {
                      bleManager.updateJoystick(id, x, y);
                    },
                  );
                }
                return SizedBox.shrink();
              }),
              if (controllerElements.isEmpty)
                ...getDefaultLayout(screenWidth, screenHeight).map((element) {
                  if (element.type == ControllerElementType.button) {
                    return CustomButton(
                      element: element,
                      onPressed: (id, pressed) {
                        // send button press/release to PC
                        final bit = element.buttonId;
                        bleManager.updateButton(bit, pressed);
                      },
                    );
                  } else if (element.type == ControllerElementType.joystick) {
                    return CustomJoystick(
                      element: element,
                      deadzone: 0.20,
                      onChange: (id, x, y) {
                        bleManager.updateJoystick(id, x, y);
                      },
                    );
                  }
                  return SizedBox.shrink();
                }),
            ],
          );
        },
      ),
    );
  }
}

class ConnectionStatusBanner extends StatelessWidget {
  final String status;
  final bool isError;
  final bool show;

  const ConnectionStatusBanner({
    Key? key,
    required this.status,
    required this.isError,
    required this.show,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      duration: const Duration(milliseconds: 500),
      curve: show ? Curves.easeOutCubic : Curves.easeInCubic,
      offset: show ? Offset(0, 0) : Offset(0, 1.5),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        opacity: show ? 1.0 : 0.0,
        child: IgnorePointer(
          child: SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                margin: const EdgeInsets.only(bottom: 40, left: 40, right: 40),
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.97),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Text(
                  status,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}