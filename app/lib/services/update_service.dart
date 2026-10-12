/// Update service for checking and applying dataset updates from the server.
///
/// Responsibilities, in the order they matter clinically:
///
///  1. **Authenticity.** Every payload is verified against an Ed25519 public key
///     compiled into the app *before* it is parsed or stored. A missing
///     signature is a failure, not a pass.
///  2. **Integrity.** The SHA-256 of the exact bytes received must equal the
///     value the signed manifest committed to.
///  3. **Freshness.** The payload must declare a version newer than the one
///     installed, so a validly signed but old payload cannot roll the dataset
///     back onto a known-bad concentration.
///  4. **Atomicity.** Nothing is written unless all of the above hold, and the
///     write itself is a single SQLite transaction.
///
/// There is no network access anywhere in the calculation path. This service
/// runs from a background sync at app start and on demand from the settings
/// screen, never while a dose is being computed.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;
import 'package:http/http.dart' as http;

import '../models/drug.dart';
import 'database_service.dart';

/// Why an update attempt ended the way it did. Surfaced in the settings screen
/// so a failed sync is diagnosable instead of silent.
enum UpdateStatus {
  /// Client is already on the newest version.
  upToDate,

  /// A newer version was downloaded, verified and applied.
  applied,

  /// The manifest itself failed signature or hash verification.
  manifestRejected,

  /// The payload failed signature or hash verification.
  payloadRejected,

  /// The payload's declared version did not match the manifest's.
  versionMismatch,

  /// The payload was not newer than what is installed (anti-rollback).
  notNewer,

  /// The delta's base version did not match what is installed.
  baseMismatch,

  /// The payload was truncated or otherwise not valid JSON.
  malformed,

  /// The network request failed, or the server was unreachable.
  networkError,

  /// The server does not know the version this client reported.
  unknownClientVersion,
}

class UpdateOutcome {
  final UpdateStatus status;
  final String? version;
  final String? detail;

  const UpdateOutcome(this.status, {this.version, this.detail});

  bool get changedData => status == UpdateStatus.applied;

  /// Message suitable for showing to a clinician.
  String get message {
    final suffix = detail == null ? '' : ' ($detail)';
    switch (status) {
      case UpdateStatus.upToDate:
        return 'Dataset is up to date.';
      case UpdateStatus.applied:
        return 'Updated to dataset $version.';
      case UpdateStatus.manifestRejected:
        return 'Update refused: the manifest failed signature verification$suffix.';
      case UpdateStatus.payloadRejected:
        return 'Update refused: the dataset failed verification$suffix.';
      case UpdateStatus.versionMismatch:
        return 'Update refused: the payload did not match the manifest$suffix.';
      case UpdateStatus.notNewer:
        return 'Update refused: the offered dataset is not newer than the '
            'installed one.';
      case UpdateStatus.baseMismatch:
        return 'Update refused: the delta does not apply to the installed '
            'dataset version.';
      case UpdateStatus.malformed:
        return 'Update refused: the dataset could not be read$suffix.';
      case UpdateStatus.unknownClientVersion:
        return 'The server does not recognise this device\'s dataset '
            'version; a full dataset will be requested.';
      case UpdateStatus.networkError:
        return 'Could not reach the dataset server. Working offline$suffix.';
    }
  }
}

class UpdateService {
  /// Default server URL: the host machine as seen from an Android emulator.
  static const String defaultServerUrl = 'http://10.0.2.2:8000';
  static String _serverUrl = defaultServerUrl;

/// The server's Ed25519 public key, hex encoded.
  ///
  /// The app holds only this value. There is no way to fetch a replacement key
  /// at runtime, which is a deliberate trade-off discussed in DECISIONS.md
  /// question 5: key rotation requires an app release unless the app also
  /// supports a signed revocation list, which this version does not.
  static const String _compiledInPublicKeyHex =
      '2f67f2dbc66691e45f77742b1dbfd51a95519561826baf7e68116fbbce45c843';

  /// The key actually used for verification.
  ///
  /// Normally [compiledInPublicKeyHex]. Tests may substitute their own key so
  /// they can sign and verify without depending on the repository's private
  /// key; [restorePublicKey] puts the compiled-in value back.
  static String serverPublicKeyHex = _compiledInPublicKeyHex;

  /// Overrides the verification key. Test-only; never called in app code.
  static set serverPublicKeyHexForTest(String hex) => serverPublicKeyHex = hex;

  /// Restores the compiled-in key.
  static void restorePublicKey() =>
      serverPublicKeyHex = _compiledInPublicKeyHex;

  /// The key as compiled into the build, for display in diagnostics.
  static String get compiledInPublicKeyHex => _compiledInPublicKeyHex;

  /// Schema version this build understands.
  static const int supportedSchemaVersion = 2;

  static String get serverUrl => _serverUrl;

  static void setServerUrl(String url) {
    var cleaned = url.trim();
    if (cleaned.endsWith('/')) cleaned = cleaned.substring(0, cleaned.length - 1);
    _serverUrl = cleaned;
  }

  static void resetServerUrl() => _serverUrl = defaultServerUrl;

  /// Verifies an Ed25519 signature over UTF-8 text.
  ///
  /// Returns false on any error, including a malformed key or signature, so
  /// that an exception can never be mistaken for a successful verification.
  static bool verifySignature(String message, String? signatureHex) {
    if (signatureHex == null || signatureHex.isEmpty) return false;
    try {
      final pubKeyBytes = Uint8List.fromList(hex.decode(serverPublicKeyHex));
      final sigBytes = Uint8List.fromList(hex.decode(signatureHex));
      if (sigBytes.length != 64) return false;
      final pubKey = ed.PublicKey(pubKeyBytes);
      return ed.verify(pubKey, Uint8List.fromList(utf8.encode(message)), sigBytes);
    } catch (_) {
      return false;
    }
  }

  /// Checks the manifest for a newer dataset.
  ///
  /// The manifest is signed with the same key as payloads, and a missing or
  /// invalid signature is a hard failure.
  static Future<UpdateOutcome> checkForUpdate() async {
    final currentVersion = await DatabaseService.getDatasetVersion();

    http.Response response;
    try {
      response = await http
          .get(
            Uri.parse(
              '$_serverUrl/v1/manifest'
              '?schema=$supportedSchemaVersion&current=$currentVersion',
            ),
            headers: {'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      return const UpdateOutcome(UpdateStatus.networkError);
    }

    if (response.statusCode == 304) {
      return const UpdateOutcome(UpdateStatus.upToDate);
    }
    if (response.statusCode != 200) {
      return UpdateOutcome(
        UpdateStatus.networkError,
        detail: 'HTTP ${response.statusCode}',
      );
    }

    final signature = response.headers['x-signature'];
    if (!verifySignature(response.body, signature)) {
      // Required, not optional. Treating an absent signature as "no signature
      // to check" would let anyone who can strip a header bypass verification.
      return const UpdateOutcome(
        UpdateStatus.manifestRejected,
        detail: 'missing or invalid X-Signature',
      );
    }

    final Map<String, dynamic> manifest;
    try {
      manifest = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      return const UpdateOutcome(UpdateStatus.malformed, detail: 'manifest');
    }

    final latestVersion = manifest['latest_version'] as String?;
    if (latestVersion == null) {
      return const UpdateOutcome(UpdateStatus.malformed, detail: 'manifest');
    }

    final expectedHash = manifest['sha256'] as String?;
    if (expectedHash == null || expectedHash.isEmpty) {
      return const UpdateOutcome(
        UpdateStatus.manifestRejected,
        detail: 'manifest did not commit to a payload hash',
      );
    }

    final currentNumber = parseVersionNumber(currentVersion);
    final latestNumber = parseVersionNumber(latestVersion);
    if (currentNumber != null &&
        latestNumber != null &&
        latestNumber <= currentNumber) {
      return UpdateOutcome(UpdateStatus.notNewer, version: latestVersion);
    }

    // If the server cannot produce a delta from our version, we must take a
    // full snapshot. Say so explicitly rather than relying on a 404 later.
    final deltaAvailable = manifest['delta_available'] as bool? ?? false;
    final fetchAsSnapshot = !deltaAvailable;

    return await downloadAndApply(
      manifestVersion: latestVersion,
      expectedHash: expectedHash,
      manifestSignature: manifest['signature'] as String?,
      baseVersion: currentVersion,
      fetchAsSnapshot: fetchAsSnapshot,
    );
  }

  /// Downloads, verifies and atomically applies a dataset.
  ///
  /// Exposed separately from [checkForUpdate] so tests can drive it with a
  /// tampered, truncated or mis-signed payload without a live server.
  static Future<UpdateOutcome> downloadAndApply({
    required String manifestVersion,
    required String expectedHash,
    required String? manifestSignature,
    required String baseVersion,
    bool fetchAsSnapshot = false,
  }) async {
    final url = fetchAsSnapshot
        ? '$_serverUrl/v1/datasets/$manifestVersion'
        : '$_serverUrl/v1/datasets/$manifestVersion?from=$baseVersion';

    final http.Response response;
    try {
      response = await http
          .get(Uri.parse(url), headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 30));
    } catch (_) {
      return const UpdateOutcome(UpdateStatus.networkError);
    }

    if (response.statusCode != 200) {
      // 404 here means the server cannot serve a delta from our version. That
      // is recoverable: ask for the full snapshot instead.
      if (response.statusCode == 404 && !fetchAsSnapshot) {
        return downloadAndApply(
          manifestVersion: manifestVersion,
          expectedHash: expectedHash,
          manifestSignature: manifestSignature,
          baseVersion: baseVersion,
          fetchAsSnapshot: true,
        );
      }
      return UpdateOutcome(
        UpdateStatus.networkError,
        detail: 'HTTP ${response.statusCode}',
      );
    }

    final body = response.body;

    // 1. Integrity. The manifest committed to this exact hash, and the
    //    manifest itself was signature-checked above, so a mismatch means the
    //    bytes were altered or truncated in transit.
    final actualHash = sha256.convert(utf8.encode(body)).toString();
    if (actualHash != expectedHash) {
      return const UpdateOutcome(
        UpdateStatus.payloadRejected,
        detail: 'SHA-256 mismatch',
      );
    }

    // Cross-check the transport header when present. Both must agree.
    final headerSha = response.headers['x-sha256'];
    if (headerSha != null && headerSha != actualHash) {
      return const UpdateOutcome(
        UpdateStatus.payloadRejected,
        detail: 'X-SHA256 header disagrees with the body',
      );
    }

    // 2. Authenticity. Required. The signature may arrive on the response or
    //    be carried inside the already-verified manifest.
    final signature = response.headers['x-signature'] ?? manifestSignature;
    if (!verifySignature(body, signature)) {
      return const UpdateOutcome(
        UpdateStatus.payloadRejected,
        detail: 'missing or invalid Ed25519 signature',
      );
    }

    // 3. Structure. A truncated body fails here rather than being partially
    //    applied.
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      return const UpdateOutcome(UpdateStatus.malformed, detail: 'not JSON');
    }

    // 4. Schema compatibility.
    final schemaVersion = data['schema_version'];
    if (schemaVersion != supportedSchemaVersion) {
      return UpdateOutcome(
        UpdateStatus.payloadRejected,
        detail: 'unsupported schema_version $schemaVersion',
      );
    }

    // 5. The payload must agree with the manifest about which version it is.
    //    Without this a validly signed older payload could be filed under a
    //    newer version label.
    final payloadVersion = data['dataset_version'] as String?;
    if (payloadVersion == null || payloadVersion != manifestVersion) {
      return UpdateOutcome(
        UpdateStatus.versionMismatch,
        version: manifestVersion,
        detail: payloadVersion == null
            ? 'payload did not declare a version'
            : 'payload declared $payloadVersion',
      );
    }

    final isFullSnapshot = data['drugs'] is List && data['upserts'] is! List;
    final payloadBase = data['base_version'] as String?;

    final upserts = <Drug>[];
    final source = isFullSnapshot ? data['drugs'] as List : data['upserts'];
    if (source is List) {
      for (final entry in source) {
        if (entry is Map<String, dynamic>) {
          upserts.add(Drug.fromJson(entry));
        }
      }
    }

    final withdrawn = <String>[];
    if (data['withdrawn'] is List) {
      for (final id in data['withdrawn'] as List) {
        if (id is String) withdrawn.add(id);
      }
    }

    final withdrawnReasons = <String, String>{};
    if (data['withdrawn_reasons'] is Map) {
      for (final entry in (data['withdrawn_reasons'] as Map).entries) {
        withdrawnReasons['${entry.key}'] = '${entry.value}';
      }
    }

    // 6. Apply atomically, with the anti-rollback and base-version guards.
    try {
      final result = await DatabaseService.applyUpdate(
        newVersion: manifestVersion,
        schemaVersion: supportedSchemaVersion,
        upserts: upserts,
        withdrawn: withdrawn,
        withdrawnReasons: withdrawnReasons,
        baseVersion: isFullSnapshot ? '' : (payloadBase ?? baseVersion),
        isFullSnapshot: isFullSnapshot,
      );

      switch (result) {
        case ApplyResult.applied:
          return UpdateOutcome(UpdateStatus.applied, version: manifestVersion);
        case ApplyResult.notNewer:
          return UpdateOutcome(UpdateStatus.notNewer, version: manifestVersion);
        case ApplyResult.baseMismatch:
          return UpdateOutcome(UpdateStatus.baseMismatch, version: manifestVersion);
      }
    } catch (_) {
      // A failed transaction leaves the previous dataset intact.
      return const UpdateOutcome(
        UpdateStatus.payloadRejected,
        detail: 'could not be stored',
      );
    }
  }

  /// Uploads pending calculation logs.
  ///
  /// Batched and resumable: only the IDs the server confirms are marked as
  /// uploaded, so an interrupted upload re-sends rather than silently dropping
  /// records. The server deduplicates on calc_id, so a re-send is harmless.
  static Future<int> uploadCalcLogs() async {
    var uploaded = 0;
    // Bound the work per call so a very backlogged device does not hold the
    // sync open indefinitely.
    for (var page = 0; page < 10; page++) {
      final logs = await DatabaseService.getUnuploadedLogs();
      if (logs.isEmpty) break;

      final http.Response response;
      try {
        response = await http
            .post(
              Uri.parse('$_serverUrl/v1/calc_logs'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'logs': logs}),
            )
            .timeout(const Duration(seconds: 15));
      } catch (_) {
        break; // Offline. The logs stay pending and retry on the next sync.
      }

      if (response.statusCode != 200 && response.statusCode != 201) break;

      // Trust only what the server actually recorded. `inserted` plus
      // `duplicates` accounts for every row we sent; anything else means the
      // server dropped records and we must not mark them as uploaded.
      int accounted = 0;
      try {
        final body = jsonDecode(response.body) as Map<String, dynamic>;
        accounted = ((body['inserted'] as num?)?.toInt() ?? 0) +
            ((body['duplicates'] as num?)?.toInt() ?? 0);
      } catch (_) {
        break;
      }
      if (accounted < logs.length) break;

      await DatabaseService.markLogsUploaded(
        logs.map((l) => l['calc_id'] as String).toList(),
      );
      uploaded += logs.length;

      if (logs.length < 200) break;
    }
    return uploaded;
  }

  /// Runs a full background sync: check for an update, then flush logs.
  static Future<UpdateOutcome> backgroundSync() async {
    final outcome = await checkForUpdate();
    await uploadCalcLogs();
    return outcome;
  }
}

