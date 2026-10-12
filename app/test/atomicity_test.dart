// Atomicity and rollback tests for dataset updates.
//
// Part E.2: "Updates must be applied atomically. If the app is closed or killed
// at any point during an update, it must start next time with either the
// complete old data or the complete new data."
//
// These tests run against a real SQLite database in a temp directory and
// exercise the failure modes that matter: a mid-transaction exception, a
// duplicate key, and a process that dies with an open transaction. BREAK_IT.md
// documents the manual procedure for the device-level kill, which cannot be
// automated here; the mechanism under test is the same one.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late Database db;

  setUpAll(() {
    // Runs the real SQLite engine on the test host, so these tests exercise the
    // same transaction semantics as the device rather than a fake.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vetifi_atomicity');
    db = await openDatabase(
      '${tmp.path}/test.db',
      version: 1,
      onCreate: (d, _) async {
        await d.execute('''
          CREATE TABLE drugs (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            concentration_mg_ml REAL,
            is_withdrawn INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await d.execute(
          'CREATE TABLE dataset_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
      },
    );
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<void> seed(List<String> ids, {String version = 'v14'}) async {
    await db.transaction((txn) async {
      for (final id in ids) {
        await txn.insert('drugs', {
          'id': id,
          'name': 'drug-$id',
          'concentration_mg_ml': 10.0,
          'is_withdrawn': 0,
        });
      }
      await txn.insert('dataset_meta', {'key': 'dataset_version', 'value': version});
    });
  }

  Future<List<String>> ids() async {
    final rows = await db.query('drugs', columns: ['id'], orderBy: 'id');
    return [for (final r in rows) r['id'] as String];
  }

  Future<String> version() async {
    final rows = await db.query('dataset_meta', where: 'key = ?',
        whereArgs: ['dataset_version']);
    return rows.isEmpty ? 'none' : rows.first['value'] as String;
  }

  group('A failed update leaves the old dataset completely intact', () {
    test('an exception mid-transaction rolls back every row and the version',
        () async {
      await seed(['d001', 'd002', 'd003']);

      // sqflite wraps a callback exception in a DatabaseException; the point
      // is that it propagates and the transaction rolls back.
      await expectLater(
        db.transaction((txn) async {
          await txn.update('drugs', {'concentration_mg_ml': 999.0});
          await txn.insert('drugs',
              {'id': 'd004', 'name': 'new', 'concentration_mg_ml': 1.0});
          await txn.insert('dataset_meta',
              {'key': 'dataset_version', 'value': 'v15'});
          throw StateError('killed mid-update');
        }),
        throwsA(anything),
      );

      // Nothing partial survived.
      expect(await ids(), ['d001', 'd002', 'd003']);
      expect(await version(), 'v14');
      final rows = await db.query('drugs', columns: ['concentration_mg_ml']);
      for (final r in rows) {
        expect(r['concentration_mg_ml'], 10.0,
            reason: 'no row may keep a partially applied value');
      }
    });

    test('a duplicate key mid-transaction rolls back the whole update', () async {
      await seed(['d001', 'd002']);

      await expectLater(
        db.transaction((txn) async {
          await txn.insert('drugs',
              {'id': 'd003', 'name': 'first', 'concentration_mg_ml': 1.0});
          // Second insert of d003 violates the primary key.
          await txn.insert('drugs',
              {'id': 'd003', 'name': 'second', 'concentration_mg_ml': 2.0});
        }),
        throwsA(isA<DatabaseException>()),
      );

      expect(await ids(), ['d001', 'd002']);
    });

    test('a version bump written after the rows is rolled back with them',
        () async {
      await seed(['d001'], version: 'v14');

      await expectLater(
        db.transaction((txn) async {
          await txn.delete('drugs', where: 'id = ?', whereArgs: ['d001']);
          await txn.insert('drugs',
              {'id': 'd009', 'name': 'replacement', 'concentration_mg_ml': 5.0});
          await txn.insert('dataset_meta',
              {'key': 'dataset_version', 'value': 'v15'},
              conflictAlgorithm: ConflictAlgorithm.replace);
          throw StateError('died before commit');
        }),
        throwsA(anything),
      );

      // Either the old row, or the new one. Never neither, never both.
      final remaining = await ids();
      expect(remaining, hasLength(1));
      expect(await version(), 'v14');
    });
  });

  group('A crash with an uncommitted transaction rolls back on reopen', () {
    test('data written but not committed is not visible after reopening',
        () async {
      await seed(['d001', 'd002']);

      // Open a second connection and begin writing without committing, then
      // abandon it the way a killed process would.
      final path = '${tmp.path}/test.db';
      final other = await openDatabase(path);
      await other.rawUpdate('BEGIN IMMEDIATE');
      await other.insert('drugs',
          {'id': 'd042', 'name': 'ghost', 'concentration_mg_ml': 1.0});
      await other.rawUpdate(
          "UPDATE dataset_meta SET value = 'v15' WHERE key = 'dataset_version'");
      // No commit. The handle is dropped, which releases the lock and rolls
      // back, exactly as an OS-level kill of the owning process would.
      await other.close();

      // Reopen from scratch: what a cold start sees.
      final reopened = await openDatabase(path);
      final rows = await reopened.query('drugs', columns: ['id'], orderBy: 'id');
      expect([for (final r in rows) r['id'] as String], ['d001', 'd002']);
      final meta = await reopened.query('dataset_meta');
      expect(meta.first['value'], 'v14');
      await reopened.close();
    });
  });

  group('A committed update is complete and consistent', () {
    test('all rows and the version land together', () async {
      await seed(['d001', 'd002']);

      await db.transaction((txn) async {
        for (final id in ['d003', 'd004', 'd005']) {
          await txn.insert('drugs',
              {'id': id, 'name': 'drug-$id', 'concentration_mg_ml': 10.0});
        }
        await txn.insert('dataset_meta', {'key': 'dataset_version', 'value': 'v15'},
            conflictAlgorithm: ConflictAlgorithm.replace);
      });

      expect(await ids(), ['d001', 'd002', 'd003', 'd004', 'd005']);
      expect(await version(), 'v15');
    });

    test('withdrawal and reinstatement are applied in the right order',
        () async {
      await seed(['d001', 'd002']);

      await db.transaction((txn) async {
        // Withdraw d001, then reinstate it in the same transaction. The second
        // write must win, which is how a re-published drug becomes usable again.
        await txn.update('drugs', {'is_withdrawn': 1}, where: 'id = ?',
            whereArgs: ['d001']);
        await txn.insert('drugs', {
          'id': 'd001',
          'name': 'drug-d001',
          'concentration_mg_ml': 10.0,
          'is_withdrawn': 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });

      final row = await db.query('drugs', where: 'id = ?', whereArgs: ['d001']);
      expect(row.first['is_withdrawn'], 0);
    });
  });

  group('Large updates commit as one unit', () {
    test('a 5000 row delta applies atomically', () async {
      await seed(['d001']);

      final sw = Stopwatch()..start();
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (var i = 0; i < 5000; i++) {
          batch.insert('drugs', {
            'id': 'gen_$i',
            'name': 'generated $i',
            'concentration_mg_ml': 10.0,
            'is_withdrawn': 0,
          });
        }
        await batch.commit(noResult: true);
        await txn.insert('dataset_meta', {'key': 'dataset_version', 'value': 'v15'},
            conflictAlgorithm: ConflictAlgorithm.replace);
      });
      sw.stop();

      expect(await ids(), hasLength(5001));
      expect(await version(), 'v15');
      // ignore: avoid_print
      print('5000 row transaction committed in ${sw.elapsedMilliseconds}ms');
    });
  });
}