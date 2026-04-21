import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math'as math;
import 'bluetooth_connection.dart';
import 'models/controller_element.dart';
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
  bool isLoading = true;
  bool paused = false;
  Timer? bannerTimer;
  Offset editorPosition = const Offset(0.5, 0.05);

  double neutralRoll = 1.55;
  double maxDeviation = 1.1;
  double filteredSteering = 0.0;
  double smoothedZ = 0.0;
  double steeringValue = 0.0; // -1.0 (left) to +1.0 (right)

  StreamSubscription<AccelerometerEvent>? accelSubscription;
  double accelZ = 0.0;  // Current Z-axis accel
  double stepThreshold = 1.5;  // Tune this: higher = needs stronger shake/step
  double lastAccelZ = 0.0;
  Timer? stepTimer;  // Debounce steps
  bool isWalking = false;  // True if forward motion detected
  bool steeringEnabled = false; // New: toggle for steering control
  bool steppingEnabled = false; // New: true if stepping is enabled

  String messageBuffer = ""; // Buffer for large transmissions
  bool isReceivingLayout = false;
  double downloadProgress = 0.0;
  DateTime? lastLayoutChunkTime;
  Timer? layoutWatchdog;

  static String defaultKey = "Default_Layout";
  ControllerLayout? defaultLayout;
  ControllerLayout? currentLayout;
  ControllerLayout? cachedLayout; 

  Widget? _processedBackground;
  Widget? backgroundColor;

  bool isEditing = false;
  String? currentStorageKey;
  String? originalLayoutJson;
  ControllerLayout? editLayoutCopy;
  ControllerElement? selectedElement;

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
    cachedLayout = null;
    currentLayout = null;
    currentStorageKey = null;
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
        if (bleManager.pcDevice == null) {
          setState(() => paused = false);
        }
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
    defaultLayout = await getDefaultLayout();
    currentStorageKey = defaultKey;
    if (!prefs.containsKey(defaultKey)) {
      print("[Init] Default layout not found. Creating it now...");
      await saveLayout(defaultKey, defaultLayout!);
    }
    setState(() {
      currentLayout = defaultLayout;
    });
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
          currentLayout = defaultLayout;
          currentStorageKey = defaultKey;
          _processedBackground = null;
          backgroundColor = null;
          final allKeys = prefs.getKeys();
          for (String key in allKeys) {
            final jsonString = prefs.getString(key);
            if (jsonString == null) continue;
            try {
              final Map<String, dynamic> data = jsonDecode(jsonString);
              // Check if it's the same game/version AND it's already a favorite
              if (data['gameId'] == defaultLayout!.gameId && data['favorite'] == true) {
                final layout = ControllerLayout.fromJson(data);
                currentLayout = layout;
                currentStorageKey = key;
              }
            } catch (e) {
              continue; // Skip keys that aren't valid layout JSON
            }
          }
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

        if (message == "ENABLE_STEERING") {
          setState(() => steeringEnabled = true);
          return;
        }

        if (message == "DISABLE_STEERING") {
          setState(() => steeringEnabled = false);
          return;
        }

        if (message == "ENABLE_STEP") {
          setState(() => steppingEnabled = true);
          return;
        }

        if (message == "DISABLE_STEP") {
          setState(() => steppingEnabled = false);
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
        if ((steering - steeringValue).abs() > 0.01 && steeringEnabled) {
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
        if (steppingEnabled) {
          if (isWalking) {
            bleManager.updateStep(ControllerId.leftJoystick, -1.0);
          } else {
            bleManager.updateStep(ControllerId.leftJoystick, 0.0);
          }
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Failed to Receive Custom Layout")),
      );
      // If the image was too big and corrupted the JSON, the error will be caught here
    }
  }

  Future<void> initPrefs() async {
    prefs = await SharedPreferences.getInstance();   // ← initialize here
    // await prefs.clear();
    // final allKeys = prefs.getKeys();
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
        cachedLayout = ControllerLayout.fromJson(jsonDecode(jsonString));
        currentLayout = cachedLayout; // Set current layout to the loaded cached layout
        if (isEditing) {
          cloneLayout();
        }
        processBackgroundImage(currentLayout!.backgroundImage);
        buildBackgroundColor(currentLayout!.backgroundColor);
        print("--------------------------------------------");
        print("[Storage] Local layout found for $storageKey, name: ${currentLayout!.layoutName}");
        return true;
      } catch (e) {
        print("[Storage] Error loading saved layout: $e");
      }
    }
    return false;
  }

  Future<ControllerLayout> getDefaultLayout() async {
    return ControllerLayout(
      gameId: "default_controller",
      layoutName: "Default Layout",
      version: "1",
      backgroundColor: "FF121212", // Dark grey background
      elements: [
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
          buttonId: 1 << 14,
          label: "square",
          useSystemIcon: "square",
        ),
        ControllerElement(
          id: ControllerId.buttonCross.name,
          type: ControllerElementType.button,
          position: Offset(0.87, 0.642),
          size: 65,
          buttonId: 1 << 12,
          label: "cross",
          useSystemIcon: "cross",
        ),
        ControllerElement(
          id: ControllerId.buttonCircle.name,
          type: ControllerElementType.button,
          position: Offset(0.935, 0.499),
          size: 65,
          buttonId: 1 << 13,
          label: "circle",
          useSystemIcon: "circle",
        ),
        ControllerElement(
          id: ControllerId.buttonTriangle.name,
          type: ControllerElementType.button,
          position: Offset(0.87, 0.358),
          size: 65,
          buttonId: 1 << 15,
          label: "triangle",
          useSystemIcon: "triangle",
        ),
        ControllerElement(
          id: ControllerId.buttonUp.name,
          type: ControllerElementType.button,
          position: Offset(0.141, 0.358),
          size: 65,
          buttonId: 1 << 0,
          label: "arrow_up",
          useSystemIcon: "arrow_up",
        ),
        ControllerElement(
          id: ControllerId.buttonDown.name,
          type: ControllerElementType.button,
          position: Offset(0.141, 0.642),
          size: 65,
          buttonId: 1 << 1,
          label: "arrow_down",
          useSystemIcon: "arrow_down",
        ),
        ControllerElement(
          id: ControllerId.buttonLeft.name,
          type: ControllerElementType.button,
          position: Offset(0.075, 0.499),
          size: 65,
          buttonId: 1 << 2,
          label: "arrow_left",
          useSystemIcon: "arrow_left",
        ),
        ControllerElement(
          id: ControllerId.buttonRight.name,
          type: ControllerElementType.button,
          position: Offset(0.206, 0.499),
          size: 65,
          buttonId: 1 << 3,
          label: "arrow_right",
          useSystemIcon: "arrow_right",
        ),
      ],
    );
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

  void cloneLayout() {
    final String raw = jsonEncode(currentLayout!.toJson());
    editLayoutCopy = ControllerLayout.fromJson(jsonDecode(raw));
    originalLayoutJson = jsonEncode(editLayoutCopy!.toJson());
  }

  void toggleEditMode() async {
    if (isEditing) {
      bool proceed = await _handleUnsavedChanges();
      if (!proceed) return; // User cancelled or we shouldn't exit yet
    }
    setState(() {
      if (!isEditing) {
        cloneLayout();
      } else {
        // EXITING EDIT MODE (from the toggle logic):
        editLayoutCopy = null;
        originalLayoutJson = null;
      }
      isEditing = !isEditing;
      selectedElement = null; 
    });
    // Optionally disable BLE inputs while editing
    bleManager.setInputPause(isEditing);
  }

  Widget _buildStandardToolbar() {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
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
                  return StatefulBuilder(
                    builder: (context, setDialogState) {
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
                                _buildMenuButton(
                                  const Icon(Icons.tune, color: Colors.white54, size: 20), 
                                  "Customize Layout", 
                                  () {
                                    Navigator.pop(context);
                                    toggleEditMode();
                                }),
                                const SizedBox(height: 10),
                                _buildMenuButton(
                                  const Icon(Icons.tune, color: Colors.white54, size: 20), 
                                  steeringEnabled ? "Disable Tilt Steering" : "Enable Tilt Steering",
                                  () {
                                    setDialogState(() {
                                      steeringEnabled = !steeringEnabled;
                                    });
                                }),
                                const SizedBox(height: 10),
                                _buildMenuButton(
                                  const Icon(Icons.tune, color: Colors.white54, size: 20), 
                                  steppingEnabled ? "Disable Step Detection" : "Enable Step Detection",
                                  () {
                                    setDialogState(() {
                                      steppingEnabled = !steppingEnabled;
                                    });
                                }),
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
    );
  }

  Widget _buildEditorToolbar() {
    final double toolbarWidth = MediaQuery.of(context).size.width * 0.45;
    return GestureDetector(
      onPanUpdate: (details) {
        setState(() {
          final size = MediaQuery.of(context).size;
          
          // Update the position based on the drag delta
          // We normalize the movement by dividing by screen size
          double newX = editorPosition.dx + (details.delta.dx / size.width);
          double newY = editorPosition.dy + (details.delta.dy / size.height);

          // Clamp values so it doesn't leave the screen (optional)
          editorPosition = Offset(
            newX.clamp(0.1, 0.9), 
            newY.clamp(0.01, 0.8)
          );
        });
      },
      child: ConstrainedBox(
        constraints: BoxConstraints(
          // Use minWidth and maxWidth as the same value to "lock" the size
          minWidth: toolbarWidth,
          maxWidth: toolbarWidth, 
          maxHeight: 130,
        ),
        child: Card(
          color: Color(0xFF1A1A1A),
          elevation: 8, // Adds a shadow to make it look "above" the buttons
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          child: Padding(
            padding: const EdgeInsets.all(6.0),
            child: Row(
              children: [
                Expanded(
                  flex: 6,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          GestureDetector(
                            onTap: toggleEditMode,
                            child: const Icon(Icons.close, color: Colors.white54, size: 16),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              editLayoutCopy!.layoutName,
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () async {
                              bool isTurningOn = !editLayoutCopy!.favorite;
                              if (isTurningOn) {
                                final allKeys = prefs.getKeys();
                                for (String key in allKeys) {
                                  final jsonString = prefs.getString(key);
                                  if (jsonString == null) continue;
                                  try {
                                    final Map<String, dynamic> data = jsonDecode(jsonString);
                                    // Check if it's the same game/version AND it's already a favorite
                                    if (data['gameId'] == editLayoutCopy!.gameId && 
                                        data['version'] == editLayoutCopy!.version && 
                                        data['favorite'] == true) {
                                      final layout = ControllerLayout.fromJson(data);
                                      layout.favorite = false;
                                      await saveLayout(key, layout);
                                    }
                                  } catch (e) {
                                    continue; // Skip keys that aren't valid layout JSON
                                  }
                                }
                              }
                              setState(() {
                                editLayoutCopy!.favorite = !editLayoutCopy!.favorite;
                              });
                              await saveLayout(currentStorageKey!, editLayoutCopy!);
                            },
                            child: Icon(editLayoutCopy!.favorite ? Icons.star : Icons.star_border, color: Color.fromARGB(255, 243, 195, 3), size: 16),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Size slider
                      Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(minHeight: 48),
                        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05), // Darker subtle background
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: selectedElement == null
                            ? const Center(
                                child: Text(
                                  "No Element Selected",
                                  style: TextStyle(color: Colors.white38, fontSize: 10, fontStyle: FontStyle.italic),
                                ),
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    "Size: ${selectedElement!.size.toInt()}",
                                    style: const TextStyle(color: Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold),
                                  ),
                                  SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 2,
                                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                                    ),
                                    child: Slider(
                                      value: selectedElement!.size,
                                      min: 40,
                                      max: 100,
                                      activeColor: Colors.blueAccent,
                                      inactiveColor: Colors.white10,
                                      onChanged: (val) => setState(() => selectedElement!.size = val),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            height: 25, // Smaller height
                            child: TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                minimumSize: Size.zero, // Removes default min-width
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                side: const BorderSide(color: Color(0xFF505050), width: 1), 
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                              ),
                              onPressed: () async {
                                bool confirm = await confirmDialog();
                                if (confirm && editLayoutCopy != null) {
                                  await prefs.remove(currentStorageKey!);
                                  var layoutName = editLayoutCopy!.layoutName;
                                  setState(() {
                                    selectedElement = null;
                                    editLayoutCopy = defaultLayout;
                                    currentLayout = defaultLayout;
                                    currentStorageKey = defaultKey;
                                    originalLayoutJson = jsonEncode(editLayoutCopy!.toJson());
                                    _processedBackground = null;
                                    backgroundColor = null;
                                  });
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text("Layout '$layoutName' deleted")),
                                  );
                                }
                              },
                              child: const Text("Delete", style: TextStyle(color: Colors.redAccent, fontSize: 11)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            height: 25,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blueAccent,
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                              ),
                              onPressed: () async {
                                String? newName = await showSaveDialog();
                                if (newName != null && newName.isNotEmpty && editLayoutCopy != null) {
                                  setState(() {
                                    selectedElement = null;
                                    editLayoutCopy!.layoutName = newName; // Update the name in the layout data
                                    currentStorageKey = newName;
                                  });
                                  await saveLayout(newName, editLayoutCopy!);
                                  originalLayoutJson = jsonEncode(editLayoutCopy!.toJson());
                                  _buildLayoutList(); // Refresh the list to show the new layout
                                  loadLayout(newName);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text("New Layout '$newName' Saved")),
                                  );
                                }
                              },
                              child: const Text("Save New", style: TextStyle(color: Colors.white, fontSize: 11)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            height: 25,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.lightGreenAccent[700],
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                              ),
                              onPressed: () async {
                                setState(() {
                                  selectedElement = null;
                                });
                                print("[UI] Saving layout to $currentStorageKey");
                                await saveLayout(currentStorageKey!, editLayoutCopy!);
                                originalLayoutJson = jsonEncode(editLayoutCopy!.toJson());
                                loadLayout(currentStorageKey!);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text("Layout '${editLayoutCopy!.layoutName}' Saved")),
                                );
                              },
                              child: const Text("Save", style: TextStyle(color: Colors.white, fontSize: 11)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const VerticalDivider(color: Color(0xFF505050), thickness: 1, width: 20),
                Expanded(
                  flex: 4,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("SAVED LAYOUTS", style: TextStyle(color: Colors.white38, fontSize: 9, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            children: _buildLayoutList(), // Helper to list saved layouts
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Helper method to keep your buttons consistent
  Widget _buildMenuButton(Widget iconWidget, String label, VoidCallback onTap) {
    return Material(
      color: Colors.transparent, // Required for InkWell to show effects
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        splashColor: Colors.white.withOpacity(0.1),
        highlightColor: Colors.black.withOpacity(0.2),
        child: Ink(
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
              Expanded( // Expanded ensures the text doesn't overflow
                child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 16)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildLayoutList() {
    final allKeys = prefs.getKeys().toList();
    allKeys.sort((a, b) {
      if (a == "Default_Layout") return -1; // 'a' comes first
      if (b == "Default_Layout") return 1;  // 'b' comes first
      return 0; // maintain relative order for everything else
    });
    return allKeys.map((key) {
      try {
        final jsonString = prefs.getString(key);
        if (jsonString == null) return const SizedBox();

        // Convert the JSON string back into your ControllerLayout object
        final layout = ControllerLayout.fromJson(jsonDecode(jsonString));
        bool isSelected = currentStorageKey == key;
        return Padding(
          padding: const EdgeInsets.only(bottom: 4.0),
          child: InkWell(
            onTap: () async {
              bool proceed = await _handleUnsavedChanges(); // Wait for user choice
              if (!proceed) return;
              setState(() {
                selectedElement = null; // Clear any selected element when switching layouts
                currentStorageKey = key; // Update the reference
              });
              loadLayout(key); 
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              decoration: BoxDecoration(
                color: isSelected 
                    ? Colors.blueAccent.withOpacity(0.2) // Highlight current
                    : Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: isSelected 
                      ? Colors.blueAccent 
                      : Colors.transparent,
                  width: 0.5
                ),
              ),
              child: Text(
                layout.layoutName,
                style: const TextStyle(color: Colors.white, fontSize: 10),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        );
      } catch (e) {
        // If a key isn't a valid JSON layout, skip it
        return const SizedBox();
      }
    }).toList();
  }

  Future<String?> showSaveDialog() async {
    String? errorText;
    final TextEditingController nameController = TextEditingController();

    return showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1A1A1A),
            title: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Save New Layout", style: TextStyle(color: Colors.white, fontSize: 16), textAlign: TextAlign.center),
                if (errorText != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      errorText!,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
              ],
            ),
            content: TextField(
              controller: nameController,
              autofocus: true,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: "Layout Name",
                floatingLabelBehavior: FloatingLabelBehavior.always,
                labelStyle: TextStyle(color: Colors.blueAccent, fontSize: 17),
                floatingLabelStyle: TextStyle(color: Colors.blueAccent, fontSize: 17),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.blueAccent)),
                hintText: "Enter name...",
                hintStyle: TextStyle(color: Colors.white24, fontSize: 14),
              ),
              onChanged: (_) {
                // Clear error when user starts typing again
                if (errorText != null) {
                  setDialogState(() => errorText = null);
                }
              },
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("Cancel", style: TextStyle(color: Colors.white54)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
                onPressed: () => {
                  if (nameController.text.isEmpty) {
                    setDialogState(() => errorText = "Name cannot be empty")
                  } else if (prefs.containsKey(nameController.text)) {
                    setDialogState(() => errorText = "This name already exists. Please use a different name")
                  } else {
                    Navigator.pop(context, nameController.text)
                  }
                },
                child: const Text("Save", style: TextStyle(color: Colors.white)),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<bool> confirmDialog() async {
    return await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text(
          "Delete Confirmation", 
          style: TextStyle(color: Colors.white, fontSize: 16),
          textAlign: TextAlign.center
        ),
        content: Text(
          "Are you sure you want to delete '${editLayoutCopy?.layoutName}'?",
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel", style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Delete", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    ) ?? false; // Return false if user taps outside the dialog
  }

  bool _hasUnsavedChanges() {
    if (editLayoutCopy == null || originalLayoutJson == null) return false;
    
    // Encode the CURRENT state to JSON
    String currentJson = jsonEncode(editLayoutCopy!.toJson());
    
    // If they are different, the user moved something or changed a size
    return currentJson != originalLayoutJson;
  }

  Future<bool> _handleUnsavedChanges() async {
    if (!_hasUnsavedChanges()) return true;

    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: Stack(
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 10, right: 30), // Space for the icon
              child: const Text(
                "Unsaved Changes",
                style: TextStyle(color: Colors.white, fontSize: 16)
              ),
            ),
            Positioned(
              right: -10, // Adjust to fit your padding
              top: -10,
              child: IconButton(
                icon: const Icon(Icons.close, size: 20, color: Colors.white54),
                onPressed: () => Navigator.pop(context, null), // null = Same as clicking outside
              ),
            ),
          ],
        ),
        content: const Text(
          "You have made changes to the layout. Do you want to save them?",
          style: TextStyle(color: Colors.white70, fontSize: 14)
          ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, true), // Discard and exit
            child: const Text("Discard", style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blueAccent),
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Save", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (discard == null) return false;
    if (discard == false) {
      await saveLayout(currentStorageKey!, editLayoutCopy!);
      originalLayoutJson = jsonEncode(editLayoutCopy!.toJson());
      setState(() {
        currentLayout = editLayoutCopy;
      });
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final List<ControllerElement> elementsToRender = isEditing 
      ? (editLayoutCopy?.elements ?? []) 
        : (currentLayout?.elements ?? []);
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
                  Positioned.fill(
                    child: Opacity(
                      opacity: 0.8, // Optional: dim it slightly so buttons pop
                      child: _processedBackground ?? backgroundColor ?? Container(color: Colors.black87),
                    ),
                  ),
                  ...elementsToRender.map((element) {
                    // Check if this specific element is the one currently selected in the editor
                    bool isSelected = selectedElement?.id == element.id;
                    if (element.type == ControllerElementType.button) {
                      return CustomButton(
                        element: element,
                        isEditing: isEditing,
                        isSelected: isSelected,
                        onSelect: () => setState(() => selectedElement = element),
                        onPressed: (id, pressed) {
                          // send button press/release to PC
                          if (!isEditing) {
                            final bit = element.buttonId;
                            bleManager.updateButton(bit, pressed);
                          }
                        },
                        onPositionChanged: (newOffset) => setState(() => element.position = newOffset),
                      );
                    } else {
                      return CustomJoystick(
                        element: element,
                        deadzone: 0.20,
                        isEditing: isEditing,
                        isSelected: isSelected,
                        onSelect: () => setState(() => selectedElement = element),
                        onChange: (id, x, y) {
                          if (!isEditing) {
                            final type = element.joystickType ?? "left";
                            bleManager.updateJoystick(type, x, y);
                          }
                        },
                        onPositionChanged: (newOffset) => setState(() => element.position = newOffset),
                      );
                    }
                  }),
                  // Top-center button
                  if (isEditing) ...[
                    Positioned(
                      // Calculate pixels from normalized Offset
                      left: (editorPosition.dx * screenWidth) - (screenWidth * 0.45 / 2), 
                      top: editorPosition.dy * screenHeight,
                      child: _buildEditorToolbar(),
                    ),
                  ] else ...[
                    Positioned(
                      top: 5, // Adjust this value to move it higher or lower
                      left: 16,
                      right: 16,
                      child: _buildStandardToolbar(),
                    ),
                    // Connection status banner
                    Positioned(
                      bottom: 10, // Adjust as needed
                      left: 16,
                      right: 16,
                      child: Center(
                        child: ConnectionStatusBanner(
                          status: _status,
                          isError: _status.contains('Disconnected'),
                          show: showStatusBanner,
                        ),
                      ),
                    ),
                  ],
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