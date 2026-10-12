/// Calculator screen for dose calculation.
///
/// Displays species selection, weight input, and dose/volume results.
/// Handles all data quality issues with clear error messages.
/// Also handles CRI calculations for CRI drugs.
library;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:uuid/uuid.dart';

import '../l10n/app_language.dart';
import '../l10n/strings.dart';
import '../models/drug.dart';
import '../services/dose_calculator.dart';
import '../services/database_service.dart';
import '../theme.dart';
import '../widgets/language_toggle_button.dart';

class CalculatorScreen extends StatefulWidget {
  final Drug drug;
  final String datasetVersion;

  const CalculatorScreen({
    super.key,
    required this.drug,
    required this.datasetVersion,
  });

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  final TextEditingController _weightController = TextEditingController();
  final TextEditingController _doseRateController = TextEditingController();
  final TextEditingController _fluidRateController = TextEditingController();
  final TextEditingController _bagSizeController = TextEditingController();
  
  String _weightUnit = 'kg';
  String? _selectedSpecies;
  DoseResult? _result;
  CriResult? _criResult;
  String? _error;
  String? _weightError;

  /// Set after a successful calculation when the weight is physiologically
  /// unusual. Surfaced beside the result rather than blocking the calculation:
  /// a 0.8 kg kitten is real, it is just unusual to see labelled "dog".
  String? _weightAdvisory;
  bool _calculated = false;

  @override
  void initState() {
    super.initState();
    // Auto-select species if only one available
    final species = widget.drug.availableSpecies.toList();
    if (species.length == 1) {
      _selectedSpecies = species.first;
    }
  }

  @override
  void dispose() {
    _weightController.dispose();
    _doseRateController.dispose();
    _fluidRateController.dispose();
    _bagSizeController.dispose();
    super.dispose();
  }

  bool get _isCriMode {
    if (_selectedSpecies == null) return false;
    return widget.drug.isCriDrug(_selectedSpecies!);
  }

  bool get _hasStandardDose {
    if (_selectedSpecies == null) return false;
    return widget.drug.doses.containsKey(_selectedSpecies);
  }

  void _calculate() {
    setState(() {
      _calculated = true;
      _result = null;
      _criResult = null;
      _error = null;
      _weightError = null;
      _weightAdvisory = null;
    });

    if (_selectedSpecies == null) {
      setState(() => _error = 'Please select a species');
      return;
    }

    // Check if drug is withdrawn
    if (widget.drug.isWithdrawn) {
      setState(() {
        final reason = widget.drug.withdrawnReason;
        _error = 'This drug has been withdrawn'
            '${reason != null ? ': $reason' : ''}';
      });
      return;
    }

    // Parse weight
    final weightResult = parseWeight(_weightController.text, _weightUnit);
    if (weightResult.error != null) {
      setState(() => _weightError = weightResult.error);
      return;
    }
    final weight = weightResult.weight!;
    if (weight.advisory != null) {
      setState(() => _weightAdvisory = weight.advisory);
    }

    if (_isCriMode) {
      _calculateCri(weight);
    } else if (_hasStandardDose) {
      _calculateStandard(weight);
    } else {
      setState(() => _error = 'No dose data for $_selectedSpecies');
    }
  }

  void _calculateStandard(ParsedWeight weight) {
    final calcResult = DoseCalculator.calculate(
      drug: widget.drug,
      species: _selectedSpecies!,
      weightKg: weight.kg,
    );

    if (calcResult.error != null) {
      setState(() => _error = calcResult.error);
      return;
    }

    setState(() => _result = calcResult.result);

    // Save calculation log
    _saveLog(weight, calcResult.result!);
  }

  void _calculateCri(ParsedWeight weight) {
    // Parse CRI inputs
    final doseRateStr = _doseRateController.text.trim().replaceAll(',', '.');
    final fluidRateStr = _fluidRateController.text.trim().replaceAll(',', '.');
    final bagSizeStr = _bagSizeController.text.trim().replaceAll(',', '.');

    final doseRate = double.tryParse(doseRateStr);
    final fluidRate = double.tryParse(fluidRateStr);
    final bagSize = double.tryParse(bagSizeStr);

    if (doseRate == null || doseRate <= 0) {
      setState(() => _error = 'Please enter a valid dose rate');
      return;
    }
    if (fluidRate == null || fluidRate <= 0) {
      setState(() => _error = 'Please enter a valid fluid rate');
      return;
    }
    if (bagSize == null || bagSize <= 0) {
      setState(() => _error = 'Please enter a valid bag size');
      return;
    }

    // Dose-rate range checking is done in DoseCalculator.calculateCri, which
    // attaches an advisory the result card displays. It used to be an empty
    // if-block here with a comment saying it would warn "for now", so an
    // out-of-range rate produced a clean result with nothing flagged.
    final criCalcResult = DoseCalculator.calculateCri(
      drug: widget.drug,
      species: _selectedSpecies!,
      weightKg: weight.kg,
      doseRate: doseRate,
      fluidRateMlHr: fluidRate,
      bagSizeMl: bagSize,
    );

    if (criCalcResult.error != null) {
      setState(() => _error = criCalcResult.error);
      return;
    }

    setState(() => _criResult = criCalcResult.result);

    // Save CRI calculation log
    _saveCriLog(weight, criCalcResult.result!);
  }

  Future<void> _saveLog(ParsedWeight weight, DoseResult result) async {
    final log = CalculationLog(
      calcId: const Uuid().v4(),
      drugId: widget.drug.id,
      drugName: widget.drug.name,
      species: _selectedSpecies!,
      weightKg: weight.kg,
      weightUnit: weight.originalUnit,
      weightEntered: weight.originalValue,
      doseMinMg: result.doseMinMg,
      doseMaxMg: result.doseMaxMg,
      volumeMinMl: result.volumeMinMl,
      volumeMaxMl: result.volumeMaxMl,
      datasetVersion: widget.datasetVersion,
      timestamp: DateTime.now(),
    );
    await DatabaseService.saveCalcLog(log);
  }

  Future<void> _saveCriLog(ParsedWeight weight, CriResult result) async {
    final log = CalculationLog(
      calcId: const Uuid().v4(),
      drugId: widget.drug.id,
      drugName: widget.drug.name,
      species: _selectedSpecies!,
      weightKg: weight.kg,
      weightUnit: weight.originalUnit,
      weightEntered: weight.originalValue,
      doseMinMg: 0,
      doseMaxMg: 0,
      volumeMinMl: result.mlToAdd,
      volumeMaxMl: result.mlToAdd,
      datasetVersion: widget.datasetVersion,
      timestamp: DateTime.now(),
      doseRate: result.doseRate,
      fluidRateMlHr: result.fluidRateMlHr,
      bagSizeMl: result.bagSizeMl,
      mlToAdd: result.mlToAdd,
      bagDurationHrs: result.bagDurationHours,
    );
    await DatabaseService.saveCalcLog(log);
  }

  @override
  Widget build(BuildContext context) {
    final drug = widget.drug;

    return ValueListenableBuilder<AppLanguage>(
      valueListenable: LanguageController.instance.currentLanguage,
      builder: (context, currentLang, _) {
        final strings = AppStrings(currentLang);

        return Scaffold(
          appBar: AppBar(
            title: Text(drug.name),
            actions: [
              const LanguageToggleButton(),
              const SizedBox(width: 8),
              Container(
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    widget.datasetVersion,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                ),
              ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Drug info card
                _DrugInfoCard(drug: drug, strings: strings),

                const SizedBox(height: 16),

                // Withdrawn warning
                if (drug.isWithdrawn) ...[
                  _WarningBanner(
                    icon: Icons.block,
                    color: VetifiTheme.error,
                    bgColor: VetifiTheme.errorBg,
                    title: strings.drugWithdrawnTitle,
                    message: drug.withdrawnReason ?? strings.drugWithdrawnDefaultMsg,
                  ),
                  const SizedBox(height: 16),
                ],

                // Global errors
                if (drug.hasGlobalError && !drug.isWithdrawn) ...[
                  _WarningBanner(
                    icon: Icons.warning_amber_rounded,
                    color: VetifiTheme.warning,
                    bgColor: VetifiTheme.warningBg,
                    title: strings.dataIssueTitle,
                    message: drug.concentration == null
                        ? 'Invalid concentration: "${drug.concentrationRaw}". Cannot calculate doses.'
                        : drug.validationErrors.first,
                  ),
                  const SizedBox(height: 16),
                ],

                // Species selection
                if (!drug.isWithdrawn) ...[
                  Text(
                    strings.species,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  _SpeciesSelector(
                    availableSpecies: drug.availableSpecies.toList()..sort(),
                    selectedSpecies: _selectedSpecies,
                    drug: drug,
                    strings: strings,
                    onSelect: (species) {
                      setState(() {
                        _selectedSpecies = species;
                        _result = null;
                        _criResult = null;
                        _error = null;
                        _calculated = false;
                      });
                    },
                  ),

                  // Species-specific error
                  if (_selectedSpecies != null) ...[
                    Builder(builder: (context) {
                      final specErr = drug.speciesError(_selectedSpecies!);
                      if (specErr != null) {
                        return Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: _WarningBanner(
                            icon: Icons.error_outline,
                            color: VetifiTheme.error,
                            bgColor: VetifiTheme.errorBg,
                            title: strings.cannotCalculateTitle,
                            message: specErr,
                          ),
                        );
                      }
                      return const SizedBox.shrink();
                    }),
                  ],

                  const SizedBox(height: 20),

                  // Weight input
                  if (_selectedSpecies != null &&
                      drug.speciesError(_selectedSpecies!) == null) ...[
                    Text(
                      strings.bodyWeight,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _weightController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              hintText: strings.enterWeightHint,
                              errorText: _weightError,
                              prefixIcon: const Icon(Icons.monitor_weight_outlined),
                            ),
                            onChanged: (_) {
                              if (_calculated) {
                                setState(() {
                                  _result = null;
                                  _criResult = null;
                                  _error = null;
                                  _calculated = false;
                                });
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Unit toggle
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: Colors.grey.shade300),
                          ),
                          child: Row(
                            children: [
                              _UnitButton(
                                label: strings.kg,
                                selected: _weightUnit == 'kg',
                                onTap: () => setState(() {
                                  _weightUnit = 'kg';
                                  _result = null;
                                  _criResult = null;
                                  _calculated = false;
                                }),
                                isLeft: true,
                              ),
                              _UnitButton(
                                label: strings.lb,
                                selected: _weightUnit == 'lb',
                                onTap: () => setState(() {
                                  _weightUnit = 'lb';
                                  _result = null;
                                  _criResult = null;
                                  _calculated = false;
                                }),
                                isLeft: false,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    // CRI-specific inputs
                    if (_isCriMode) ...[
                      const SizedBox(height: 16),
                      _buildCriInputs(strings),
                    ],

                    const SizedBox(height: 20),

                    // Calculate button
                    SizedBox(
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: _calculate,
                        icon: const Icon(Icons.calculate, size: 22),
                        label: Text(
                          _isCriMode ? strings.criSectionTitle : strings.calculateDose,
                        ),
                      ),
                    ),

                    // Error display
                    if (_error != null && _calculated) ...[
                      const SizedBox(height: 16),
                      _WarningBanner(
                        icon: Icons.error_outline,
                        color: VetifiTheme.error,
                        bgColor: VetifiTheme.errorBg,
                        title: strings.cannotCalculateTitle,
                        message: _error!,
                      ),
                    ],

                    // Unusual but plausible weight. Advisory, not a refusal.
                    if (_weightAdvisory != null && _error == null) ...[
                      const SizedBox(height: 16),
                      _WarningBanner(
                        icon: Icons.info_outline,
                        color: VetifiTheme.warning,
                        bgColor: VetifiTheme.warningBg,
                        title: 'Check the weight',
                        message: _weightAdvisory!,
                      ),
                    ],

                    // Standard dose result
                    if (_result != null) ...[
                      const SizedBox(height: 20),
                      _DoseResultCard(
                        result: _result!,
                        drug: drug,
                        species: _selectedSpecies!,
                        datasetVersion: widget.datasetVersion,
                        strings: strings,
                      ),
                    ],

                    // CRI result
                    if (_criResult != null) ...[
                      const SizedBox(height: 20),
                      _CriResultCard(
                        result: _criResult!,
                        drug: drug,
                        species: _selectedSpecies!,
                        datasetVersion: widget.datasetVersion,
                        strings: strings,
                      ),
                    ],
                  ],
                ],

                const SizedBox(height: 32),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCriInputs(AppStrings strings) {
    final criDose = widget.drug.criDoses[_selectedSpecies!]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          strings.doseRateLabel,
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 4),
        Text(
          'Range: ${criDose.min} – ${criDose.max} ${criDose.unit}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _doseRateController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            hintText: 'e.g. ${criDose.min}',
            prefixIcon: const Icon(Icons.speed),
            suffixText: criDose.unit,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          strings.fluidRateLabel,
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _fluidRateController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            hintText: 'e.g. 10',
            prefixIcon: Icon(Icons.water_drop_outlined),
            suffixText: 'mL/hr',
          ),
        ),
        const SizedBox(height: 16),
        Text(
          strings.bagSizeLabel,
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _bagSizeController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            hintText: 'e.g. 500',
            prefixIcon: Icon(Icons.local_drink_outlined),
            suffixText: 'mL',
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _DrugInfoCard extends StatelessWidget {
  final Drug drug;
  final AppStrings strings;

  const _DrugInfoCard({required this.drug, required this.strings});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VetifiTheme.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: VetifiTheme.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.medication,
                  color: VetifiTheme.primary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      drug.name,
                      style: GoogleFonts.inter(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: VetifiTheme.textPrimary,
                      ),
                    ),
                    Text(
                      drug.id.toUpperCase(),
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: VetifiTheme.textMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1),
          const SizedBox(height: 14),
          Row(
            children: [
              _DetailItem(label: strings.route, value: drug.route),
              const SizedBox(width: 24),
              _DetailItem(
                label: strings.concentration,
                value: drug.concentrationRaw,
                isError: drug.concentration == null,
              ),
              if (drug.concentration != null &&
                  drug.concentrationRaw.contains('%'))
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _DetailItem(
                    label: '(= mg/mL)',
                    value: '${drug.concentration!.mgPerMl} mg/mL',
                  ),
                ),
              if (drug.maxTotalMg != null) ...[
                const SizedBox(width: 24),
                _DetailItem(
                  label: 'Max Total',
                  value: '${drug.maxTotalMg} mg',
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailItem extends StatelessWidget {
  final String label;
  final String value;
  final bool isError;

  const _DetailItem({
    required this.label,
    required this.value,
    this.isError = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            color: VetifiTheme.textMuted,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: GoogleFonts.inter(
            fontSize: 14,
            color: isError ? VetifiTheme.error : VetifiTheme.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _SpeciesSelector extends StatelessWidget {
  final List<String> availableSpecies;
  final String? selectedSpecies;
  final Drug drug;
  final AppStrings strings;
  final ValueChanged<String> onSelect;

  const _SpeciesSelector({
    required this.availableSpecies,
    required this.selectedSpecies,
    required this.drug,
    required this.strings,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: availableSpecies.map((species) {
        final selected = species == selectedSpecies;
        final hasError = drug.speciesError(species) != null;
        final icon = species == 'dog' ? '🐕' : species == 'cat' ? '🐈' : '🐾';

        return Padding(
          padding: const EdgeInsets.only(right: 10),
          child: ChoiceChip(
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(icon, style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 6),
                Text(
                  strings.speciesName(species),
                  style: GoogleFonts.inter(
                    fontWeight: FontWeight.w500,
                    color: selected
                        ? VetifiTheme.primary
                        : hasError
                            ? VetifiTheme.warning
                            : VetifiTheme.textPrimary,
                  ),
                ),
                if (hasError) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.warning_amber,
                    size: 14,
                    color: VetifiTheme.warning,
                  ),
                ],
              ],
            ),
            selected: selected,
            onSelected: (_) => onSelect(species),
            selectedColor: VetifiTheme.primary.withValues(alpha: 0.12),
            backgroundColor: VetifiTheme.surfaceCard,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                color: selected
                    ? VetifiTheme.primary
                    : hasError
                        ? VetifiTheme.warning.withValues(alpha: 0.5)
                        : Colors.grey.shade300,
                width: selected ? 2 : 1,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
        );
      }).toList(),
    );
  }
}

class _UnitButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool isLeft;

  const _UnitButton({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.isLeft,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        decoration: BoxDecoration(
          color: selected ? VetifiTheme.primary : Colors.transparent,
          borderRadius: BorderRadius.horizontal(
            left: isLeft ? const Radius.circular(9) : Radius.zero,
            right: isLeft ? Radius.zero : const Radius.circular(9),
          ),
        ),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : VetifiTheme.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _WarningBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color bgColor;
  final String title;
  final String message;

  const _WarningBanner({
    required this.icon,
    required this.color,
    required this.bgColor,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: color.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Result cards
// ---------------------------------------------------------------------------

/// A single non-fatal note shown inside a result card.
///
/// Kept visually quieter than [_WarningBanner] because these accompany a
/// successful calculation rather than replacing one.
class _ResultNote extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _ResultNote({
    required this.icon,
    required this.color,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: GoogleFonts.inter(
                fontSize: 12.5,
                height: 1.35,
                color: color.withValues(alpha: 0.95),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// True when the rounded display differs from the computed value, so the exact
/// figure is worth showing alongside it.
bool _unroundedDiffers(DoseResult result) {
  final minShown = double.tryParse(formatVolumeMl(result.volumeMinMl));
  final maxShown = double.tryParse(formatVolumeMl(result.volumeMaxMl));
  if (minShown == null || maxShown == null) return false;
  return (minShown - result.volumeMinMl).abs() > 0.0005 ||
      (maxShown - result.volumeMaxMl).abs() > 0.0005;
}

/// Renders a volume range without any rounding loss, for the "Exact:" line.
String _exactRange(double minMl, double maxMl) {
  String exact(double v) {
    if (v <= 0) return '0';
    var s = v.toStringAsFixed(6);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }

  if (minMl == maxMl) return exact(minMl);
  return '${exact(minMl)} to ${exact(maxMl)}';
}

class _DoseResultCard extends StatelessWidget {
  final DoseResult result;
  final Drug drug;
  final String species;
  final String datasetVersion;
  final AppStrings strings;

  const _DoseResultCard({
    required this.result,
    required this.drug,
    required this.species,
    required this.datasetVersion,
    required this.strings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: VetifiTheme.resultBg,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: VetifiTheme.resultBg.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle, color: VetifiTheme.resultAccent, size: 20),
                const SizedBox(width: 8),
                Text(
                  strings.resultHeader,
                  style: GoogleFonts.inter(
                    color: VetifiTheme.resultText,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const Spacer(),
                Text(
                  datasetVersion,
                  style: GoogleFonts.inter(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),

          // Main volume result — LARGE and unmistakable
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Column(
              children: [
                Text(
                  strings.volumeToAdminister.toUpperCase(),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    color: VetifiTheme.resultAccent.withValues(alpha: 0.8),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      formatVolumeMl(result.volumeMinMl),
                      style: GoogleFonts.inter(
                        color: VetifiTheme.resultAccent,
                        fontSize: 36,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (result.volumeMinMl != result.volumeMaxMl) ...[
                      Text(
                        ' – ',
                        style: GoogleFonts.inter(
                          color: VetifiTheme.resultAccent.withValues(alpha: 0.6),
                          fontSize: 28,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        formatVolumeMl(result.volumeMaxMl),
                        style: GoogleFonts.inter(
                          color: VetifiTheme.resultAccent,
                          fontSize: 36,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                    const SizedBox(width: 6),
                    Text(
                      'mL',
                      style: GoogleFonts.inter(
                        color: VetifiTheme.resultAccent.withValues(alpha: 0.7),
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),

                // Max total warning
                if (result.maxTotalCapped) ...[
                  const SizedBox(height: 10),
                  _ResultNote(
                    icon: Icons.info_outline,
                    color: VetifiTheme.cappedWarning,
                    text: result.originalDoseMaxMg != null
                        ? '${strings.maxCappedAlert}: '
                            '${formatDoseMg(result.originalDoseMaxMg!)} mg '
                            'capped at ${formatDoseMg(result.doseMaxMg)} mg. '
                            'Give as two divided doses.'
                        : '${strings.maxCappedAlert} (${drug.maxTotalMg} mg)',
                  ),
                ],

                // Clinical advisories: syringe choice, rounding cost, and the
                // unrounded micro-volume. See DECISIONS.md questions 1 and 3.
                for (final advisory in result.advisories) ...[
                  const SizedBox(height: 10),
                  _ResultNote(
                    icon: Icons.info_outline,
                    color: VetifiTheme.cappedWarning,
                    text: advisory,
                  ),
                ],

                // Exact value, for when the displayed rounding is not enough.
                // Shown whenever the two differ, so nothing is ever hidden.
                if (_unroundedDiffers(result)) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Exact: ${_exactRange(result.volumeMinMl, result.volumeMaxMl)} mL',
                    style: GoogleFonts.inter(
                      color: Colors.white38,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Details
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(14),
              ),
            ),
            child: Column(
              children: [
                _ResultDetailRow(
                  label: strings.totalDoseMg,
                  value:
                      '${formatDoseMg(result.doseMinMg)} – ${formatDoseMg(result.doseMaxMg)} mg',
                ),
                const SizedBox(height: 8),
                _ResultDetailRow(
                  label: strings.doseRate,
                  value: result.doseUnit,
                ),
                const SizedBox(height: 8),
                _ResultDetailRow(
                  label: strings.concentration,
                  value: result.concentrationDisplay,
                ),
                if (drug.concentrationRaw.contains('%'))
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: _ResultDetailRow(
                      label: '',
                      value: '= ${result.concentrationMgPerMl} mg/mL',
                    ),
                  ),
                const SizedBox(height: 8),
                _ResultDetailRow(
                  label: strings.bodyWeight,
                  value: '${result.weightKg.toStringAsFixed(2)} kg',
                ),
                const SizedBox(height: 8),
                _ResultDetailRow(
                  label: strings.route,
                  value: drug.route,
                ),
                const SizedBox(height: 8),
                _ResultDetailRow(
                  label: strings.species,
                  value: strings.speciesName(species),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CriResultCard extends StatelessWidget {
  final CriResult result;
  final Drug drug;
  final String species;
  final String datasetVersion;
  final AppStrings strings;

  const _CriResultCard({
    required this.result,
    required this.drug,
    required this.species,
    required this.datasetVersion,
    required this.strings,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: VetifiTheme.resultBg,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: VetifiTheme.resultBg.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.05),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle, color: VetifiTheme.resultAccent, size: 20),
                const SizedBox(width: 8),
                Text(
                  strings.criResultHeader,
                  style: GoogleFonts.inter(
                    color: VetifiTheme.resultText,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
                const Spacer(),
                Text(
                  datasetVersion,
                  style: GoogleFonts.inter(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),

          // Main result
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Column(
              children: [
                Text(
                  strings.addToBag,
                  style: GoogleFonts.inter(
                    color: VetifiTheme.resultAccent.withValues(alpha: 0.7),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      formatVolumeMl(result.mlToAdd),
                      style: GoogleFonts.inter(
                        color: VetifiTheme.resultAccent,
                        fontSize: 36,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'mL',
                      style: GoogleFonts.inter(
                        color: VetifiTheme.resultAccent.withValues(alpha: 0.7),
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  strings.bagDuration.toUpperCase(),
                  style: GoogleFonts.inter(
                    color: Colors.white38,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  formatDuration(result.bagDurationMinutes),
                  style: GoogleFonts.inter(
                    color: Colors.white70,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),

                // Advisories: out-of-range dose rate, dilution from the added
                // volume, and sub-measurable volumes. See DECISIONS.md Q3.
                for (final advisory in result.advisories) ...[
                  const SizedBox(height: 12),
                  _ResultNote(
                    icon: Icons.info_outline,
                    color: VetifiTheme.cappedWarning,
                    text: advisory,
                  ),
                ],
              ],
            ),
          ),

          // Details
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(14),
              ),
            ),
            child: Column(
              children: [
                _ResultDetailRow(
                  label: strings.doseRate,
                  value: '${result.doseRate} mcg/kg/min',
                ),
                const SizedBox(height: 8),
                _ResultDetailRow(
                  label: strings.fluidRate,
                  value: '${result.fluidRateMlHr} mL/hr',
                ),
                const SizedBox(height: 8),
                _ResultDetailRow(
                  label: strings.bagSize,
                  value: '${result.bagSizeMl} mL',
                ),
                const SizedBox(height: 8),
                _ResultDetailRow(
                  label: strings.concentration,
                  value: result.concentrationDisplay,
                ),
                const SizedBox(height: 8),
                _ResultDetailRow(
                  label: strings.bodyWeight,
                  value: '${result.weightKg.toStringAsFixed(2)} kg',
                ),
                const SizedBox(height: 8),
                _ResultDetailRow(
                  label: strings.species,
                  value: strings.speciesName(species),
                ),

                // Both concentrations, so the effect of the added volume is
                // visible rather than only described in prose.
                const Divider(
                  height: 20,
                  thickness: 1,
                  color: Colors.white10,
                ),
                _ResultDetailRow(
                  label: 'Intended concentration',
                  value:
                      '${result.nominalConcentrationMgPerMl.toStringAsFixed(4)} mcg/mL',
                ),
                const SizedBox(height: 8),
                _ResultDetailRow(
                  label: 'In the finished bag',
                  value:
                      '${result.deliveredConcentrationMgPerMl.toStringAsFixed(4)} mcg/mL',
                ),
                const SizedBox(height: 8),
                _ResultDetailRow(
                  label: 'Dilution from added volume',
                  value:
                      '${(result.dilutionErrorFraction * 100).toStringAsFixed(2)}%',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultDetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _ResultDetailRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            color: Colors.white54,
            fontSize: 13,
          ),
        ),
        Text(
          value,
          style: GoogleFonts.inter(
            color: Colors.white.withValues(alpha: 0.9),
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
