import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:gpx/gpx.dart';

/// Synthetic GPX trail: Haversine random walk in small steps; timestamps run **forward**
/// from [recordingStartUtc] to [recordingEndUtc] so the first track point matches the chosen start.
///
/// Geometry is still a synthetic random walk from [startLat]/[startLon]; total length and
/// point timestamps follow session step count and recording start/end time.
class SimulatedGpxGenerator {
  SimulatedGpxGenerator._();

  static const double _fallbackLat = 3.2206334;
  static const double _fallbackLon = 101.9676587;

  /// Last-resort coordinates when GPS is unavailable.
  static double get fallbackLat => _fallbackLat;
  static double get fallbackLon => _fallbackLon;

  /// User location when permitted; otherwise [_fallbackLat] / [_fallbackLon].
  static Future<({double lat, double lon})> resolveDefaultStartPosition() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        return (lat: _fallbackLat, lon: _fallbackLon);
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.low),
      ).timeout(const Duration(seconds: 8));
      return (lat: pos.latitude, lon: pos.longitude);
    } catch (_) {
      return (lat: _fallbackLat, lon: _fallbackLon);
    }
  }

  static const double _scale = 0.0001;
  static const double _angleVariability = math.pi / 7;

  /// Same haversine formula as your Kotlin snippet; distances in **kilometers**.
  static double haversineKm(
    double lon1,
    double lat1,
    double lon2,
    double lat2,
  ) {
    const r = 6371.0;
    final dLat = _toRad(lat2 - lat1);
    final dLon = _toRad(lon2 - lon1);
    final a = math.pow(math.sin(dLat / 2), 2).toDouble() +
        math.cos(_toRad(lat1)) *
            math.cos(_toRad(lat2)) *
            math.pow(math.sin(dLon / 2), 2).toDouble();
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  static double _toRad(double deg) => deg * math.pi / 180.0;

  /// Assumed average stride for converting hardware step count to distance (walking).
  static const double defaultMetersPerStep = 0.75;

  /// Port of the Python loop: builds track points, then GPX 1.1 XML via [GpxWriter].
  ///
  /// [recordingStartUtc] / [recordingEndUtc] define session wall time (track timestamps span this).
  /// [hardwareStepCount] × [metersPerStep] / 1000 → synthetic path length in km.
  static String buildXml({
    required DateTime recordingStartUtc,
    required DateTime recordingEndUtc,
    required int hardwareStepCount,
    double startLat = _fallbackLat,
    double startLon = _fallbackLon,
    double metersPerStep = defaultMetersPerStep,
    math.Random? random,
  }) {
    final rnd = random ?? math.Random();
    final startUtc = recordingStartUtc.toUtc();
    final endUtc = recordingEndUtc.toUtc();
    var durationSeconds = endUtc.difference(startUtc).inMicroseconds / 1e6;
    if (durationSeconds < 1) durationSeconds = 1;

    final totalDistanceKm = (hardwareStepCount * metersPerStep) / 1000.0;

    final distBetweenPoints = haversineKm(startLon, startLat, startLon + _scale, startLat);
    if (distBetweenPoints <= 0) {
      throw StateError('Invalid distanceBetweenPoints (scale segment length).');
    }

    final List<Wpt> wpts;
    final double reportedPathKm;
    final String descExtra;

    if (totalDistanceKm <= 0) {
      wpts = [
        Wpt(lat: startLat, lon: startLon, time: startUtc),
        Wpt(lat: startLat, lon: startLon, time: endUtc),
      ];
      reportedPathKm = 0;
      descExtra =
          'No steps recorded; track is stationary from session start to end. '
          'Session ${durationSeconds.toStringAsFixed(1)} s. ';
    } else {
      var currentTime = startUtc;
      final speed = durationSeconds / (totalDistanceKm / distBetweenPoints);

      final lat = <double>[startLat, 0.0];
      final lon = <double>[startLon, 0.0];

      var distance = 0.0;
      var i = 1;
      var angle = rnd.nextDouble() * 2 * math.pi;

      final inserted = <_SimPoint>[];

      while (distance < totalDistanceKm) {
        lat[i % 2] = lat[(i + 1) % 2] + math.cos(angle) * _scale;
        lon[i % 2] = lon[(i + 1) % 2] + math.sin(angle) * _scale;
        distance += haversineKm(
          lon[i % 2],
          lat[i % 2],
          lon[(i + 1) % 2],
          lat[(i + 1) % 2],
        );
        i++;
        currentTime = currentTime.add(
          Duration(microseconds: (speed * 1e6).round()),
        );
        inserted.add(_SimPoint(lat[i % 2], lon[i % 2], currentTime));
        angle += rnd.nextDouble() * _angleVariability - _angleVariability / 2.0;
      }

      if (inserted.isNotEmpty) {
        final last = inserted.removeLast();
        inserted.add(_SimPoint(last.lat, last.lon, endUtc));
      }
      reportedPathKm = distance;
      descExtra =
          'Synthetic path length matches step-based estimate (~${totalDistanceKm.toStringAsFixed(3)} km). '
          'Session wall time ${durationSeconds.toStringAsFixed(1)} s (${(durationSeconds / 60).toStringAsFixed(2)} min). '
          'Stride model: ${metersPerStep} m/step × $hardwareStepCount steps. ';

      wpts = inserted
          .map(
            (p) => Wpt(
              lat: p.lat,
              lon: p.lon,
              time: p.time,
            ),
          )
          .toList();
    }

    final gpx = Gpx()
      ..version = '1.1'
      ..creator = 'FYP Android Controller (simulated trail)'
      ..metadata = (Metadata()
        ..name = 'Simulated exercise trail'
        ..desc =
            '$descExtra'
            'Synthetic random-walk geometry (not real GPS fixes). '
            'Path distance ~${reportedPathKm.toStringAsFixed(3)} km.'
        ..time = wpts.isEmpty ? startUtc : wpts.first.time);

    gpx.trks = [
      Trk(
        name: 'Simulated trail',
        cmt:
            'Haversine random walk, SCALE=$_scale. Steps: $hardwareStepCount. Session: $startUtc → $endUtc.',
        trksegs: [Trkseg(trkpts: wpts)],
      ),
    ];

    final body = GpxWriter().asString(gpx, pretty: true);
    return _injectRecordingWindowComment(body, startUtc, endUtc);
  }

  /// Machine-readable session bounds for the PC server (ignored by typical GPX parsers).
  static String _injectRecordingWindowComment(
    String gpxXml,
    DateTime recordingStartUtc,
    DateTime recordingEndUtc,
  ) {
    final start = recordingStartUtc.toUtc().toIso8601String();
    final end = recordingEndUtc.toUtc().toIso8601String();
    final comment = '<!-- fyp-recording-window start=$start end=$end -->';
    final firstNl = gpxXml.indexOf('\n');
    if (firstNl == -1) return '$comment\n$gpxXml';
    final firstLine = gpxXml.substring(0, firstNl).trimLeft();
    if (firstLine.startsWith('<?xml')) {
      return '${gpxXml.substring(0, firstNl + 1)}$comment\n${gpxXml.substring(firstNl + 1)}';
    }
    return '$comment\n$gpxXml';
  }
}

class _SimPoint {
  const _SimPoint(this.lat, this.lon, this.time);
  final double lat;
  final double lon;
  final DateTime time;
}
