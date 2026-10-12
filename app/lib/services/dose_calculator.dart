/// Dose calculation service.
///
/// All calculation logic is here, including unit conversion,
/// weight parsing, and safety checks. No network calls.
library;

import '../models/drug.dart';

// ---------------------------------------------------------------------------
// Weight parsing
// ---------------------------------------------------------------------------

/// Result of parsing a weight input.
class ParsedWeight {
  final double kg;
  final double originalValue;
  final String originalUnit;

  const ParsedWeight({
    required this.kg,
    required this.originalValue,
    required this.originalUnit,
  });

  /// True when the weight is outside the range a dog or cat normally occupies,
  /// but still physiologically possible. Shown as an advisory rather than
  /// refused: a 0.8 kg animal is real, it is just unusual to see labelled "dog".
  bool get isPhysiologicallyUnusual =>
      kg < kAdvisoryMinWeightKg || kg > kAdvisoryMaxWeightKg;

  String? get advisory {
    if (!isPhysiologicallyUnusual) return null;
    if (kg < kAdvisoryMinWeightKg) {
      return 'Weight is below the usual range for dogs and cats. If this is a '
          'kitten or a neonatal, check the species and the dose reference used.';
    }
    return 'Weight is above the usual range for dogs and cats. Check that the '
        'weight was entered in the right unit.';
  }
}

/// Parses a weight string entered by the user.
///
/// Accepts a decimal point or a decimal comma, since both are common in the
/// field. Rejects values outside [kAbsoluteMinWeightKg]..[kAbsoluteMaxWeightKg],
/// which no real patient spans.
///
/// Returns a record whose `error` is non-null when the input cannot be used.
({ParsedWeight? weight, String? error}) parseWeight(
  String input,
  String unit,
) {
  if (input.trim().isEmpty) {
    return (weight: null, error: 'Please enter a weight');
  }

  // Replace comma decimal separator.
  final normalised = input.trim().replaceAll(',', '.');

  // A comma used as a thousands separator ("1,200") would normalise to
  // "1.200", which parses as 1.2. Reject more than one separator outright
  // rather than guessing which convention the user meant.
  if ('.'.allMatches(normalised).length > 1) {
    return (
      weight: null,
      error: 'Invalid number "$input": use one decimal separator, '
          'for example 4.5 or 4,5',
    );
  }

  final value = double.tryParse(normalised);
  if (value == null) {
    return (weight: null, error: 'Invalid number: "$input"');
  }

  if (value.isNaN || value.isInfinite) {
    return (weight: null, error: 'Invalid weight value');
  }

  if (value <= 0) {
    return (weight: null, error: 'Weight must be greater than zero');
  }

  // Convert to kg.
  final double kg;
  final unitLower = unit.trim().toLowerCase();
  if (unitLower == 'kg' || unitLower == 'kgs') {
    kg = value;
  } else if (unitLower == 'lb' || unitLower == 'lbs') {
    // Exact definition: 1 lb = 0.45359237 kg. Using 2.2 introduces a 0.21%
    // systematic error, which is small but pointless when the exact factor is
    // a constant away.
    kg = value * 0.45359237;
  } else {
    return (weight: null, error: 'Unknown weight unit: "$unit"');
  }

  if (!kg.isFinite) {
    return (weight: null, error: 'Invalid weight value');
  }

  if (kg > kAbsoluteMaxWeightKg) {
    return (
      weight: null,
      error: 'Weight exceeds ${kAbsoluteMaxWeightKg.toStringAsFixed(0)} kg',
    );
  }

  if (kg < kAbsoluteMinWeightKg) {
    return (
      weight: null,
      error: 'Weight is below $kAbsoluteMinWeightKg kg',
    );
  }

  return (
    weight: ParsedWeight(kg: kg, originalValue: value, originalUnit: unit),
    error: null,
  );
}

// ---------------------------------------------------------------------------
// Dose calculation result
// ---------------------------------------------------------------------------

class DoseResult {
  final double doseMinMg;
  final double doseMaxMg;
  final double volumeMinMl;
  final double volumeMaxMl;
  final double concentrationMgPerMl;
  final String concentrationDisplay;
  final double weightKg;
  final String doseUnit;
  final bool maxTotalCapped;
  final double? originalDoseMaxMg; // Before capping
  final double? originalVolumeMaxMl; // Before capping

  /// Non-fatal clinical advisories to show alongside the result.
  final List<String> advisories;

  const DoseResult({
    required this.doseMinMg,
    required this.doseMaxMg,
    required this.volumeMinMl,
    required this.volumeMaxMl,
    required this.concentrationMgPerMl,
    required this.concentrationDisplay,
    required this.weightKg,
    required this.doseUnit,
    this.maxTotalCapped = false,
    this.originalDoseMaxMg,
    this.originalVolumeMaxMl,
    this.advisories = const [],
  });

  /// True when the smaller of the two volumes is below what the smallest
  /// commonly available syringe can measure.
  ///
  /// Drives the "dilute before drawing up" advisory in DECISIONS.md Q1.
  bool get isSubMeasurable => volumeMinMl < kMinMeasurableVolumeMl;
}

// ---------------------------------------------------------------------------
// CRI calculation result
// ---------------------------------------------------------------------------

class CriResult {
  final double mlToAdd;
  final double bagDurationMinutes;
  final double doseRate; // mcg/kg/min
  final double weightKg;
  final double fluidRateMlHr;
  final double bagSizeMl;
  final double concentrationMgPerMl;
  final String concentrationDisplay;

  /// Non-fatal clinical advisories, e.g. dilution or an out-of-range rate.
  final List<String> advisories;

  const CriResult({
    required this.mlToAdd,
    required this.bagDurationMinutes,
    required this.doseRate,
    required this.weightKg,
    required this.fluidRateMlHr,
    required this.bagSizeMl,
    required this.concentrationMgPerMl,
    required this.concentrationDisplay,
    this.advisories = const [],
  });

  double get bagDurationHours => bagDurationMinutes / 60;

  /// Fraction of the final bag volume contributed by the drug itself.
  ///
  /// This is the number that decides whether adding the drug meaningfully
  /// dilutes the bag. Answered in DECISIONS.md Q3.
  double get drugVolumeFraction =>
      bagSizeMl + mlToAdd <= 0 ? 0 : mlToAdd / (bagSizeMl + mlToAdd);

  /// Concentration the patient actually receives, accounting for the volume
  /// the drug adds to the bag.
  double get deliveredConcentrationMgPerMl {
    final total = bagSizeMl + mlToAdd;
    return total <= 0 ? 0 : (mlToAdd * concentrationMgPerMl) / total;
  }

  /// Concentration if the bag volume were not increased by the drug, i.e. the
  /// concentration the prescriber intended.
  double get nominalConcentrationMgPerMl {
    return bagSizeMl <= 0 ? 0 : (mlToAdd * concentrationMgPerMl) / bagSizeMl;
  }

  /// Relative underdose caused by the drug's own volume, as a fraction.
  ///
  /// 0.0 means no dilution; 0.1 means the patient receives 10% less drug per
  /// mL than intended.
  double get dilutionErrorFraction {
    final nominal = nominalConcentrationMgPerMl;
    if (nominal <= 0) return 0;
    return (nominal - deliveredConcentrationMgPerMl) / nominal;
  }
}

// ---------------------------------------------------------------------------
// Calculator service
// ---------------------------------------------------------------------------

class DoseCalculator {
  /// Calculate a standard bolus dose.
  ///
  /// Returns either a [DoseResult] or an error string.
  static ({DoseResult? result, String? error}) calculate({
    required Drug drug,
    required String species,
    required double weightKg,
  }) {
    // Check for withdrawn drug
    final speciesErr = drug.speciesError(species);
    if (speciesErr != null) {
      return (result: null, error: speciesErr);
    }

    final concentration = drug.concentration;
    if (concentration == null) {
      return (
        result: null,
        error: 'Invalid concentration: "${drug.concentrationRaw}"',
      );
    }

    final doseRange = drug.doses[species];
    if (doseRange == null) {
      return (result: null, error: 'No dose data for $species');
    }

    // Convert to mg/kg. Returns null for a unit we cannot convert with
    // confidence, and we refuse rather than assuming mg/kg: a g/kg entry read
    // as mg/kg is a 1000x underdose.
    final doseInMg = doseRange.toMgPerKg();
    if (doseInMg == null) {
      return (
        result: null,
        error: 'Unsupported dose unit "${doseRange.unit}" for $species. '
            'Cannot calculate safely.',
      );
    }

    // Calculate total dose in mg
    double doseMinMg = doseInMg.min * weightKg;
    double doseMaxMg = doseInMg.max * weightKg;

    // Apply max total cap if present
    bool capped = false;
    double? originalDoseMaxMg;
    double? originalVolumeMaxMl;

    if (drug.maxTotalMg != null) {
      if (doseMaxMg > drug.maxTotalMg!) {
        originalDoseMaxMg = doseMaxMg;
        doseMaxMg = drug.maxTotalMg!;
        capped = true;
      }
      if (doseMinMg > drug.maxTotalMg!) {
        originalDoseMaxMg ??= doseMinMg;
        doseMinMg = drug.maxTotalMg!;
        capped = true;
      }
    }

    // Calculate volume in mL
    final volumeMinMl = doseMinMg / concentration.mgPerMl;
    final volumeMaxMl = doseMaxMg / concentration.mgPerMl;

    if (capped && originalDoseMaxMg != null) {
      originalVolumeMaxMl = originalDoseMaxMg / concentration.mgPerMl;
    }

    final advisories = <String>[];

    // A volume below what a syringe can resolve must never be displayed as a
    // plain number. Previously this rounded to "0.000 mL", which reads as a
    // confident instruction to draw up nothing.
    if (volumeMaxMl < kMinMeasurableVolumeMl) {
      return (
        result: null,
        error: 'Required volume is below the measurable range of any syringe '
            '(${formatVolumeMl(volumeMaxMl)} mL). Dilute the drug before '
            'administering.',
      );
    }

    if (volumeMinMl < kMinMeasurableVolumeMl) {
      advisories.add(
        'Lower end of this range (${formatVolumeMl(volumeMinMl)} mL) is below '
        '1 mL. Use a 1 mL tuberculin syringe; a standard 3 mL syringe has '
        '0.1 mL graduations and cannot resolve this.',
      );
    } else if (volumeMinMl < kSmallVolumeThresholdMl) {
      advisories.add(
        'Small volume. Confirm the syringe has 0.01 mL graduations before '
        'drawing up.',
      );
    }

    // Rounding a large volume to one decimal place is a real dose change.
    // Say how much rather than letting the vet discover it.
    final roundingLossMl = volumeMaxMl - double.parse(volumeMaxMl.toStringAsFixed(1));
    if (volumeMaxMl > 10 && roundingLossMl.abs() / volumeMaxMl > 0.01) {
      advisories.add(
        'Rounding to 1 decimal place changes this volume by '
        '${formatVolumeMl(roundingLossMl.abs())} mL '
        '(${(roundingLossMl.abs() / volumeMaxMl * 100).toStringAsFixed(1)}%).',
      );
    }

    return (
      result: DoseResult(
        doseMinMg: doseMinMg,
        doseMaxMg: doseMaxMg,
        volumeMinMl: volumeMinMl,
        volumeMaxMl: volumeMaxMl,
        concentrationMgPerMl: concentration.mgPerMl,
        concentrationDisplay: concentration.original,
        weightKg: weightKg,
        doseUnit: doseRange.unit,
        maxTotalCapped: capped,
        originalDoseMaxMg: originalDoseMaxMg,
        originalVolumeMaxMl: originalVolumeMaxMl,
        advisories: advisories,
      ),
      error: null,
    );
  }

  /// Calculate a CRI (Constant Rate Infusion).
  ///
  /// Dimensional derivation, with every factor accounted for:
  ///
  ///   bag_duration_min = bag_size_ml / fluid_rate_ml_hr * 60 min/hr
  ///   total_drug_mcg   = dose_rate_mcg_kg_min * weight_kg * bag_duration_min
  ///   total_drug_mg    = total_drug_mcg / 1000 mcg/mg
  ///   ml_to_add        = total_drug_mg / concentration_mg_ml
  ///
  /// The 60 and the 1000 are the two factors most often dropped. Omitting 60
  /// underestimates by 60x; omitting 1000 overdoses by 1000x.
  static ({CriResult? result, String? error}) calculateCri({
    required Drug drug,
    required String species,
    required double weightKg,
    required double doseRate, // mcg/kg/min
    required double fluidRateMlHr, // mL/hr
    required double bagSizeMl, // mL
  }) {
    // Validate drug
    final concentration = drug.concentration;
    if (concentration == null) {
      return (
        result: null,
        error: 'Invalid concentration: "${drug.concentrationRaw}"',
      );
    }

    if (drug.isWithdrawn) {
      return (
        result: null,
        error:
            'This drug has been withdrawn${drug.withdrawnReason != null ? ': ${drug.withdrawnReason}' : ''}',
      );
    }

    // Check CRI data exists
    if (!drug.isCriDrug(species)) {
      return (result: null, error: 'No CRI data available for $species');
    }

    final criDose = drug.criDoses[species]!;

    final criUnitError = criDose.validationError;
    if (criUnitError != null) {
      return (result: null, error: criUnitError);
    }

    // Validate inputs
    if (!doseRate.isFinite || doseRate <= 0) {
      return (result: null, error: 'Dose rate must be greater than zero');
    }
    if (!fluidRateMlHr.isFinite || fluidRateMlHr <= 0) {
      return (result: null, error: 'Fluid rate must be greater than zero');
    }
    if (!bagSizeMl.isFinite || bagSizeMl <= 0) {
      return (result: null, error: 'Bag size must be greater than zero');
    }

    // Calculate bag duration in minutes
    final bagDurationMinutes = (bagSizeMl / fluidRateMlHr) * 60;

    // Calculate total drug needed in mg
    // dose_rate is in mcg/kg/min, convert to mg: ÷ 1000
    final totalDrugMg = (doseRate * weightKg * bagDurationMinutes) / 1000;

    // Calculate volume of drug solution to add
    final mlToAdd = totalDrugMg / concentration.mgPerMl;

    if (!mlToAdd.isFinite || mlToAdd <= 0) {
      return (result: null, error: 'Calculation produced an unusable volume');
    }

    final advisories = <String>[];

    // Out-of-range dose rate. We still compute it, because a vet may have a
    // legitimate clinical reason, but we never present it as a clean result.
    // Previously this check existed with an empty body and a comment saying it
    // would warn "for now", so a 500 mcg/kg/min rate against a 5-10 range
    // produced 187.5 mL with no indication anything was wrong.
    if (doseRate < criDose.min) {
      advisories.add(
        'Dose rate ${_trimNum(doseRate)} ${criDose.unit} is BELOW the '
        'validated range for $species (${_trimNum(criDose.min)}-'
        '${_trimNum(criDose.max)}). Confirm before use.',
      );
    } else if (doseRate > criDose.max) {
      advisories.add(
        'Dose rate ${_trimNum(doseRate)} ${criDose.unit} is ABOVE the '
        'validated range for $species (${_trimNum(criDose.min)}-'
        '${_trimNum(criDose.max)}). This is a '
        '${(doseRate / criDose.max).toStringAsFixed(1)}x overdose against '
        'the approved maximum. Confirm before use.',
      );
    }

    // Drug volume as a share of the finished bag. Answered in DECISIONS.md Q3.
    final totalVolume = bagSizeMl + mlToAdd;
    final drugFraction = totalVolume <= 0 ? 0.0 : mlToAdd / totalVolume;
    final underdosePercent = drugFraction <= 0
        ? 0.0
        : (1 - bagSizeMl / totalVolume) * 100;

    if (drugFraction > kDilutionWarningFraction) {
      advisories.add(
        'The drug adds ${formatVolumeMl(mlToAdd)} mL to a '
        '${formatVolumeMl(bagSizeMl)} mL bag, so the delivered concentration '
        'is ${underdosePercent.toStringAsFixed(1)}% below the intended '
        '${(totalDrugMg / bagSizeMl).toStringAsFixed(3)} mg/mL. Withdraw '
        '${formatVolumeMl(mlToAdd)} mL of fluid from the bag before adding '
        'the drug to hold the concentration.',
      );
    } else if (drugFraction > 0.005) {
      advisories.add(
        'The drug slightly increases the bag volume, reducing the delivered '
        'concentration by ${underdosePercent.toStringAsFixed(1)}%. Below the '
        'pump\'s usual +/-5% accuracy, so no action is needed.',
      );
    }

    if (mlToAdd > bagSizeMl) {
      advisories.add(
        'The drug volume exceeds the bag volume. Check the arithmetic and the '
        'chosen concentration.',
      );
    }

    if (mlToAdd < kMinMeasurableVolumeMl) {
      advisories.add(
        'The drug volume is below measurable syringe resolution. Dilute before '
        'adding to the bag.',
      );
    }

    return (
      result: CriResult(
        mlToAdd: mlToAdd,
        bagDurationMinutes: bagDurationMinutes,
        doseRate: doseRate,
        weightKg: weightKg,
        fluidRateMlHr: fluidRateMlHr,
        bagSizeMl: bagSizeMl,
        concentrationMgPerMl: concentration.mgPerMl,
        concentrationDisplay: concentration.original,
        advisories: advisories,
      ),
      error: null,
    );
  }

  /// Trims a trailing ".0" so advisory text reads "5" not "5.0".
  static String _trimNum(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }
}

// ---------------------------------------------------------------------------
// Clinical thresholds
// ---------------------------------------------------------------------------

/// The smallest volume a clinician can reliably measure and draw up.
///
/// A 1 mL tuberculin syringe is graduated at 0.01 mL. Anything below that is
/// not measurable in a syringe and must never be displayed as a number, since
/// a displayed number reads as an instruction.
const double kMinMeasurableVolumeMl = 0.01;

/// Below this, the syringe choice itself becomes clinically relevant.
const double kSmallVolumeThresholdMl = 0.1;

/// Drug volume as a fraction of the finished bag above which dilution is worth
/// warning about.
///
/// 2% is chosen because IV pumps are typically accurate to +/-5%; below that the
/// dilution error is inside the pump's own error band. Above it the app tells
/// the user how much fluid to withdraw first.
const double kDilutionWarningFraction = 0.02;

/// Weight below which a "dog" is more likely a mislabelled kitten or a
/// neonatal, and above which a "dog" is unusual enough to warrant a check.
const double kAdvisoryMinWeightKg = 1.0;
const double kAdvisoryMaxWeightKg = 60.0;

/// Physiological bounds. Outside these, the input is more likely a typo or a
/// unit error than a real animal.
const double kAbsoluteMinWeightKg = 0.01;
const double kAbsoluteMaxWeightKg = 1500.0;

// ---------------------------------------------------------------------------
// Volume formatting
// ---------------------------------------------------------------------------

/// Formats a volume in mL for display.
///
/// Rules:
/// - below measurable: rendered as "< 0.001", never as a rounded zero
/// - < 0.01 mL: 3 decimal places
/// - < 10 mL: 2 decimal places
/// - > 10 mL: 1 decimal place
///
/// Trailing zeros are kept in the significant range so that "2.50 mL" cannot
/// be misread as "2.5 mL" at a glance in a busy clinic.
String formatVolumeMl(double ml) {
  if (ml <= 0) {
    return '0.0';
  } else if (ml < 0.0005) {
    return '< 0.001';
  } else if (ml < 0.01) {
    return ml.toStringAsFixed(3);
  } else if (ml < 1) {
    return ml.toStringAsFixed(2);
  } else if (ml <= 10) {
    return ml.toStringAsFixed(2);
  } else {
    return ml.toStringAsFixed(1);
  }
}

/// Formats a dose in mg for display.
String formatDoseMg(double mg) {
  if (mg < 0.01) {
    return mg.toStringAsFixed(4);
  } else if (mg < 1) {
    return mg.toStringAsFixed(3);
  } else if (mg < 10) {
    return mg.toStringAsFixed(2);
  } else if (mg < 100) {
    return mg.toStringAsFixed(1);
  } else {
    return mg.toStringAsFixed(0);
  }
}

/// Formats a time duration in minutes to a human-readable string.
String formatDuration(double minutes) {
  if (minutes < 60) {
    return '${minutes.toStringAsFixed(0)} min';
  }
  final hours = (minutes / 60).floor();
  final mins = (minutes % 60).round();
  if (mins == 0) {
    return '$hours hr';
  }
  return '$hours hr $mins min';
}
