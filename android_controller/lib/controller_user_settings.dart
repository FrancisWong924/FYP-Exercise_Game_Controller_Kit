import 'package:shared_preferences/shared_preferences.dart';

import 'app_version.dart';

class ControllerUserSettings {
  static const _tutorialShownForVersionKey = 'tutorial_shown_for_version';
  static const _legacyTutorialAutoShownKey = 'tutorial_auto_shown';

  /// Returns true once per app version; persists immediately on auto-start.
  static Future<bool> tryConsumeTutorialForCurrentVersion() async {
    final prefs = await SharedPreferences.getInstance();
    final current = AppVersion.current;
    var shown = prefs.getString(_tutorialShownForVersionKey);

    if (shown == null && prefs.getBool(_legacyTutorialAutoShownKey) == true) {
      shown = '1.0.0';
    }

    if (shown == current) return false;

    await prefs.setString(_tutorialShownForVersionKey, current);
    await prefs.remove(_legacyTutorialAutoShownKey);
    return true;
  }
}
