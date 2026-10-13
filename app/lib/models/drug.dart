/// Models for the Vetifi drug dose calculator.
///
/// Handles parsing, validation, and representation of drug data
/// from the dataset, including all known data quality issues.
library;

import 'dart:convert';

// ---------------------------------------------------------------------------
// Concentration parser
// ---------------------------------------------------------------------------

/// Parsed concentration result in mg/mL.
class ParsedConcentration {
  final double mgPerMl;
  final String original;

  const ParsedConcentration({required this.mgPerMl, required this.original});

  @override
  String toString() => original;
}

/// Parses concentration strings like "50 mg/mL" or "10%" into mg/mL.
///
/// Handles:
/// - "X mg/mL" format
/// - "X%" format (w/v percentage: 1% = 10 mg/mL)
/// - Returns null for unparseable or zero/negative concentrations.
ParsedConcentration? parseConcentration(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  // Try percentage format: "10%" means 10 g per 100 mL = 100 mg/mL.
  // Above 100% w/v is physically impossible and always a data-entry error.
  // (Dart \d is ASCII-only, matching the server's ASCII-only patterns, so a
  // string with Unicode digits fails here exactly as it fails there.)
  final pctMatch = RegExp(r'^(\d+\.?\d*)\s*%$').firstMatch(trimmed);
  if (pctMatch != null) {
    final pct = double.tryParse(pctMatch.group(1)!);
    if (pct == null || pct <= 0 || pct > 100) return null;
    final mgPerMl = pct * 10; // 1% w/v = 10 mg/mL
    return ParsedConcentration(mgPerMl: mgPerMl, original: trimmed);
  }

  // Try "X mg/mL" format
  final mgMlMatch =
      RegExp(r'^(\d+\.?\d*)\s*mg\s*/\s*m[lL]$', caseSensitive: false)
          .firstMatch(trimmed);
  if (mgMlMatch != null) {
    final val = double.tryParse(mgMlMatch.group(1)!);
    if (val == null || val <= 0) return null;
    return ParsedConcentration(mgPerMl: val, original: trimmed);
  }

  return null;
}

// ---------------------------------------------------------------------------
// Species normalisation
// ---------------------------------------------------------------------------

/// Normalises species keys to canonical form.
/// "Dog", "DOG", "dog" → "dog"
/// "feline", "Feline", "cat", "Cat" → "cat"
String? normaliseSpecies(String raw) {
  final lower = raw.trim().toLowerCase();
  if (lower == 'dog' || lower == 'canine') return 'dog';
  if (lower == 'cat' || lower == 'feline') return 'cat';
  return lower; // preserve unknown species as-is
}

// ---------------------------------------------------------------------------
// Unit vocabulary (shared with server/app/validator.py)
// ---------------------------------------------------------------------------

/// Units a bolus dose may be expressed in.
///
/// This set is duplicated in server/app/validator.py. Change both together.
/// An unrecognised unit is refused rather than assumed to be mg/kg: a dataset
/// expressed in g/kg computed as mg/kg is a 1000x underdose, and one expressed
/// in mcg/kg/min computed as mg/kg is a 1000x overdose. Neither is acceptable
/// as a silent fallback.
const Set<String> kSupportedDoseUnits = {'mg/kg', 'mcg/kg'};

/// Units a constant rate infusion may be expressed in.
const Set<String> kSupportedCriUnits = {'mcg/kg/min'};

/// Normalises a unit string for comparison against the supported sets.
///
/// Returns null when the unit is not one we can compute with confidence. The
/// server performs the identical normalisation so that the two accept exactly
/// the same vocabulary and the rules cannot drift apart.
String? canonicalDoseUnit(String? raw) {
  if (raw == null) return null;
  final normalised = raw.trim().toLowerCase();
  if (kSupportedDoseUnits.contains(normalised) ||
      kSupportedCriUnits.contains(normalised)) {
    return normalised;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Dose range model
// ---------------------------------------------------------------------------

class DoseRange {
  final double min;
  final double max;
  final String unit; // canonical: "mg/kg" or "mcg/kg"

  const DoseRange({required this.min, required this.max, required this.unit});

  /// Converts the dose to mg/kg, or returns null if the unit is not one we can
  /// convert with confidence.
  DoseRange? toMgPerKg() {
    switch (unit) {
      case 'mg/kg':
        return this;
      case 'mcg/kg':
        return DoseRange(min: min / 1000, max: max / 1000, unit: 'mg/kg');
      default:
        return null;
    }
  }

  /// Whether this dose range is valid and computable (unit understood,
  /// min <= max, both positive).
  bool get isValid => validationError == null;

  /// Validation error message, or null if valid.
  String? get validationError {
    if (!kSupportedDoseUnits.contains(unit)) {
      return 'Unsupported dose unit "$unit" '
          '(expected ${kSupportedDoseUnits.join(' or ')})';
    }
    // NaN passes every comparison (NaN <= 0 and NaN > max are both false),
    // so it must be rejected explicitly rather than by the range checks.
    if (!min.isFinite || !max.isFinite) {
      return 'Dose values must be finite numbers';
    }
    if (min <= 0 || max <= 0) return 'Dose values must be positive';
    if (min > max) return 'Minimum dose ($min) exceeds maximum dose ($max)';
    return null;
  }

  factory DoseRange.fromJson(Map<String, dynamic> json) {
    final rawUnit = json['unit'];
    return DoseRange(
      min: (json['min'] as num).toDouble(),
      max: (json['max'] as num).toDouble(),
      unit: canonicalDoseUnit(rawUnit as String?) ?? '$rawUnit',
    );
  }

  Map<String, dynamic> toJson() => {'min': min, 'max': max, 'unit': unit};
}

// ---------------------------------------------------------------------------
// CRI dose model
// ---------------------------------------------------------------------------

class CriDose {
  final double min;
  final double max;
  final String unit; // "mcg/kg/min"

  const CriDose({required this.min, required this.max, required this.unit});

  bool get isValid => validationError == null;

  String? get validationError {
    if (!kSupportedCriUnits.contains(unit)) {
      return 'Unsupported CRI unit "$unit" '
          '(expected ${kSupportedCriUnits.join(' or ')})';
    }
    if (!min.isFinite || !max.isFinite) {
      return 'CRI dose values must be finite numbers';
    }
    if (min <= 0 || max <= 0) return 'CRI dose values must be positive';
    if (min > max) {
      return 'Minimum CRI dose ($min) exceeds maximum ($max)';
    }
    return null;
  }

  factory CriDose.fromJson(Map<String, dynamic> json) {
    final rawUnit = json['unit'];
    return CriDose(
      min: (json['min'] as num).toDouble(),
      max: (json['max'] as num).toDouble(),
      unit: canonicalDoseUnit(rawUnit as String?) ?? '$rawUnit',
    );
  }

  Map<String, dynamic> toJson() => {'min': min, 'max': max, 'unit': unit};
}

// ---------------------------------------------------------------------------
// Drug model
// ---------------------------------------------------------------------------

class Drug {
  final String id;
  final String name; // Trimmed on parse
  final String rawName; // Original name from dataset
  final String concentrationRaw;
  final ParsedConcentration? concentration;
  final String route;
  final double? maxTotalMg;
  final Map<String, DoseRange> doses; // Normalised species keys
  final Map<String, CriDose> criDoses; // CRI doses if present
  final bool isWithdrawn;
  final String? withdrawnReason;
  final List<String> validationErrors;

  Drug({
    required this.id,
    required this.name,
    required this.rawName,
    required this.concentrationRaw,
    required this.concentration,
    required this.route,
    this.maxTotalMg,
    required this.doses,
    required this.criDoses,
    this.isWithdrawn = false,
    this.withdrawnReason,
    required this.validationErrors,
  });

  /// Whether the drug has any global issues that prevent all calculations.
  bool get hasGlobalError =>
      validationErrors.isNotEmpty || concentration == null;

  /// Whether a specific species can be calculated.
  String? speciesError(String species) {
    if (isWithdrawn) {
      return 'This drug has been withdrawn${withdrawnReason != null ? ': $withdrawnReason' : ''}';
    }
    if (concentration == null) {
      return 'Invalid concentration: "$concentrationRaw"';
    }
    if (validationErrors.isNotEmpty) {
      return validationErrors.first;
    }

    // Check for CRI drug
    if (criDoses.isNotEmpty && !doses.containsKey(species)) {
      if (!criDoses.containsKey(species)) {
        return 'No CRI dose data available for $species';
      }
      final criDose = criDoses[species]!;
      final criError = criDose.validationError;
      if (criError != null) return criError;
      return null; // CRI is valid
    }

    if (!doses.containsKey(species)) {
      return 'No dose data available for $species';
    }
    final doseRange = doses[species]!;
    final doseError = doseRange.validationError;
    if (doseError != null) return doseError;
    return null;
  }

  /// Whether this drug is a CRI drug for a given species.
  bool isCriDrug(String species) {
    return criDoses.containsKey(species) && criDoses[species] != null;
  }

  /// Whether this is a CRI-only drug (no standard bolus doses).
  bool get isCriOnly => criDoses.isNotEmpty && doses.isEmpty;

  /// All species this drug has data for (standard + CRI combined).
  Set<String> get availableSpecies {
    return {...doses.keys, ...criDoses.keys};
  }

  /// Display name combining name + route for disambiguation.
  String get displayName {
    return '$name ($route)';
  }

  /// Parse a drug entry from a dataset JSON map.
  ///
  /// Total: mistyped scalars become validation errors, never throws. The
  /// update path treats an unreadable entry as a malformed payload, but the
  /// bundled base dataset goes through here too, so a throw would be a crash
  /// on launch rather than a refused update.
  factory Drug.fromJson(Map<String, dynamic> json) {
    final List<String> errors = [];

    // `as String?` throws on a non-string (e.g. an int id), turning a data
    // problem into a crash. Read defensively and report instead.
    final id = json['id'] is String ? json['id'] as String : '';
    final rawName = json['name'] is String ? json['name'] as String : '';
    final name = rawName.trim();
    final concentrationRaw =
        json['concentration'] is String ? json['concentration'] as String : '';
    final concentration = parseConcentration(concentrationRaw);
    final route = json['route'] is String ? json['route'] as String : '';

    double? maxTotalMg;
    final maxTotalRaw = json['max_total_mg'];
    if (maxTotalRaw != null) {
      // `is num` excludes bool: max_total_mg=true would otherwise throw here
      // (or worse, publish as 1 mg on a Python server that accepts bools).
      final maxTotalValue =
          maxTotalRaw is num ? maxTotalRaw.toDouble() : double.nan;
      if (maxTotalValue.isFinite && maxTotalValue > 0) {
        maxTotalMg = maxTotalValue;
      } else {
        errors.add('max_total_mg must be a positive finite number');
      }
    }

    if (id.isEmpty) errors.add('Missing drug ID');
    if (name.isEmpty) errors.add('Missing drug name');
    if (route.isEmpty) errors.add('Missing route');
    if (concentration == null && concentrationRaw.isNotEmpty) {
      // Don't add as a validation error that prevents ALL calculations;
      // let speciesError handle it so it's clearer to the user.
    } else if (concentrationRaw.isEmpty) {
      errors.add('Missing concentration');
    }

    // Parse standard doses with species normalisation
    final Map<String, DoseRange> doses = {};
    final seenDoseSpecies = <String>{};
    if (json['doses'] is Map<String, dynamic>) {
      final dosesMap = json['doses'] as Map<String, dynamic>;
      for (final entry in dosesMap.entries) {
        final normSpecies = normaliseSpecies(entry.key);
        if (normSpecies == null) continue;
        if (entry.value == null) continue; // Explicitly null species dose
        // "Dog" and "dog" would overwrite each other silently. The server
        // refuses this at publish time; flag it here too for datasets that
        // predate the check.
        if (!seenDoseSpecies.add(normSpecies)) {
          errors.add(
            'Duplicate dose entry for "$normSpecies" ("${entry.key}")',
          );
        }
        if (entry.value is Map<String, dynamic>) {
          try {
            doses[normSpecies] = DoseRange.fromJson(
              entry.value as Map<String, dynamic>,
            );
          } catch (e) {
            errors.add('Invalid dose data for $normSpecies: $e');
          }
        }
      }
    }

    // Parse CRI doses
    final Map<String, CriDose> criDoses = {};
    final seenCriSpecies = <String>{};
    if (json['cri'] is Map<String, dynamic>) {
      final criMap = json['cri'] as Map<String, dynamic>;
      for (final entry in criMap.entries) {
        final normSpecies = normaliseSpecies(entry.key);
        if (normSpecies == null) continue;
        if (entry.value == null) continue;
        if (!seenCriSpecies.add(normSpecies)) {
          errors.add(
            'Duplicate CRI entry for "$normSpecies" ("${entry.key}")',
          );
        }
        if (entry.value is Map<String, dynamic>) {
          try {
            criDoses[normSpecies] = CriDose.fromJson(
              entry.value as Map<String, dynamic>,
            );
          } catch (e) {
            errors.add('Invalid CRI data for $normSpecies: $e');
          }
        }
      }
    }

    if (doses.isEmpty && criDoses.isEmpty) {
      errors.add('No usable dose data: "doses" and "cri" are both empty');
    }

    final isWithdrawn = json['is_withdrawn'] is bool
        ? json['is_withdrawn'] as bool
        : false;
    final withdrawnReason = json['withdrawn_reason'] is String
        ? json['withdrawn_reason'] as String
        : null;

    return Drug(
      id: id,
      name: name,
      rawName: rawName,
      concentrationRaw: concentrationRaw,
      concentration: concentration,
      route: route,
      maxTotalMg: maxTotalMg,
      doses: doses,
      criDoses: criDoses,
      isWithdrawn: isWithdrawn,
      withdrawnReason: withdrawnReason,
      validationErrors: errors,
    );
  }

  /// Serialize to JSON for storage.
  Map<String, dynamic> toJson() {
    final map = <String, dynamic>{
      'id': id,
      'name': rawName,
      'concentration': concentrationRaw,
      'route': route,
      'doses': doses.map((k, v) => MapEntry(k, v.toJson())),
    };
    if (maxTotalMg != null) map['max_total_mg'] = maxTotalMg;
    if (criDoses.isNotEmpty) {
      map['cri'] = criDoses.map((k, v) => MapEntry(k, v.toJson()));
    }
    if (isWithdrawn) {
      map['is_withdrawn'] = true;
      if (withdrawnReason != null) map['withdrawn_reason'] = withdrawnReason;
    }
    return map;
  }

  /// Create a copy with withdrawn status.
  Drug copyWithWithdrawn({required String reason}) {
    return Drug(
      id: id,
      name: name,
      rawName: rawName,
      concentrationRaw: concentrationRaw,
      concentration: concentration,
      route: route,
      maxTotalMg: maxTotalMg,
      doses: doses,
      criDoses: criDoses,
      isWithdrawn: true,
      withdrawnReason: reason,
      validationErrors: validationErrors,
    );
  }
}

// ---------------------------------------------------------------------------
// Dataset model
// ---------------------------------------------------------------------------

class Dataset {
  final int schemaVersion;
  final String datasetVersion;
  final List<Drug> drugs;

  Dataset({
    required this.schemaVersion,
    required this.datasetVersion,
    required this.drugs,
  });

  factory Dataset.fromJson(Map<String, dynamic> json) {
    final schemaVersion = json['schema_version'] as int? ?? 1;
    final datasetVersion = json['dataset_version'] as String? ?? 'unknown';
    final drugsList = (json['drugs'] as List<dynamic>?)
            ?.map((d) => Drug.fromJson(d as Map<String, dynamic>))
            .toList() ??
        [];

    return Dataset(
      schemaVersion: schemaVersion,
      datasetVersion: datasetVersion,
      drugs: drugsList,
    );
  }

  Map<String, dynamic> toJson() => {
        'schema_version': schemaVersion,
        'dataset_version': datasetVersion,
        'drugs': drugs.map((d) => d.toJson()).toList(),
      };

  String toJsonString() => jsonEncode(toJson());
}

// ---------------------------------------------------------------------------
// Calculation log model
// ---------------------------------------------------------------------------

class CalculationLog {
  final String calcId; // UUID
  final String drugId;
  final String drugName;
  final String species;
  final double weightKg;
  final String weightUnit; // "kg" or "lb" (as entered)
  final double weightEntered; // original value entered
  final double doseMinMg;
  final double doseMaxMg;
  final double volumeMinMl;
  final double volumeMaxMl;
  final String datasetVersion;
  final DateTime timestamp;
  final bool uploaded;
  // CRI-specific fields (nullable)
  final double? doseRate;
  final double? fluidRateMlHr;
  final double? bagSizeMl;
  final double? mlToAdd;
  final double? bagDurationHrs;

  CalculationLog({
    required this.calcId,
    required this.drugId,
    required this.drugName,
    required this.species,
    required this.weightKg,
    required this.weightUnit,
    required this.weightEntered,
    required this.doseMinMg,
    required this.doseMaxMg,
    required this.volumeMinMl,
    required this.volumeMaxMl,
    required this.datasetVersion,
    required this.timestamp,
    this.uploaded = false,
    this.doseRate,
    this.fluidRateMlHr,
    this.bagSizeMl,
    this.mlToAdd,
    this.bagDurationHrs,
  });

  Map<String, dynamic> toJson() => {
        'calc_id': calcId,
        'drug_id': drugId,
        'drug_name': drugName,
        'species': species,
        'weight_kg': weightKg,
        'weight_unit': weightUnit,
        'weight_entered': weightEntered,
        'dose_min_mg': doseMinMg,
        'dose_max_mg': doseMaxMg,
        'volume_min_ml': volumeMinMl,
        'volume_max_ml': volumeMaxMl,
        'dataset_version': datasetVersion,
        'timestamp': timestamp.toIso8601String(),
        if (doseRate != null) 'dose_rate': doseRate,
        if (fluidRateMlHr != null) 'fluid_rate_ml_hr': fluidRateMlHr,
        if (bagSizeMl != null) 'bag_size_ml': bagSizeMl,
        if (mlToAdd != null) 'ml_to_add': mlToAdd,
        if (bagDurationHrs != null) 'bag_duration_hrs': bagDurationHrs,
      };

  Map<String, dynamic> toDbMap() => {
        ...toJson(),
        'uploaded': uploaded ? 1 : 0,
        'timestamp': timestamp.toIso8601String(),
      };
}
