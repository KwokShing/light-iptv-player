import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../models/proxy_settings.dart';
import '../services/proxy_service.dart';

/// Loads/persists the proxy settings (same shared_preferences JSON pattern as
/// SourcesController) and mirrors them into [ProxyService.current] so the
/// HttpOverrides callback and mpv option application always see the latest
/// values.
class ProxyController extends ChangeNotifier {
  ProxySettings _settings = const ProxySettings();
  ProxySettings get settings => _settings;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(proxyStorageKey);
    if (raw != null) {
      try {
        _settings =
            ProxySettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (e) {
        debugPrint('ProxyController: failed to parse stored settings: $e');
      }
    }
    await _apply(_settings);
    notifyListeners();
  }

  Future<void> save(ProxySettings next) async {
    _settings = next;
    await _apply(next);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(proxyStorageKey, jsonEncode(next.toJson()));
  }

  /// Publishes [next] to ProxyService, starting/stopping the local SOCKS
  /// bridge first so `findProxy` never points at a dead bridge port.
  Future<void> _apply(ProxySettings next) async {
    if (next.active && next.type == ProxyType.socks5) {
      try {
        await ProxyService.bridge.ensureStarted(next);
      } catch (e) {
        debugPrint('ProxyController: failed to start SOCKS bridge: $e');
      }
      ProxyService.current = next;
    } else {
      ProxyService.current = next;
      await ProxyService.bridge.stop();
    }
  }
}
