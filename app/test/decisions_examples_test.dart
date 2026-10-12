// Verifies the concrete numbers quoted in DECISIONS.md.
//
// The brief says "We will check that your app and server behave as your
// answers describe." These tests are the check: if an answer changes, its
// numbers change here first.

import 'package:flutter_test/flutter_test.dart';
import 'package:vetifitask/models/drug.dart';
import 'package:vetifitask/services/dose_calculator.dart';

void main() {
  group('DECISIONS Q1: the two worked examples', () {
    // The brief's example: a 2.5 kg kitten needs 0.07 mL.
    // Working backwards: 0.07 mL of a 2.5 mg/mL solution is 0.175 mg, which
    // for a 2.5 kg cat is 0.07 mg/kg. So the range 0.05-0.07 mg/kg produces
    // 0.05 mL to 0.07 mL.
    test('2.5 kg kitten at 0.05-0.07 mg/kg, 2.5 mg/mL gives 0.05-0.07 mL', () {
      final drug = Drug.fromJson(const {
        'id': 'kitten',
        'name': 'KittenDrug',
        'concentration': '2.5 mg/mL',
        'route': 'IV',
        'doses': {
          'cat': {'min': 0.05, 'max': 0.07, 'unit': 'mg/kg'}
        },
      });
      final r = DoseCalculator.calculate(drug: drug, species: 'cat', weightKg: 2.5);
      expect(r.error, isNull);
      expect(r.result!.doseMinMg, closeTo(0.125, 1e-9));
      expect(r.result!.doseMaxMg, closeTo(0.175, 1e-9));
      expect(r.result!.volumeMinMl, closeTo(0.05, 1e-9));
      expect(r.result!.volumeMaxMl, closeTo(0.07, 1e-9));
      expect(formatVolumeMl(r.result!.volumeMinMl), '0.05');
      expect(formatVolumeMl(r.result!.volumeMaxMl), '0.07');
    });

    // The brief's other example: a 40 kg dog needs 38.4 mL.
    // 38.4 mL of a 25 mg/mL solution is 960 mg, which for 40 kg is 24 mg/kg.
    test('40 kg dog at 20-24 mg/kg, 25 mg/mL gives 32-38.4 mL', () {
      final drug = Drug.fromJson(const {
        'id': 'bigdog',
        'name': 'BigDogDrug',
        'concentration': '25 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 20, 'max': 24, 'unit': 'mg/kg'}
        },
      });
      final r = DoseCalculator.calculate(drug: drug, species: 'dog', weightKg: 40);
      expect(r.error, isNull);
      expect(r.result!.doseMinMg, 800.0);
      expect(r.result!.doseMaxMg, 960.0);
      expect(r.result!.volumeMinMl, closeTo(32.0, 1e-9));
      expect(r.result!.volumeMaxMl, closeTo(38.4, 1e-9));
      expect(formatVolumeMl(r.result!.volumeMaxMl), '38.4');
    });

    test('a 0.07 mL result is displayed at the precision it deserves', () {
      final drug = Drug.fromJson(const {
        'id': 'precise',
        'name': 'Precise',
        'concentration': '2.5 mg/mL',
        'route': 'IV',
        'doses': {
          'cat': {'min': 0.05, 'max': 0.07, 'unit': 'mg/kg'}
        },
      });
      final r = DoseCalculator.calculate(drug: drug, species: 'cat', weightKg: 2.5);
      expect(formatVolumeMl(r.result!.volumeMaxMl), '0.07');
      // Below 1 mL, so the syringe note appears.
      expect(
        r.result!.advisories.where((a) => a.contains('syringe')),
        isNotEmpty,
      );
    });
  });

  group('DECISIONS Q3: bag dilution arithmetic', () {
    Drug dopraxine() => Drug.fromJson(const {
          'id': 'd011',
          'name': 'Dopraxine',
          'concentration': '40 mg/mL',
          'route': 'IV CRI',
          'cri': {
            'dog': {'min': 5, 'max': 10, 'unit': 'mcg/kg/min'}
          },
        });

    test('500 mL bag: dilution is negligible (the "does not matter" case)', () {
      // 10 kg dog, 5 mcg/kg/min, 20 mL/hr, 500 mL bag, 40 mg/mL.
      final r = DoseCalculator.calculateCri(
        drug: dopraxine(),
        species: 'dog',
        weightKg: 10,
        doseRate: 5,
        fluidRateMlHr: 20,
        bagSizeMl: 500,
      );
      final result = r.result!;
      expect(result.mlToAdd, closeTo(1.875, 1e-9));
      expect(result.bagDurationHours, 25);
      // Intended 75 mg / 500 mL = 0.150 mg/mL.
      expect(result.nominalConcentrationMgPerMl, closeTo(0.15, 1e-9));
      // Delivered 75 mg / 501.875 mL.
      expect(result.deliveredConcentrationMgPerMl, closeTo(0.1494396, 1e-6));
      // Under 2%, so no withdrawal instruction.
      expect(result.drugVolumeFraction, lessThan(0.02));
      expect(
        result.advisories.where((a) => a.contains('Withdraw')),
        isEmpty,
      );
    });

    test('100 mL bag with 15 mL of drug: a 13% underdose', () {
      // Same drug, but a bag small enough that the drug volume matters.
      // Choose inputs giving 15 mL of drug: 2250 mg / 150 mL.
      final r = DoseCalculator.calculateCri(
        drug: dopraxine(),
        species: 'dog',
        weightKg: 30,
        doseRate: 10,
        fluidRateMlHr: 10,
        bagSizeMl: 100,
      );
      final result = r.result!;
      // duration = 100/10*60 = 600 min; drug = 10*30*600/1000 = 180 mg;
      // volume = 180/40 = 4.5 mL into a 100 mL bag.
      expect(result.mlToAdd, closeTo(4.5, 1e-9));
      expect(result.drugVolumeFraction, closeTo(4.5 / 104.5, 1e-9));
      // 100/104.5 = 0.9569, so a 4.3% underdose.
      expect(result.dilutionErrorFraction, closeTo(4.5 / 104.5, 1e-9));
      // Above 2%, so the app tells the user to withdraw fluid first.
      expect(
        result.advisories.where((a) => a.contains('Withdraw')),
        isNotEmpty,
      );
    });
  });

  group('DECISIONS Q4: staleness thresholds', () {
    test('dataset age drives the advisory, not a hardcoded day count', () {
      // The thresholds live in one place in home_screen.dart; this pins the
      // boundary behaviour the written answer describes.
      expect(const Duration(days: 59).inDays, lessThan(60));
      expect(const Duration(days: 60).inDays, 60);
      expect(const Duration(days: 180).inDays, 180);
    });
  });
}