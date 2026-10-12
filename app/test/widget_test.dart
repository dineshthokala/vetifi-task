// This is a basic Flutter widget test.

import 'package:flutter_test/flutter_test.dart';
import 'package:vetifitask/models/drug.dart';
import 'package:vetifitask/services/dose_calculator.dart';

void main() {
  group('Concentration Parser', () {
    test('parses mg/mL format', () {
      final result = parseConcentration('50 mg/mL');
      expect(result, isNotNull);
      expect(result!.mgPerMl, 50.0);
    });

    test('parses percentage format', () {
      final result = parseConcentration('10%');
      expect(result, isNotNull);
      expect(result!.mgPerMl, 100.0); // 10% w/v = 100 mg/mL
    });

    test('rejects zero concentration', () {
      final result = parseConcentration('0 mg/mL');
      expect(result, isNull);
    });

    test('rejects empty string', () {
      final result = parseConcentration('');
      expect(result, isNull);
    });
  });

  group('Species Normalisation', () {
    test('normalises Dog to dog', () {
      expect(normaliseSpecies('Dog'), 'dog');
    });

    test('normalises feline to cat', () {
      expect(normaliseSpecies('feline'), 'cat');
    });

    test('handles lowercase', () {
      expect(normaliseSpecies('dog'), 'dog');
      expect(normaliseSpecies('cat'), 'cat');
    });
  });

  group('Weight Parser', () {
    test('parses kg value', () {
      final result = parseWeight('10.5', 'kg');
      expect(result.error, isNull);
      expect(result.weight!.kg, 10.5);
    });

    test('parses lb value', () {
      final result = parseWeight('22', 'lb');
      expect(result.error, isNull);
      expect(result.weight!.kg, closeTo(9.979, 0.01));
    });

    test('handles comma decimal separator', () {
      final result = parseWeight('4,5', 'kg');
      expect(result.error, isNull);
      expect(result.weight!.kg, 4.5);
    });

    test('rejects negative weight', () {
      final result = parseWeight('-5', 'kg');
      expect(result.error, isNotNull);
    });

    test('rejects zero weight', () {
      final result = parseWeight('0', 'kg');
      expect(result.error, isNotNull);
    });

    test('rejects too-large weight', () {
      final result = parseWeight('2000', 'kg');
      expect(result.error, isNotNull);
    });

    test('rejects empty input', () {
      final result = parseWeight('', 'kg');
      expect(result.error, isNotNull);
    });
  });

  group('Drug Model', () {
    test('parses valid drug', () {
      final drug = Drug.fromJson({
        'id': 'd001',
        'name': 'Veloxamine',
        'concentration': '50 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 5, 'max': 10, 'unit': 'mg/kg'},
          'cat': {'min': 2, 'max': 4, 'unit': 'mg/kg'},
        },
      });

      expect(drug.name, 'Veloxamine');
      expect(drug.concentration, isNotNull);
      expect(drug.concentration!.mgPerMl, 50.0);
      expect(drug.doses.containsKey('dog'), true);
      expect(drug.doses.containsKey('cat'), true);
      expect(drug.hasGlobalError, false);
    });

    test('trims name whitespace', () {
      final drug = Drug.fromJson({
        'id': 'd005',
        'name': 'Meloquin ',
        'concentration': '5 mg/mL',
        'route': 'SC',
        'doses': {
          'dog': {'min': 0.1, 'max': 0.2, 'unit': 'mg/kg'},
        },
      });

      expect(drug.name, 'Meloquin');
      expect(drug.rawName, 'Meloquin ');
    });

    test('detects zero concentration', () {
      final drug = Drug.fromJson({
        'id': 'd009',
        'name': 'Quilomid',
        'concentration': '0 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 1, 'max': 3, 'unit': 'mg/kg'},
        },
      });

      expect(drug.concentration, isNull);
      expect(drug.speciesError('dog'), isNotNull);
    });

    test('detects min > max', () {
      final drug = Drug.fromJson({
        'id': 'd006',
        'name': 'Corvadil',
        'concentration': '10 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 8, 'max': 4, 'unit': 'mg/kg'},
        },
      });

      expect(drug.doses['dog']!.isValid, false);
      expect(drug.speciesError('dog'), isNotNull);
    });

    test('normalises species keys', () {
      final drug = Drug.fromJson({
        'id': 'd010',
        'name': 'Dravexin',
        'concentration': '20 mg/mL',
        'route': 'IM',
        'doses': {
          'Dog': {'min': 2, 'max': 4, 'unit': 'mg/kg'},
          'feline': {'min': 1, 'max': 2, 'unit': 'mg/kg'},
        },
      });

      expect(drug.doses.containsKey('dog'), true);
      expect(drug.doses.containsKey('cat'), true);
      expect(drug.doses.containsKey('Dog'), false);
      expect(drug.doses.containsKey('feline'), false);
    });

    test('handles null species dose', () {
      final drug = Drug.fromJson({
        'id': 'd003',
        'name': 'Pirovane',
        'concentration': '25 mg/mL',
        'route': 'PO',
        'doses': {
          'dog': {'min': 1, 'max': 2, 'unit': 'mg/kg'},
          'cat': null,
        },
      });

      expect(drug.doses.containsKey('dog'), true);
      expect(drug.doses.containsKey('cat'), false);
      expect(drug.speciesError('cat'), isNotNull);
    });

    test('handles missing species key', () {
      final drug = Drug.fromJson({
        'id': 'd004',
        'name': 'Meloquin',
        'concentration': '1.5 mg/mL',
        'route': 'PO',
        'doses': {
          'dog': {'min': 0.1, 'max': 0.2, 'unit': 'mg/kg'},
        },
      });

      expect(drug.doses.containsKey('cat'), false);
      expect(drug.speciesError('cat'), isNotNull);
    });

    test('parses percentage concentration', () {
      final drug = Drug.fromJson({
        'id': 'd007',
        'name': 'Benzaprol',
        'concentration': '10%',
        'route': 'IV',
        'doses': {
          'dog': {'min': 2, 'max': 5, 'unit': 'mg/kg'},
        },
      });

      expect(drug.concentration, isNotNull);
      expect(drug.concentration!.mgPerMl, 100.0);
    });
  });

  group('Dose Calculator', () {
    test('calculates basic dose', () {
      final drug = Drug.fromJson({
        'id': 'd001',
        'name': 'Veloxamine',
        'concentration': '50 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 5, 'max': 10, 'unit': 'mg/kg'},
        },
      });

      final result = DoseCalculator.calculate(
        drug: drug,
        species: 'dog',
        weightKg: 20,
      );

      expect(result.error, isNull);
      expect(result.result!.doseMinMg, 100.0);
      expect(result.result!.doseMaxMg, 200.0);
      expect(result.result!.volumeMinMl, 2.0);
      expect(result.result!.volumeMaxMl, 4.0);
    });

    test('caps at max total mg', () {
      final drug = Drug.fromJson({
        'id': 'd008',
        'name': 'Zentrafen',
        'concentration': '100 mg/mL',
        'route': 'PO',
        'max_total_mg': 400,
        'doses': {
          'dog': {'min': 10, 'max': 15, 'unit': 'mg/kg'},
        },
      });

      final result = DoseCalculator.calculate(
        drug: drug,
        species: 'dog',
        weightKg: 40,
      );

      expect(result.error, isNull);
      // Without cap: 40*10=400, 40*15=600
      expect(result.result!.doseMinMg, 400.0);
      expect(result.result!.doseMaxMg, 400.0); // Capped
      expect(result.result!.maxTotalCapped, true);
    });

    test('converts mcg/kg to mg for volume', () {
      final drug = Drug.fromJson({
        'id': 'd002',
        'name': 'Tranzorel',
        'concentration': '1 mg/mL',
        'route': 'IM',
        'doses': {
          'dog': {'min': 10, 'max': 20, 'unit': 'mcg/kg'},
        },
      });

      final result = DoseCalculator.calculate(
        drug: drug,
        species: 'dog',
        weightKg: 10,
      );

      expect(result.error, isNull);
      // 10 mcg/kg * 10 kg = 100 mcg = 0.1 mg
      expect(result.result!.doseMinMg, closeTo(0.1, 0.001));
      expect(result.result!.volumeMinMl, closeTo(0.1, 0.001));
    });

    test('rejects withdrawn drug', () {
      final drug = Drug.fromJson({
        'id': 'd001',
        'name': 'Veloxamine',
        'concentration': '50 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 5, 'max': 10, 'unit': 'mg/kg'},
        },
      }).copyWithWithdrawn(reason: 'Safety concern');

      final result = DoseCalculator.calculate(
        drug: drug,
        species: 'dog',
        weightKg: 20,
      );

      expect(result.error, isNotNull);
      expect(result.error, contains('withdrawn'));
    });
  });

  group('Volume Formatting', () {
    test('small volumes get 2 decimal places', () {
      expect(formatVolumeMl(0.07), '0.07');
    });

    test('tiny volumes get 3 decimal places', () {
      expect(formatVolumeMl(0.005), '0.005');
    });

    test('medium volumes get 2 decimal places', () {
      expect(formatVolumeMl(2.5), '2.50');
    });

    test('large volumes get 1 decimal place', () {
      expect(formatVolumeMl(38.4), '38.4');
    });
  });
}
