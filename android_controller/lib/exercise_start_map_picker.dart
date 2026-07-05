import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

Future<LatLng?> showExerciseStartMapPicker(
  BuildContext context, {
  required LatLng initialCenter,
  bool forTutorialStep = false,
  GlobalKey? dialogKey,
  VoidCallback? onShown,
}) {
  return showDialog<LatLng>(
    context: context,
    barrierDismissible: !forTutorialStep,
    builder: (ctx) => _ExerciseStartMapDialog(
      initialCenter: initialCenter,
      forTutorialStep: forTutorialStep,
      dialogKey: dialogKey,
      onShown: onShown,
    ),
  );
}

class _ExerciseStartMapDialog extends StatefulWidget {
  const _ExerciseStartMapDialog({
    required this.initialCenter,
    this.forTutorialStep = false,
    this.dialogKey,
    this.onShown,
  });

  final LatLng initialCenter;
  final bool forTutorialStep;
  final GlobalKey? dialogKey;
  final VoidCallback? onShown;

  @override
  State<_ExerciseStartMapDialog> createState() => _ExerciseStartMapDialogState();
}

class _ExerciseStartMapDialogState extends State<_ExerciseStartMapDialog> {
  late LatLng _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialCenter;
    if (widget.onShown != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onShown!());
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final maxDialogHeight = size.height - 48;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: Material(
        key: widget.dialogKey,
        color: const Color(0xFF1A1A1A),
        elevation: 24,
        shadowColor: Colors.black54,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Colors.white10),
        ),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: size.width * 0.58,
            maxHeight: maxDialogHeight,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
                child: Text(
                  'Pick GPX start point',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Colors.white70,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${_selected.latitude.toStringAsFixed(5)}, ${_selected.longitude.toStringAsFixed(5)}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.white70),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 4),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: FlutterMap(
                            options: MapOptions(
                              initialCenter: widget.initialCenter,
                              initialZoom: 15,
                              onTap: (_, p) => setState(() => _selected = p),
                            ),
                            children: [
                              TileLayer(
                                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                                userAgentPackageName: 'fyp.android_controller',
                              ),
                              MarkerLayer(
                                markers: [
                                  Marker(
                                    point: _selected,
                                    width: 40,
                                    height: 40,
                                    alignment: Alignment.bottomCenter,
                                    child: const Icon(Icons.place, color: Colors.red, size: 40),
                                  ),
                                ],
                              ),
                              SimpleAttributionWidget(
                                source: const Text('OpenStreetMap'),
                                onTap: () {},
                                alignment: Alignment.bottomRight,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Pan and zoom, then tap the map to place the pin.',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(fontSize: 11, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text("Cancel", style: TextStyle(color: Colors.white54)),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Colors.blueAccent),
                      onPressed: () => Navigator.pop(context, _selected),
                      child: const Text('Use this point', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
