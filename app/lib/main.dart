import 'package:flutter/material.dart';

// Multi-language import commented out for now:
// import 'l10n/app_language.dart';
import 'screens/home_screen.dart';
import 'theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Multi-language disabled for now:
  // await LanguageController.instance.init();
  runApp(const VetifiApp());
}

class VetifiApp extends StatelessWidget {
  const VetifiApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Multi-language dynamic switching commented out for now:
    // return ValueListenableBuilder<AppLanguage>(
    //   valueListenable: LanguageController.instance.currentLanguage,
    //   builder: (context, lang, _) {
    //     return MaterialApp(
    //       title: lang == AppLanguage.kn
    //           ? 'ವೆಟಿಫೈ - ಪಶುವೈದ್ಯಕೀಯ ಡೋಸ್ ಕ್ಯಾಲ್ಕುಲೇಟರ್'
    //           : 'Vetifi - Drug Dose Calculator',
    //       debugShowCheckedModeBanner: false,
    //       theme: VetifiTheme.themeFor(lang),
    //       home: const HomeScreen(),
    //     );
    //   },
    // );
    return MaterialApp(
      title: 'Vetifi - Drug Dose Calculator',
      debugShowCheckedModeBanner: false,
      theme: VetifiTheme.theme,
      home: const HomeScreen(),
    );
  }
}
