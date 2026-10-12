/// Multi-language strings for Vetifi in English and Kannada (ಕನ್ನಡ).
library;

import 'app_language.dart';

class AppStrings {
  final AppLanguage language;
  const AppStrings(this.language);

  bool get isKannada => language == AppLanguage.kn;

  // General App
  String get appTitle => isKannada ? 'ವೆಟಿಫೈ' : 'Vetifi';
  String get appSubtitle => isKannada
      ? 'ಪಶುವೈದ್ಯಕೀಯ ಡೋಸ್ ಕ್ಯಾಲ್ಕುಲೇಟರ್'
      : 'Veterinary Dose Calculator';

  // Home Screen & Search
  String get searchHint => isKannada ? 'ಔಷಧಿಗಳನ್ನು ಹುಡುಕಿ...' : 'Search drugs...';
  String drugCount(int count) => isKannada
      ? '$count ಔಷಧಿಗಳು'
      : '$count drug${count == 1 ? '' : 's'}';
  String datasetVersion(String v) => isKannada ? 'ಡೇಟಾಸೆಟ್ $v' : 'Dataset $v';
  String get noDrugsFound => isKannada ? 'ಯಾವ ಔಷಧಿಯೂ ಕಂಡುಬಂದಿಲ್ಲ' : 'No drugs found';
  String get tryDifferentSearch => isKannada
      ? 'ಬೇರೆ ಹೆಸರನ್ನು ಟೈಪ್ ಮಾಡಿ'
      : 'Try a different search term';
  String get offlineReady => isKannada ? 'ಆಫ್‌ಲೈನ್ ಲಭ್ಯವಿದೆ' : 'Offline Ready';

  // Drug Card
  String get route => isKannada ? 'ಮಾರ್ಗ' : 'Route';
  String get concentration => isKannada ? 'ಸಾಂದ್ರತೆ' : 'Concentration';
  String get withdrawnTag => isKannada ? 'ಹಿಂಪಡೆಯಲಾಗಿದೆ' : 'Withdrawn';
  String get dataIssueTag => isKannada ? 'ದೋಷವಿದೆ' : 'Data issue';
  String get criBadge => isKannada ? 'CRI ಇನ್ಫ್ಯೂಷನ್' : 'IV CRI';

  // Calculator Screen
  String get drugWithdrawnTitle => isKannada ? 'ಔಷಧಿ ಹಿಂಪಡೆಯಲಾಗಿದೆ' : 'Drug Withdrawn';
  String get drugWithdrawnDefaultMsg => isKannada
      ? 'ಈ ಔಷಧಿಯನ್ನು ಹಿಂಪಡೆಯಲಾಗಿದೆ ಮತ್ತು ಡೋಸ್ ಲೆಕ್ಕಹಾಕಲಾಗುವುದಿಲ್ಲ.'
      : 'This drug has been withdrawn and cannot be calculated.';
  String get dataIssueTitle => isKannada ? 'ಡೇಟಾ ದೋಷ' : 'Data Issue';
  String get cannotCalculateTitle => isKannada ? 'ಲೆಕ್ಕಾಚಾರ ಸಾಧ್ಯವಿಲ್ಲ' : 'Cannot Calculate';
  String get species => isKannada ? 'ಪ್ರಾಣಿ' : 'Species';
  String get selectSpeciesPrompt => isKannada
      ? 'ದಯವಿಟ್ಟು ಪ್ರಾಣಿಯನ್ನು ಆಯ್ಕೆಮಾಡಿ'
      : 'Please select a species';

  // Species Names
  String speciesName(String key) {
    final lower = key.trim().toLowerCase();
    if (lower == 'dog' || lower == 'canine') return isKannada ? 'ನಾಯಿ (Dog)' : 'Dog';
    if (lower == 'cat' || lower == 'feline') return isKannada ? 'ಬೆಕ್ಕು (Cat)' : 'Cat';
    return key;
  }

  // Weight Input
  String get bodyWeight => isKannada ? 'ದೇಹದ ತೂಕ' : 'Body Weight';
  String get enterWeightHint => isKannada ? 'ಉದಾ: 12.5' : 'e.g. 12.5';
  String get kg => isKannada ? 'ಕೆ.ಜಿ (kg)' : 'kg';
  String get lb => isKannada ? 'ಪೌಂಡ್ (lb)' : 'lb';
  String get weightEmptyError => isKannada ? 'ದಯವಿಟ್ಟು ತೂಕ ನಮೂದಿಸಿ' : 'Please enter a weight';
  String get calculateDose => isKannada ? 'ಡೋಸ್ ಲೆಕ್ಕಾಚಾರ ಮಾಡಿ' : 'Calculate Dose';

  // Standard Dose Results
  String get resultHeader => isKannada ? 'ಲೆಕ್ಕಹಾಕಿದ ಡೋಸ್ ಶ್ರೇಣಿ' : 'Dose Result';
  String get volumeToAdminister => isKannada
      ? 'ನೀಡಬೇಕಾದ ವಾಲ್ಯೂಮ್ (ಪ್ರಮಾಣ)'
      : 'Volume to Administer';
  String get totalDoseMg => isKannada ? 'ಒಟ್ಟು ಡೋಸ್ (Active Dose)' : 'Total Dose';
  String get maxCappedAlert => isKannada
      ? 'ಗರಿಷ್ಠ ಸುರಕ್ಷಿತ ಮಿತಿಗೆ ಸೀಮಿತಗೊಳಿಸಲಾಗಿದೆ (Capped at maximum safe limit)'
      : 'Dose capped at maximum safe limit';
  String get precisionWarning => isKannada
      ? 'ನಿಖರತೆ ಎಚ್ಚರಿಕೆ: ಸೂಕ್ಷ್ಮ ಡೋಸ್. 0.3/0.5 mL ಇನ್ಸುಲಿನ್ ಅಥವಾ ಟ್ಯೂಬರ್ಕ್ಯುಲಿನ್ ಸಿರಿಂಜ್ ಬಳಸಿ.'
      : 'Precision Alert: Small volume. Use 0.3 mL or 0.5 mL tuberculin syringe.';
  String get syringeRecommendation => isKannada
      ? 'ಸಿರಿಂಜ್ ಶಿಫಾರಸು'
      : 'Syringe Recommendation';

  // CRI Results
  String get criSectionTitle => isKannada
      ? 'ನಿರಂತರ ದರ ಇನ್ಫ್ಯೂಷನ್ (CRI)'
      : 'Constant Rate Infusion (CRI)';
  String get doseRateLabel => isKannada
      ? 'ಡೋಸ್ ದರ (mcg/kg/min)'
      : 'Dose Rate (mcg/kg/min)';
  String get fluidRateLabel => isKannada
      ? 'ದ್ರವ ದರ (mL/hr)'
      : 'Fluid Rate (mL/hr)';
  String get bagSizeLabel => isKannada
      ? 'ಬ್ಯಾಗ್ ಗಾತ್ರ (mL)'
      : 'Bag Size (mL)';
  String get enterValidDoseRate => isKannada
      ? 'ದಯವಿಟ್ಟು ಮಾನ್ಯವಾದ ಡೋಸ್ ದರ ನಮೂದಿಸಿ'
      : 'Please enter a valid dose rate';
  String get enterValidFluidRate => isKannada
      ? 'ದಯವಿಟ್ಟು ಮಾನ್ಯವಾದ ದ್ರವ ದರ ನಮೂದಿಸಿ'
      : 'Please enter a valid fluid rate';
  String get enterValidBagSize => isKannada
      ? 'ದಯವಿಟ್ಟು ಮಾನ್ಯವಾದ ಬ್ಯಾಗ್ ಗಾತ್ರ ನಮೂದಿಸಿ'
      : 'Please enter a valid bag size';
  String get drugVolumeToAdd => isKannada
      ? 'ಬ್ಯಾಗ್‌ಗೆ ಸೇರಿಸಬೇಕಾದ ಔಷಧಿ ಪ್ರಮಾಣ'
      : 'Volume of Drug to Add';
  String get bagDuration => isKannada ? 'ಬ್ಯಾಗ್ ಬಾಳಿಕೆ ಅವಧಿ' : 'Bag Duration';
  String get hours => isKannada ? 'ಗಂಟೆಗಳು' : 'hours';
  String get nominalConcInBag => isKannada
      ? 'ಬ್ಯಾಗ್‌ನಲ್ಲಿ ಔಷಧಿ ಸಾಂದ್ರತೆ'
      : 'Concentration in Bag';
  String get bagWithdrawalTip => isKannada
      ? 'ಸೂಚನೆ: ನಿಖರ ಸಾಂದ್ರತೆಗಾಗಿ ಔಷಧಿ ಸೇರಿಸುವ ಮೊದಲು ಅಷ್ಟೇ ಪ್ರಮಾಣದ ದ್ರವವನ್ನು ಬ್ಯಾಗ್‌ನಿಂದ ತೆಗೆಯಿರಿ.'
      : 'Tip: Withdraw equivalent volume from bag before injecting drug to preserve precise concentration.';

  String get criResultHeader =>
      isKannada ? 'CRI ಲೆಕ್ಕಾಚಾರ ಫಲಿತಾಂಶ' : 'CRI Result';
  String get addToBag => isKannada ? 'ಬ್ಯಾಗ್‌ಗೆ ಸೇರಿಸಿ' : 'ADD TO BAG';
  String get doseRate => isKannada ? 'ಡೋಸ್ ದರ' : 'Dose rate';
  String get fluidRate => isKannada ? 'ದ್ರವ ದರ' : 'Fluid rate';
  String get bagSize => isKannada ? 'ಬ್ಯಾಗ್ ಗಾತ್ರ' : 'Bag size';

  // Language Switcher
  String get currentLanguageLabel => isKannada ? 'ಕನ್ನಡ' : 'English';
  String get toggleLanguagePrompt => isKannada ? 'Switch to English' : 'ಕನ್ನಡಕ್ಕೆ ಬದಲಾಯಿಸಿ';
}
