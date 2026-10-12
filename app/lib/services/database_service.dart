/// Local database service using SQLite.
///
/// Handles drug storage, calculation logs, and atomic dataset updates.
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/drug.dart';

/// Parses a dataset version string such as "v14" into its integer number.
///
/// Returns null when the string is not a recognisable version. Used to reject
/// downgrades: a client must never move backwards to an older dataset, because
/// an older dataset may carry a concentration that was later found to be wrong.
int? parseVersionNumber(String? version) {
  if (version == null) return null;
  final match = RegExp(r'^v?(\d+)$', caseSensitive: false)
      .firstMatch(version.trim());
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// Outcome of a [DatabaseService.applyUpdate] attempt.
enum ApplyResult {
  /// The new dataset was written.
  applied,

  /// The incoming version was not newer than the installed one. The stored
  /// dataset is untouched. This is the anti-rollback guard.
  notNewer,

  /// The client is on a version newer than the payload's base version, so a
  /// delta cannot be applied on top of it. The stored dataset is untouched.
  baseMismatch,
}

/// Metadata about the dataset currently installed on the device.
class DatasetInfo {
  final String version;
  final int? versionNumber;
  final int schemaVersion;
  final DateTime? fetchedAt;

  const DatasetInfo({
    required this.version,
    required this.versionNumber,
    required this.schemaVersion,
    required this.fetchedAt,
  });

  static const unknown = DatasetInfo(
    version: 'unknown',
    versionNumber: null,
    schemaVersion: 0,
    fetchedAt: null,
  );

  /// Age of the local dataset, or null if we have never recorded when it
  /// arrived. Drives the staleness advisory in DECISIONS.md question 4.
  Duration? get age {
    if (fetchedAt == null) return null;
    return DateTime.now().difference(fetchedAt!);
  }
}

class DatabaseService {
  static Database? _db;
  static const String _dbName = 'vetifi.db';
  static const int _dbVersion = 2;

  /// Keys used in the dataset_meta table.
  static const String _kVersion = 'dataset_version';
  static const String _kSchemaVersion = 'schema_version';
  static const String _kFetchedAt = 'dataset_fetched_at_ms';

  /// Get the database, initialising if needed.
  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);

    return await openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: (db) async {
        // Required so the app survives being killed mid-update.
        await db.execute('PRAGMA foreign_keys = ON');
      },
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    // Drugs table
    await db.execute('''
      CREATE TABLE drugs (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        raw_name TEXT NOT NULL,
        name_folded TEXT NOT NULL,
        concentration_raw TEXT NOT NULL,
        concentration_mg_ml REAL,
        route TEXT NOT NULL,
        max_total_mg REAL,
        doses_json TEXT NOT NULL,
        cri_json TEXT,
        is_withdrawn INTEGER NOT NULL DEFAULT 0,
        withdrawn_reason TEXT,
        validation_errors_json TEXT NOT NULL DEFAULT '[]',
        raw_json TEXT NOT NULL
      )
    ''');

    // Case-insensitive prefix search (Part B). `name_folded` holds the
    // lower-cased name so LIKE queries can use the index; SQLite's LIKE is
    // case-insensitive for ASCII only, which does not cover every locale.
    await db.execute(
      'CREATE INDEX idx_drugs_name_folded ON drugs(name_folded)',
    );
    await db.execute(
      'CREATE INDEX idx_drugs_withdrawn ON drugs(is_withdrawn)',
    );

    // Calculation logs table
    await db.execute('''
      CREATE TABLE calc_logs (
        calc_id TEXT PRIMARY KEY,
        drug_id TEXT NOT NULL,
        drug_name TEXT NOT NULL,
        species TEXT NOT NULL,
        weight_kg REAL NOT NULL,
        weight_unit TEXT NOT NULL,
        weight_entered REAL NOT NULL,
        dose_min_mg REAL NOT NULL,
        dose_max_mg REAL NOT NULL,
        volume_min_ml REAL NOT NULL,
        volume_max_ml REAL NOT NULL,
        dataset_version TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        uploaded INTEGER NOT NULL DEFAULT 0,
        dose_rate REAL,
        fluid_rate_ml_hr REAL,
        bag_size_ml REAL,
        ml_to_add REAL,
        bag_duration_hrs REAL
      )
    ''');

    // Partial index over pending uploads keeps the Part E.4 upload query from
    // scanning the whole log table once a device has been offline for months.
    await db.execute('''
      CREATE INDEX idx_calc_logs_pending ON calc_logs(uploaded, timestamp)
    ''');

    // Dataset metadata table
    await db.execute('''
      CREATE TABLE dataset_meta (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  /// Migrates v1 -> v2.
  ///
  /// v1 lacked `name_folded` and the fetch timestamp. Both are additive, so the
  /// migration backfills from existing rows rather than discarding the
  /// user's local dataset.
  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      final columns = await db.rawQuery('PRAGMA table_info(drugs)');
      final hasFolded = columns.any((c) => c['name'] == 'name_folded');
      if (!hasFolded) {
        await db.execute(
          'ALTER TABLE drugs ADD COLUMN name_folded TEXT NOT NULL DEFAULT ""',
        );
        await db.execute(
          "UPDATE drugs SET name_folded = lower(trim(raw_name))",
        );
      }
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_drugs_name_folded ON drugs(name_folded)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_drugs_withdrawn ON drugs(is_withdrawn)',
      );
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_calc_logs_pending '
        'ON calc_logs(uploaded, timestamp)',
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Dataset management
  // ---------------------------------------------------------------------------

  /// Loads the bundled datasets on first launch.
  ///
  /// Two assets are merged into one local dataset:
  ///   * `base_dataset_v14.json`      - the content team's base version
  ///   * `generated_50k_drugs.json`  - the Part B search corpus
  ///
  /// Both are applied inside a single transaction, so a device that is killed
  /// during first launch starts again with an empty drugs table rather than a
  /// half-populated one, and the retry succeeds.
  static Future<void> ensureBaseDataset() async {
    final db = await database;
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM drugs'),
    );

    if (count == null || count == 0) {
      await _loadBundledDatasets(db);
    }
  }

  static Future<void> _loadBundledDatasets(Database db) async {
    final baseJson = jsonDecode(
      await rootBundle.loadString('assets/data/base_dataset_v14.json'),
    ) as Map<String, dynamic>;
    final base = Dataset.fromJson(baseJson);

    // The search corpus is a bare JSON array rather than a wrapped dataset, and
    // it carries no version of its own: it is merged into whatever base
    // version is bundled.
    final generatedRaw = await rootBundle.loadString(
      'assets/data/generated_50k_drugs.json',
    );
    final generatedList = jsonDecode(generatedRaw) as List<dynamic>;

    await db.transaction((txn) async {
      await _insertDrugs(txn, base.drugs);
      await _insertDrugs(
        txn,
        generatedList.map((e) => Drug.fromJson(e as Map<String, dynamic>)),
      );
      await _writeMeta(txn, version: base.datasetVersion,
          schemaVersion: base.schemaVersion);
    });
  }

  /// Bulk-inserts drugs in batches.
  ///
  /// A single 50,000 row transaction of individual INSERTs takes long enough to
  /// trip the Android watchdog on a low-end device, so rows are batched. The
  /// whole load is still one outer transaction: either every row lands or none
  /// do.
  static Future<void> _insertDrugs(
    Transaction txn,
    Iterable<Drug> drugs, {
    int batchSize = 500,
  }) async {
    final batch = <Map<String, dynamic>>[];
    for (final drug in drugs) {
      batch.add(_drugToRow(drug));
      if (batch.length >= batchSize) {
        await _flush(txn, batch);
      }
    }
    if (batch.isNotEmpty) await _flush(txn, batch);
  }

  static Future<void> _flush(Transaction txn, List<Map<String, dynamic>> batch) async {
    // INSERT OR REPLACE rather than a Batch, because sqflite's Batch.commit()
    // takes no conflictAlgorithm. REPLACE (not IGNORE) is required: a re-applied
    // delta must overwrite a stale row, including clearing an is_withdrawn flag
    // when a drug is reinstated.
    final sql = '''
      INSERT OR REPLACE INTO drugs (
        id, name, raw_name, name_folded, concentration_raw, concentration_mg_ml,
        route, max_total_mg, doses_json, cri_json, is_withdrawn,
        withdrawn_reason, validation_errors_json, raw_json
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''';
    for (final row in batch) {
      await txn.rawInsert(sql, [
        row['id'],
        row['name'],
        row['raw_name'],
        row['name_folded'],
        row['concentration_raw'],
        row['concentration_mg_ml'],
        row['route'],
        row['max_total_mg'],
        row['doses_json'],
        row['cri_json'],
        row['is_withdrawn'],
        row['withdrawn_reason'],
        row['validation_errors_json'],
        row['raw_json'],
      ]);
    }
  }

  static Future<void> _writeMeta(
    Transaction txn, {
    required String version,
    required int schemaVersion,
    DateTime? fetchedAt,
  }) async {
    final stamp = fetchedAt ?? DateTime.now();
    final entries = <String, String>{
      _kVersion: version,
      _kSchemaVersion: schemaVersion.toString(),
      _kFetchedAt: stamp.millisecondsSinceEpoch.toString(),
    };
    for (final e in entries.entries) {
      await txn.insert(
        'dataset_meta',
        {'key': e.key, 'value': e.value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }

  static Map<String, dynamic> _drugToRow(Drug drug) {
    return {
      'id': drug.id,
      'name': drug.name,
      'raw_name': drug.rawName,
      // Pre-folded for the case-insensitive search index.
      'name_folded': drug.name.toLowerCase(),
      'concentration_raw': drug.concentrationRaw,
      'concentration_mg_ml': drug.concentration?.mgPerMl,
      'route': drug.route,
      'max_total_mg': drug.maxTotalMg,
      'doses_json': jsonEncode(
        drug.doses.map((k, v) => MapEntry(k, v.toJson())),
      ),
      'cri_json': drug.criDoses.isNotEmpty
          ? jsonEncode(drug.criDoses.map((k, v) => MapEntry(k, v.toJson())))
          : null,
      'is_withdrawn': drug.isWithdrawn ? 1 : 0,
      'withdrawn_reason': drug.withdrawnReason,
      'validation_errors_json': jsonEncode(drug.validationErrors),
      'raw_json': jsonEncode(drug.toJson()),
    };
  }

  // ---------------------------------------------------------------------------
  // Drug queries
  // ---------------------------------------------------------------------------

  /// Get all drugs.
  static Future<List<Drug>> getAllDrugs() async {
    final db = await database;
    final rows = await db.query('drugs', orderBy: 'name ASC');
    return rows.map(_drugFromRow).toList();
  }

  /// Returns a bounded candidate set for [query] using indexed SQL.
  ///
  /// This is the cheap first stage of search. It answers "which rows could
  /// possibly match" inside the database engine, using the `name_folded` index
  /// for the prefix predicate, and hands a small pool to the fuzzy stage.
  /// Without it, every keystroke would run Levenshtein across all 50,000 rows
  /// on the UI isolate.
  ///
  /// LIKE wildcards in [query] are escaped, so a user typing "%" searches for
  /// a literal percent sign instead of matching every row.
  static Future<List<Drug>> searchCandidates(
    String query, {
    int limit = 400,
  }) async {
    final db = await database;
    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty) return const [];

    final escaped = trimmed
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');

    final rows = await db.rawQuery(
      "SELECT * FROM drugs "
      "WHERE name_folded LIKE ? ESCAPE '\\' "
      "OR name_folded LIKE ? ESCAPE '\\' "
      'ORDER BY name ASC LIMIT ?',
      ['$escaped%', '%$escaped%', limit],
    );
    return rows.map(_drugFromRow).toList();
  }

  /// Retrieves the drugs with the given IDs, preserving the input order.
  static Future<List<Drug>> getDrugsByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    final db = await database;
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.rawQuery(
      'SELECT * FROM drugs WHERE id IN ($placeholders)',
      ids,
    );
    final byId = {
      for (final row in rows) row['id'] as String: _drugFromRow(row),
    };
    return [for (final id in ids) if (byId[id] != null) byId[id]!];
  }

  /// All names paired with IDs, for building the fuzzy search index.
  ///
  /// Deliberately does not hydrate full [Drug] objects: loading 50,000 of them
  /// costs far more memory than the clinical app needs, because only a handful
  /// are ever opened.
  ///
  /// Content-team entries are returned before generated ones so that, when two
  /// rows are otherwise equally good matches, the real drug wins. This matters:
  /// the Part B corpus contains names that collide with the clinical ones.
  static Future<List<({String id, String name})>> getSearchIndexEntries() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT id, name_folded FROM drugs
      ORDER BY (id LIKE 'gen\\_%' ESCAPE '\\'), name_folded ASC
    ''');
    return [
      for (final row in rows)
        (id: row['id'] as String, name: row['name_folded'] as String),
    ];
  }

  /// Get a drug by ID.
  static Future<Drug?> getDrug(String id) async {
    final db = await database;
    final rows = await db.query('drugs', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return _drugFromRow(rows.first);
  }

  static Drug _drugFromRow(Map<String, dynamic> row) {
    final doses = <String, DoseRange>{};
    final dosesJson =
        jsonDecode(row['doses_json'] as String) as Map<String, dynamic>;
    for (final entry in dosesJson.entries) {
      doses[entry.key] = DoseRange.fromJson(
        entry.value as Map<String, dynamic>,
      );
    }

    final criDoses = <String, CriDose>{};
    if (row['cri_json'] != null) {
      final criJson =
          jsonDecode(row['cri_json'] as String) as Map<String, dynamic>;
      for (final entry in criJson.entries) {
        criDoses[entry.key] = CriDose.fromJson(
          entry.value as Map<String, dynamic>,
        );
      }
    }

    final validationErrors =
        (jsonDecode(row['validation_errors_json'] as String) as List<dynamic>)
            .cast<String>();

    return Drug(
      id: row['id'] as String,
      name: row['name'] as String,
      rawName: row['raw_name'] as String,
      concentrationRaw: row['concentration_raw'] as String,
      concentration: row['concentration_mg_ml'] != null
          ? ParsedConcentration(
              mgPerMl: row['concentration_mg_ml'] as double,
              original: row['concentration_raw'] as String,
            )
          : null,
      route: row['route'] as String,
      maxTotalMg: row['max_total_mg'] as double?,
      doses: doses,
      criDoses: criDoses,
      isWithdrawn: (row['is_withdrawn'] as int) == 1,
      withdrawnReason: row['withdrawn_reason'] as String?,
      validationErrors: validationErrors,
    );
  }

  // ---------------------------------------------------------------------------
  // Atomic dataset updates
  // ---------------------------------------------------------------------------

  /// Apply a dataset update atomically.
  ///
  /// Everything happens inside one SQLite transaction, so a device that is
  /// killed at any point during the update restarts with either the complete
  /// old dataset or the complete new one. See BREAK_IT.md for the manual
  /// procedure that demonstrates this.
  ///
  /// [isFullSnapshot] must be true when the payload carries a complete `drugs`
  /// list rather than a delta. A snapshot is authoritative, so rows missing
  /// from it are deleted. Treating a snapshot as a set of upserts leaves
  /// withdrawn and deleted drugs behind as if they were still current, which is
  /// how a withdrawn drug becomes calculable again.
  static Future<ApplyResult> applyUpdate({
    required String newVersion,
    required int schemaVersion,
    required List<Drug> upserts,
    required List<String> withdrawn,
    required Map<String, String> withdrawnReasons,
    required String baseVersion,
    bool isFullSnapshot = false,
  }) async {
    final db = await database;

    final currentNumber = parseVersionNumber(await getDatasetVersion());
    final newNumber = parseVersionNumber(newVersion);

    // Refuse to move backwards. An older dataset may carry a concentration
    // that has since been found to be wrong, so replaying one is a safety
    // regression even though its signature is valid.
    if (currentNumber != null && newNumber != null && newNumber <= currentNumber) {
      return ApplyResult.notNewer;
    }

    // A delta is only meaningful relative to the version the client already
    // holds. If they disagree, applying it would silently corrupt the dataset.
    if (!isFullSnapshot) {
      final base = parseVersionNumber(baseVersion);
      if (base != null && currentNumber != null && base != currentNumber) {
        return ApplyResult.baseMismatch;
      }
    }

    await db.transaction((txn) async {
      if (isFullSnapshot) {
        // The snapshot is the whole truth. Remove anything it does not list,
        // so withdrawn and deleted drugs do not survive as stale rows.
        final keepIds = upserts.map((d) => d.id).toList();
        if (keepIds.isEmpty) {
          await txn.delete('drugs');
        } else {
          // Chunked to stay under SQLite's variable limit.
          for (var i = 0; i < keepIds.length; i += 500) {
            final chunk = keepIds.sublist(
              i,
              (i + 500).clamp(0, keepIds.length),
            );
            final placeholders = List.filled(chunk.length, '?').join(',');
            await txn.rawDelete(
              'DELETE FROM drugs WHERE id NOT IN ($placeholders)',
              chunk,
            );
          }
        }
      }

      // Withdrawals first, then upserts. A drug that is withdrawn and
      // re-upserted in the same version is a reinstatement, so the upsert wins
      // and the flag clears.
      for (final drugId in withdrawn) {
        final reason = withdrawnReasons[drugId] ?? 'Drug withdrawn';
        await txn.update(
          'drugs',
          {'is_withdrawn': 1, 'withdrawn_reason': reason},
          where: 'id = ?',
          whereArgs: [drugId],
        );
      }

      await _insertDrugs(txn, upserts);

      await _writeMeta(
        txn,
        version: newVersion,
        schemaVersion: schemaVersion,
      );
    });

    return ApplyResult.applied;
  }

  // ---------------------------------------------------------------------------
  // Dataset version
  // ---------------------------------------------------------------------------

  /// Full metadata for the installed dataset.
  static Future<DatasetInfo> getDatasetInfo() async {
    final db = await database;
    final rows = await db.query('dataset_meta');
    final map = {for (final r in rows) r['key'] as String: r['value'] as String};

    final version = map[_kVersion] ?? 'unknown';
    final fetchedMs = int.tryParse(map[_kFetchedAt] ?? '');
    return DatasetInfo(
      version: version,
      versionNumber: parseVersionNumber(version),
      schemaVersion: int.tryParse(map[_kSchemaVersion] ?? '') ?? 0,
      fetchedAt: fetchedMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(fetchedMs),
    );
  }

  /// Get the current dataset version.
  static Future<String> getDatasetVersion() async {
    final db = await database;
    final rows = await db.query(
      'dataset_meta',
      where: 'key = ?',
      whereArgs: [_kVersion],
    );
    if (rows.isEmpty) return 'unknown';
    return rows.first['value'] as String;
  }

  // ---------------------------------------------------------------------------
  // Calculation logs
  // ---------------------------------------------------------------------------

  /// Save a calculation log.
  static Future<void> saveCalcLog(CalculationLog log) async {
    final db = await database;
    await db.insert(
      'calc_logs',
      log.toDbMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore, // Dedup by calc_id
    );
  }

  /// Get a page of un-uploaded calculation logs, oldest first.
  ///
  /// Paged rather than "everything at once": a device that has been offline for
  /// months can hold thousands of logs, and posting them in a single request
  /// risks both a request timeout and an unbounded body on the server.
  static Future<List<Map<String, dynamic>>> getUnuploadedLogs({
    int limit = 200,
  }) async {
    final db = await database;
    return db.query(
      'calc_logs',
      where: 'uploaded = ?',
      whereArgs: [0],
      orderBy: 'timestamp ASC',
      limit: limit,
    );
  }

  /// Count of logs still waiting to be uploaded, for the settings screen.
  static Future<int> pendingLogCount() async {
    final db = await database;
    return Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM calc_logs WHERE uploaded = 0'),
        ) ??
        0;
  }

  /// Mark calculation logs as uploaded.
  static Future<void> markLogsUploaded(List<String> calcIds) async {
    final db = await database;
    final batch = db.batch();
    for (final id in calcIds) {
      batch.update(
        'calc_logs',
        {'uploaded': 1},
        where: 'calc_id = ?',
        whereArgs: [id],
      );
    }
    await batch.commit(noResult: true);
  }
}
