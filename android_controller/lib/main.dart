import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math'as math;
import 'bluetooth_connection.dart';
import 'models/controller_element.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:sensors_plus/sensors_plus.dart' as sensors_plus;
import 'package:flutter_rotation_sensor/flutter_rotation_sensor.dart' as rotation_sensor;
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

  StreamSubscription<rotation_sensor.OrientationEvent>? orientationSubscription;
  double steeringValue = 0.0; // -1.0 (left) to +1.0 (right)
  Timer? sendTimer;
  bool isSteeringActive = false;

  StreamSubscription<sensors_plus.AccelerometerEvent>? accelSubscription;
  double accelZ = 0.0;  // Current Z-axis accel
  double stepThreshold = 1.5;  // Tune this: higher = needs stronger shake/step
  double lastAccelZ = 0.0;
  bool isSteppingActive = false;  // True if currently detecting steps
  bool isWalking = false;  // True if forward motion detected
  Timer? stepTimer;  // Debounce steps

  // Customizable layout!
  List<ControllerElement> controllerElements = [];

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    rotation_sensor.RotationSensor.samplingPeriod = rotation_sensor.SensorInterval.gameInterval; // ~20ms updates
    // Remap for landscape if needed (test: if roll signs feel flipped, adjust)
    rotation_sensor.RotationSensor.coordinateSystem = rotation_sensor.CoordinateSystem.transformed(rotation_sensor.Axis3.X, -rotation_sensor.Axis3.Z);
    initializeApp();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    orientationSubscription?.cancel();
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
        
        // Stop tilt steering
        if (isSteeringActive) {
          orientationSubscription?.cancel();
          sendTimer?.cancel();
          setState(() {
            steeringValue = 0.0;
          });
        }

        // Stop step detection
        if (isSteppingActive) {
          accelSubscription?.cancel();
          stepTimer?.cancel();
          setState(() {
            isWalking = false;
          });
          // Send neutral joystick to avoid "stuck forward"
          bleManager.updateJoystick(ControllerId.leftJoystick, 0.0, 0.0);
        }
      }

      // When reconnecting and previously enabled, restart sensors
      if (status == BleConnectionStatus.connected) {
        // Restart features if they were enabled before disconnect
        if (isSteeringActive) {
          startTiltSteering();
        }
        if (isSteppingActive) {
          startWalkingDetection();
        }
      }
    });

    // Listen to incoming data
    bleManager.receivedDataStream.listen((data) {
      String message = utf8.decode(data).trim();
      print("[UI] ← From PC: $message");

      // Handle tilt steering commands
      if (message == "TILT_ON") {
        setState(() {
          isSteeringActive = true;
          startTiltSteering();
        });
      } else if (message == "TILT_OFF") {
        setState(() {
          isSteeringActive = false;
        });
      }

      // Handle step detection
      if (message == "STEP_ON") {
        setState(() {
          isSteppingActive = true;
          startWalkingDetection();
        });
      } else if (message == "STEP_OFF") {
        setState(() {
          isSteppingActive = false;
        });
      }

      // NEW: Handle vibration command
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

  void startTiltSteering() {
    orientationSubscription?.cancel();
    sendTimer?.cancel();

    orientationSubscription = rotation_sensor.RotationSensor.orientationStream.listen((rotation_sensor.OrientationEvent event) {
      if (paused || !isSteeringActive) return;

      // In landscape: roll = left/right tilt (radians)
      double roll = event.eulerAngles.roll;       // -π to +π

      if (roll > math.pi)  roll -= 2 * math.pi;
      if (roll < -math.pi) roll += 2 * math.pi;

      const double maxRoll = 0.75;  // ~70° → tweak this for your preference!
      double steering = (roll / maxRoll).clamp(-1.0, 1.0);

      // Deadzone
      if (steering.abs() < 0.08) steering = 0.0;

      if ((steering - steeringValue).abs() > 0.01) {
        setState(() {
          steeringValue = steering;
        });
      }

      // print("Roll: ${roll.toStringAsFixed(3)} → Steering: ${steering.toStringAsFixed(3)}");
    });

    // Your existing periodic sender (BLE steering update)
    sendTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (isSteeringActive && steeringValue.abs() > 0.001) {
        bleManager.updateSteering(
          steeringValue,  // left = negative, right = positive
        );
      }
    });
  }

  void startWalkingDetection() {
    accelSubscription?.cancel();

    // Smoothed values to reduce noise
    double smoothedZ = 0.0;

    accelSubscription = sensors_plus.accelerometerEventStream(samplingPeriod: sensors_plus.SensorInterval.gameInterval)
        .listen((sensors_plus.AccelerometerEvent event) {
      if (paused || !isSteppingActive) return;  // Reuse your pause logic

      accelZ = event.z;  // Z-axis: up/down (gravity ≈9.8 when flat)
      smoothedZ = 0.8 * smoothedZ + 0.2 * accelZ;  // Adjust 0.2 for more/less smoothing
      // Simple step detection: detect peaks in Z (up/down bounce)
      double deltaZ = (smoothedZ - lastAccelZ).abs();
      lastAccelZ = smoothedZ;

      if (deltaZ > stepThreshold) {
        // Detected a "step" → set forward
        isWalking = true;
        stepTimer?.cancel();
        stepTimer = Timer(const Duration(milliseconds: 300), () {  // Debounce
          isWalking = false;
        });
      }

      if (isWalking) {
        bleManager.updateJoystick(ControllerId.leftJoystick, 0.0, -1.0);  // Forward on left Y
      } else {
        bleManager.updateJoystick(ControllerId.leftJoystick, 0.0, 0.0);  // Neutral
      }

      // print("Accel Z: ${accelZ.toStringAsFixed(3)} → Smoothed: ${smoothedZ.toStringAsFixed(3)} → Delta: ${deltaZ.toStringAsFixed(3)} → Walking: $isWalking");
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
                  child: GestureDetector(
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