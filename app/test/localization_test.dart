import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vetifitask/l10n/app_language.dart';
import 'package:vetifitask/l10n/strings.dart';

void main() {
  group('AppLanguage and Localization Tests', () {
    test('English strings return expected defaults', () {
      final strings = AppStrings(AppLanguage.en);
      expect(strings.isKannada, isFalse);
      expect(strings.appTitle, 'Vetifi');
      expect(strings.appSubtitle, 'Veterinary Dose Calculator');
      expect(strings.searchHint, 'Search drugs...');
      expect(strings.speciesName('dog'), 'Dog');
      expect(strings.speciesName('cat'), 'Cat');
      expect(strings.calculateDose, 'Calculate Dose');
      expect(strings.criSectionTitle, 'Constant Rate Infusion (CRI)');
    });

    test('Kannada strings return correct Kannada translations', () {
      final strings = AppStrings(AppLanguage.kn);
      expect(strings.isKannada, isTrue);
      expect(strings.appTitle, 'ವೆಟಿಫೈ');
      expect(strings.appSubtitle, 'ಪಶುವೈದ್ಯಕೀಯ ಡೋಸ್ ಕ್ಯಾಲ್ಕುಲೇಟರ್');
      expect(strings.searchHint, 'ಔಷಧಿಗಳನ್ನು ಹುಡುಕಿ...');
      expect(strings.speciesName('dog'), 'ನಾಯಿ (Dog)');
      expect(strings.speciesName('cat'), 'ಬೆಕ್ಕು (Cat)');
      expect(strings.calculateDose, 'ಡೋಸ್ ಲೆಕ್ಕಾಚಾರ ಮಾಡಿ');
      expect(strings.criSectionTitle, 'ನಿರಂತರ ದರ ಇನ್ಫ್ಯೂಷನ್ (CRI)');
      expect(strings.criResultHeader, 'CRI ಲೆಕ್ಕಾಚಾರ ಫಲಿತಾಂಶ');
      expect(strings.addToBag, 'ಬ್ಯಾಗ್‌ಗೆ ಸೇರಿಸಿ');
    });

    test('LanguageController toggles and saves preference', () async {
      SharedPreferences.setMockInitialValues({});
      final controller = LanguageController();
      await controller.init();

      expect(controller.language, AppLanguage.en);

      // Toggle to Kannada
      await controller.toggleLanguage();
      expect(controller.language, AppLanguage.kn);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('vetifi_selected_language'), 'kn');

      // Toggle back to English
      await controller.toggleLanguage();
      expect(controller.language, AppLanguage.en);
      expect(prefs.getString('vetifi_selected_language'), 'en');

      // Explicit set
      await controller.setLanguage(AppLanguage.kn);
      expect(controller.language, AppLanguage.kn);
    });

    test('LanguageController restores persisted language on init', () async {
      SharedPreferences.setMockInitialValues({'vetifi_selected_language': 'kn'});
      final controller = LanguageController();
      await controller.init();

      expect(controller.language, AppLanguage.kn);
    });
  });
}
