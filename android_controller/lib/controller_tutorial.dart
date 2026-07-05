import 'package:flutter/material.dart';
import 'package:tutorial_coach_mark/tutorial_coach_mark.dart';

class ControllerTutorial {
  static Rect? boundsFromKeys(List<GlobalKey> keys) {
    Rect? union;
    for (final key in keys) {
      final context = key.currentContext;
      if (context == null) return null;
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return null;
      final topLeft = box.localToGlobal(Offset.zero);
      final rect = topLeft & box.size;
      union = union == null ? rect : union.expandToInclude(rect);
    }
    return union;
  }

  static Rect? visibleBoundsFromKey(GlobalKey key) {
    final context = key.currentContext;
    if (context == null) return null;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;

    final widgetRect = box.localToGlobal(Offset.zero) & box.size;

    final scrollableState = Scrollable.maybeOf(context);
    if (scrollableState == null) return widgetRect;

    final viewportBox = scrollableState.context.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return widgetRect;

    final viewportRect = viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
    final intersection = widgetRect.intersect(viewportRect);
    if (intersection.isEmpty) return null;
    return intersection;
  }

  static void showToolbarIntro(
    BuildContext context, {
    required GlobalKey keyTarget,
    VoidCallback? onFinish,
  }) {
    final target = TargetFocus(
      identify: 'toolbar_actions',
      keyTarget: keyTarget,
      shape: ShapeLightFocus.RRect,
      radius: 8,
      paddingFocus: 8,
      enableOverlayTab: true,
      enableTargetTab: true,
      contents: [
        TargetContent(
          align: ContentAlign.bottom,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          builder: (context, controller) => _messageCard(
            'These toolbar buttons control the game session. Left button take a screenshot, middle buton pause or resume gameplay, and right button open settings to customize your layout and controls.',
          ),
        ),
      ],
    );

    TutorialCoachMark(
      targets: [target],
      colorShadow: Colors.black,
      opacityShadow: 0.72,
      paddingFocus: 0,
      hideSkip: true,
      pulseEnable: false,
      onFinish: onFinish,
    ).show(context: context);
  }

  static void showCustomizeLayoutIntro(
    BuildContext context, {
    required Rect highlightBounds,
    VoidCallback? onFinish,
  }) {
    const padding = 8.0;
    final target = TargetFocus(
      identify: 'customize_layout',
      targetPosition: TargetPosition(
        Size(
          highlightBounds.width + padding * 2,
          highlightBounds.height + padding * 2,
        ),
        Offset(
          highlightBounds.left - padding,
          highlightBounds.top - padding,
        ),
      ),
      shape: ShapeLightFocus.RRect,
      radius: 8,
      enableOverlayTab: true,
      enableTargetTab: true,
      contents: [
        TargetContent(
          align: ContentAlign.bottom,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          builder: (context, controller) => _messageCard(
            'In setting, Use Customize Layout to move, resize, and add controller buttons on screen. You also can switch layout here',
          ),
        ),
      ],
    );

    TutorialCoachMark(
      targets: [target],
      colorShadow: Colors.black,
      opacityShadow: 0.72,
      paddingFocus: 0,
      hideSkip: true,
      pulseEnable: false,
      onFinish: onFinish,
    ).show(context: context);
  }

  static void showElementMappingIntro(
    BuildContext context, {
    required Rect highlightBounds,
    VoidCallback? onFinish,
  }) {
    const padding = 8.0;
    final target = TargetFocus(
      identify: 'element_mapping',
      targetPosition: TargetPosition(
        Size(
          highlightBounds.width + padding * 2,
          highlightBounds.height + padding * 2,
        ),
        Offset(
          highlightBounds.left - padding,
          highlightBounds.top - padding,
        ),
      ),
      shape: ShapeLightFocus.RRect,
      radius: 8,
      enableOverlayTab: true,
      enableTargetTab: true,
      contents: [
        TargetContent(
          align: ContentAlign.bottom,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          builder: (context, controller) => _messageCard(
            'Use Element Mapping Customization to assign game actions to each controller button, include tilt steering and step detection',
          ),
        ),
      ],
    );

    TutorialCoachMark(
      targets: [target],
      colorShadow: Colors.black,
      opacityShadow: 0.72,
      paddingFocus: 0,
      hideSkip: true,
      pulseEnable: false,
      onFinish: onFinish,
    ).show(context: context);
  }

  static void showMotionControlsIntro(
    BuildContext context, {
    required Rect highlightBounds,
    VoidCallback? onFinish,
  }) {
    const padding = 8.0;
    final target = TargetFocus(
      identify: 'motion_controls',
      targetPosition: TargetPosition(
        Size(
          highlightBounds.width + padding * 2,
          highlightBounds.height + padding * 2,
        ),
        Offset(
          highlightBounds.left - padding,
          highlightBounds.top - padding,
        ),
      ),
      shape: ShapeLightFocus.RRect,
      radius: 8,
      enableOverlayTab: true,
      enableTargetTab: true,
      contents: [
        TargetContent(
          align: ContentAlign.top,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          builder: (context, controller) => _messageCard(
            'Enable and disable Tilt Steering to steer by tilting your phone, Enable and disable Step Detection to send walking input using motion sensors here.',
          ),
        ),
      ],
    );

    TutorialCoachMark(
      targets: [target],
      colorShadow: Colors.black,
      opacityShadow: 0.72,
      paddingFocus: 0,
      hideSkip: true,
      pulseEnable: false,
      onFinish: onFinish,
    ).show(context: context);
  }

  static void showExerciseGpxIntro(
    BuildContext context, {
    required Rect highlightBounds,
    VoidCallback? onFinish,
  }) {
    const padding = 8.0;
    final target = TargetFocus(
      identify: 'exercise_gpx',
      targetPosition: TargetPosition(
        Size(
          highlightBounds.width + padding * 2,
          highlightBounds.height + padding * 2,
        ),
        Offset(
          highlightBounds.left - padding,
          highlightBounds.top - padding,
        ),
      ),
      shape: ShapeLightFocus.RRect,
      radius: 8,
      enableOverlayTab: true,
      enableTargetTab: true,
      contents: [
        TargetContent(
          align: ContentAlign.top,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          builder: (context, controller) => _messageCard(
            'Start exercise GPX recording to track your walk and send the route to your PC when finished.',
          ),
        ),
      ],
    );

    TutorialCoachMark(
      targets: [target],
      colorShadow: Colors.black,
      opacityShadow: 0.72,
      paddingFocus: 0,
      hideSkip: true,
      pulseEnable: false,
      onFinish: onFinish,
    ).show(context: context);
  }

  static void showExerciseGpxStopIntro(
    BuildContext context, {
    required Rect highlightBounds,
    VoidCallback? onFinish,
  }) {
    const padding = 8.0;
    final target = TargetFocus(
      identify: 'exercise_gpx_stop',
      targetPosition: TargetPosition(
        Size(
          highlightBounds.width + padding * 2,
          highlightBounds.height + padding * 2,
        ),
        Offset(
          highlightBounds.left - padding,
          highlightBounds.top - padding,
        ),
      ),
      shape: ShapeLightFocus.RRect,
      radius: 8,
      enableOverlayTab: true,
      enableTargetTab: true,
      contents: [
        TargetContent(
          align: ContentAlign.top,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          builder: (context, controller) => _messageCard(
            'Remember to tap Stop exercise GPX to end recording and send the route to your PC when you finished your exercise.',
          ),
        ),
      ],
    );

    TutorialCoachMark(
      targets: [target],
      colorShadow: Colors.black,
      opacityShadow: 0.72,
      paddingFocus: 0,
      hideSkip: true,
      pulseEnable: false,
      onFinish: onFinish,
    ).show(context: context);
  }

  static void showEditorToolbarIntro(
    BuildContext context, {
    required Rect highlightBounds,
    VoidCallback? onFinish,
  }) {
    const padding = 8.0;
    final target = TargetFocus(
      identify: 'editor_toolbar',
      targetPosition: TargetPosition(
        Size(
          highlightBounds.width + padding * 2,
          highlightBounds.height + padding * 2,
        ),
        Offset(
          highlightBounds.left - padding,
          highlightBounds.top - padding,
        ),
      ),
      shape: ShapeLightFocus.RRect,
      radius: 8,
      enableOverlayTab: true,
      enableTargetTab: true,
      contents: [
        TargetContent(
          align: ContentAlign.bottom,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          builder: (context, controller) => _messageCard(
            'When you are in Customize Layout. This is the editor toolbar to lets you save and delete layouts, switch between saved layouts, and adjust resize snap. You can drag the panel to reposition it. Tap the close icon when you want to exit.',
          ),
        ),
      ],
    );

    TutorialCoachMark(
      targets: [target],
      colorShadow: Colors.black,
      opacityShadow: 0.72,
      paddingFocus: 0,
      hideSkip: true,
      pulseEnable: false,
      onFinish: onFinish,
    ).show(context: context);
  }

  static void showEditorToolbarLeftIntro(
    BuildContext context, {
    required Rect highlightBounds,
    VoidCallback? onFinish,
  }) {
    const padding = 8.0;
    final target = TargetFocus(
      identify: 'editor_toolbar_left',
      targetPosition: TargetPosition(
        Size(
          highlightBounds.width + padding * 2,
          highlightBounds.height + padding * 2,
        ),
        Offset(
          highlightBounds.left - padding,
          highlightBounds.top - padding,
        ),
      ),
      shape: ShapeLightFocus.RRect,
      radius: 8,
      enableOverlayTab: true,
      enableTargetTab: true,
      contents: [
        TargetContent(
          align: ContentAlign.bottom,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          builder: (context, controller) => _messageCard(
            'Here you can mark the current layout as favorite, set resize snap step, and use Delete, Save New, or Save to manage the current layout.',
          ),
        ),
      ],
    );

    TutorialCoachMark(
      targets: [target],
      colorShadow: Colors.black,
      opacityShadow: 0.72,
      paddingFocus: 0,
      hideSkip: true,
      pulseEnable: false,
      onFinish: onFinish,
    ).show(context: context);
  }

  static void showEditorToolbarRightIntro(
    BuildContext context, {
    required Rect highlightBounds,
    VoidCallback? onFinish,
  }) {
    const padding = 8.0;
    final target = TargetFocus(
      identify: 'editor_toolbar_right',
      targetPosition: TargetPosition(
        Size(
          highlightBounds.width + padding * 2,
          highlightBounds.height + padding * 2,
        ),
        Offset(
          highlightBounds.left - padding,
          highlightBounds.top - padding,
        ),
      ),
      shape: ShapeLightFocus.RRect,
      radius: 8,
      enableOverlayTab: true,
      enableTargetTab: true,
      contents: [
        TargetContent(
          align: ContentAlign.bottom,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          builder: (context, controller) => _messageCard(
            'Browse your saved layouts here and tap one to load it into the editor.',
          ),
        ),
      ],
    );

    TutorialCoachMark(
      targets: [target],
      colorShadow: Colors.black,
      opacityShadow: 0.72,
      paddingFocus: 0,
      hideSkip: true,
      pulseEnable: false,
      onFinish: onFinish,
    ).show(context: context);
  }

  static void showElementMappingButtonsIntro(
    BuildContext context, {
    required Rect highlightBounds,
    Rect? dialogBounds,
    VoidCallback? onFinish,
  }) {
    _showElementMappingSectionIntro(
      context,
      identify: 'element_mapping_buttons',
      highlightBounds: highlightBounds,
      dialogBounds: dialogBounds,
      message:
          'In Element Mapping Customization, you can assign a game action to each controller button using the dropdown next to its label.',
      onFinish: onFinish,
    );
  }

  static void showElementMappingTiltIntro(
    BuildContext context, {
    required Rect highlightBounds,
    Rect? dialogBounds,
    VoidCallback? onFinish,
  }) {
    _showElementMappingSectionIntro(
      context,
      identify: 'element_mapping_tilt',
      highlightBounds: highlightBounds,
      dialogBounds: dialogBounds,
      message:
          'In tilt section, you can choose which joystick receives tilt input and adjust its deadzone using sliders anytime.',
      onFinish: onFinish,
    );
  }

  static void showElementMappingStepIntro(
    BuildContext context, {
    required Rect highlightBounds,
    Rect? dialogBounds,
    VoidCallback? onFinish,
  }) {
    _showElementMappingSectionIntro(
      context,
      identify: 'element_mapping_step',
      highlightBounds: highlightBounds,
      dialogBounds: dialogBounds,
      message:
          'In Step section, choose where step detection output is sent using the dropdown, whether a joystick axis or a mapped button.',
      onFinish: onFinish,
    );
  }

  static void showExerciseMapIntro(
    BuildContext context, {
    required GlobalKey dialogKey,
    VoidCallback? onFinish,
  }) {
    final ref = boundsFromKeys([dialogKey]);
    if (ref == null) return;

    const edgePadding = 8.0;
    const estimatedMessageHeight = 240.0;
    final screenSize = MediaQuery.sizeOf(context);
    final spaceRight = screenSize.width - ref.right;
    final messageMaxWidth = (spaceRight - edgePadding * 2).clamp(150.0, 220.0);
    final top = edgePadding
        .clamp(edgePadding, screenSize.height - estimatedMessageHeight - edgePadding);

    final customPosition = CustomTargetContentPosition(
      left: ref.right + edgePadding,
      right: edgePadding,
      top: top,
    );

    final target = TargetFocus(
      identify: 'exercise_map',
      keyTarget: dialogKey,
      shape: ShapeLightFocus.RRect,
      radius: 12,
      paddingFocus: 0,
      enableOverlayTab: true,
      enableTargetTab: true,
      contents: [
        TargetContent(
          align: ContentAlign.custom,
          customPosition: customPosition,
          padding: EdgeInsets.zero,
          builder: (context, controller) => Align(
            alignment: Alignment.centerLeft,
            child: _messageCard(
              'This is the view when you start exercise GPX recording. Pick your exercise start point on the map. Pan, zoom, and tap to place the pin.',
              maxWidth: messageMaxWidth,
            ),
          ),
        ),
      ],
    );

    TutorialCoachMark(
      targets: [target],
      colorShadow: Colors.black,
      opacityShadow: 0.72,
      paddingFocus: 0,
      hideSkip: true,
      pulseEnable: false,
      onFinish: onFinish,
    ).show(context: context, rootOverlay: false);
  }

  static void _showElementMappingSectionIntro(
    BuildContext context, {
    required String identify,
    required Rect highlightBounds,
    Rect? dialogBounds,
    required String message,
    VoidCallback? onFinish,
  }) {
    const padding = 8.0;
    const edgePadding = 8.0;
    const estimatedMessageHeight = 130.0;
    final screenSize = MediaQuery.sizeOf(context);
    final ref = dialogBounds ?? highlightBounds;
    final spaceRight = screenSize.width - ref.right;
    final messageMaxWidth = (spaceRight - edgePadding * 2).clamp(120.0, 200.0);
    final top = ((ref.top + ref.height / 2) - estimatedMessageHeight / 2)
        .clamp(edgePadding, screenSize.height - estimatedMessageHeight - edgePadding);

    final customPosition = CustomTargetContentPosition(
      left: ref.right + edgePadding,
      right: edgePadding,
      top: top,
    );

    final target = TargetFocus(
      identify: identify,
      targetPosition: TargetPosition(
        Size(
          highlightBounds.width + padding * 2,
          highlightBounds.height + padding * 2,
        ),
        Offset(
          highlightBounds.left - padding,
          highlightBounds.top - padding,
        ),
      ),
      shape: ShapeLightFocus.RRect,
      radius: 8,
      enableOverlayTab: true,
      enableTargetTab: true,
      contents: [
        TargetContent(
          align: ContentAlign.custom,
          customPosition: customPosition,
          padding: EdgeInsets.zero,
          builder: (context, controller) => Align(
            alignment: Alignment.centerLeft,
            child: _messageCard(
              message,
              maxWidth: messageMaxWidth,
            ),
          ),
        ),
      ],
    );

    TutorialCoachMark(
      targets: [target],
      colorShadow: Colors.black,
      opacityShadow: 0.72,
      paddingFocus: 0,
      hideSkip: true,
      pulseEnable: false,
      onFinish: onFinish,
    ).show(context: context);
  }

  static Widget _messageCard(String message, {double maxWidth = 380}) {
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF2D2D30),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF007ACC), width: 2),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message,
              style: const TextStyle(
                color: Color(0xFFF3F3F3),
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Tap anywhere to continue',
              style: TextStyle(
                color: Color(0xFF8E8E8E),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
