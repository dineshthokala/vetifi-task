// Dose and CRI calculation tests.
//
// These are the tests that stand between a data error and a dosing error. Each
// one corresponds to a failure mode in BREAK_IT.md, and each asserts both that
// the calculation is refused (or flagged) and that the refusal names the
// problem, because a refusal a clinician cannot act on is nearly as bad as a
// wrong number.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vetifitask/models/drug.dart';
import 'package:vetifitask/services/dose_calculator.dart';

Drug drugFrom(Map<String, dynamic> json) => Drug.fromJson(json);

void main() {
  group('Weight parsing', () {
    test('accepts a decimal point and a decimal comma', () {
      expect(parseWeight('4.5', 'kg').weight!.kg, 4.5);
      expect(parseWeight('4,5', 'kg').weight!.kg, 4.5);
    });

    test('uses the exact pound conversion', () {
      // 1 lb = 0.45359237 kg exactly. Using 2.2 introduces a 0.21% error.
      expect(parseWeight('1', 'lb').weight!.kg, closeTo(0.45359237, 1e-9));
      expect(parseWeight('22', 'lb').weight!.kg, closeTo(9.979032, 1e-6));
    });

    test('rejects impossible values', () {
      expect(parseWeight('', 'kg').error, isNotNull);
      expect(parseWeight('0', 'kg').error, isNotNull);
      expect(parseWeight('-5', 'kg').error, isNotNull);
      expect(parseWeight('abc', 'kg').error, isNotNull);
      expect(parseWeight('2000', 'kg').error, isNotNull);
      expect(parseWeight('0.005', 'kg').error, isNotNull);
    });

    test('rejects more than one decimal separator rather than guessing', () {
      expect(parseWeight('4.5.6', 'kg').error, isNotNull);
      expect(parseWeight('1.2.3', 'kg').error, isNotNull);
    });

    test('a comma is read as a decimal separator, as the brief specifies', () {
      // The brief requires that "4,5" mean 4.5. So "1,200" is 1.2 kg, not
      // 1200 kg. A user who means twelve hundred must type "1200" or "1200,0".
      // The comma-as-decimal rule wins; it is the documented convention.
      expect(parseWeight('1,200', 'kg').weight!.kg, 1.2);
      expect(parseWeight('1200', 'kg').weight!.kg, 1200.0);
    });

    test('rejects an unknown unit rather than assuming kg', () {
      expect(parseWeight('20', 'stone').error, isNotNull);
    });

    test('flags an unusual but plausible weight as an advisory', () {
      // A 0.8 kg kitten is real. It should warn, not refuse.
      final w = parseWeight('0.8', 'kg').weight!;
      expect(w.isPhysiologicallyUnusual, isTrue);
      expect(w.advisory, isNotNull);

      final normal = parseWeight('12', 'kg').weight!;
      expect(normal.isPhysiologicallyUnusual, isFalse);
      expect(normal.advisory, isNull);
    });

    test('a very large dog is flagged', () {
      final w = parseWeight('75', 'kg').weight!;
      expect(w.isPhysiologicallyUnusual, isTrue);
    });
  });

  group('Concentration parsing', () {
    test('parses mg/mL', () {
      expect(parseConcentration('50 mg/mL')!.mgPerMl, 50.0);
    });

    test('parses percentage as w/v', () {
      // 10% w/v = 10 g per 100 mL = 100 mg/mL. Reading it as 10 mg/mL would
      // be a 10x overdose.
      expect(parseConcentration('10%')!.mgPerMl, 100.0);
      expect(parseConcentration('0.5%')!.mgPerMl, 5.0);
    });

    test('rejects zero and negative concentrations', () {
      expect(parseConcentration('0 mg/mL'), isNull);
      expect(parseConcentration('-5 mg/mL'), isNull);
    });

    test('rejects an unparseable concentration rather than guessing', () {
      expect(parseConcentration('50 mg'), isNull);
      expect(parseConcentration('one hundred'), isNull);
      expect(parseConcentration(''), isNull);
    });
  });

  group('Data quality refusals', () {
    test('refuses an inverted dose range and says why', () {
      final drug = drugFrom({
        'id': 'd006',
        'name': 'Corvadil',
        'concentration': '10 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 8, 'max': 4, 'unit': 'mg/kg'}
        },
      });
      final r = DoseCalculator.calculate(drug: drug, species: 'dog', weightKg: 20);
      expect(r.result, isNull);
      expect(r.error, contains('exceeds maximum'));
    });

    test('refuses a zero concentration', () {
      final drug = drugFrom({
        'id': 'd009',
        'name': 'Quilomid',
        'concentration': '0 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 1, 'max': 3, 'unit': 'mg/kg'}
        },
      });
      final r = DoseCalculator.calculate(drug: drug, species: 'dog', weightKg: 20);
      expect(r.result, isNull);
      expect(r.error, contains('concentration'));
    });

    test('refuses a missing or null species dose rather than extrapolating', () {
      // d003 has an explicit null for cat; d004 omits cat entirely. Both are
      // refused. Showing the dog dose for a cat is the failure mode this guards.
      for (final json in [
        {
          'id': 'd003',
          'name': 'Pirovane',
          'concentration': '25 mg/mL',
          'route': 'PO',
          'doses': {
            'dog': {'min': 1, 'max': 2, 'unit': 'mg/kg'},
            'cat': null,
          },
        },
        {
          'id': 'd004',
          'name': 'Meloquin',
          'concentration': '1.5 mg/mL',
          'route': 'PO',
          'doses': {
            'dog': {'min': 0.1, 'max': 0.2, 'unit': 'mg/kg'}
          },
        },
      ]) {
        final drug = drugFrom(json);
        final r = DoseCalculator.calculate(drug: drug, species: 'cat', weightKg: 4);
        expect(r.result, isNull, reason: 'must not extrapolate across species');
        expect(r.error, contains('No dose data'));
      }
    });

    test('refuses an unrecognised dose unit instead of assuming mg/kg', () {
      // g/kg read as mg/kg would be a 1000x underdose.
      final drug = drugFrom({
        'id': 'x1',
        'name': 'UnitTrap',
        'concentration': '10 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 1, 'max': 2, 'unit': 'g/kg'}
        },
      });
      final r = DoseCalculator.calculate(drug: drug, species: 'dog', weightKg: 10);
      expect(r.result, isNull);
      expect(r.error, contains('unit'));
    });

    test('refuses mcg/kg/min appearing in a bolus doses block', () {
      // Read as mg/kg this would be a 1000x overdose.
      final drug = drugFrom({
        'id': 'x2',
        'name': 'CriUnitTrap',
        'concentration': '40 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 5, 'max': 10, 'unit': 'mcg/kg/min'}
        },
      });
      final r = DoseCalculator.calculate(drug: drug, species: 'dog', weightKg: 10);
      expect(r.result, isNull);
      expect(r.error, contains('unit'));
    });

    test('refuses a withdrawn drug', () {
      final drug = drugFrom({
        'id': 'd001',
        'name': 'Veloxamine',
        'concentration': '50 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 5, 'max': 10, 'unit': 'mg/kg'}
        },
      }).copyWithWithdrawn(reason: 'Batch recall');

      final r = DoseCalculator.calculate(drug: drug, species: 'dog', weightKg: 20);
      expect(r.result, isNull);
      expect(r.error, contains('withdrawn'));
      expect(r.error, contains('Batch recall'));
    });

    test('normalises species keys before deciding availability', () {
      final drug = drugFrom({
        'id': 'd010',
        'name': 'Dravexin',
        'concentration': '20 mg/mL',
        'route': 'IM',
        'doses': {
          'Dog': {'min': 2, 'max': 4, 'unit': 'mg/kg'},
          'feline': {'min': 1, 'max': 2, 'unit': 'mg/kg'},
        },
      });
      expect(drug.doses.keys, containsAll(['dog', 'cat']));
      expect(drug.speciesError('dog'), isNull);
      expect(drug.speciesError('cat'), isNull);
    });
  });

  group('Unit conversion', () {
    test('converts mcg/kg to mg/kg before dividing by concentration', () {
      // Getting this wrong is a 1000x overdose.
      final drug = drugFrom({
        'id': 'd002',
        'name': 'Tranzorel',
        'concentration': '1 mg/mL',
        'route': 'IM',
        'doses': {
          'dog': {'min': 10, 'max': 20, 'unit': 'mcg/kg'}
        },
      });
      final r = DoseCalculator.calculate(drug: drug, species: 'dog', weightKg: 10);
      expect(r.error, isNull);
      expect(r.result!.doseMinMg, closeTo(0.1, 1e-9)); // 10 mcg/kg * 10 kg
      expect(r.result!.volumeMinMl, closeTo(0.1, 1e-9));
    });
  });

  group('Max total cap', () {
    Drug zentrafen() => drugFrom({
          'id': 'd008',
          'name': 'Zentrafen',
          'concentration': '100 mg/mL',
          'route': 'PO',
          'max_total_mg': 400,
          'doses': {
            'dog': {'min': 10, 'max': 15, 'unit': 'mg/kg'}
          },
        });

    test('caps the upper bound and reports the uncapped value', () {
      final r = DoseCalculator.calculate(drug: zentrafen(), species: 'dog', weightKg: 40);
      expect(r.error, isNull);
      // 40 kg * 10 mg/kg = 400; 40 kg * 15 = 600, capped to 400.
      expect(r.result!.doseMinMg, 400.0);
      expect(r.result!.doseMaxMg, 400.0);
      expect(r.result!.maxTotalCapped, isTrue);
      // The clinician needs to see what was suppressed.
      expect(r.result!.originalDoseMaxMg, 600.0);
    });

    test('leaves an uncapped dose alone', () {
      final r = DoseCalculator.calculate(drug: zentrafen(), species: 'dog', weightKg: 20);
      expect(r.result!.doseMinMg, 200.0);
      expect(r.result!.doseMaxMg, 300.0);
      expect(r.result!.maxTotalCapped, isFalse);
    });
  });

  group('Sub-measurable volumes', () {
    test('refuses a volume no syringe can measure', () {
      // 0.01 kg * 0.1 mg/kg / 100 mg/mL = 0.00001 mL. Displaying "0.000 mL"
      // reads as a confident instruction to draw up nothing.
      final drug = drugFrom({
        'id': 'tiny',
        'name': 'Tiny',
        'concentration': '100 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 0.1, 'max': 0.2, 'unit': 'mg/kg'}
        },
      });
      final r = DoseCalculator.calculate(drug: drug, species: 'dog', weightKg: 0.01);
      expect(r.result, isNull);
      expect(r.error, contains('measurable'));
    });

    test('advises on a small but measurable volume', () {
      final drug = drugFrom({
        'id': 'small',
        'name': 'Small',
        'concentration': '100 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 1, 'max': 2, 'unit': 'mg/kg'}
        },
      });
      // 2.5 kg * 0.1 mg/kg / 100 = 0.0025 mL is too small; use 1 mg/kg.
      final r = DoseCalculator.calculate(drug: drug, species: 'dog', weightKg: 2.5);
      expect(r.result, isNotNull);
      expect(r.result!.advisories, isNotEmpty);
      expect(r.result!.advisories.first, contains('syringe'));
    });
  });

  group('Volume formatting', () {
    test('never renders a non-zero volume as zero', () {
      expect(formatVolumeMl(0.00001), '< 0.001');
      expect(formatVolumeMl(0.0004), '< 0.001');
      expect(formatVolumeMl(0.0005), isNot('0.000'));
    });

    test('keeps significant digits in the clinical range', () {
      expect(formatVolumeMl(0.07), '0.07');
      expect(formatVolumeMl(0.005), '0.005');
      expect(formatVolumeMl(2.5), '2.50');
      expect(formatVolumeMl(38.4), '38.4');
    });
  });

  group('CRI calculation', () {
    Drug dopraxine() => drugFrom({
          'id': 'd011',
          'name': 'Dopraxine',
          'concentration': '40 mg/mL',
          'route': 'IV CRI',
          'cri': {
            'dog': {'min': 5, 'max': 10, 'unit': 'mcg/kg/min'},
            'cat': null,
          },
        });

    test('computes the volume to add with correct unit handling', () {
      // 5 mcg/kg/min * 10 kg * 1500 min = 75000 mcg = 75 mg.
      // 75 mg / 40 mg/mL = 1.875 mL. Bag lasts 500/20*60 = 1500 min = 25 hr.
      final r = DoseCalculator.calculateCri(
        drug: dopraxine(),
        species: 'dog',
        weightKg: 10,
        doseRate: 5,
        fluidRateMlHr: 20,
        bagSizeMl: 500,
      );
      expect(r.error, isNull);
      expect(r.result!.mlToAdd, closeTo(1.875, 1e-9));
      expect(r.result!.bagDurationMinutes, 1500);
      expect(r.result!.bagDurationHours, 25);
    });

    test('flags a dose rate above the validated range', () {
      // 500 mcg/kg/min against a 5-10 range is a 50x overdose. It used to be
      // computed and displayed as a clean result.
      final r = DoseCalculator.calculateCri(
        drug: dopraxine(),
        species: 'dog',
        weightKg: 10,
        doseRate: 500,
        fluidRateMlHr: 20,
        bagSizeMl: 500,
      );
      expect(r.error, isNull, reason: 'still computed, but flagged');
      final text = r.result!.advisories.join(' ');
      expect(text, contains('ABOVE'));
      expect(text, contains('50.0x'));
    });

    test('flags a dose rate below the validated range', () {
      final r = DoseCalculator.calculateCri(
        drug: dopraxine(),
        species: 'dog',
        weightKg: 10,
        doseRate: 1,
        fluidRateMlHr: 20,
        bagSizeMl: 500,
      );
      expect(r.result!.advisories.join(' '), contains('BELOW'));
    });

    test('a rate inside the range produces no rate advisory', () {
      final r = DoseCalculator.calculateCri(
        drug: dopraxine(),
        species: 'dog',
        weightKg: 10,
        doseRate: 7,
        fluidRateMlHr: 20,
        bagSizeMl: 500,
      );
      expect(
        r.result!.advisories.where((a) => a.contains('Dose rate')),
        isEmpty,
      );
    });

    test('reports the dilution caused by the added volume', () {
      // 1.875 mL into 500 mL is 0.37% of the finished volume: below the 2%
      // threshold, so informational rather than actionable.
      final r = DoseCalculator.calculateCri(
        drug: dopraxine(),
        species: 'dog',
        weightKg: 10,
        doseRate: 5,
        fluidRateMlHr: 20,
        bagSizeMl: 500,
      );
      final result = r.result!;
      expect(result.drugVolumeFraction, closeTo(1.875 / 501.875, 1e-9));
      expect(result.dilutionErrorFraction, greaterThan(0));
      expect(result.dilutionErrorFraction, lessThan(0.005));
      expect(result.nominalConcentrationMgPerMl,
          closeTo(75 / 500, 1e-9));
      expect(result.deliveredConcentrationMgPerMl,
          closeTo(75 / 501.875, 1e-9));
    });

    test('warns when the drug meaningfully dilutes the bag', () {
      // A small bag makes the same 1.875 mL a much larger fraction.
      final r = DoseCalculator.calculateCri(
        drug: dopraxine(),
        species: 'dog',
        weightKg: 10,
        doseRate: 10,
        fluidRateMlHr: 2,
        bagSizeMl: 20,
      );
      final result = r.result!;
      expect(result.drugVolumeFraction, greaterThan(0.02));
      expect(
        result.advisories.where((a) => a.contains('Withdraw')),
        isNotEmpty,
        reason: 'must tell the user how much fluid to remove first',
      );
    });

    test('warns when the drug volume exceeds the bag volume', () {
      // 10 mcg/kg/min for 150 kg over a 50 mL bag run at 2 mL/hr:
      // duration = 50/2*60 = 1500 min, drug = 10*150*1500/1000 = 2250 mg,
      // volume = 2250/40 = 56.25 mL, which is more than the bag itself.
      final r = DoseCalculator.calculateCri(
        drug: dopraxine(),
        species: 'dog',
        weightKg: 150,
        doseRate: 10,
        fluidRateMlHr: 2,
        bagSizeMl: 50,
      );
      expect(r.result!.mlToAdd, greaterThan(50));
      expect(
        r.result!.advisories.where((a) => a.contains('exceeds the bag volume')),
        isNotEmpty,
      );
    });

    test('rejects non-positive inputs', () {
      final cases = <Map<String, double>>[
        {'doseRate': 0.0, 'fluidRateMlHr': 20.0, 'bagSizeMl': 500.0},
        {'doseRate': 5.0, 'fluidRateMlHr': 0.0, 'bagSizeMl': 500.0},
        {'doseRate': 5.0, 'fluidRateMlHr': 20.0, 'bagSizeMl': 0.0},
        {'doseRate': -5.0, 'fluidRateMlHr': 20.0, 'bagSizeMl': 500.0},
      ];
      for (final args in cases) {
        final r = DoseCalculator.calculateCri(
          drug: dopraxine(),
          species: 'dog',
          weightKg: 10,
          doseRate: args['doseRate']!,
          fluidRateMlHr: args['fluidRateMlHr']!,
          bagSizeMl: args['bagSizeMl']!,
        );
        expect(r.result, isNull);
      }
    });

    test('refuses a withdrawn drug', () {
      final withdrawn = dopraxine().copyWithWithdrawn(reason: 'Recall');
      final r = DoseCalculator.calculateCri(
        drug: withdrawn,
        species: 'dog',
        weightKg: 10,
        doseRate: 5,
        fluidRateMlHr: 20,
        bagSizeMl: 500,
      );
      expect(r.result, isNull);
      expect(r.error, contains('withdrawn'));
    });

    test('refuses a species with no CRI data', () {
      final r = DoseCalculator.calculateCri(
        drug: dopraxine(),
        species: 'cat',
        weightKg: 4,
        doseRate: 5,
        fluidRateMlHr: 20,
        bagSizeMl: 500,
      );
      expect(r.result, isNull);
    });
  });

  group('End-to-end against the shipped base dataset', () {
    late Dataset dataset;

    setUpAll(() {
      dataset = Dataset.fromJson(
        jsonDecode(_baseDatasetJson) as Map<String, dynamic>,
      );
    });

    Drug byId(String id) => dataset.drugs.firstWhere((d) => d.id == id);

    test('every base drug either calculates or refuses with a reason', () {
      // The invariant that matters: nothing returns a null error and a null
      // result, and nothing calculable is silently wrong.
      for (final drug in dataset.drugs) {
        for (final species in ['dog', 'cat']) {
          final r = DoseCalculator.calculate(
            drug: drug,
            species: species,
            weightKg: 10,
          );
          expect(
            r.result != null || r.error != null,
            isTrue,
            reason: '${drug.id}/$species produced neither a result nor an error',
          );
          if (r.result != null) {
            expect(r.result!.volumeMinMl, greaterThan(0));
            expect(r.result!.volumeMaxMl,
                greaterThanOrEqualTo(r.result!.volumeMinMl));
          }
        }
      }
    });

    test('Benzaprol 10% is read as 100 mg/mL', () {
      final r = DoseCalculator.calculate(drug: byId('d007'), species: 'dog', weightKg: 20);
      expect(r.result!.concentrationMgPerMl, 100.0);
      expect(r.result!.doseMinMg, 40.0);
      expect(r.result!.volumeMinMl, 0.4);
    });

    test('the duplicate-name drugs remain distinguishable', () {
      // d004 and d005 both trim to "Meloquin" but carry different
      // concentrations. Search shows route and concentration, so a clinician
      // can tell them apart, but the concentrations must not be conflated.
      final a = byId('d004');
      final b = byId('d005');
      expect(a.name, b.name);
      expect(a.concentration!.mgPerMl, isNot(b.concentration!.mgPerMl));
      expect(a.route, isNot(b.route));
    });

    test('withdrawal round-trips through JSON', () {
      final drug = byId('d001');
      final asJson = drug.toJson();
      expect(asJson.containsKey('is_withdrawn'), isFalse,
          reason: 'only withdrawn drugs carry the flag');

      final withdrawn = Drug.fromJson({
        ...asJson,
        'is_withdrawn': true,
        'withdrawn_reason': 'Batch recall',
      });
      expect(withdrawn.isWithdrawn, isTrue);
      expect(DoseCalculator.calculate(drug: withdrawn, species: 'dog', weightKg: 10).result,
          isNull);
    });
  });
}

/// The base dataset as shipped in the app bundle.
const String _baseDatasetJson = '''
{
  "schema_version": 2,
  "dataset_version": "v14",
  "drugs": [
    {"id": "d001", "name": "Veloxamine", "concentration": "50 mg/mL", "route": "IV",
      "doses": {"dog": {"min": 5, "max": 10, "unit": "mg/kg"},
                "cat": {"min": 2, "max": 4, "unit": "mg/kg"}}},
    {"id": "d002", "name": "Tranzorel", "concentration": "1 mg/mL", "route": "IM",
      "doses": {"dog": {"min": 10, "max": 20, "unit": "mcg/kg"},
                "cat": {"min": 5, "max": 10, "unit": "mcg/kg"}}},
    {"id": "d003", "name": "Pirovane", "concentration": "25 mg/mL", "route": "PO",
      "doses": {"dog": {"min": 1, "max": 2, "unit": "mg/kg"}, "cat": null}},
    {"id": "d004", "name": "Meloquin", "concentration": "1.5 mg/mL", "route": "PO",
      "doses": {"dog": {"min": 0.1, "max": 0.2, "unit": "mg/kg"}}},
    {"id": "d005", "name": "Meloquin ", "concentration": "5 mg/mL", "route": "SC",
      "doses": {"dog": {"min": 0.1, "max": 0.2, "unit": "mg/kg"},
                "cat": {"min": 0.05, "max": 0.1, "unit": "mg/kg"}}},
    {"id": "d006", "name": "Corvadil", "concentration": "10 mg/mL", "route": "IV",
      "doses": {"dog": {"min": 8, "max": 4, "unit": "mg/kg"}}},
    {"id": "d007", "name": "Benzaprol", "concentration": "10%", "route": "IV",
      "doses": {"dog": {"min": 2, "max": 5, "unit": "mg/kg"},
                "cat": {"min": 2, "max": 5, "unit": "mg/kg"}}},
    {"id": "d008", "name": "Zentrafen", "concentration": "100 mg/mL", "route": "PO",
      "max_total_mg": 400,
      "doses": {"dog": {"min": 10, "max": 15, "unit": "mg/kg"}}},
    {"id": "d009", "name": "Quilomid", "concentration": "0 mg/mL", "route": "IV",
      "doses": {"dog": {"min": 1, "max": 3, "unit": "mg/kg"}}},
    {"id": "d010", "name": "Dravexin", "concentration": "20 mg/mL", "route": "IM",
      "doses": {"Dog": {"min": 2, "max": 4, "unit": "mg/kg"},
                "feline": {"min": 1, "max": 2, "unit": "mg/kg"}}}
  ]
}
''';