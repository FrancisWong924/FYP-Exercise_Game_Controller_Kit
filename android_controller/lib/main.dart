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

class _ControllerAppState extends State<ControllerApp> with WidgetsBindingObserver {
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

  StreamSubscription<AccelerometerEvent>? accelSubscription;
  double accelZ = 0.0;  // Current Z-axis accel
  double stepThreshold = 1.5;  // Tune this: higher = needs stronger shake/step
  double lastAccelZ = 0.0;
  bool isWalking = false;  // True if forward motion detected
  Timer? stepTimer;  // Debounce steps

  String messageBuffer = ""; // Buffer for large transmissions
  bool isReceivingLayout = false;
  double downloadProgress = 0.0;
  DateTime? lastLayoutChunkTime;
  Timer? layoutWatchdog;

  ControllerLayout? customLayout; 
  bool isUsingCustomLayout = false;

  Widget? _processedBackground;
  Widget? backgroundColor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    initializeApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    customLayout = null;
    accelSubscription?.cancel();
    stepTimer?.cancel();
    bleManager.stopInputSending();
    bleManager.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    switch (state) {
      case AppLifecycleState.paused:
        // App is in the background (user switched apps or home screen)
        print("App Paused: Backgrounded");
        _handleInterruption();
        break;
      case AppLifecycleState.inactive:
        // App is in an idle state (Phone call coming in, iOS Control Center, or Alarm)
        print("App Inactive: Interruption detected");
        _handleInterruption();
        break;
      case AppLifecycleState.resumed:
        // User came back to the app
        print("App Resumed");
        break;
      case AppLifecycleState.detached:
        // App is still hosted by a flutter engine but is detached from any host views
        break;
      case AppLifecycleState.hidden: // Introduced in newer Flutter versions
        break;
    }
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
        _resetLoadingState();
        accelSubscription?.cancel();
        // Stop tilt steering
        setState(() {
          steeringValue = 0.0;
          isUsingCustomLayout = false;
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
    bleManager.receivedDataStream.listen((data) async {
      try {
        String message = utf8.decode(data).trim();
        // print("[UI] ← From PC: $message");
        if (message.startsWith("CONNECT_GAME:")) {
          List<String> parts = message.split(":");
          
          if (parts.length >= 3) {
            String gameId = parts[1];
            String version = parts[2];
            String storageKey = "${gameId}_v$version"; // Create a unique key per version

            print("[UI] Game Handshake: $gameId (Version: $version)");
            
            if (customLayout != null && customLayout!.gameId == gameId && customLayout!.version == version) {
              setState(() {
                isUsingCustomLayout = true;
              });
              return;
            }
            
            if (prefs.containsKey(storageKey)) {
              print("[UI] Found cached layout for $storageKey");
              bool success = await loadLayout(storageKey); // Change loadLayout to return bool
  
              if (!success) {
                print("[UI] Cached layout corrupted. Requesting fresh one...");
                bleManager.sendMessage("NEED_LAYOUT");
              }
            } else {
              print("[UI] Layout not found for $storageKey. Requesting...");
              bleManager.sendMessage("NEED_LAYOUT");
            }
          }
          return;
        }
        
        // 1. SIGNAL: Start of a large message
        if (message == "START_MSG") {
          print("[UI] Incoming large layout started...");
          setState(() {
            isReceivingLayout = true;
            messageBuffer = ""; 
          });
          bleManager.setInputPause(true);

          lastLayoutChunkTime = DateTime.now();
          layoutWatchdog?.cancel();
          layoutWatchdog = Timer.periodic(const Duration(seconds: 1), (timer) {
              if (lastLayoutChunkTime == null) return;
              
              // The "Heartbeat Elapsed" idea: if now - lastSeen > 3 seconds
              if (DateTime.now().difference(lastLayoutChunkTime!).inSeconds > 2) {
                  print("[UI] Layout transfer heartbeat lost!");
                  timer.cancel();
                  _resetLoadingState();
                  return;
              }
              setState(() {});
          });
          return;
        }

        // 2. SIGNAL: End of a large message
        if (message == "END_MSG") {
          print("[UI] Large message complete. Processing...");
          layoutWatchdog?.cancel();
          await handleFullJsonPayload(messageBuffer);
          _resetLoadingState();
          return;
        }

        // 3. DATA CHUNK: Append to buffer
        if (message.startsWith("CHUNK:")) {
          lastLayoutChunkTime = DateTime.now();
          messageBuffer += message.replaceFirst("CHUNK:", "");
          return;
        }

        if (message.startsWith("LAYOUT:")) {
          handleFullJsonPayload(message);
        }
      
        // Handle vibration command
        if (message == "VIBRATE") {
          triggerVibration();
          return;
        }
      } catch (e) {
        print("[UI] Error decoding incoming BLE data: $e");
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

  void _handleInterruption() {
    // Logic to prevent the car/character from driving off forever
    if (!paused) {
      setState(() => paused = true);
      bleManager.sendMessage("PAUSE");
    }
  }

  void _resetLoadingState() {
    layoutWatchdog?.cancel();
    lastLayoutChunkTime = null;
    if (isReceivingLayout) {
      setState(() {
        isReceivingLayout = false;
        messageBuffer = "";
      });
      bleManager.setInputPause(false);
      print("[UI] Layout loading state reset.");
    }
  }

  // Call this once when you need both features
  void startAccelerometerListening() {
    accelSubscription?.cancel();

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
          steeringValue = steering;
          bleManager.updateSteering(steeringValue);
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

  Future<void> handleFullJsonPayload(String fullJson) async {
    try {
      final Map<String, dynamic> decoded = jsonDecode(fullJson);
      String gameId = decoded['gameId'];
      int version = decoded['version'];
      
      String storageKey = "${gameId}_v$version";
      final layout = ControllerLayout.fromJson(decoded);
      print('Saving layout...');
      // Save to SharedPreferences
      await saveLayout(storageKey, layout);
      loadLayout(storageKey);
    } catch (e) {
      print("[UI] Failed to parse reassembled JSON: $e");
      // If the image was too big and corrupted the JSON, the error will be caught here
    }
  }

  Future<void> initPrefs() async {
    prefs = await SharedPreferences.getInstance();   // ← initialize here
    // await prefs.clear();
  //   final allKeys = prefs.getKeys();
  // print("--- [DEBUG] SharedPreferences Content ---");
  // if (allKeys.isEmpty) {
  //   print("Storage is empty.");
  // } else {
  //   for (String key in allKeys) {
  //     // Log the key and a preview of the value
  //     final value = prefs.get(key).toString();
  //     final preview = value.length > 50 ? "${value.substring(0, 50)}..." : value;
  //     print("Key: [$key] | Value: $preview");
  //   }
  // }
  // print("-----------------------------------------");
    setState(() => isLoading = false);
  }

  Future<void> saveLayout(String storageKey, ControllerLayout layout) async {
    final String jsonString = jsonEncode(layout.toJson());
    await prefs.setString(storageKey, jsonString);
    print("[Storage] Layout for $storageKey saved.");
  }

  Future<bool> loadLayout(String storageKey) async {
    final jsonString = prefs.getString(storageKey);
    if (jsonString != null) {
      try {     
        // Use the fromJson factory we created earlier
        customLayout = ControllerLayout.fromJson(jsonDecode(jsonString));
        processBackgroundImage(customLayout!.backgroundImage);
        buildBackgroundColor(customLayout!.backgroundColor);
        setState(() {
          isUsingCustomLayout = true;
        });

        print("[Storage] Local layout found for $storageKey");
        return true;
      } catch (e) {
        print("[Storage] Error loading saved layout: $e");
      }
    }
    return false;
  }

  List<ControllerElement> getDefaultLayout(double screenWidth, double screenHeight) {
    return [
      ControllerElement(
        id: ControllerId.leftJoystick.name,
        type: ControllerElementType.joystick,
        joystickType: "left",
        position: Offset(0.252, 0.75),
        label: "left_joystick",
        size: 55,
      ),
      ControllerElement(
        id: ControllerId.rightJoystick.name,
        type: ControllerElementType.joystick,
        joystickType: "right",
        position: Offset(0.76, 0.75),
        label: "right_joystick",
        size: 55,
      ),
      ControllerElement(
        id: ControllerId.buttonSquare.name,
        type: ControllerElementType.button,
        position: Offset(0.804, 0.499),
        size: 65,
        buttonId: 1 << 2,
        label: "square",
      ),
      ControllerElement(
        id: ControllerId.buttonCross.name,
        type: ControllerElementType.button,
        position: Offset(0.87, 0.642),
        size: 65,
        buttonId: 1 << 0,
        label: "cross",
      ),
      ControllerElement(
        id: ControllerId.buttonCircle.name,
        type: ControllerElementType.button,
        position: Offset(0.935, 0.499),
        size: 65,
        buttonId: 1 << 1,
        label: "circle",
      ),
      ControllerElement(
        id: ControllerId.buttonTriangle.name,
        type: ControllerElementType.button,
        position: Offset(0.87, 0.358),
        size: 65,
        buttonId: 1 << 3,
        label: "triangle",
      ),
      ControllerElement(
        id: ControllerId.buttonUp.name,
        type: ControllerElementType.button,
        position: Offset(0.141, 0.358),
        size: 65,
        buttonId: 1 << 12,
        label: "arrow_up",
      ),
      ControllerElement(
        id: ControllerId.buttonDown.name,
        type: ControllerElementType.button,
        position: Offset(0.141, 0.642),
        size: 65,
        buttonId: 1 << 13,
        label: "arrow_down",
      ),
      ControllerElement(
        id: ControllerId.buttonLeft.name,
        type: ControllerElementType.button,
        position: Offset(0.075, 0.499),
        size: 65,
        buttonId: 1 << 14,
        label: "arrow_left",
      ),
      ControllerElement(
        id: ControllerId.buttonRight.name,
        type: ControllerElementType.button,
        position: Offset(0.206, 0.499),
        size: 65,
        buttonId: 1 << 15,
        label: "arrow_right",
      ),
    ];
  }

  void processBackgroundImage(String? source) {
    if (source == null || source.isEmpty) return;

    if (source.startsWith('http://') || source.startsWith('https://')) {
      _processedBackground = Image.network(source,
        fit: BoxFit.cover,
        errorBuilder: (ctx, err, stack) => Container(color: Colors.black87),
      );
    } else {
      try {
        final bytes = base64Decode(source.split(',').last);
        _processedBackground = Image.memory(bytes, fit: BoxFit.cover);
      } catch (e) {
        print("Failed to decode base64 image: $e");
        _processedBackground = Container(color: const Color(0xE2FFFFFF));
      }
    }
  }

  void buildBackgroundColor(String? hexColor) {
    if (hexColor == null || hexColor.isEmpty) return;

    try {
      backgroundColor = Container(color: Color(int.parse(hexColor, radix: 16)));
      return;
    } catch (e) {
      print("Color parse error: $e");
    }
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
      body: Stack(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final double screenWidth = constraints.maxWidth;
              final double screenHeight = constraints.maxHeight;
              return Stack(
                children: [
                  if (isUsingCustomLayout)
                    Positioned.fill(
                      child: Opacity(
                        opacity: 0.8, // Optional: dim it slightly so buttons pop
                        child: _processedBackground ?? backgroundColor ?? Container(color: Colors.black87),
                      ),
                    ),
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
                              final sent = await bleManager.sendMessage(paused ? "PAUSE" : "RESUME");
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
                  if (isUsingCustomLayout && customLayout != null)
                    ...customLayout!.elements.map((element) {
                      if (element.type == ControllerElementType.button) {
                        return CustomButton(
                          element: element,
                          onPressed: (id, pressed) {
                            // send button press/release to PC
                            final bit = element.buttonId;
                            bleManager.updateButton(bit, pressed);
                          },
                        );
                      } else {
                        return CustomJoystick(
                          element: element,
                          deadzone: 0.20,
                          onChange: (id, x, y) {
                            final type = element.joystickType ?? "left";
                            bleManager.updateJoystick(type, x, y);
                          },
                        );
                      }
                    })
                  else
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
                      } else {
                        return CustomJoystick(
                          element: element,
                          deadzone: 0.20,
                          onChange: (id, x, y) {
                            final type = element.joystickType ?? "left";
                            bleManager.updateJoystick(type, x, y);
                          },
                        );
                      }
                    }),
                ],
              );
            },
          ),
          if (isReceivingLayout)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.8), // Dim the screen
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 200,
                        child: LinearProgressIndicator(
                          backgroundColor: Colors.white10,
                          valueColor: AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                        ),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        "RECEIVING CUSTOM LAYOUT...",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "${(messageBuffer.length / 1024).toStringAsFixed(1)} KB received",
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
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