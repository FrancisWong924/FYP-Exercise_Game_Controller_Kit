import 'dart:async';
import 'dart:io';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';

/// Hardware step counter for games (same pedometer source as GPX recording).
/// Counts only when BLE connected, game WebSocket session active, and step detection enabled.
/// Pauses while the controller app game pause flag is true.
class GameStepCounter {
  StreamSubscription<StepCount>? _sub;
  int? _baseline;
  int? _lastRaw;
  int _count = 0;

  bool _bleConnected = false;
  bool _gameWsActive = false;
  bool _stepDetectionEnabled = false;
  bool _paused = false;
  bool _starting = false;

  int get count => _count;

  bool get _shouldRun =>
      _bleConnected && _gameWsActive && _stepDetectionEnabled && !_paused;

  void _log(String message) => print('[GameStepCounter] $message');

  /// Snapshot for logcat when diagnosing why [count] stays at 0.
  String debugState() =>
      'shouldRun=$_shouldRun '
      'ble=$_bleConnected ws=$_gameWsActive stepEnabled=$_stepDetectionEnabled paused=$_paused '
      'streaming=${_sub != null} starting=$_starting '
      'baseline=$_baseline raw=$_lastRaw count=$_count';

  void reset() {
    final prevBaseline = _baseline;
    if (_lastRaw != null) {
      _baseline = _lastRaw;
    }
    _count = 0;
    _log('reset() baseline $prevBaseline → $_baseline (raw=$_lastRaw)');
  }

  void setBleConnected(bool value) {
    _log('setBleConnected($value)');
    _bleConnected = value;
    if (!value) {
      unawaited(_stopStream('BLE disconnected'));
    } else {
      unawaited(_syncStream('BLE connected'));
    }
  }

  void setGameWsActive(bool value) {
    _log('setGameWsActive($value)');
    _gameWsActive = value;
    if (!value) {
      unawaited(_stopStream('game WS disarmed'));
    } else {
      unawaited(_syncStream('game WS armed'));
    }
  }

  void setStepDetectionEnabled(bool value) {
    _log('setStepDetectionEnabled($value)');
    _stepDetectionEnabled = value;
    if (!value) {
      unawaited(_stopStream('step detection disabled'));
    } else {
      unawaited(_syncStream('step detection enabled'));
    }
  }

  void setPaused(bool value) {
    _log('setPaused($value)');
    _paused = value;
    unawaited(_syncStream(value ? 'paused' : 'unpaused'));
  }

  Future<bool> _ensurePermissions() async {
    if (Platform.isAndroid) {
      final status = await Permission.activityRecognition.request();
      final granted = status.isGranted;
      _log('permission activityRecognition → $status granted=$granted');
      return granted;
    }
    if (Platform.isIOS) {
      final status = await Permission.sensors.request();
      final granted = status.isGranted;
      _log('permission sensors → $status granted=$granted');
      return granted;
    }
    _log('permission skipped (non-mobile platform)');
    return true;
  }

  Future<void> _syncStream(String reason) async {
    _log('_syncStream($reason) ${debugState()}');
    if (!_shouldRun) {
      _log('_syncStream aborted: gates not met → ${debugState()}');
      await _stopStream('gates not met');
      return;
    }
    if (_sub != null) {
      _log('_syncStream skipped: pedometer listener already active');
      return;
    }
    if (_starting) {
      _log('_syncStream skipped: start already in progress');
      return;
    }
    _starting = true;
    _log('starting pedometer stream…');
    try {
      if (!await _ensurePermissions()) {
        _log('pedometer NOT started: permission denied');
        return;
      }

      late StepCount first;
      try {
        first = await Pedometer.stepCountStream.first
            .timeout(const Duration(seconds: 12));
        _log('pedometer first sample: raw=${first.steps}');
      } catch (e) {
        _log('pedometer NOT started: first sample failed — $e');
        return;
      }

      if (!_shouldRun) {
        _log('pedometer NOT started: gates changed during first sample → ${debugState()}');
        return;
      }

      _lastRaw = first.steps;
      if (_baseline == null) {
        _baseline = first.steps;
        _count = 0;
        _log('baseline set from first sample: baseline=$_baseline count=0');
      } else {
        _count = (_lastRaw! - _baseline!).clamp(0, 0x7fffffff);
        _log('resumed with existing baseline: baseline=$_baseline raw=$_lastRaw count=$_count');
      }

      await _sub?.cancel();
      _sub = Pedometer.stepCountStream.listen((StepCount e) {
        if (!_shouldRun) return;
        final prevCount = _count;
        _lastRaw = e.steps;
        if (_baseline == null) {
          _baseline = e.steps;
          _count = 0;
        } else {
          _count = (e.steps - _baseline!).clamp(0, 0x7fffffff);
        }
        if (_count != prevCount) {
          _log('step update: raw=${e.steps} baseline=$_baseline count=$_count (+${_count - prevCount})');
        }
      });
      _log('pedometer listener ACTIVE — counting started ${debugState()}');
    } finally {
      _starting = false;
    }
  }

  Future<void> _stopStream(String reason) async {
    final wasActive = _sub != null;
    _starting = false;
    await _sub?.cancel();
    _sub = null;
    if (wasActive) {
      _log('pedometer listener STOPPED ($reason) ${debugState()}');
    }
  }

  Future<void> dispose() async {
    await _stopStream('dispose');
  }
}
