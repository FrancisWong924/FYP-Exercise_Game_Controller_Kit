import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'bluetooth_connection.dart';
import 'models/controller_element.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:simple_gesture_detector/simple_gesture_detector.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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

  final Map<String, double> joyValues = {};   // "joy1" → x, "joy1_y" → y
  int currentButtons = 0;  // Only one variable for ALL buttons!

  // Customizable layout!
  List<ControllerElement> controllerElements = [];

  @override
  void initState() {
    super.initState();
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
    });
    // Start Bluetooth connection
    bleManager.startScanningAndConnect();
    initPrefs();
  }

  @override
  void dispose() {
    bleManager.stopInputSending();
    bleManager.dispose();
    super.dispose();
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
        id: "left_joystick",
        type: ControllerElementType.joystick,
        position: Offset(screenWidth - 590, screenHeight - 90),
        size: 55,
      ),
      ControllerElement(
        id: "right_joystick",
        type: ControllerElementType.joystick,
        position: Offset(screenWidth - 200, screenHeight - 90),
        size: 55,
      ),
      ControllerElement(
        id: "button_square",
        type: ControllerElementType.button,
        position: Offset(screenWidth - 160, screenHeight - 180),
        size: 65,
        buttonId: 1 << 2,
        label: "square",
      ),
      ControllerElement(
        id: "button_x",
        type: ControllerElementType.button,
        position: Offset(screenWidth - 105, screenHeight - 125),
        size: 65,
        buttonId: 1 << 0,
        label: "cross",
      ),
      ControllerElement(
        id: "button_o",
        type: ControllerElementType.button,
        position: Offset(screenWidth - 50, screenHeight - 180),
        size: 65,
        buttonId: 1 << 1,
        label: "circle",
      ),
      ControllerElement(
        id: "button_triangle",
        type: ControllerElementType.button,
        position: Offset(screenWidth - 105, screenHeight - 235),
        size: 65,
        buttonId: 1 << 3,
        label: "triangle",
      ),
      ControllerElement(
        id: "button_up",
        type: ControllerElementType.button,
        position: Offset(screenWidth - 685, screenHeight - 235),
        size: 65,
        buttonId: 1 << 12,
        label: "arrow_up",
      ),
      ControllerElement(
        id: "button_down",
        type: ControllerElementType.button,
        position: Offset(screenWidth - 685, screenHeight - 125),
        size: 65,
        buttonId: 1 << 13,
        label: "arrow_down",
      ),
      ControllerElement(
        id: "button_left",
        type: ControllerElementType.button,
        position: Offset(screenWidth - 740, screenHeight - 180),
        size: 65,
        buttonId: 1 << 14,
        label: "arrow_left",
      ),
      ControllerElement(
        id: "button_right",
        type: ControllerElementType.button,
        position: Offset(screenWidth - 630, screenHeight - 180),
        size: 65,
        buttonId: 1 << 15,
        label: "arrow_right",
      ),
    ];
  }

  void updateButton(int buttonId, bool pressed) {
    setState(() {
      if (pressed) {
        currentButtons |= buttonId;    // Set bit
      } else {
        currentButtons &= ~buttonId;   // Clear bit
      }
    });

    // Send immediately — games love instant response
    // bleManager.sendPacket({
    //   "type": "btn",
    //   "buttons": currentButtons
    // });
  }

  double applyDeadzone(double value, [double deadzone = 0.15]) {
    if (value.abs() < deadzone) return 0.0;
    return (value.abs() - deadzone) / (1.0 - deadzone) * (value > 0 ? 1 : -1);
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
                      // Update your button state bitmask
                      updateButton(element.buttonId, pressed);
                    },
                  );
                } else if (element.type == ControllerElementType.joystick) {
                  return CustomJoystick(
                    element: element,
                    deadzone: 0.20,
                    onChange: (id, x, y) {
                      bleManager.movementInput(InputState(joyLX: x, joyLY: y));
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
                        // Update your button state bitmask
                        updateButton(element.buttonId, pressed);
                      },
                    );
                  } else if (element.type == ControllerElementType.joystick) {
                    return CustomJoystick(
                      element: element,
                      deadzone: 0.20,
                      onChange: (id, x, y) {
                        bleManager.movementInput(InputState(joyLX: x, joyLY: y));
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