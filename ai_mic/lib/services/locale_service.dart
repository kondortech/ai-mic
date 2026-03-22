import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _localeKey = 'app_locale';

/// Manages app locale persistence and provides a stream for reactive updates.
class LocaleService extends ChangeNotifier {
  LocaleService._();
  static final LocaleService _instance = LocaleService._();
  static LocaleService get instance => _instance;

  Locale _locale = const Locale('en');
  Locale get locale => _locale;

  /// Supported locale options for the language picker.
  static const List<Locale> supportedLocales = [
    Locale('en'),
    Locale('es'),
    Locale('de'),
    Locale('ru'),
  ];

  /// Initialize by loading persisted locale. Call once at app startup.
  /// Defaults to English when no preference is saved.
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_localeKey);
    if (code == null || code.isEmpty) {
      _locale = const Locale('en'); // default to English
    } else {
      _locale = Locale(code);
    }
  }

  /// Set the app locale.
  Future<void> setLocale(Locale locale) async {
    _locale = locale;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_localeKey, locale.languageCode);
    notifyListeners();
  }
}
