import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'bluetooth_connection.dart';
import 'simulated_gpx_generator.dart';
import 'exercise_start_map_picker.dart';
import 'package:latlong2/latlong.dart';
import 'models/controller_element.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';
import 'game_step_counter.dart';
import 'controller_tutorial.dart';
import 'controller_user_settings.dart';

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
  final GameStepCounter gameStepCounter = GameStepCounter();
  late SharedPreferences prefs;
  String _status = 'Connecting...';
  bool showStatusBanner = true;
  bool isLoading = true;
  bool isSettingsOpen = false;
  bool paused = false;
  Timer? bannerTimer;
  Offset editorPosition = const Offset(0.5, 0.05);

  double neutralRoll = 1.55;
  double maxDeviation = 1.1;
  double filteredSteering = 0.0;
  double smoothedZ = 0.0;
  double steeringValue = 0.0; // -1.0 (left) to +1.0 (right)

  StreamSubscription<AccelerometerEvent>? accelSubscription;
  final List<double> _walkingAccelRollWindow = [];
  static const int _walkingAccelRollWindowSize = 9;
  final List<double> _recentSteppingSteering = [];
  static const int _recentSteppingSteeringSize = 7;
  static const double _steppingSteeringMax = 0.75;
  double _lastConfirmedSteppingSteering = 0.0;
  bool _wasWalking = false;
  double accelZ = 0.0;  // Current Z-axis accel
  double stepThreshold = 1.5;  // Tune this: higher = needs stronger shake/step
  double lastAccelZ = 0.0;
  double stepValue = 0.0;
  Timer? stepTimer;  // Debounce steps
  bool isWalking = false;  // True if forward motion detected
  bool steeringEnabled = false; // New: toggle for steering control
  bool steppingEnabled = false; // New: true if stepping is enabled

  String messageBuffer = ""; // Buffer for large transmissions
  bool isReceivingLayout = false;
  double downloadProgress = 0.0;
  DateTime? lastLayoutChunkTime;
  Timer? layoutWatchdog;

  static const String _kExerciseMapPickLat = 'exercise_map_pick_lat';
  static const String _kExerciseMapPickLon = 'exercise_map_pick_lon';
  static const String _kDefaultLayoutStandardToolbar = 'default_layout_uses_standard_toolbar';

  static String defaultKey = "Default_Layout";
  static String superTaxKartKey = "SuperTaxKart_v1";
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
  double lastSentStepValue = 0.0;
  double resizeGridSize = 8;
  final TextEditingController _resizeGridSizeController = TextEditingController(text: '8');

  final GlobalKey _standardToolbarKey = GlobalKey();
  final GlobalKey _tutorialLayoutToolbarKey = GlobalKey();
  final GlobalKey _tutorialScreenshotKey = GlobalKey();
  final GlobalKey _tutorialPauseKey = GlobalKey();
  final GlobalKey _tutorialSettingsKey = GlobalKey();
  final GlobalKey _tutorialCustomizeLayoutKey = GlobalKey();
  final GlobalKey _tutorialElementMappingKey = GlobalKey();
  final GlobalKey _tutorialTiltSteeringKey = GlobalKey();
  final GlobalKey _tutorialStepDetectionKey = GlobalKey();
  final GlobalKey _tutorialExerciseGpxKey = GlobalKey();
  final GlobalKey _tutorialEditorToolbarKey = GlobalKey();
  final GlobalKey _tutorialEditorToolbarLeftKey = GlobalKey();
  final GlobalKey _tutorialEditorToolbarRightKey = GlobalKey();
  final GlobalKey _tutorialElementMappingButtonsKey = GlobalKey();
  final GlobalKey _tutorialElementMappingTiltKey = GlobalKey();
  final GlobalKey _tutorialElementMappingStepKey = GlobalKey();
  final GlobalKey _tutorialElementMappingDialogKey = GlobalKey();
  final GlobalKey _tutorialExerciseMapDialogKey = GlobalKey();
  bool _tutorialScheduled = false;

  bool _gpxExerciseRecording = false;
  bool _gpxSetupInProgress = false;
  bool _gpxTutorialStopDisplay = false;
  StateSetter? _settingsDialogSetState;
  StreamSubscription<StepCount>? _gpxPedometerSub;
  int? _gpxStepBaseline;
  int? _gpxLastPedometerSteps;
  double? _gpxSessionStartLat;
  double? _gpxSessionStartLon;
  DateTime? _gpxRecordingStartedAtUtc;

  final Map<String, int> buttonBitmasks = {
    "UP": 1 << 0,
    "DOWN": 1 << 1,
    "LEFT": 1 << 2,
    "RIGHT": 1 << 3,
    "START": 1 << 4,
    "BACK": 1 << 5,
    "LS": 1 << 6,
    "RS": 1 << 7,
    "LB": 1 << 8,
    "RB": 1 << 9,
    "LT": 1 << 10,
    "RT": 1 << 11,
    "A": 1 << 12,
    "B": 1 << 13,
    "X": 1 << 14,
    "Y": 1 << 15,
    "PAUSE/RESUME": ControllerButtonIds.pauseResume,
    "SCREENSHOT": ControllerButtonIds.screenshot,
    "SETTINGS": ControllerButtonIds.settings,
  };

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
    _stopMotionSensorListening();
    _gpxPedometerSub?.cancel();
    stepTimer?.cancel();
    _resizeGridSizeController.dispose();
    bleManager.stopInputSending();
    unawaited(gameStepCounter.dispose());
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
          _setPaused(false);
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
    gameStepCounter.reset();
    await initPrefs();
    defaultLayout = await getDefaultLayout();
    currentStorageKey = defaultKey;
    if (!prefs.containsKey(defaultKey)) {
      print("[Init] Default layout not found. Creating it now...");
      await saveLayout(defaultKey, defaultLayout!);
      setState(() {
        currentLayout = defaultLayout;
      });
    } else {
      await loadLayout(defaultKey);
    }
    await _migrateDefaultLayoutToStandardToolbar();

    final superTaxKartLayout = await getSuperTaxKartLayout();
    if (!prefs.containsKey(superTaxKartKey)) {
      print("[Init] SuperTaxKart layout not found. Creating it now...");
      await saveLayout(superTaxKartKey, superTaxKartLayout);
    }
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
        _stopMotionSensorListening();
        stepTimer?.cancel();
        setState(() {
          steeringValue = 0.0;
          isWalking = false;
          _processedBackground = null;
          backgroundColor = null;
        });
        unawaited(_restoreLayoutAfterDisconnect());
      }

      gameStepCounter.setBleConnected(status == BleConnectionStatus.connected);

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
          message = message.replaceFirst("LAYOUT:", "");
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
          print("[UI] ENABLE_STEP → game step counter + accelerometer stepping");
          _setSteppingEnabled(true);
          return;
        }

        if (message == "DISABLE_STEP") {
          print("[UI] DISABLE_STEP");
          _setSteppingEnabled(false);
          return;
        }

        if (message.startsWith("GET_STEP_COUNT:")) {
          final reqId = message.substring("GET_STEP_COUNT:".length);
          print("[UI] GET_STEP_COUNT reqId=$reqId → count=${gameStepCounter.count}");
          print("[UI] ${gameStepCounter.debugState()}");
          if (reqId.isNotEmpty) {
            await bleManager.sendMessage("STEP_COUNT:$reqId:${gameStepCounter.count}");
          }
          return;
        }

        if (message == "RESET_STEP_COUNT") {
          print("[UI] RESET_STEP_COUNT");
          gameStepCounter.reset();
          return;
        }

        if (message == "STEP_COUNT_ARM") {
          print("[UI] STEP_COUNT_ARM");
          gameStepCounter.setGameWsActive(true);
          return;
        }

        if (message == "STEP_COUNT_DISARM") {
          print("[UI] STEP_COUNT_DISARM");
          gameStepCounter.setGameWsActive(false);
          return;
        }
      } catch (e) {
        print("[UI] Error decoding incoming BLE data: $e");
      }
    });
    // Start Bluetooth connection, then auto-tutorial once permissions/UI settle.
    await bleManager.startScanningAndConnect();
    _scheduleTutorialIfNeeded();
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

  void _setPaused(bool value) {
    if (paused == value) return;
    setState(() => paused = value);
    gameStepCounter.setPaused(value);
  }

  void _setSteppingEnabled(bool value) {
    if (steppingEnabled == value) return;
    setState(() => steppingEnabled = value);
    print("[UI] steppingEnabled:$value");
    gameStepCounter.setStepDetectionEnabled(value);
  }

  Future<void> _handleLayoutButtonPress(ControllerElement element, bool pressed) async {
    final bit = element.buttonId;
    final layout = currentLayout;
    if (layout == null) return;

    if (bit == ControllerButtonIds.pauseResume) {
      if (!pressed) return;
      final nextPaused = !paused;
      _setPaused(nextPaused);
      final sent = await bleManager.sendMessage(
        nextPaused ? "PAUSE" : "RESUME",
        tiltTarget: layout.tiltTarget,
        stepTarget: layout.stepTarget,
        stepBitmask: layout.stepButtonBitmask,
      );
      if (!sent) _setPaused(!nextPaused);
      return;
    }

    if (bit == ControllerButtonIds.screenshot) {
      if (!pressed) return;
      await bleManager.sendMessage("SCREENSHOT");
      return;
    }

    if (bit == ControllerButtonIds.settings) {
      if (!pressed) return;
      _openSettingsDialog();
      return;
    }

    bleManager.updateButton(bit, pressed);
  }

  void _handleInterruption() {
    if (_gpxSetupInProgress) return;
    // Logic to prevent the car/character from driving off forever
    if (!paused) {
      _setPaused(true);
      bleManager.sendMessage("PAUSE", 
        tiltTarget: currentLayout!.tiltTarget,
        stepTarget: currentLayout!.stepTarget,
        stepBitmask: currentLayout!.stepButtonBitmask
      );
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

  void _stopMotionSensorListening() {
    accelSubscription?.cancel();
    accelSubscription = null;
    _walkingAccelRollWindow.clear();
    _recentSteppingSteering.clear();
    _lastConfirmedSteppingSteering = 0.0;
    _wasWalking = false;
  }

  // Call this once when you need both features
  void startAccelerometerListening() {
    _stopMotionSensorListening();

    accelSubscription = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval)
      .listen((AccelerometerEvent event) {
        if (paused || isSettingsOpen) return;

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

        final activeStepValue = steppingEnabled && isWalking ? -1.0 : 0.0;

        // ── STEERING (landscape left/right tilt) ───────────────────────────────
        final accelRoll = math.atan2(event.z, event.y);
        final roll = _estimateRoll(accelRoll, isWalking);
        double deviation = neutralRoll - roll;
        double rawSteering = deviation / maxDeviation;
        rawSteering = rawSteering.clamp(-1.0, 1.0);

        if (isWalking != _wasWalking) {
          filteredSteering = rawSteering;
          _wasWalking = isWalking;
        } else if (isWalking) {
          // No EMA while stepping — avoids latching a single bad frame.
          filteredSteering = rawSteering;
        } else {
          const double smoothing = 0.2;
          filteredSteering = filteredSteering * (1 - smoothing) + rawSteering * smoothing;
        }

        double steering = filteredSteering;
        final normalTiltDeadzone =
            currentLayout?.effectiveTiltDeadzone ?? ControllerLayout.defaultTiltDeadzone;
        final steppingTiltDeadzone = currentLayout?.effectiveTiltDeadzoneWhileStepping ??
            ControllerLayout.defaultTiltDeadzoneWhileStepping;
        final appliedTiltDeadzone =
            activeStepValue != 0.0 ? steppingTiltDeadzone : normalTiltDeadzone;
        steering = _applyTiltDeadzoneAndRescale(steering, appliedTiltDeadzone);
        if (activeStepValue != 0.0) {
          steering = steering.clamp(-_steppingSteeringMax, _steppingSteeringMax);
          steering = _sanitizeSteppingSteering(steering);
        } else {
          _recentSteppingSteering.clear();
          _lastConfirmedSteppingSteering = 0.0;
        }
        // print("steering: ${steering.toStringAsFixed(3)}");

        if (steppingEnabled) {
          stepValue = activeStepValue;

          // We check if the state actually changed to prevent spamming BLE
          if (stepValue != lastSentStepValue) {
            lastSentStepValue = stepValue;

            bleManager.updateStep(
              stepValue,
              jid: currentLayout!.stepTarget,
              bitmask: currentLayout!.stepButtonBitmask,
            );
          }
        }

        if (steeringEnabled) {
          if ((steering - steeringValue).abs() > 0.01) {
            steeringValue = steering;
            bleManager.updateSteering(steeringValue, currentLayout!.tiltTarget);
          }
        }
    });
  }

  /// While stepping: majority-sign median accel (no gyro — shake corrupts integration).
  /// While still: raw accelerometer roll.
  double _estimateRoll(double accelRoll, bool walking) {
    if (!walking) {
      _walkingAccelRollWindow.clear();
      return accelRoll;
    }

    _walkingAccelRollWindow.add(accelRoll);
    if (_walkingAccelRollWindow.length > _walkingAccelRollWindowSize) {
      _walkingAccelRollWindow.removeAt(0);
    }
    return _majoritySignMedianRoll(_walkingAccelRollWindow);
  }

  double _majoritySignMedianRoll(List<double> rolls) {
    if (rolls.isEmpty) return 0.0;
    if (rolls.length < 3) return _medianRoll(rolls);

    var negCount = 0;
    var posCount = 0;
    for (final roll in rolls) {
      final steer = neutralRoll - roll;
      if (steer < -0.02) {
        negCount++;
      } else if (steer > 0.02) {
        posCount++;
      }
    }

    if (negCount > posCount) {
      final negRolls =
          rolls.where((roll) => neutralRoll - roll < 0).toList(growable: false);
      if (negRolls.isNotEmpty) return _medianRoll(negRolls);
    } else if (posCount > negCount) {
      final posRolls =
          rolls.where((roll) => neutralRoll - roll > 0).toList(growable: false);
      if (posRolls.isNotEmpty) return _medianRoll(posRolls);
    }

    return _medianRoll(rolls);
  }

  /// Rejects opposite-sign spikes (e.g. +1.0 while tilting left) before BLE send.
  double _sanitizeSteppingSteering(double steering) {
    const signThreshold = 0.08;

    if (_recentSteppingSteering.length >= 3) {
      var negCount = 0;
      var posCount = 0;
      for (final sample in _recentSteppingSteering) {
        if (sample < -signThreshold) {
          negCount++;
        } else if (sample > signThreshold) {
          posCount++;
        }
      }

      final oppositeSpike = (negCount > posCount && steering > signThreshold) ||
          (posCount > negCount && steering < -signThreshold);
      final extremeOpposite = steering.abs() >= 0.85 &&
          ((negCount > posCount && steering > 0) ||
              (posCount > negCount && steering < 0));

      if (oppositeSpike || extremeOpposite) {
        steering = _lastConfirmedSteppingSteering;
      }
    }

    _recentSteppingSteering.add(steering);
    if (_recentSteppingSteering.length > _recentSteppingSteeringSize) {
      _recentSteppingSteering.removeAt(0);
    }

    if (steering.abs() > signThreshold) {
      _lastConfirmedSteppingSteering = steering;
    }

    return steering;
  }

  double _medianRoll(List<double> rolls) {
    if (rolls.isEmpty) return 0.0;
    final sorted = List<double>.from(rolls)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  double _applyTiltDeadzoneAndRescale(double value, double deadzone) {
    final dz = deadzone.clamp(0.0, 0.99);
    final absValue = value.abs();
    if (absValue <= dz) return 0.0;

    final normalized = (absValue - dz) / (1.0 - dz);
    return (value.isNegative ? -normalized : normalized).clamp(-1.0, 1.0);
  }

  Future<void> _onExerciseGpxMenuPressed() async {
    if (_gpxExerciseRecording) {
      await _stopExerciseGpxRecording();
    } else {
      await _startExerciseGpxRecording();
    }
  }

  Future<bool> _ensureExerciseGpxPermissions() async {
    if (Platform.isAndroid) {
      final ar = await Permission.activityRecognition.request();
      return ar.isGranted;
    }
    if (Platform.isIOS) {
      final s = await Permission.sensors.request();
      return s.isGranted;
    }
    return true;
  }

  void _closeSettingsDialogIfOpen() {
    if (!isSettingsOpen) return;
    final nav = Navigator.of(context, rootNavigator: true);
    if (nav.canPop()) nav.pop();
  }

  Future<void> _startExerciseGpxRecording({bool forTutorialStep = false}) async {
    if (!mounted) return;

    if (!forTutorialStep &&
        (bleManager.pcDevice == null || !bleManager.pcDevice!.isConnected)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Not connected to the PC server. Please connect to the PC server, then start exercise GPX again.'),
        ),
      );
      return;
    }

    if (!forTutorialStep) _gpxSetupInProgress = true;
    try {
      if (!forTutorialStep) {
        if (!await _ensureExerciseGpxPermissions()) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Physical activity permission is required for step counting.')),
          );
          return;
        }
      }

      final lastLat = prefs.getDouble(_kExerciseMapPickLat);
      final lastLon = prefs.getDouble(_kExerciseMapPickLon);
      late final LatLng initialCenter;
      if (lastLat != null && lastLon != null) {
        initialCenter = LatLng(lastLat, lastLon);
      } else if (forTutorialStep) {
        initialCenter = LatLng(
          SimulatedGpxGenerator.fallbackLat,
          SimulatedGpxGenerator.fallbackLon,
        );
      } else {
        final def = await SimulatedGpxGenerator.resolveDefaultStartPosition();
        initialCenter = LatLng(def.lat, def.lon);
      }

      if (!mounted) return;

      if (!forTutorialStep) {
        _closeSettingsDialogIfOpen();
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
      }

      final picked = await showExerciseStartMapPicker(
        context,
        initialCenter: initialCenter,
        forTutorialStep: forTutorialStep,
        dialogKey: forTutorialStep ? _tutorialExerciseMapDialogKey : null,
        onShown: forTutorialStep
            ? () {
                if (mounted) _showExerciseMapTutorialHighlight(attempt: 0);
              }
            : null,
      );
      if (picked == null || !mounted) return;

      if (forTutorialStep) return;

      await prefs.setDouble(_kExerciseMapPickLat, picked.latitude);
      await prefs.setDouble(_kExerciseMapPickLon, picked.longitude);

      late StepCount firstStep;
      try {
        firstStep = await Pedometer.stepCountStream.first.timeout(const Duration(seconds: 12));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Step counter unavailable: $e')),
        );
        return;
      }

      if (!mounted) return;

      await _gpxPedometerSub?.cancel();
      _gpxStepBaseline = firstStep.steps;
      _gpxLastPedometerSteps = firstStep.steps;
      _gpxSessionStartLat = picked.latitude;
      _gpxSessionStartLon = picked.longitude;
      _gpxRecordingStartedAtUtc = DateTime.now().toUtc();
      _gpxExerciseRecording = true;
      _gpxPedometerSub = Pedometer.stepCountStream.listen((StepCount e) {
        if (!_gpxExerciseRecording) return;
        _gpxLastPedometerSteps = e.steps;
      });

      setState(() {});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Exercise GPX recording started. Open settings and tap the same item when finished.'),
          duration: Duration(seconds: 4),
        ),
      );
    } finally {
      if (!forTutorialStep) _gpxSetupInProgress = false;
    }
  }

  Future<void> _stopExerciseGpxRecording() async {
    _closeSettingsDialogIfOpen();
    if (!mounted) return;

    await _gpxPedometerSub?.cancel();
    _gpxPedometerSub = null;

    final baseline = _gpxStepBaseline;
    final startLat = _gpxSessionStartLat ?? SimulatedGpxGenerator.fallbackLat;
    final startLon = _gpxSessionStartLon ?? SimulatedGpxGenerator.fallbackLon;
    final recordingEndUtc = DateTime.now().toUtc();
    final recordingStartUtc = _gpxRecordingStartedAtUtc ?? recordingEndUtc;
    int steps = 0;
    if (baseline != null && _gpxLastPedometerSteps != null) {
      steps = (_gpxLastPedometerSteps! - baseline).clamp(0, 0x7fffffff);
    }

    _gpxExerciseRecording = false;
    _gpxStepBaseline = null;
    _gpxLastPedometerSteps = null;
    _gpxSessionStartLat = null;
    _gpxSessionStartLon = null;
    _gpxRecordingStartedAtUtc = null;
    setState(() {});

    if (!mounted) return;

    try {
      final xml = SimulatedGpxGenerator.buildXml(
        recordingStartUtc: recordingStartUtc,
        recordingEndUtc: recordingEndUtc,
        hardwareStepCount: steps,
        startLat: startLat,
        startLon: startLon,
      );
      var pcOk = false;
      if (bleManager.pcDevice != null && bleManager.pcDevice!.isConnected) {
        pcOk = await bleManager.sendGpxExportToPc(xml);
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            pcOk
                ? 'Exercise GPX sent to PC.'
                : 'Could not send GPX to PC (connection lost or send failed).',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Exercise GPX failed: $e')),
      );
    }
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
      String payload = fullJson.trim();
      if (payload.startsWith("LAYOUT:")) {
        payload = payload.replaceFirst("LAYOUT:", "");
      }
      final Map<String, dynamic> decoded = jsonDecode(payload);
      String gameId = decoded['gameId'];
      int version = decoded['version'];
      
      String storageKey = "${gameId}_v$version";
      final layout = ControllerLayout.fromJson(decoded);
      print('Saving layout...');
      // Save to SharedPreferences
      await saveLayout(storageKey, layout);
      await loadLayout(storageKey);
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

  void _scheduleTutorialIfNeeded() {
    if (_tutorialScheduled || isEditing) return;
    _tutorialScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || isEditing) return;
      if (!await ControllerUserSettings.tryConsumeTutorialForCurrentVersion()) return;
      if (!mounted || isEditing) return;
      // BLE permission / system UI dialogs can change screen metrics after first layout.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (!mounted || isEditing) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || isEditing) return;
      _startControllerTutorial(attempt: 0);
    });
  }

  GlobalKey? _tutorialKeyForElement(String id) {
    switch (id) {
      case 'toolbar_screenshot':
        return _tutorialScreenshotKey;
      case 'toolbar_pause':
        return _tutorialPauseKey;
      case 'toolbar_settings':
        return _tutorialSettingsKey;
      default:
        return null;
    }
  }

  void _startTutorialManually() {
    Navigator.of(context, rootNavigator: true).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !isEditing) _startControllerTutorial(attempt: 0);
    });
  }

  void _startControllerTutorial({required int attempt}) {
    if (!mounted || isEditing) return;

    final elements = currentLayout?.elements ?? [];
    final usesLayoutToolbar = _layoutHasToolbarElements(elements);
    final toolbarKey =
        usesLayoutToolbar ? _tutorialLayoutToolbarKey : _standardToolbarKey;

    if (toolbarKey.currentContext == null) {
      if (attempt < 8) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _startControllerTutorial(attempt: attempt + 1);
        });
      }
      return;
    }

    ControllerTutorial.showToolbarIntro(
      context,
      keyTarget: toolbarKey,
      onFinish: () {
        if (mounted) _openSettingsDialog(forTutorialStep: true);
      },
    );
  }

  Widget _buildLayoutToolbarTutorialAnchor(
    List<ControllerElement> elements,
    double screenWidth,
    double screenHeight,
  ) {
    final toolbarEls =
        elements.where((e) => _isToolbarElementId(e.id)).toList();
    if (toolbarEls.isEmpty) return const SizedBox.shrink();

    double left = double.infinity;
    double top = double.infinity;
    double right = 0;
    double bottom = 0;
    for (final e in toolbarEls) {
      final layout = e.buttonLayoutSize;
      const hostPadding = LayoutEditorResize.hostPadding;
      final w = layout.width + hostPadding * 2;
      final h = layout.height + hostPadding * 2;
      final cx = e.position.dx * screenWidth;
      final cy = e.position.dy * screenHeight;
      left = math.min(left, cx - w / 2);
      top = math.min(top, cy - h / 2);
      right = math.max(right, cx + w / 2);
      bottom = math.max(bottom, cy + h / 2);
    }

    return Positioned(
      left: left,
      top: top,
      width: right - left,
      height: bottom - top,
      child: IgnorePointer(
        child: SizedBox(key: _tutorialLayoutToolbarKey),
      ),
    );
  }

  void _showCustomizeLayoutTutorialStep({required int attempt}) {
    if (!mounted || isEditing) return;

    final bounds = ControllerTutorial.boundsFromKeys([_tutorialCustomizeLayoutKey]);
    if (bounds == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showCustomizeLayoutTutorialStep(attempt: attempt + 1);
        });
      }
      return;
    }

    ControllerTutorial.showCustomizeLayoutIntro(
      context,
      highlightBounds: bounds,
      onFinish: () {
        if (mounted) _showElementMappingTutorialStep(attempt: 0);
      },
    );
  }

  void _showElementMappingTutorialStep({required int attempt}) {
    if (!mounted || isEditing) return;

    final bounds = ControllerTutorial.boundsFromKeys([_tutorialElementMappingKey]);
    if (bounds == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showElementMappingTutorialStep(attempt: attempt + 1);
        });
      }
      return;
    }

    ControllerTutorial.showElementMappingIntro(
      context,
      highlightBounds: bounds,
      onFinish: () {
        if (mounted) _showMotionControlsTutorialStep(attempt: 0);
      },
    );
  }

  void _showMotionControlsTutorialStep({required int attempt}) {
    if (!mounted || isEditing) return;

    final bounds = ControllerTutorial.boundsFromKeys([
      _tutorialTiltSteeringKey,
      _tutorialStepDetectionKey,
    ]);
    if (bounds == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showMotionControlsTutorialStep(attempt: attempt + 1);
        });
      }
      return;
    }

    ControllerTutorial.showMotionControlsIntro(
      context,
      highlightBounds: bounds,
      onFinish: () {
        if (mounted) _showExerciseGpxTutorialStep(attempt: 0);
      },
    );
  }

  Future<void> _showExerciseGpxTutorialStep({required int attempt}) async {
    if (!mounted || isEditing) return;

    final widgetContext = _tutorialExerciseGpxKey.currentContext;
    if (widgetContext == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showExerciseGpxTutorialStep(attempt: attempt + 1);
        });
      }
      return;
    }

    await Scrollable.ensureVisible(
      widgetContext,
      alignment: 1.0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );

    if (!mounted || isEditing) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showExerciseGpxStartTutorialHighlight(attempt: 0);
    });
  }

  void _showExerciseGpxStartTutorialHighlight({required int attempt}) {
    if (!mounted || isEditing) return;

    final bounds = ControllerTutorial.boundsFromKeys([_tutorialExerciseGpxKey]);
    if (bounds == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showExerciseGpxStartTutorialHighlight(attempt: attempt + 1);
        });
      }
      return;
    }

    ControllerTutorial.showExerciseGpxIntro(
      context,
      highlightBounds: bounds,
      onFinish: () {
        if (mounted) _showEditorToolbarTutorialStep();
      },
    );
  }

  Future<void> _showExerciseGpxStopTutorialStep({required int attempt}) async {
    if (!mounted) return;

    final widgetContext = _tutorialExerciseGpxKey.currentContext;
    if (widgetContext == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showExerciseGpxStopTutorialStep(attempt: attempt + 1);
        });
      }
      return;
    }

    await Scrollable.ensureVisible(
      widgetContext,
      alignment: 1.0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );

    if (!mounted) return;

    _setGpxTutorialStopDisplay(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showExerciseGpxStopTutorialHighlight(attempt: 0);
    });
  }

  void _showExerciseGpxStopTutorialHighlight({required int attempt}) {
    if (!mounted) return;

    final bounds = ControllerTutorial.boundsFromKeys([_tutorialExerciseGpxKey]);
    if (bounds == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showExerciseGpxStopTutorialHighlight(attempt: attempt + 1);
        });
      }
      return;
    }

    ControllerTutorial.showExerciseGpxStopIntro(
      context,
      highlightBounds: bounds,
      onFinish: () {
        _setGpxTutorialStopDisplay(false);
        if (!mounted) return;
        if (isSettingsOpen && Navigator.of(context, rootNavigator: true).canPop()) {
          Navigator.of(context, rootNavigator: true).pop();
          setState(() => isSettingsOpen = false);
        }
      },
    );
  }

  Future<void> _showEditorToolbarTutorialStep() async {
    if (!mounted) return;

    if (isSettingsOpen && Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
      if (mounted) setState(() => isSettingsOpen = false);
    }

    if (!isEditing) {
      toggleEditMode();
    }

    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showEditorToolbarTutorialHighlight(attempt: 0);
    });
  }

  void _showEditorToolbarTutorialHighlight({required int attempt}) {
    if (!mounted || !isEditing) return;

    final bounds = ControllerTutorial.boundsFromKeys([_tutorialEditorToolbarKey]);
    if (bounds == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showEditorToolbarTutorialHighlight(attempt: attempt + 1);
        });
      }
      return;
    }

    ControllerTutorial.showEditorToolbarIntro(
      context,
      highlightBounds: bounds,
      onFinish: () {
        if (mounted) _showEditorToolbarLeftTutorialHighlight(attempt: 0);
      },
    );
  }

  void _showEditorToolbarLeftTutorialHighlight({required int attempt}) {
    if (!mounted || !isEditing) return;

    final bounds = ControllerTutorial.boundsFromKeys([_tutorialEditorToolbarLeftKey]);
    if (bounds == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showEditorToolbarLeftTutorialHighlight(attempt: attempt + 1);
        });
      }
      return;
    }

    ControllerTutorial.showEditorToolbarLeftIntro(
      context,
      highlightBounds: bounds,
      onFinish: () {
        if (mounted) _showEditorToolbarRightTutorialHighlight(attempt: 0);
      },
    );
  }

  void _showEditorToolbarRightTutorialHighlight({required int attempt}) {
    if (!mounted || !isEditing) return;

    final bounds = ControllerTutorial.boundsFromKeys([_tutorialEditorToolbarRightKey]);
    if (bounds == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showEditorToolbarRightTutorialHighlight(attempt: attempt + 1);
        });
      }
      return;
    }

    ControllerTutorial.showEditorToolbarRightIntro(
      context,
      highlightBounds: bounds,
      onFinish: () {
        if (!mounted) return;
        _exitEditModeForTutorial();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _showElementMappingButtonsTutorialStep();
        });
      },
    );
  }

  void _exitEditModeForTutorial() {
    if (!isEditing) return;
    setState(() {
      editLayoutCopy = null;
      originalLayoutJson = null;
      isEditing = false;
      selectedElement = null;
    });
    bleManager.setInputPause(false);
  }

  Future<void> _showElementMappingButtonsTutorialStep() async {
    if (!mounted) return;

    mappingSetting(forTutorialStep: true);
  }

  Future<void> _scrollAndHighlightElementMappingButtons({required int attempt}) async {
    if (!mounted) return;

    final widgetContext = _tutorialElementMappingButtonsKey.currentContext;
    if (widgetContext == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollAndHighlightElementMappingButtons(attempt: attempt + 1);
        });
      }
      return;
    }

    await Scrollable.ensureVisible(
      widgetContext,
      alignment: 0.0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );

    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showElementMappingButtonsTutorialHighlight(attempt: 0);
    });
  }

  void _showElementMappingButtonsTutorialHighlight({required int attempt}) {
    if (!mounted) return;

    final bounds = ControllerTutorial.visibleBoundsFromKey(_tutorialElementMappingButtonsKey);
    if (bounds == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showElementMappingButtonsTutorialHighlight(attempt: attempt + 1);
        });
      }
      return;
    }

    final dialogBounds = ControllerTutorial.boundsFromKeys([_tutorialElementMappingDialogKey]);

    ControllerTutorial.showElementMappingButtonsIntro(
      context,
      highlightBounds: bounds,
      dialogBounds: dialogBounds,
      onFinish: () {
        if (mounted) _scrollAndHighlightElementMappingTilt(attempt: 0);
      },
    );
  }

  Future<void> _scrollAndHighlightElementMappingTilt({required int attempt}) async {
    if (!mounted) return;

    final widgetContext = _tutorialElementMappingTiltKey.currentContext;
    if (widgetContext == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollAndHighlightElementMappingTilt(attempt: attempt + 1);
        });
      }
      return;
    }

    await Scrollable.ensureVisible(
      widgetContext,
      alignment: 0.0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );

    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showElementMappingTiltTutorialHighlight(attempt: 0);
    });
  }

  void _showElementMappingTiltTutorialHighlight({required int attempt}) {
    if (!mounted) return;

    final bounds = ControllerTutorial.visibleBoundsFromKey(_tutorialElementMappingTiltKey);
    if (bounds == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showElementMappingTiltTutorialHighlight(attempt: attempt + 1);
        });
      }
      return;
    }

    final dialogBounds = ControllerTutorial.boundsFromKeys([_tutorialElementMappingDialogKey]);

    ControllerTutorial.showElementMappingTiltIntro(
      context,
      highlightBounds: bounds,
      dialogBounds: dialogBounds,
      onFinish: () {
        if (mounted) _scrollAndHighlightElementMappingStep(attempt: 0);
      },
    );
  }

  Future<void> _scrollAndHighlightElementMappingStep({required int attempt}) async {
    if (!mounted) return;

    final widgetContext = _tutorialElementMappingStepKey.currentContext;
    if (widgetContext == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollAndHighlightElementMappingStep(attempt: attempt + 1);
        });
      }
      return;
    }

    await Scrollable.ensureVisible(
      widgetContext,
      alignment: 0.0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOut,
    );

    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showElementMappingStepTutorialHighlight(attempt: 0);
    });
  }

  void _showElementMappingStepTutorialHighlight({required int attempt}) {
    if (!mounted) return;

    final bounds = ControllerTutorial.visibleBoundsFromKey(_tutorialElementMappingStepKey);
    if (bounds == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showElementMappingStepTutorialHighlight(attempt: attempt + 1);
        });
      }
      return;
    }

    final dialogBounds = ControllerTutorial.boundsFromKeys([_tutorialElementMappingDialogKey]);

    ControllerTutorial.showElementMappingStepIntro(
      context,
      highlightBounds: bounds,
      dialogBounds: dialogBounds,
      onFinish: () {
        if (mounted) _showExerciseMapTutorialStep();
      },
    );
  }

  Future<void> _showExerciseMapTutorialStep() async {
    if (!mounted) return;

    final nav = Navigator.of(context, rootNavigator: true);
    if (nav.canPop()) {
      nav.pop();
    }

    if (!mounted) return;
    await _startExerciseGpxRecording(forTutorialStep: true);
  }

  void _showExerciseMapTutorialHighlight({required int attempt}) {
    if (!mounted) return;

    if (_tutorialExerciseMapDialogKey.currentContext == null) {
      if (attempt < 5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showExerciseMapTutorialHighlight(attempt: attempt + 1);
        });
      }
      return;
    }

    ControllerTutorial.showExerciseMapIntro(
      _tutorialExerciseMapDialogKey.currentContext!,
      dialogKey: _tutorialExerciseMapDialogKey,
      onFinish: () {
        if (!mounted) return;
        final nav = Navigator.of(context, rootNavigator: true);
        if (nav.canPop()) nav.pop();
        if (mounted) _openSettingsDialog(forGpxStopTutorialStep: true);
      },
    );
  }

  Future<void> _restoreLayoutAfterDisconnect() async {
    currentStorageKey = defaultKey;
    await loadLayout(defaultKey);
    ControllerLayout? favoriteLayout;
    String? favoriteKey;
    for (final key in prefs.getKeys()) {
      if (key == _kExerciseMapPickLat || key == _kExerciseMapPickLon) continue;
      final raw = prefs.get(key);
      if (raw is! String) continue;
      try {
        final data = jsonDecode(raw) as Map<String, dynamic>;
        if (data['gameId'] == defaultLayout!.gameId && data['favorite'] == true) {
          favoriteLayout = ControllerLayout.fromJson(data);
          favoriteKey = key;
        }
      } catch (_) {
        continue;
      }
    }
    if (!mounted || favoriteLayout == null || favoriteKey == null) return;
    setState(() {
      currentLayout = favoriteLayout;
      currentStorageKey = favoriteKey;
    });
  }

  Future<void> saveLayout(String storageKey, ControllerLayout layout) async {
    final String jsonString = jsonEncode(layout.toJson());
    await prefs.setString(storageKey, jsonString);
    print("[Storage] Layout for $storageKey saved.");
  }

  Future<bool> loadLayout(String storageKey) async {
    final previousLayout = currentLayout;
    final jsonString = prefs.getString(storageKey);
    if (jsonString != null) {
      try {     
        // Use the fromJson factory we created earlier
        cachedLayout = ControllerLayout.fromJson(jsonDecode(jsonString));
        currentLayout = cachedLayout; // Set current layout to the loaded cached layout
        currentStorageKey = storageKey;
        if (previousLayout != null) {
          bleManager.resetTiltAndStepInputs(
            tiltTarget: previousLayout.tiltTarget,
            stepTarget: previousLayout.stepTarget,
            stepBitmask: previousLayout.stepButtonBitmask,
          );
          steeringValue = 0.0;
          lastSentStepValue = 0.0;
          bleManager.forceTransmitInputPacket();
        }
        if (isEditing) {
          cloneLayout();
        }
        processBackgroundImage(currentLayout!.backgroundImage);
        buildBackgroundColor(currentLayout!.backgroundColor);
        print("--------------------------------------------");
        print("[Storage] Local layout found for $storageKey, name: ${currentLayout!.layoutName}");
        if (mounted) {
          setState(() {});
        }
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
          id: "l1",
          type: ControllerElementType.button,
          position: Offset(0.21, 0.09),
          label: "LB",
          size: 44,
          buttonId: 1 << 8,
          buttonShape: ButtonShape.rectangle,
        ),
        ControllerElement(
          id: "r1",
          type: ControllerElementType.button,
          position: Offset(0.79, 0.09),
          label: "RB",
          size: 44,
          buttonId: 1 << 9,
          buttonShape: ButtonShape.rectangle,
        ),
        ControllerElement(
          id: "l2",
          type: ControllerElementType.button,
          position: Offset(0.085, 0.09),
          label: "LT",
          size: 44,
          buttonId: 1 << 10,
          buttonShape: ButtonShape.rectangle,
        ),
        ControllerElement(
          id: "r2",
          type: ControllerElementType.button,
          position: Offset(0.915, 0.09),
          label: "RT",
          size: 44,
          buttonId: 1 << 11,
          buttonShape: ButtonShape.rectangle,
        ),
        ControllerElement(
          id: ControllerId.buttonSquare.name,
          type: ControllerElementType.button,
          position: Offset(0.804, 0.499),
          size: 65,
          buttonId: 1 << 14,
          label: "X",
        ),
        ControllerElement(
          id: ControllerId.buttonCross.name,
          type: ControllerElementType.button,
          position: Offset(0.87, 0.642),
          size: 65,
          buttonId: 1 << 12,
          label: "A",
        ),
        ControllerElement(
          id: ControllerId.buttonCircle.name,
          type: ControllerElementType.button,
          position: Offset(0.935, 0.499),
          size: 65,
          buttonId: 1 << 13,
          label: "B",
        ),
        ControllerElement(
          id: ControllerId.buttonTriangle.name,
          type: ControllerElementType.button,
          position: Offset(0.87, 0.358),
          size: 65,
          buttonId: 1 << 15,
          label: "Y",
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

  Future<void> _migrateDefaultLayoutToStandardToolbar() async {
    if (prefs.getBool(_kDefaultLayoutStandardToolbar) == true) return;

    final jsonString = prefs.getString(defaultKey);
    if (jsonString == null) {
      await prefs.setBool(_kDefaultLayoutStandardToolbar, true);
      return;
    }

    try {
      final Map<String, dynamic> json = jsonDecode(jsonString);
      final data = json['data'] as Map<String, dynamic>;
      final elements = data['elements'] as List;
      final hasToolbar = elements.any(
        (e) => _isToolbarElementId((e as Map<String, dynamic>)['id'] as String),
      );
      if (!hasToolbar) {
        await prefs.setBool(_kDefaultLayoutStandardToolbar, true);
        return;
      }

      data['elements'] =
          elements.where((e) => !_isToolbarElementId((e as Map<String, dynamic>)['id'] as String)).toList();
      final migrated = ControllerLayout.fromJson(json);
      defaultLayout = migrated;
      await saveLayout(defaultKey, migrated);
      if (currentStorageKey == defaultKey) {
        await loadLayout(defaultKey);
      }
      await prefs.setBool(_kDefaultLayoutStandardToolbar, true);
      print('[Init] Migrated default layout to use standard toolbar.');
    } catch (e) {
      print('[Init] Default layout migration skipped: $e');
    }
  }

  Future<ControllerLayout> getSuperTaxKartLayout() async {
    final raw = await rootBundle.loadString('assets/SuperTaxKart.exersync');
    final Map<String, dynamic> json = jsonDecode(raw);
    json.putIfAbsent('gameId', () => 'SuperTaxKart');
    json.putIfAbsent('version', () => '1');
    return ControllerLayout.fromJson(json);
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

  bool _isToolbarElementId(String id) => id.startsWith('toolbar_');

  bool _layoutHasToolbarElements(List<ControllerElement> elements) =>
      elements.any((e) => _isToolbarElementId(e.id));

  bool get _showGpxStopInSettings => _gpxExerciseRecording || _gpxTutorialStopDisplay;

  void _setGpxTutorialStopDisplay(bool value) {
    if (_gpxTutorialStopDisplay == value) return;
    _gpxTutorialStopDisplay = value;
    _settingsDialogSetState?.call(() {});
  }

  void _openSettingsDialog({bool forTutorialStep = false, bool forGpxStopTutorialStep = false}) {
    setState(() => isSettingsOpen = true);
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            _settingsDialogSetState = setDialogState;
            return Center(
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: MediaQuery.of(context).size.width * 0.45,
                  padding: const EdgeInsets.all(20),
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.85,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 10)
                    ],
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          "SETTINGS",
                          style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                        ),
                        const SizedBox(height: 20),
                        _buildMenuButton(
                          const Icon(Icons.tune, color: Colors.white54, size: 20),
                          "Customize Layout",
                          () {
                            Navigator.pop(context);
                            toggleEditMode();
                          },
                          key: _tutorialCustomizeLayoutKey,
                        ),
                        const SizedBox(height: 10),
                        _buildMenuButton(
                          const Icon(Icons.tune, color: Colors.white54, size: 20),
                          "Element Mapping Customization",
                          () {
                            Navigator.pop(context);
                            mappingSetting();
                          },
                          key: _tutorialElementMappingKey,
                        ),
                        const SizedBox(height: 10),
                        _buildMenuButton(
                          const Icon(Icons.tune, color: Colors.white54, size: 20),
                          steeringEnabled ? "Disable Tilt Steering" : "Enable Tilt Steering",
                          () {
                            setDialogState(() {
                              steeringEnabled = !steeringEnabled;
                              if (!steeringEnabled) {
                                bleManager.updateSteering(0.0, currentLayout!.tiltTarget);
                              }
                            });
                          },
                          key: _tutorialTiltSteeringKey,
                        ),
                        const SizedBox(height: 10),
                        _buildMenuButton(
                          const Icon(Icons.tune, color: Colors.white54, size: 20),
                          steppingEnabled ? "Disable Step Detection" : "Enable Step Detection",
                          () {
                            final next = !steppingEnabled;
                            _setSteppingEnabled(next);
                            setDialogState(() {
                              if (!next) {
                                bleManager.updateStep(
                                  0.0,
                                  jid: currentLayout!.stepTarget,
                                  bitmask: currentLayout!.stepButtonBitmask,
                                );
                              }
                            });
                          },
                          key: _tutorialStepDetectionKey,
                        ),
                        const SizedBox(height: 10),
                        _buildMenuButton(
                          Icon(
                            _showGpxStopInSettings ? Icons.stop_circle_outlined : Icons.fiber_manual_record,
                            color: _showGpxStopInSettings ? Colors.redAccent : Colors.white54,
                            size: 20,
                          ),
                          _showGpxStopInSettings ? 'Stop exercise GPX' : 'Start exercise GPX recording',
                          () async {
                            await _onExerciseGpxMenuPressed();
                          },
                          key: _tutorialExerciseGpxKey,
                        ),
                        const SizedBox(height: 10),
                        _buildMenuButton(
                          const Icon(Icons.school_outlined, color: Colors.white54, size: 20),
                          "Tutorial",
                          _startTutorialManually,
                        ),
                        const SizedBox(height: 10),
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text("CLOSE", style: TextStyle(color: Colors.blueAccent)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    ).then((_) {
      _settingsDialogSetState = null;
      _gpxTutorialStopDisplay = false;
      if (mounted) setState(() => isSettingsOpen = false);
    });
    if (forTutorialStep) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showCustomizeLayoutTutorialStep(attempt: 0);
      });
    } else if (forGpxStopTutorialStep) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showExerciseGpxStopTutorialStep(attempt: 0);
      });
    }
  }

  Widget _buildStandardToolbar() {
    return Center(
      child: Row(
        key: _standardToolbarKey,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: () async {
              await bleManager.sendMessage("SCREENSHOT");
              HapticFeedback.mediumImpact();
            },
            child: Container(
              width: 36, height: 26,
              decoration: const BoxDecoration(
                color: Colors.white24,
                shape: BoxShape.rectangle,
                borderRadius: BorderRadius.all(Radius.circular(4)),
              ),
              child: const Icon(Icons.crop_free, color: Colors.white, size: 18),
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: () async {
              final nextPaused = !paused;
              _setPaused(nextPaused);
              final sent = await bleManager.sendMessage(
                nextPaused ? "PAUSE" : "RESUME",
                tiltTarget: currentLayout!.tiltTarget,
                stepTarget: currentLayout!.stepTarget,
                stepBitmask: currentLayout!.stepButtonBitmask,
              );
              if (!sent) {
                _setPaused(!nextPaused);
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
            onTap: _openSettingsDialog,
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
      key: _tutorialEditorToolbarKey,
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
          maxHeight: 145,
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
                    key: _tutorialEditorToolbarLeftKey,
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
                      Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(minHeight: 48),
                        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              "Resize snap step (0 = off)",
                              style: TextStyle(color: Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            TextField(
                              controller: _resizeGridSizeController,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                              decoration: InputDecoration(
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                filled: true,
                                fillColor: Colors.black26,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(4),
                                  borderSide: const BorderSide(color: Color(0xFF505050)),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(4),
                                  borderSide: const BorderSide(color: Color(0xFF505050)),
                                ),
                              ),
                              onChanged: (value) {
                                final parsed = double.tryParse(value.trim());
                                if (parsed != null && parsed >= 0) {
                                  setState(() => resizeGridSize = parsed);
                                }
                              },
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
                    key: _tutorialEditorToolbarRightKey,
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

  void mappingSetting({bool forTutorialStep = false}) {
    // Assuming these are your available bitmask/command options
    final List<String> availableCommands = buttonBitmasks.keys.toList();
    cloneLayout();

    showDialog(
      context: context,
      barrierColor: Colors.black54,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return StatefulBuilder( // The 'setDialogState' is born here
          builder: (context, setDialogState) {
            return GestureDetector(
              // This detects clicks on the semi-transparent barrier
              onTap: () async {
                bool canExit = await _handleUnsavedChanges();
                if (canExit) Navigator.of(context).pop();
              },
              behavior: HitTestBehavior.opaque,
              child: PopScope(
                canPop: false, // Prevent back button from closing immediately
                onPopInvokedWithResult: (didPop, result) async {
                  if (didPop) return;
                  bool canExit = await _handleUnsavedChanges();
                  if (canExit) Navigator.of(context).pop();
                },
                child: GestureDetector(
                  // This prevents clicks inside the dialog from triggering the "close" logic
                  onTap: () {},
                  child: Center(
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        key: _tutorialElementMappingDialogKey,
                        width: MediaQuery.of(context).size.width * 0.5, // Slightly wider for two columns
                        // maxHeight: MediaQuery.of(context).size.height * 0.8,
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1A1A),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white10),
                          boxShadow: [
                            BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 10)
                          ],
                        ),
                        child: SingleChildScrollView(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                "ELEMENT MAPPING",
                                style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                              ),
                              const SizedBox(height: 20),
                              Column(
                                key: _tutorialElementMappingButtonsKey,
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _buildSectionHeader("BUTTONS"),
                                  ...editLayoutCopy!.elements.where((e) => e.type == ControllerElementType.button).map((btn) {
                                    String currentLabel = buttonBitmasks.entries
                                      .firstWhere((entry) => entry.value == btn.buttonId, 
                                        orElse: () => buttonBitmasks.entries.first).key;
                                    return _buildMappingRow(
                                      btn.label, 
                                      currentLabel, 
                                      availableCommands,
                                      (String newLabel) {
                                        setDialogState(() {
                                          btn.buttonId = buttonBitmasks[newLabel]!;
                                        });
                                      }
                                    );
                                  }),
                                ],
                              ),
                              const SizedBox(height: 20),
                              Column(
                                key: _tutorialElementMappingTiltKey,
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _buildSectionHeader("TILT"),
                                  _buildMappingRow(
                                    "Steering Target", 
                                    editLayoutCopy!.tiltTarget == ControllerId.leftJoystick ? "LEFT JOYSTICK" : "RIGHT JOYSTICK", 
                                    ["LEFT JOYSTICK", "RIGHT JOYSTICK"], 
                                    (String selected) {
                                      setDialogState(() {
                                        editLayoutCopy!.tiltTarget = (selected == "LEFT JOYSTICK") 
                                            ? ControllerId.leftJoystick 
                                            : ControllerId.rightJoystick;
                                      });
                                    }
                                  ),
                                  _buildTiltDeadzoneSlider(setDialogState),
                                  _buildTiltDeadzoneWhileSteppingSlider(setDialogState),
                                ],
                              ),
                              const SizedBox(height: 20),
                              Column(
                                key: _tutorialElementMappingStepKey,
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _buildSectionHeader("STEP"),
                                  _buildMappingRow(
                                    "Step Output", 
                                    editLayoutCopy!.stepButtonBitmask != 0 
                                        ? buttonBitmasks.entries.firstWhere((e) => e.value == editLayoutCopy!.stepButtonBitmask).key 
                                        : (editLayoutCopy!.stepTarget == ControllerId.leftJoystick ? "LEFT JOYSTICK (LY)" : "RIGHT JOYSTICK (RY)"),
                                    ["LEFT JOYSTICK (LY)", "RIGHT JOYSTICK (RY)", ...availableCommands], 
                                    (String selected) {
                                      setDialogState(() {
                                        if (selected.contains("JOYSTICK")) {
                                          editLayoutCopy!.stepButtonBitmask = 0;
                                          editLayoutCopy!.stepTarget = (selected.contains("LEFT")) 
                                              ? ControllerId.leftJoystick 
                                              : ControllerId.rightJoystick;
                                        } else {
                                          editLayoutCopy!.stepButtonBitmask = buttonBitmasks[selected]!;
                                        }
                                      });
                                    }
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              TextButton(
                                onPressed: () async {
                                  // Manual save trigger
                                  await saveLayout(currentStorageKey!, editLayoutCopy!);
                                  originalLayoutJson = jsonEncode(editLayoutCopy!.toJson());
                                  setState(() => currentLayout = editLayoutCopy);
                                  Navigator.pop(context);
                                },
                                child: const Text("SAVE & CLOSE", style: TextStyle(color: Colors.blueAccent)),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    if (forTutorialStep) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollAndHighlightElementMappingButtons(attempt: 0);
      });
    }
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Text(title, style: const TextStyle(color: Colors.blueAccent, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(width: 10),
          const Expanded(child: Divider(color: Colors.white10, thickness: 1)),
        ],
      ),
    );
  }

  Widget _buildTiltDeadzoneSlider(StateSetter setDialogState) {
    return _buildDeadzoneSlider(
      setDialogState,
      label: 'TILT DEADZONE',
      value: editLayoutCopy!.tiltDeadzone ?? ControllerLayout.defaultTiltDeadzone,
      min: 0.0,
      max: 1.0,
      divisions: 100,
      onChanged: (next) => editLayoutCopy!.tiltDeadzone = next,
    );
  }

  Widget _buildTiltDeadzoneWhileSteppingSlider(StateSetter setDialogState) {
    return _buildDeadzoneSlider(
      setDialogState,
      label: 'TILT DEADZONE WHILE STEPPING',
      value: editLayoutCopy!.tiltDeadzoneWhileStepping ??
          ControllerLayout.defaultTiltDeadzoneWhileStepping,
      min: 0.0,
      max: 1.0,
      divisions: 100,
      onChanged: (next) => editLayoutCopy!.tiltDeadzoneWhileStepping = next,
    );
  }

  Widget _buildDeadzoneSlider(
    StateSetter setDialogState, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    final clamped = value.clamp(min, max);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              Text(
                clamped.toStringAsFixed(2),
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
          Slider(
            value: clamped,
            min: min,
            max: max,
            divisions: divisions,
            activeColor: Colors.blueAccent,
            inactiveColor: Colors.white24,
            onChanged: (next) {
              setDialogState(() => onChanged(next));
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMappingRow(String label, String currentValue, List<String> options, Function(String) onChanged) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label.replaceAll('_', ' ').toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 14)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.white10),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: currentValue,
                dropdownColor: const Color(0xFF2A2A2A),
                style: const TextStyle(color: Colors.white, fontSize: 13),
                icon: const Icon(Icons.arrow_drop_down, color: Colors.white54),
                items: options.map((String value) {
                  return DropdownMenuItem<String>(
                    value: value,
                    child: Text(value),
                  );
                }).toList(),
                onChanged: (val) {
                  if (val != null) onChanged(val);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Helper method to keep your buttons consistent
  Widget _buildMenuButton(Widget iconWidget, String label, VoidCallback onTap, {Key? key}) {
    return Material(
      key: key,
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
      if (a == defaultKey) return -1;
      if (b == defaultKey) return 1;
      if (a == superTaxKartKey) return -1;
      if (b == superTaxKartKey) return 1;
      return a.compareTo(b);
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
                        key: _tutorialKeyForElement(element.id),
                        element: element,
                        isEditing: isEditing,
                        isSelected: isSelected,
                        resizeGridSize: resizeGridSize,
                        systemIconOverride: element.id == 'toolbar_pause' && !isEditing
                            ? (paused ? 'play' : 'pause')
                            : null,
                        onSelect: () => setState(() => selectedElement = element),
                        onSizeChanged: (newSize) => setState(() {
                          final selected = selectedElement;
                          if (selected != null && selected.id == element.id) {
                            selected.size = newSize;
                          }
                        }),
                        onPressed: (id, pressed) {
                          if (!isEditing) {
                            _handleLayoutButtonPress(element, pressed);
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
                        resizeGridSize: resizeGridSize,
                        onSelect: () => setState(() => selectedElement = element),
                        onSizeChanged: (newSize) => setState(() {
                          final selected = selectedElement;
                          if (selected != null && selected.id == element.id) {
                            selected.size = newSize;
                          }
                        }),
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
                  ] else if (!_layoutHasToolbarElements(elementsToRender)) ...[
                    Positioned(
                      top: 5,
                      left: 16,
                      right: 16,
                      child: _buildStandardToolbar(),
                    ),
                  ],
                  if (!isEditing && _layoutHasToolbarElements(elementsToRender))
                    _buildLayoutToolbarTutorialAnchor(
                      elementsToRender,
                      screenWidth,
                      screenHeight,
                    ),
                  if (!isEditing)
                    Positioned(
                      bottom: 10,
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