import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
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

class ControllerLayout {
  final String gameId;          // e.g., "racing_game_01"
  final String layoutName;      // e.g., "Manual Transmission"
  final String version;
  final String? backgroundImage;  // The game dev might want a custom skin
  final String? backgroundColor;  // Optional solid color background (hex ARGB)
  final List<ControllerElement> elements;

  ControllerLayout({
    required this.gameId,
    required this.elements,
    required this.version,
    this.layoutName = "Default",
    this.backgroundImage,
    this.backgroundColor,
  });

  Map<String, dynamic> toJson() => {
    'gameId': gameId,
    'layoutName': layoutName,
    'version': version,
    'data': {
      'backgroundImage': backgroundImage,
      'backgroundColor': backgroundColor,
      'elements': elements.map((e) => e.toJson()).toList(),
    }
  };

  factory ControllerLayout.fromJson(Map<String, dynamic> json) {
    var data = json['data'];
    var list = data['elements'] as List;
    List<ControllerElement> elementList = list.map((i) => ControllerElement.fromJson(i)).toList();
    String? hexColor = data['backgroundColor'];
    if (hexColor != null && hexColor.startsWith('#')) {
      hexColor = hexColor.replaceAll('#', '').toUpperCase();
      if (hexColor.length == 6) {
        hexColor = "FF$hexColor";
      } else if (hexColor.length == 8) {
        String alpha = hexColor.substring(6);
        hexColor = alpha + hexColor.substring(0, 6);
      }
    }
    return ControllerLayout(
      gameId: json['gameId'].toString(),
      layoutName: json['layoutName'] ?? "Default Layout",
      version: json['version'].toString(),
      backgroundImage: data['backgroundImage'],
      backgroundColor: hexColor,
      elements: elementList,
    );
  }
}

class ControllerElement {
  final String id;                    // Unique ID
  final ControllerElementType type;
  final Offset position;              // Center position (or bottom-left for joystick)
  final double size;
  final int buttonId;                 // For buttons: bitmask value
  final String? joystickType;
  final String label;                 // Optional: "A", "X", "Fire", etc.
  final String backgroundColor;
  final String color;

  final String? image;    // For Base64 encoded strings
  final bool useSystemIcon;   // If true, use your local assets/icons/
  final double opacity;       // Some buttons should be faint

  ControllerElement({
    required this.id,
    required this.type,
    required this.position,
    required this.label,
    this.buttonId = 1 << 0,
    this.joystickType,
    this.size = 80,
    this.color = "FFFFFFFF",
    this.backgroundColor = "33FFFFFF",
    this.image,
    this.useSystemIcon = true, 
    this.opacity = 1.0,
  });

  // For saving/loading
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'x': position.dx,
    'y': position.dy,
    'size': size,
    'buttonId': buttonId,
    'joystickType': joystickType,
    'label': label,
    'backgroundColor': backgroundColor,
    'color': color,
    'image': image,
    'useSystemIcon': useSystemIcon,
    'opacity': opacity,
  };

  factory ControllerElement.fromJson(Map<String, dynamic> json) {
    String? backgroundColorData = json['backgroundColor'];
    String? colorData = json['color'];
    if (backgroundColorData != null && backgroundColorData.startsWith('#')) {
      backgroundColorData = backgroundColorData.replaceAll('#', '').toUpperCase();
      if (backgroundColorData.length == 6) {
        backgroundColorData = "FF$backgroundColorData";
      } else if (backgroundColorData.length == 8) {
        String alpha = backgroundColorData.substring(6);
        backgroundColorData = alpha + backgroundColorData.substring(0, 6);
      }
    }
    if (colorData != null && colorData.startsWith('#')) {
      colorData = colorData.replaceAll('#', '').toUpperCase();
      if (colorData.length == 6) {
        colorData = "FF$colorData";
      } else if (colorData.length == 8) {
        String alpha = colorData.substring(6);
        colorData = alpha + colorData.substring(0, 6);
      }
    }
    return ControllerElement(
      id: json['id'].toString(),
      type: ControllerElementType.values.firstWhere((e) => e.name == (json['type'] as String).toLowerCase()),
      position: Offset(json['x'] as double, json['y'] as double),
      size: (json['size'] ?? 80).toDouble(),
      buttonId: json['buttonId'] ?? 1 << 0,
      joystickType: json['joystickType']?.toString().toLowerCase(),
      label: json['label'] ?? "",
      backgroundColor: backgroundColorData ?? "33FFFFFF",
      color: colorData ?? "FFFFFFFF",
      image: json['image']?.toString(),
      useSystemIcon: json['useSystemIcon'] ?? true,
      opacity: (json['opacity'] ?? 1.0).toDouble(),
    );
  }
}

class CustomButton extends StatefulWidget {
  final ControllerElement element;
  final Function(String id, bool pressed) onPressed;

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
  Widget? _cachedIcon;
  String? _lastProcessedImage;
  bool? _lastPressedState;
  String? _lastColor;

  Widget _buildIcon(ControllerElement element) {
    // Optimization: Only rebuild the icon widget if the image string OR the press state changed
    if (_cachedIcon != null && 
        _lastProcessedImage == element.image && 
        _lastPressedState == isPressed &&
        _lastColor == element.color) {
      return _cachedIcon!;
    }

    Widget newlyCreatedWidget;
    if (element.image != null) {
      final imageData = element.image?.trimLeft() ?? '';

      if (imageData.startsWith('<svg')) {     // Custom SVG data
        imageData.replaceAll(RegExp(r'\s+'), ' ').trim();
        final Color svgColor = isPressed ? Colors.black : Color(int.parse(element.color, radix: 16));
        newlyCreatedWidget = SvgPicture.string(
          imageData,
          width: element.size * 0.6,
          height: element.size * 0.6,
          fit: BoxFit.contain,
          // You can even apply the element's color to the custom SVG!
          colorFilter: ColorFilter.mode(svgColor, BlendMode.srcIn),
        );
      } else if ((imageData.startsWith('http://') || imageData.startsWith('https://'))) {    // Remote URL
        newlyCreatedWidget = Image.network(
          imageData,
          width: element.size,
          height: element.size,
          fit: BoxFit.contain,
          // Shows a spinner while the game-provided URL loads
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return SizedBox(
              width: element.size * 0.3,
              height: element.size * 0.3,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white.withOpacity(0.5)),
            );
          },
          errorBuilder: (_, __, ___) => const Icon(Icons.cloud_off, color: Colors.white),
        );
      } else {      // Raw Image Data (Base64)
        try {
          final base64String = imageData.contains(',') ? imageData.split(',').last : imageData;
          newlyCreatedWidget = Image.memory(
            base64Decode(base64String.trim()),
            width: element.size,
            height: element.size,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => const Icon(Icons.broken_image),
          );
        } catch (e) {
          return const Icon(Icons.error);
        }
      }

      // Save to cache before returning
      _lastProcessedImage = imageData;
      _lastPressedState = isPressed;
      _lastColor = element.color;
      _cachedIcon = newlyCreatedWidget;

      return newlyCreatedWidget;
    }
 
    // System Icons
    if (element.useSystemIcon && element.image == null) {
      return _buildSvgLabel(element.label, element.size);
    }

    return Text(
      element.label,
      style: TextStyle(
        color: isPressed ? Colors.black : Colors.white,
        fontSize: element.size * 0.25,
        fontWeight: FontWeight.bold,
      ),
    );
  }

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

    // Optional tiny position tweak per icon
    final Map<String, Offset> nudge = {
      'triangle': const Offset(0, -2.5),
      'square':   const Offset(0.1, 0.8),
      'circle':   const Offset(0, 0),
      'cross':    const Offset(-0.5, 0),
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
        colorFilter: ColorFilter.mode(iconColor, BlendMode.srcIn),
        fit: BoxFit.contain,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    // Convert 0.0-1.0 to actual pixels
    final double realX = widget.element.position.dx * screenSize.width;
    final double realY = widget.element.position.dy * screenSize.height;
    // Check if we should hide the default button design
    final String? imageData = widget.element.image?.trimLeft();
    final bool hideDecoration = imageData != null && !imageData.startsWith('<svg');

    return Positioned(
      left: realX - widget.element.size / 2,
      top: realY - widget.element.size / 2,
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
            decoration: hideDecoration 
              ? null // No circle background for Links/Base64 
              : BoxDecoration(
                shape: BoxShape.circle,
                color: isPressed ? Colors.white : Color(int.parse(widget.element.backgroundColor, radix: 16)),
                border: Border.all(color: isPressed ? Colors.white : widget.element.backgroundColor != "33FFFFFF" ? Color(int.parse(widget.element.backgroundColor, radix: 16)) : Colors.white54, width: 2),
                boxShadow: isPressed ? [const BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 3))] : null,
              ),
            alignment: Alignment.center,          // ← THIS DOES THE MAGIC!
            child: _buildIcon(widget.element),
          ),
        ),
      ),
    );
  }
}

class CustomJoystick extends StatefulWidget {
  final ControllerElement element;
  final Function(String id, double x, double y) onChange;
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
    final screenSize = MediaQuery.of(context).size;
    // Convert 0.0-1.0 to actual pixels
    final double realX = widget.element.position.dx * screenSize.width;
    final double realY = widget.element.position.dy * screenSize.height;
    return Positioned(
      left: realX - maxRadius,
      top: realY - maxRadius,
      child: GestureDetector(
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        child: Container(
          width: maxRadius * 2,
          height: maxRadius * 2,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Color(int.parse(widget.element.backgroundColor, radix: 16)),
            border: Border.all(color: widget.element.color != "FFFFFFFF" ? Color(int.parse(widget.element.color, radix: 16)) : Colors.white54, width: 2),
          ),
          child: Stack(
            children: [
              Center(
                child: Container(
                  width: maxRadius * 1.6,
                  height: maxRadius * 1.6, 
                  decoration: BoxDecoration(
                    shape: BoxShape.circle, 
                    border: Border.all(color: widget.element.color != "FFFFFFFF" ? Color(int.parse(widget.element.color, radix: 16)) : Colors.white30)
                  )
                )
              ),
              Center(
                child: Transform.translate(
                  offset: delta, 
                  child: Container(
                    width: 44, 
                    height: 44, 
                    decoration: BoxDecoration(
                      color: widget.element.color != "FFFFFFFF" ? Color(int.parse(widget.element.color, radix: 16)) : Colors.white, 
                      shape: BoxShape.circle, 
                      boxShadow: const [
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