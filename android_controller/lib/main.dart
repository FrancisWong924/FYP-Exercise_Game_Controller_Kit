import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math'as math;
import 'bluetooth_connection.dart';
import 'models/controller_element.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_rotation_sensor/flutter_rotation_sensor.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  StreamSubscription<OrientationEvent>? orientationSubscription;
  double steeringValue = 0.0; // -1.0 (left) to +1.0 (right)
  Timer? sendTimer;
  bool isSteeringActive = true;

  // Customizable layout!
  List<ControllerElement> controllerElements = [];

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    RotationSensor.samplingPeriod = SensorInterval.gameInterval; // ~20ms updates
    // Remap for landscape if needed (test: if roll signs feel flipped, adjust)
    RotationSensor.coordinateSystem = CoordinateSystem.transformed(Axis3.X, -Axis3.Z);
    initializeApp();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    orientationSubscription?.cancel();
    sendTimer?.cancel();
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
    });

    // Listen to incoming data
    bleManager.receivedDataStream.listen((data) {
      String message = utf8.decode(data).trim();
      print("[UI] ← From PC: $message");

      // Handle tilt steering commands
      if (message == "TILT_ON") {
        setState(() {
          isSteeringActive = true;
          saveTiltSteeringState();
          startTiltSteering();
        });
      } else if (message == "TILT_OFF") {
        setState(() {
          isSteeringActive = false;
          saveTiltSteeringState();
        });
      }
    });
    isSteeringActive = true;
    saveTiltSteeringState();
    startTiltSteering();
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

    orientationSubscription = RotationSensor.orientationStream.listen((OrientationEvent event) {
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

    // Your existing periodic sender (BLE joystick update)
    sendTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (isSteeringActive && steeringValue.abs() > 0.001) {
        bleManager.updateSteering(
          steeringValue,  // left = negative, right = positive
        );
      }
    });
  }

  Future<void> initPrefs() async {
    prefs = await SharedPreferences.getInstance();   // ← initialize here
    isSteeringActive = prefs.getBool('tilt_steering_enabled') ?? false; // Default to false
    await loadLayout();                              // ← then load saved layout
    setState(() => isLoading = false);
  }

  Future<void> saveLayout() async {
    final json = controllerElements.map((e) => e.toJson()).toList();
    await prefs.setString('custom_controller', jsonEncode(json));
  }

  Future<void> saveTiltSteeringState() async {
    await prefs.setBool('tilt_steering_enabled', isSteeringActive);
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