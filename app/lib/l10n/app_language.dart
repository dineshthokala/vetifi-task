/// Localization and language switching service for Vetifi.
///
/// Supports English and Kannada (ಕನ್ನಡ).
/// Persists preference via SharedPreferences and notifies listeners on change.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage {
  en,
  kn;

  String get code => this == AppLanguage.en ? 'en' : 'kn';
  String get displayName => this == AppLanguage.en ? 'English' : 'ಕನ್ನಡ';
  String get shortName => this == AppLanguage.en ? 'EN' : 'ಕನ್ನಡ';
}

class LanguageController {
  static final LanguageController instance = LanguageController._internal();
  LanguageController._internal();
  factory LanguageController() => instance;

  static const String _prefKey = 'vetifi_selected_language';
  final ValueNotifier<AppLanguage> currentLanguage =
      ValueNotifier<AppLanguage>(AppLanguage.en);

  AppLanguage get language => currentLanguage.value;
  bool get isKannada => currentLanguage.value == AppLanguage.kn;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedCode = prefs.getString(_prefKey);
      if (savedCode == 'kn') {
        currentLanguage.value = AppLanguage.kn;
      } else {
        currentLanguage.value = AppLanguage.en;
      }
    } catch (_) {
      // Default to English if SharedPreferences unavailable
    }
  }

  Future<void> toggleLanguage() async {
    final next = currentLanguage.value == AppLanguage.en
        ? AppLanguage.kn
        : AppLanguage.en;
    await setLanguage(next);
  }

  Future<void> setLanguage(AppLanguage language) async {
    currentLanguage.value = language;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKey, language.code);
    } catch (_) {}
  }
}
