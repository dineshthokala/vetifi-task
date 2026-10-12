/// Coordinates dataset sync and calculation-log upload.
///
/// Wraps [UpdateService] so that callers get one answer to "did the dataset
/// change?" rather than having to interpret an [UpdateStatus] themselves, and
/// so that a failed sync is reported rather than swallowed.
library;

import 'package:connectivity_plus/connectivity_plus.dart';

import 'database_service.dart';
import 'update_service.dart';

class SyncOutcome {
  /// True when the installed dataset was replaced.
  final bool datasetChanged;

  final String datasetMessage;

  /// True when the update could not be completed. Distinct from "offline":
  /// this covers a rejected signature or a malformed payload, which are the
  /// cases an operator needs to see.
  final bool datasetFailed;

  final int logsUploaded;

  const SyncOutcome({
    required this.datasetChanged,
    required this.datasetMessage,
    required this.datasetFailed,
    this.logsUploaded = 0,
  });
}

class SyncService {
  /// Whether the device currently reports a usable connection.
  ///
  /// Checked before attempting a sync so a device in airplane mode does not
  /// pay a connection timeout on every cold start.
  static Future<bool> get hasConnection async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.any((r) => r != ConnectivityResult.none);
    } catch (_) {
      // If the platform channel is unavailable, assume there may be a
      // connection and let the request itself decide.
      return true;
    }
  }

  /// Runs a full sync.
  ///
  /// Safe to call offline: with no connection it returns immediately and
  /// reports that the app is working from its local dataset.
  static Future<SyncOutcome> syncNow({bool force = false}) async {
    if (!force && !await hasConnection) {
      return const SyncOutcome(
        datasetChanged: false,
        datasetMessage: 'Offline. Using the dataset stored on this device.',
        datasetFailed: false,
      );
    }

    final before = await DatabaseService.getDatasetVersion();

    UpdateOutcome outcome;
    try {
      outcome = await UpdateService.checkForUpdate();
    } catch (_) {
      return const SyncOutcome(
        datasetChanged: false,
        datasetMessage: 'Could not reach the dataset server. '
            'Using the dataset stored on this device.',
        datasetFailed: false,
      );
    }

    final after = await DatabaseService.getDatasetVersion();
    final changed = before != after;

    // Log upload is attempted even when the dataset is up to date, so a device
    // that has been offline for a while still drains its backlog.
    var uploaded = 0;
    try {
      uploaded = await UpdateService.uploadCalcLogs();
    } catch (_) {
      // Logs stay pending and retry on the next sync.
    }

    return SyncOutcome(
      datasetChanged: changed,
      datasetMessage: outcome.message,
      datasetFailed: switch (outcome.status) {
        UpdateStatus.manifestRejected ||
        UpdateStatus.payloadRejected ||
        UpdateStatus.versionMismatch ||
        UpdateStatus.notNewer ||
        UpdateStatus.baseMismatch ||
        UpdateStatus.malformed =>
          true,
        _ => false,
      },
      logsUploaded: uploaded,
    );
  }
}