import 'dart:convert';
import 'dart:io';

import 'package:vetifitask/services/search_index.dart';

void main() {
  final raw = File('assets/data/generated_50k_drugs.json').readAsStringSync();
  final list = jsonDecode(raw) as List<dynamic>;
  const base = [
    'veloxamine', 'tranzorel', 'pirovane', 'meloquin', 'corvadil',
    'benzaprol', 'zentrafen', 'quilomid', 'dravexin', 'dopraxine',
  ];
  final entries = <({String id, String name})>[
    for (var i = 0; i < base.length; i++) (id: 'base_$i', name: base[i]),
    for (final e in list)
      (id: (e as Map<String, dynamic>)['id'] as String,
       name: ((e['name'] as String).trim()).toLowerCase()),
  ];
  final index = SearchIndex.fromEntries(entries);
  // ignore: avoid_print
  print('entries=${index.length}');

  const queries = [
    'meloquin', 'melox', 'cillin', 'melokin', 'amoxicilli', 'xyzzy',
    'am', 'a', 'amox', 'benz', 'drug', 'xyz', 'qq', 'e', 'in', 'no',
  ];
  for (final q in queries) {
    for (var i = 0; i < 20; i++) {
      index.search(q);
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < 100; i++) {
      index.search(q);
    }
    sw.stop();
    final hits = index.search(q).length;
    // ignore: avoid_print
    print('q="$q" ${(sw.elapsedMicroseconds / 100).toStringAsFixed(0)}us/query hits=$hits');
  }
}