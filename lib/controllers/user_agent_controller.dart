import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../models/user_agent_settings.dart';
import '../services/ping_service.dart';
import '../services/user_agent_service.dart';

class UserAgentController extends ChangeNotifier {
  UserAgentSettings _settings = const UserAgentSettings();
  UserAgentSettings get settings => _settings;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(userAgentStorageKey);
    if (raw != null) {
      try {
        _settings = UserAgentSettings.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
      } catch (error) {
        debugPrint('Failed to load User-Agent settings: $error');
      }
    }
    UserAgentService.apply(_settings);
    notifyListeners();
  }

  Future<void> save(UserAgentSettings next) async {
    _settings = next;
    UserAgentService.apply(next);
    PingService.clearCache();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(userAgentStorageKey, jsonEncode(next.toJson()));
  }
}
