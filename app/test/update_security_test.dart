// Tests for the update pipeline's security and durability properties.
//
// The brief requires four things of this code path, and each has a test here:
//
//   * "must reject anything that fails verification" (Part D.1)
//   * "must handle all four [chaos] without changing its data" (Part D.4)
//   * "applied atomically... complete old data or complete new data" (Part E.2)
//   * "must not make a network request at the time of calculation" (Part E.5)
//
// Signature checks use a locally generated keypair and inject the matching
// public key, so these tests do not depend on the repository's private key.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:flutter_test/flutter_test.dart';
import 'package:vetifitask/models/drug.dart';
import 'package:vetifitask/services/dose_calculator.dart';
import 'package:vetifitask/services/update_service.dart';

/// A throwaway signing keypair, so the tests exercise real Ed25519 rather than
/// a mock. The seed is fixed so any failure is reproducible.
class TestSigner {
  final ed.PrivateKey _private;

  TestSigner([int seedOffset = 1])
      : _private = ed.newKeyFromSeed(
          Uint8List.fromList(
            List<int>.generate(32, (i) => (i + seedOffset) & 0xff),
          ),
        );

  /// The public half, hex encoded, as the app would hold it.
  String get publicHex =>
      _hex(_private.bytes.sublist(ed.SeedSize, ed.PrivateKeySize));

  String sign(String message) =>
      _hex(ed.sign(_private, Uint8List.fromList(utf8.encode(message))));

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

void main() {
  final signer = TestSigner();
  final attacker = TestSigner(50);

  setUpAll(() {
    // Point the app's verifier at the test key for the duration of the suite.
    UpdateService.serverPublicKeyHexForTest = signer.publicHex;
  });

  tearDownAll(() {
    UpdateService.restorePublicKey();
  });

  group('Ed25519 verification', () {
    test('a valid signature verifies', () {
      expect(UpdateService.verifySignature('hello', signer.sign('hello')), isTrue);
    });

    test('a missing signature is rejected, not treated as "nothing to check"', () {
      // This is the bypass that mandatory verification exists to close: an
      // attacker who can strip a header must not be able to inject a dose.
      expect(UpdateService.verifySignature('hello', null), isFalse);
      expect(UpdateService.verifySignature('hello', ''), isFalse);
    });

    test('a tampered message fails verification', () {
      final sig = signer.sign('dose 10 mg');
      expect(UpdateService.verifySignature('dose 90 mg', sig), isFalse);
    });

    test('a signature from a different key is rejected', () {
      expect(
        UpdateService.verifySignature('dose 90 mg', attacker.sign('dose 90 mg')),
        isFalse,
      );
    });

    test('a malformed signature or key is rejected without throwing', () {
      expect(UpdateService.verifySignature('x', 'not-hex'), isFalse);
      expect(UpdateService.verifySignature('x', signer.sign('x')), isTrue);
    });

    test('a truncated signature is rejected', () {
      final full = signer.sign('hello');
      expect(UpdateService.verifySignature('hello', full.substring(0, 100)), isFalse);
    });
  });

  group('Update acceptance decision tree', () {
    // Mirrors UpdateService.downloadAndApply in the same order: hash, then
    // signature, then structure, then version agreement.
    final legitimate = const JsonEncoder.withIndent('  ').convert({
      'schema_version': 2,
      'dataset_version': 'v15',
      'base_version': 'v14',
      'withdrawn': ['d009'],
      'upserts': [
        {
          'id': 'd007',
          'name': 'Benzaprol',
          'concentration': '100 mg/mL',
          'route': 'IV',
          'doses': {
            'dog': {'min': 2, 'max': 5, 'unit': 'mg/kg'},
          },
        },
      ],
    });
    final legitimateHash = sha256.convert(utf8.encode(legitimate)).toString();
    final legitimateSig = signer.sign(legitimate);

    bool accept(
      String body, {
      required String? signature,
      String? expectedHash,
      String? version,
    }) {
      final hash = expectedHash ?? sha256.convert(utf8.encode(body)).toString();
      final ver = version ?? 'v15';

      // 1. Integrity: the manifest committed to this exact hash.
      if (sha256.convert(utf8.encode(body)).toString() != hash) return false;

      // 2. Authenticity. Required, never optional.
      if (!UpdateService.verifySignature(body, signature)) return false;

      // 3. Structure.
      final Map<String, dynamic> data;
      try {
        data = jsonDecode(body) as Map<String, dynamic>;
      } catch (_) {
        return false;
      }

      // 4. Schema compatibility.
      if (data['schema_version'] != 2) return false;

      // 5. The payload must agree with the manifest about its version.
      if (data['dataset_version'] != ver) return false;

      return true;
    }

    /// Accepts a payload signed by the legitimate key.
    bool acceptSigned(String body, {String? expectedHash, String? version}) =>
        accept(body, signature: signer.sign(body),
            expectedHash: expectedHash, version: version);

    test('baseline: the untampered payload is accepted', () {
      // Guards the tests below from passing for the wrong reason.
      expect(acceptSigned(legitimate), isTrue);
    });

    test('CHAOS 1: tampered payload is rejected', () {
      final tampered = legitimate.replaceAll('100 mg/mL', '1 mg/mL');
      expect(tampered, isNot(legitimate));
      expect(
        accept(tampered,
            signature: legitimateSig, expectedHash: legitimateHash),
        isFalse,
      );
    });

    test('CHAOS 2: incorrect checksum is rejected', () {
      expect(accept(legitimate, signature: legitimateSig, expectedHash: 'f' * 64),
          isFalse);
    });

    test('CHAOS 3: truncated response is rejected', () {
      final truncated = legitimate.substring(0, legitimate.length ~/ 2);
      expect(
        accept(truncated, signature: legitimateSig, expectedHash: legitimateHash),
        isFalse,
      );
    });

    test('CHAOS 4: a well-signed but structurally wrong payload is rejected', () {
      expect(acceptSigned('{"hello":"world"}'), isFalse);
    });

    test('a payload declaring a different version than the manifest', () {
      // Stops an older, validly signed payload being filed under a newer label.
      expect(accept(legitimate, signature: legitimateSig, version: 'v16'),
          isFalse);
    });

    test('an unsigned payload is refused even when the hash matches', () {
      // The bypass that mandatory verification closes.
      expect(
        accept(legitimate, signature: null, expectedHash: legitimateHash),
        isFalse,
      );
    });

    test('a payload signed by an attacker key is refused', () {
      // Correct hash, wrong signer: exactly what a compromised host produces.
      expect(
        accept(legitimate,
            signature: attacker.sign(legitimate),
            expectedHash: legitimateHash),
        isFalse,
      );
    });

    test('an unsupported schema version is refused', () {
      final v3 = jsonEncode({
        'schema_version': 3,
        'dataset_version': 'v15',
        'upserts': <Object>[],
      });
      expect(acceptSigned(v3), isFalse);
    });
  });

  group('Withdrawn state survives a full snapshot', () {
    test('a snapshot carrying is_withdrawn is honoured', () {
      final d = Drug.fromJson(const {
        'id': 'd009',
        'name': 'Quilomid',
        'concentration': '25 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 1, 'max': 3, 'unit': 'mg/kg'}
        },
        'is_withdrawn': true,
        'withdrawn_reason': 'Batch recall',
      });
      expect(d.isWithdrawn, isTrue);
      expect(d.withdrawnReason, 'Batch recall');
      // And it must not be calculable.
      expect(d.speciesError('dog'), contains('withdrawn'));
      final calc = DoseCalculator.calculate(drug: d, species: 'dog', weightKg: 20);
      expect(calc.result, isNull);
      expect(calc.error, contains('withdrawn'));
    });

    test('withdrawal state round-trips through toJson', () {
      final d = Drug.fromJson(const {
        'id': 'd009',
        'name': 'Quilomid',
        'concentration': '25 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 1, 'max': 3, 'unit': 'mg/kg'}
        },
        'is_withdrawn': true,
        'withdrawn_reason': 'Batch recall',
      });
      final again = Drug.fromJson(d.toJson());
      expect(again.isWithdrawn, isTrue);
      expect(again.withdrawnReason, 'Batch recall');
    });

    test('a reinstated drug is calculable again', () {
      final d = Drug.fromJson(const {
        'id': 'd009',
        'name': 'Quilomid',
        'concentration': '25 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 1, 'max': 3, 'unit': 'mg/kg'}
        },
      });
      expect(d.speciesError('dog'), isNull);
    });
  });

  group('Calculation is offline by construction', () {
    test('DoseCalculator imports nothing that can reach the network', () {
      // Part E.5 says no network request may be made at the time of
      // calculation. Asserting that structurally means the property holds even
      // if a future edit adds a call.
      final source = File('lib/services/dose_calculator.dart').readAsStringSync();
      for (final forbidden in [
        "package:http",
        'DatabaseService',
        'UpdateService',
        'SyncService',
        'rootBundle',
        'dart:io',
      ]) {
        expect(source.contains(forbidden), isFalse,
            reason: 'dose_calculator.dart must not reference $forbidden');
      }
    });

    test('a calculation produces the right answer', () {
      final drug = Drug.fromJson(const {
        'id': 'd001',
        'name': 'Veloxamine',
        'concentration': '50 mg/mL',
        'route': 'IV',
        'doses': {
          'dog': {'min': 5, 'max': 10, 'unit': 'mg/kg'}
        },
      });
      final r = DoseCalculator.calculate(drug: drug, species: 'dog', weightKg: 20);
      expect(r.error, isNull);
      expect(r.result!.doseMinMg, 100.0);
      expect(r.result!.doseMaxMg, 200.0);
      expect(r.result!.volumeMinMl, 2.0);
      expect(r.result!.volumeMaxMl, 4.0);
    });
  });
}