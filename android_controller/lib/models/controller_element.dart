import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_svg/flutter_svg.dart';

enum ControllerId {
  leftJoystick,
  rightJoystick,
  buttonSquare,
  buttonCross,
  buttonCircle,
  buttonTriangle,
  buttonUp,
  buttonDown,
  buttonLeft,
  buttonRight,
  // add L1, R1, Select, Start, etc. here later
}

enum ControllerElementType {
  joystick,
  button,
  dpad,
  trigger,
}

class ControllerElement {
  final ControllerId id;                    // Unique ID
  final ControllerElementType type;
  final Offset position;              // Center position (or bottom-left for joystick)
  final double size;
  final int buttonId;                 // For buttons: bitmask value
  final String label;                 // Optional: "A", "X", "Fire", etc.
  final Color color;

  ControllerElement({
    required this.id,
    required this.type,
    required this.position,
    this.size = 80,
    this.buttonId = 0,
    this.label = "",
    this.color = const Color(0x33FFFFFF),
  });

  // For saving/loading
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'x': position.dx,
    'y': position.dy,
    'size': size,
    'buttonId': buttonId,
    'label': label,
    'color': color.value,
  };

  factory ControllerElement.fromJson(Map<String, dynamic> json) {
    return ControllerElement(
      id: json['id'],
      type: ControllerElementType.values.firstWhere((e) => e.name == json['type']),
      position: Offset(json['x'] as double, json['y'] as double),
      size: (json['size'] ?? 80).toDouble(),
      buttonId: json['buttonId'] ?? 0,
      label: json['label'] ?? "",
      color: Color(json['color'] ?? 0x33FFFFFF),
    );
  }

  // Helper to make copy (useful later)
  ControllerElement copyWith({
    Offset? position,
    double? size,
    int? buttonId,
    String? label,
    Color? color,
  }) {
    return ControllerElement(
      id: id,
      type: type,
      position: position ?? this.position,
      size: size ?? this.size,
      buttonId: buttonId ?? this.buttonId,
      label: label ?? this.label,
      color: color ?? this.color,
    );
  }
}

class CustomButton extends StatefulWidget {
  final ControllerElement element;
  final Function(ControllerId id, bool pressed) onPressed;

  const CustomButton({
    super.key,
    required this.element,
    required this.onPressed,
  });

  @override
  State<CustomButton> createState() => _CustomButtonState();
}

class _CustomButtonState extends State<CustomButton> {
  bool isPressed = false;

  Widget _buildSvgLabel(String key, double size) {
    const String path = 'assets/icons/';
    
    final Map<String, String> svgMap = {
      'square':   '${path}square.svg',
      'triangle': '${path}triangle.svg',
      'circle':   '${path}circle.svg',
      'cross':    '${path}cross.svg',
      'arrow_up':    '${path}arrow_up.svg',
      'arrow_down':  '${path}arrow_down.svg',
      'arrow_left':  '${path}arrow_left.svg',
      'arrow_right': '${path}arrow_right.svg',
    };

    final String? svgFile = svgMap[key];
    final Color iconColor = isPressed ? Colors.black : Colors.white;

    // Optional tiny position tweak per icon (makes △ and □ look perfectly centered)
    final Map<String, Offset> nudge = {
      'triangle': const Offset(0, -2.5),
      'square':   const Offset(0.5, 0),
      'circle':   const Offset(0, 0),
      'cross':    const Offset(0, 0),
    };

    if (svgFile == null) {
      // Fallback for custom text labels (L1, R2, etc.)
      return Text(
        widget.element.label,
        style: TextStyle(
          color: iconColor,
          fontSize: size * 0.38,
          fontWeight: FontWeight.bold,
        ),
      );
    }

    return Transform.translate(
      offset: nudge[key] ?? Offset.zero,
      child: SvgPicture.asset(
        svgFile,
        width: size * 0.60,
        height: size * 0.60,
        colorFilter: isPressed ? const ColorFilter.mode(Colors.black, BlendMode.srcIn) : const ColorFilter.mode(Colors.white, BlendMode.srcIn),
        fit: BoxFit.contain,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.element.position.dx - widget.element.size / 2,
      top: widget.element.position.dy - widget.element.size / 2,
      child: GestureDetector(
        onTapDown: (_) => {
          setState(() => isPressed = true),
          widget.onPressed(widget.element.id, true),
        },
        onTapUp: (_) => {
          setState(() => isPressed = false),
          widget.onPressed(widget.element.id, false),
        },
        onTapCancel: () => {
          setState(() => isPressed = false),
          widget.onPressed(widget.element.id, false),
        },
        child: Transform.scale(
          scale: isPressed ? 0.92 : 1.0,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 80),
            width: widget.element.size,
            height: widget.element.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isPressed ? Colors.white : widget.element.color ?? Colors.black.withOpacity(0.4),
              border: Border.all(color: isPressed ? Colors.white : Colors.white54, width: 2),
              boxShadow: isPressed ? [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 3))] : null,
            ),
            alignment: Alignment.center,          // ← THIS DOES THE MAGIC!
            child: _buildSvgLabel(widget.element.label, widget.element.size),
          ),
        ),
      ),
    );
  }
}

class CustomJoystick extends StatefulWidget {
  final ControllerElement element;
  final Function(ControllerId id, double x, double y) onChange;
  final double deadzone;

  const CustomJoystick({super.key, required this.element, required this.onChange,this.deadzone = 0.15});

  @override
  State<CustomJoystick> createState() => _CustomJoystickState();
}

class _CustomJoystickState extends State<CustomJoystick> {
  Offset delta = Offset.zero;
  late double maxRadius;
  Offset? dragStartCenter;
  Timer? _joystickTimer;

  @override
  void initState() {
    super.initState();
    maxRadius = widget.element.size;
  }

  @override
  void dispose() {
    _joystickTimer?.cancel();
    super.dispose();
  }

  double _applyDeadzone(double value, [double deadzone = 0.15]) {
    if (value.abs() < deadzone) return 0.0;
    return (value.abs() - deadzone) / (1.0 - deadzone) * (value > 0 ? 1.0 : -1.0);
  }

  void _onPanStart(DragStartDetails details) {
    final box = context.findRenderObject() as RenderBox;
    dragStartCenter = box.globalToLocal(details.globalPosition);
    delta = Offset.zero;  // Reset delta on start
    _startContinuousSending();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (dragStartCenter == null) return;
    final box = context.findRenderObject() as RenderBox;
    final pos = box.globalToLocal(details.globalPosition);
    delta = pos - dragStartCenter!;

    final dist = delta.distance;
    if (dist > maxRadius) delta = delta * (maxRadius / dist);

    _sendUpdate();
    setState(() {});
  }

  void _onPanEnd(DragEndDetails _) {
    _joystickTimer?.cancel();
    delta = Offset.zero;
    widget.onChange(widget.element.id, 0, 0);
    dragStartCenter = null;
    setState(() {});
  }

  void _startContinuousSending() {
    _joystickTimer?.cancel();
    _joystickTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _sendUpdate();
    });
  }

  void _sendUpdate() {
    final rawX = delta.dx / maxRadius;
    final rawY = delta.dy / maxRadius;
    final x = _applyDeadzone(rawX, widget.deadzone);
    final y = _applyDeadzone(rawY, widget.deadzone);
    widget.onChange(widget.element.id, x, y);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: widget.element.position.dx - maxRadius,
      top: widget.element.position.dy - maxRadius,
      child: GestureDetector(
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        child: Container(
          width: maxRadius * 2,
          height: maxRadius * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.element.color,
            border: Border.all(color: Colors.white54, width: 2),
          ),
          child: Stack(
            children: [
              Center(
                child: Container(
                  width: maxRadius * 1.6,
                  height: maxRadius * 1.6, 
                  decoration: BoxDecoration(
                    shape: BoxShape.circle, 
                    border: Border.all(color: Colors.white30)
                  )
                )
              ),
              Center(
                child: Transform.translate(
                  offset: delta, 
                  child: Container(
                    width: 44, 
                    height: 44, 
                    decoration: const BoxDecoration(
                      color: Colors.white, 
                      shape: BoxShape.circle, 
                      boxShadow: [
                        BoxShadow(blurRadius: 8, color: Colors.black45)
                      ]
                    )
                  )
                )
              ),
            ],
          ),
        ),
      ),
    );
  }
}