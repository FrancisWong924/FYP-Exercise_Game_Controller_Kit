import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
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

enum ButtonShape {
  circle,
  square,
  rectangle,
}

/// Matches PC layout creator: absolute corner resize with optional grid snap, min sizes only.
class LayoutEditorResize {
  static const double joystickMinRadius = 40.0;
  static const double buttonSquareMinSize = 40.0;
  static const double buttonRectMinWidth = 24.0;
  static const double buttonRectMinHeight = 24.0;

  static double snapToGrid(double value, double gridSize) {
    if (gridSize <= 0) return value;
    return (value / gridSize).roundToDouble() * gridSize;
  }

  static void applyButtonResizeFromPointer({
    required ControllerElement element,
    required Offset elementCenterOnScreen,
    required Offset pointerOnScreen,
    required double gridSize,
  }) {
    final logicalDx = math.max(pointerOnScreen.dx - elementCenterOnScreen.dx, 0.0);
    final logicalDy = math.max(pointerOnScreen.dy - elementCenterOnScreen.dy, 0.0);

    if (element.buttonShape == ButtonShape.rectangle) {
      final nextW = math.max(logicalDx * 2, buttonRectMinWidth).toDouble();
      final nextH = math.max(logicalDy * 2, buttonRectMinHeight).toDouble();
      element.buttonWidth = math.max(snapToGrid(nextW, gridSize), buttonRectMinWidth);
      element.buttonHeight = math.max(snapToGrid(nextH, gridSize), buttonRectMinHeight);
      return;
    }

    final nextSize = math.max(math.max(logicalDx, logicalDy) * 2, buttonSquareMinSize).toDouble();
    element.size = math.max(snapToGrid(nextSize, gridSize), buttonSquareMinSize);
  }

  static void applyJoystickResizeFromPointer({
    required ControllerElement element,
    required Offset elementCenterOnScreen,
    required Offset pointerOnScreen,
    required double gridSize,
  }) {
    final logicalDx = math.max(pointerOnScreen.dx - elementCenterOnScreen.dx, 0.0);
    final logicalDy = math.max(pointerOnScreen.dy - elementCenterOnScreen.dy, 0.0);
    final next = math.max(math.max(logicalDx, logicalDy), joystickMinRadius).toDouble();
    element.size = math.max(snapToGrid(next, gridSize), joystickMinRadius);
  }
}

class ControllerLayout {
  final String gameId;          // e.g., "racing_game_01"
  String layoutName;      // e.g., "Manual Transmission"
  bool favorite;        // User can mark certain layouts as favorites
  final String version;
  final String? backgroundImage;  // The game dev might want a custom skin
  final String? backgroundColor;  // Optional solid color background (hex ARGB)
  ControllerId tiltTarget;
  ControllerId stepTarget;
  int stepButtonBitmask;
  final List<ControllerElement> elements;

  ControllerLayout({
    required this.gameId,
    required this.elements,
    required this.version,
    this.layoutName = "Default",
    this.backgroundImage,
    this.backgroundColor,
    this.favorite = false,
    this.tiltTarget = ControllerId.rightJoystick,
    this.stepTarget = ControllerId.leftJoystick,
    this.stepButtonBitmask = 0,
  });

  Map<String, dynamic> toJson() => {
    'gameId': gameId,
    'layoutName': layoutName,
    'version': version,
    'favorite': favorite,
    'data': {
      'backgroundImage': backgroundImage,
      'backgroundColor': backgroundColor,
      "tiltTarget": tiltTarget.index, // Store as int
      "stepTarget": stepTarget.index,
      "stepButtonBitmask": stepButtonBitmask,
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
    int tiltIdx = data['tiltTarget'] ?? ControllerId.rightJoystick.index;
    int stepIdx = data['stepTarget'] ?? ControllerId.leftJoystick.index;
    return ControllerLayout(
      gameId: json['gameId'].toString(),
      layoutName: json['layoutName'] ?? "Default Layout",
      version: json['version'].toString(),
      backgroundImage: data['backgroundImage'],
      backgroundColor: hexColor,
      favorite: json['favorite'] ?? false,
      tiltTarget: ControllerId.values[tiltIdx],
      stepTarget: ControllerId.values[stepIdx],
      stepButtonBitmask: data['stepButtonBitmask'] ?? 0,
      elements: elementList,
    );
  }
}

class ControllerElement {
  final String id;                    // Unique ID
  final ControllerElementType type;
  final String? joystickType;
  final String label;                 // Optional: "A", "X", "Fire", etc.
  final String backgroundColor;
  final String color;
  final String? image;    // For Base64 encoded strings
  final String? useSystemIcon;   // If true, use your local assets/icons/
  final double opacity;       // Some buttons should be faint
  int buttonId;                 // For buttons: bitmask value
  double size;
  Offset position;              // Center position (or bottom-left for joystick)
  ButtonShape buttonShape;
  double? buttonWidth;
  double? buttonHeight;

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
    this.useSystemIcon = null, 
    this.opacity = 1.0,
    this.buttonShape = ButtonShape.circle,
    this.buttonWidth,
    this.buttonHeight,
  });

  /// [ButtonShape.rectangle]: width = [size] × 2, height = [size] × 0.75
  static const double rectangleWidthFactor = 2.0;
  static const double rectangleHeightFactor = 0.75;

  Size get buttonLayoutSize {
    switch (buttonShape) {
      case ButtonShape.circle:
      case ButtonShape.square:
        return Size(size, size);
      case ButtonShape.rectangle:
        return Size(
          (buttonWidth != null && buttonWidth! > 0) ? buttonWidth! : size * rectangleWidthFactor,
          (buttonHeight != null && buttonHeight! > 0) ? buttonHeight! : size * rectangleHeightFactor,
        );
    }
  }

  double get buttonVisualScale => math.min(buttonLayoutSize.width, buttonLayoutSize.height);

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
    'buttonShape': buttonShape.name,
    if (buttonWidth != null) 'buttonWidth': buttonWidth,
    if (buttonHeight != null) 'buttonHeight': buttonHeight,
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
    final String typeName = (json['type'] as String).toLowerCase();
    final ControllerElementType elemType = ControllerElementType.values.firstWhere((e) => e.name == typeName);
    final int bid = json['buttonId'] ?? 1 << 0;
    ButtonShape shape = ButtonShape.circle;
    if (json['buttonShape'] != null) {
      final String sn = (json['buttonShape'] as String).toLowerCase();
      shape = ButtonShape.values.firstWhere((e) => e.name == sn, orElse: () => ButtonShape.circle);
    }
    return ControllerElement(
      id: json['id'].toString(),
      type: elemType,
      position: Offset(json['x'] as double, json['y'] as double),
      size: (json['size'] ?? 80).toDouble(),
      buttonId: bid,
      joystickType: json['joystickType']?.toString().toLowerCase(),
      label: json['label'] ?? "",
      backgroundColor: backgroundColorData ?? "33FFFFFF",
      color: colorData ?? "FFFFFFFF",
      image: json['image']?.toString(),
      useSystemIcon: json['useSystemIcon'],
      opacity: (json['opacity'] ?? 1.0).toDouble(),
      buttonShape: shape,
      buttonWidth: (json['buttonWidth'] is num) ? (json['buttonWidth'] as num).toDouble() : null,
      buttonHeight: (json['buttonHeight'] is num) ? (json['buttonHeight'] as num).toDouble() : null,
    );
  }
}

class CustomButton extends StatefulWidget {
  final ControllerElement element;
  final bool isEditing;
  final bool isSelected;
  final VoidCallback onSelect;
  final Function(Offset newPosition) onPositionChanged;
  final Function(String id, bool pressed) onPressed;
  final ValueChanged<double>? onSizeChanged;
  final double resizeGridSize;

  const CustomButton({
    super.key,
    required this.element,
    required this.onPressed,
    required this.onSelect,
    required this.onPositionChanged,
    this.onSizeChanged,
    this.isEditing = false,
    this.isSelected = false,
    this.resizeGridSize = 8,
  });

  @override
  State<CustomButton> createState() => _CustomButtonState();
}

class _CustomButtonState extends State<CustomButton> {
  bool isPressed = false;
  bool _isResizing = false;
  bool _dragStartedFromResizeZone = false;
  Widget? _cachedIcon;
  String? _lastProcessedImage;
  bool? _lastPressedState;
  String? _lastColor;
  double? _lastVisualScale;
  ButtonShape? _lastButtonShape;
  String? _lastUseSystemIcon;

  BoxDecoration _buttonFaceDecoration(ControllerElement element, double w, double h) {
    final Color bg = isPressed ? Colors.white : Color(int.parse(element.backgroundColor, radix: 16));
    final Color borderCol = isPressed
        ? Colors.white
        : element.backgroundColor != "33FFFFFF"
            ? Color(int.parse(element.backgroundColor, radix: 16))
            : Colors.white54;
    switch (element.buttonShape) {
      case ButtonShape.circle:
        return BoxDecoration(
          shape: BoxShape.circle,
          color: bg,
          border: Border.all(color: borderCol, width: 2),
          boxShadow: isPressed ? [const BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 3))] : null,
        );
      case ButtonShape.square:
        final double r = math.min(w, h) * 0.14;
        return BoxDecoration(
          borderRadius: BorderRadius.circular(r),
          color: bg,
          border: Border.all(color: borderCol, width: 2),
          boxShadow: isPressed ? [const BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 3))] : null,
        );
      case ButtonShape.rectangle:
        final double r = math.min(w, h) * 0.22;
        return BoxDecoration(
          borderRadius: BorderRadius.circular(r),
          color: bg,
          border: Border.all(color: borderCol, width: 2),
          boxShadow: isPressed ? [const BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 3))] : null,
        );
    }
  }

  Widget _buildIcon(ControllerElement element) {
    final double vis = element.buttonVisualScale;
    if (_cachedIcon != null &&
        _lastProcessedImage == element.image &&
        _lastPressedState == isPressed &&
        _lastColor == element.color &&
        _lastVisualScale == vis &&
        _lastButtonShape == element.buttonShape &&
        _lastUseSystemIcon == element.useSystemIcon) {
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
          width: vis * 0.6,
          height: vis * 0.6,
          fit: BoxFit.contain,
          // You can even apply the element's color to the custom SVG!
          colorFilter: ColorFilter.mode(svgColor, BlendMode.srcIn),
        );
      } else if ((imageData.startsWith('http://') || imageData.startsWith('https://'))) {    // Remote URL
        newlyCreatedWidget = Image.network(
          imageData,
          width: vis,
          height: vis,
          fit: BoxFit.contain,
          // Shows a spinner while the game-provided URL loads
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return SizedBox(
              width: vis * 0.3,
              height: vis * 0.3,
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
            width: vis,
            height: vis,
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
      _lastVisualScale = vis;
      _lastButtonShape = element.buttonShape;
      _lastUseSystemIcon = element.useSystemIcon;
      _cachedIcon = newlyCreatedWidget;

      return newlyCreatedWidget;
    }
 
    // System Icons
    if (element.useSystemIcon != null && element.useSystemIcon != "None" && element.image == null) {
      newlyCreatedWidget = _buildSvgLabel(element.useSystemIcon!, vis, element.color);
      _lastProcessedImage = null;
      _lastPressedState = isPressed;
      _lastColor = element.color;
      _lastVisualScale = vis;
      _lastButtonShape = element.buttonShape;
      _lastUseSystemIcon = element.useSystemIcon;
      _cachedIcon = newlyCreatedWidget;
      return newlyCreatedWidget;
    }

    newlyCreatedWidget = Text(
      element.label,
      style: TextStyle(
        color: isPressed ? Colors.black : Colors.white,
        fontSize: vis * 0.35,
        fontWeight: FontWeight.bold,
      ),
    );
    _lastProcessedImage = null;
    _lastPressedState = isPressed;
    _lastColor = element.color;
    _lastVisualScale = vis;
    _lastButtonShape = element.buttonShape;
    _lastUseSystemIcon = element.useSystemIcon;
    _cachedIcon = newlyCreatedWidget;
    return newlyCreatedWidget;
  }

  Widget _buildSvgLabel(String key, double visualScale, String colorHex) {
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
    final Color iconColor = isPressed ? Colors.black : colorHex != "FFFFFFFF" ? Color(int.parse(colorHex, radix: 16)) : Colors.white;

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
          fontSize: visualScale * 0.38,
          fontWeight: FontWeight.bold,
        ),
      );
    }

    return Transform.translate(
      offset: nudge[key] ?? Offset.zero,
      child: SvgPicture.asset(
        svgFile,
        width: visualScale * 0.60,
        height: visualScale * 0.60,
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

    final layout = widget.element.buttonLayoutSize;
    final double w = layout.width;
    final double h = layout.height;
    const double resizeHitSize = 36.0;
    final center = Offset(realX, realY);
    return Positioned(
      left: realX - (w / 2) - 4,
      top: realY - (h / 2) - 4,
      child: GestureDetector(
        onPanStart: widget.isEditing
            ? (details) {
                if (!widget.isSelected) return;
                final lp = details.localPosition;
                _dragStartedFromResizeZone =
                    lp.dx >= (w - resizeHitSize) && lp.dy >= (h - resizeHitSize);
                if (_dragStartedFromResizeZone) {
                  setState(() => _isResizing = true);
                  LayoutEditorResize.applyButtonResizeFromPointer(
                    element: widget.element,
                    elementCenterOnScreen: center,
                    pointerOnScreen: details.globalPosition,
                    gridSize: widget.resizeGridSize,
                  );
                  widget.onSizeChanged?.call(widget.element.size);
                }
              }
            : null,
        onPanUpdate: widget.isEditing ? (details) {
          if (!widget.isSelected) return;
          if (_isResizing) {
            setState(() {
              LayoutEditorResize.applyButtonResizeFromPointer(
                element: widget.element,
                elementCenterOnScreen: center,
                pointerOnScreen: details.globalPosition,
                gridSize: widget.resizeGridSize,
              );
              widget.onSizeChanged?.call(widget.element.size);
            });
            return;
          }

          if (!_dragStartedFromResizeZone) {
            double newX = (details.globalPosition.dx / screenSize.width).clamp(0.0, 1.0);
            double newY = (details.globalPosition.dy / screenSize.height).clamp(0.0, 1.0);
            widget.onPositionChanged(Offset(newX, newY));
          }
        } : null,
        onPanEnd: widget.isEditing
            ? (_) => setState(() {
                  _isResizing = false;
                  _dragStartedFromResizeZone = false;
                })
            : null,
        onPanCancel: widget.isEditing
            ? () => setState(() {
                  _isResizing = false;
                  _dragStartedFromResizeZone = false;
                })
            : null,
        onTap: widget.isEditing ? widget.onSelect : null,
        onTapDown: widget.isEditing ? null : (_) => {
          setState(() => isPressed = true),
          widget.onPressed(widget.element.id, true),
        },
        onTapUp: widget.isEditing ? null : (_) => {
          setState(() => isPressed = false),
          widget.onPressed(widget.element.id, false),
        },
        onTapCancel: widget.isEditing ? null : () => {
          setState(() => isPressed = false),
          widget.onPressed(widget.element.id, false),
        },
        child: Container(
          padding: const EdgeInsets.all(4), // Space between button and selection line
          decoration: BoxDecoration(
            border: widget.isSelected 
                ? Border.all(color: Colors.blueAccent.withOpacity(0.8), width: 1.5) 
                : Border.all(color: Colors.transparent),
            borderRadius: BorderRadius.circular(4), // Slightly rounded corners for the square
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Transform.scale(
                scale: isPressed ? 0.92 : 1.0,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 80),
                  width: w,
                  height: h,
                  decoration: hideDecoration
                      ? null
                      : _buttonFaceDecoration(widget.element, w, h),
                  alignment: Alignment.center,
                  child: _buildIcon(widget.element),
                ),
              ),
              if (widget.isEditing && widget.isSelected)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Colors.blueAccent,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: Colors.white, width: 1),
                      ),
                      child: const Icon(
                        Icons.open_in_full,
                        size: 12,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class CustomJoystick extends StatefulWidget {
  final ControllerElement element;
  final bool isEditing;
  final bool isSelected;
  final VoidCallback onSelect;
  final Function(Offset newPosition) onPositionChanged;
  final Function(String id, double x, double y) onChange;
  final double deadzone;
  final ValueChanged<double>? onSizeChanged;
  final double resizeGridSize;

  const CustomJoystick({super.key,
    required this.element,
    required this.onChange,
    required this.onSelect,
    required this.onPositionChanged,
    this.onSizeChanged,
    this.isEditing = false,
    this.isSelected = false,
    this.deadzone = 0.15,
    this.resizeGridSize = 8,
  });

  @override
  State<CustomJoystick> createState() => _CustomJoystickState();
}

class _CustomJoystickState extends State<CustomJoystick> {
  Offset delta = Offset.zero;
  Offset? dragStartCenter;
  Timer? _joystickTimer;
  bool _isResizing = false;
  bool _dragStartedFromResizeZone = false;

  @override
  void initState() {
    super.initState();
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
    if (dist > widget.element.size) delta = delta * (widget.element.size / dist);

    _sendUpdate();
    setState(() {});
  }

  void _onPanEnd(DragEndDetails _) {
    _joystickTimer?.cancel();
    setState(() {
      delta = Offset.zero;
    });
    widget.onChange(widget.element.id, 0, 0);
    dragStartCenter = null;
  }

  void _startContinuousSending() {
    _joystickTimer?.cancel();
    _joystickTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _sendUpdate();
    });
  }

  void _sendUpdate() {
    final rawX = delta.dx / widget.element.size;
    final rawY = delta.dy / widget.element.size;
    final x = _applyDeadzone(rawX, widget.deadzone);
    final y = _applyDeadzone(rawY, widget.deadzone);
    widget.onChange(widget.element.id, x, y);
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final double maxRadius = widget.element.size;
    final double diameter = maxRadius * 2;
    const double resizeHitSize = 36.0;
    // Convert 0.0-1.0 to actual pixels
    final double realX = widget.element.position.dx * screenSize.width;
    final double realY = widget.element.position.dy * screenSize.height;
    final center = Offset(realX, realY);
    return Positioned(
      left: realX - maxRadius - 4,
      top: realY - maxRadius - 4,
      child: GestureDetector(
        onPanStart: widget.isEditing
            ? (details) {
                if (!widget.isSelected) return;
                final lp = details.localPosition;
                _dragStartedFromResizeZone =
                    lp.dx >= (diameter - resizeHitSize) && lp.dy >= (diameter - resizeHitSize);
                if (_dragStartedFromResizeZone) {
                  setState(() => _isResizing = true);
                  LayoutEditorResize.applyJoystickResizeFromPointer(
                    element: widget.element,
                    elementCenterOnScreen: center,
                    pointerOnScreen: details.globalPosition,
                    gridSize: widget.resizeGridSize,
                  );
                  widget.onSizeChanged?.call(widget.element.size);
                }
              }
            : _onPanStart,
        onPanUpdate: widget.isEditing
          ? (details) {
              if (!widget.isSelected) return;
              if (_isResizing) {
                setState(() {
                  LayoutEditorResize.applyJoystickResizeFromPointer(
                    element: widget.element,
                    elementCenterOnScreen: center,
                    pointerOnScreen: details.globalPosition,
                    gridSize: widget.resizeGridSize,
                  );
                  widget.onSizeChanged?.call(widget.element.size);
                });
                return;
              }
              if (!_dragStartedFromResizeZone) {
                double newX = (details.globalPosition.dx / screenSize.width).clamp(0.0, 1.0);
                double newY = (details.globalPosition.dy / screenSize.height).clamp(0.0, 1.0);
                widget.onPositionChanged(Offset(newX, newY));
              }
            } 
          : _onPanUpdate,
        onPanEnd: widget.isEditing
            ? (_) => setState(() {
                  _isResizing = false;
                  _dragStartedFromResizeZone = false;
                })
            : _onPanEnd,
        onPanCancel: widget.isEditing
            ? () => setState(() {
                  _isResizing = false;
                  _dragStartedFromResizeZone = false;
                })
            : null,
        onTap: widget.isEditing ? widget.onSelect : null,
        child: Container(
          padding: const EdgeInsets.all(4), 
          decoration: BoxDecoration(
            border: widget.isSelected 
                ? Border.all(color: Colors.blueAccent.withOpacity(0.8), width: 1.5) 
                : Border.all(color: Colors.transparent),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: diameter,
                height: diameter,
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
              if (widget.isEditing && widget.isSelected)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: IgnorePointer(
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: Colors.blueAccent,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: Colors.white, width: 1),
                      ),
                      child: const Icon(
                        Icons.open_in_full,
                        size: 12,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}