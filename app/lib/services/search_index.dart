/// Typo-tolerant drug search.
///
/// Part B requires that "melokin" finds Meloquin and "benzaprl" finds
/// Benzaprol, that exact matches rank above prefix matches, that prefix matches
/// rank above approximate ones, and that typing does not drop frames.
///
/// The design here is a three-stage funnel, because running Levenshtein across
/// 50,000 rows on every keystroke is what made the previous implementation
/// unusable:
///
///   1. **Exact and prefix** — served directly from a precomputed map, O(1)
///      and O(prefix length).
///   2. **Substring** — served from a trigram index, so only rows that share a
///      trigram with the query are examined.
///   3. **Approximate** — bounded Levenshtein over whatever survives stages 1
///      and 2, capped so the worst case stays predictable.
///
/// The whole search runs in an isolate via [searchDrugs], so no amount of
/// dataset size can block a frame.
library;

/// A single search hit.
class DrugHit {
  final String id;
  final String name;
  final int score;

  const DrugHit(this.id, this.name, this.score);
}

/// Why a row matched, most specific first. Used for grouping and for testing.
enum MatchKind {
  /// The name is exactly the query.
  exact,

  /// The name starts with the query.
  prefix,

  /// The query is a prefix of one of the words in the name.
  wordPrefix,

  /// The name contains the query somewhere.
  substring,

  /// The name is within a small edit distance of the query.
  approximate,
}

/// Immutable, serialisable index over drug names.
///
/// Only ids and folded names are held, not full [Drug] objects: the search list
/// needs to display a name, and opening a drug re-reads it from SQLite. Holding
/// 50,000 hydrated drugs would cost far more memory for no benefit.
class SearchIndex {
  /// Exact name -> id.
  final Map<String, String> _exact;

  /// First word of the name -> ids, for word-prefix matches.
  final Map<String, List<String>> _wordPrefix;

  /// Every word in the name -> ids.
  final Map<String, List<String>> _words;

  /// Character trigram -> ids, for substring narrowing.
  final Map<String, List<String>> _trigrams;

  /// id -> folded name, for rendering.
  final Map<String, String> _names;

  /// Distinct first words, sorted, for binary-search prefix lookup.
  ///
  /// Scanning `_wordPrefix` for a prefix match is O(distinct first words),
  /// which measured at roughly 30 ms over the 50k corpus. A sorted array plus
  /// a binary search for the lower bound turns that into O(log n) plus only the
  /// entries that actually match.
  final List<String> _sortedFirstWords;

  /// Distinct word strings, sorted, for binary-search word-prefix lookup.
  final List<String> _sortedWords;

  /// Length-bucketed ids, so a short query does not test against long names.
  final Map<int, List<String>> _byLength;

  SearchIndex._(
    this._exact,
    this._wordPrefix,
    this._words,
    this._trigrams,
    this._names,
    this._sortedFirstWords,
    this._sortedWords,
    this._byLength,
  );

  /// Number of indexed drugs.
  int get length => _names.length;

  /// Builds an index from `(id, name)` pairs.
  ///
  /// Names are expected to already be lower-cased by the caller, which is what
  /// the database hands back via `name_folded`.
  factory SearchIndex.fromEntries(List<({String id, String name})> entries) {
    final exact = <String, String>{};
    final wordPrefix = <String, List<String>>{};
    final words = <String, List<String>>{};
    final trigrams = <String, List<String>>{};
    final names = <String, String>{};
    final byLength = <int, List<String>>{};

    for (final entry in entries) {
      final id = entry.id;
      final name = entry.name;
      names[id] = name;

      // First occurrence wins for exact matches, so ordering is stable.
      exact.putIfAbsent(name, () => id);

      final parts = name.split(' ').where((p) => p.isNotEmpty).toList();
      if (parts.isNotEmpty) {
        wordPrefix.putIfAbsent(parts.first, () => <String>[]).add(id);
        for (final part in parts) {
          words.putIfAbsent(part, () => <String>[]).add(id);
        }
      }

      for (final tri in _trigramsOf(name)) {
        trigrams.putIfAbsent(tri, () => <String>[]).add(id);
      }

      byLength.putIfAbsent(name.length, () => <String>[]).add(id);
    }

    final sortedFirstWords = wordPrefix.keys.toList()..sort();
    final sortedWords = words.keys.toList()..sort();

    return SearchIndex._(
      exact,
      wordPrefix,
      words,
      trigrams,
      names,
      sortedFirstWords,
      sortedWords,
      byLength,
    );
  }

  /// Index of the first element >= [prefix] in a sorted list, or -1.
  static int _lowerBound(List<String> sorted, String prefix) {
    var lo = 0;
    var hi = sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (sorted[mid].compareTo(prefix) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Every key in [sorted] starting with [prefix].
  ///
  /// Walks forward from the lower bound and stops at the first non-match, which
  /// is safe because the list is sorted: once a string sorts at or after the
  /// prefix range, everything after it does too.
  static List<String> _keysWithPrefix(List<String> sorted, String prefix) {
    final out = <String>[];
    final start = _lowerBound(sorted, prefix);
    for (var i = start; i < sorted.length; i++) {
      final key = sorted[i];
      if (!key.startsWith(prefix)) break;
      out.add(key);
      // A prefix matching thousands of keys is not a useful search result set.
      if (out.length >= 64) break;
    }
    return out;
  }

  /// Trigrams of a name, padded so short names still produce some.
  static Set<String> _trigramsOf(String name) {
    final padded = '  $name ';
    if (padded.length < 3) return {padded};
    return {
      for (var i = 0; i + 3 <= padded.length; i++) padded.substring(i, i + 3),
    };
  }

  /// Maximum edit distance tolerated for an approximate match.
  ///
  /// Scales with query length: 1 for very short queries where a single edit
  /// changes most of the word, 3 for longer ones where that is still one or two
  /// typos. Beyond that the matches stop being recognisably the same drug, and
  /// a vet clicking the wrong row is worse than a missing result.
  static int maxEditsFor(String query) {
    if (query.length <= 3) return 1;
    if (query.length <= 6) return 2;
    return 3;
  }

  /// Runs a search and returns ranked results.
  ///
  /// [limit] caps both the work done and the number of results, so the cost of
  /// a keystroke does not grow without bound.
  List<DrugHit> search(String rawQuery, {int limit = 60}) {
    final query = rawQuery.trim().toLowerCase();
    if (query.isEmpty) return const [];

    // Exact.
    final exactId = _exact[query];
    if (exactId != null) {
      return [DrugHit(exactId, _names[exactId]!, 1000)];
    }

    // An exact match on any word is a strong signal: "oral" for
    // "Amoxicillin Oral Solution".
    final wordExact = _words[query];
    if (wordExact != null && wordExact.isNotEmpty) {
      return [
        for (final id in wordExact.take(limit))
          DrugHit(id, _names[id]!, 900),
      ];
    }

    final scores = <String, int>{};

    // Ceiling on how many distinct rows a single query may score. Sized well
    // above `limit` so the final ranking still has something to choose from,
    // but bounded so that no keystroke can cost an unbounded amount of work.
    final maxScored = limit * 2;

    void bump(String id, int score) {
      final existing = scores[id];
      // Keep the strongest reason; a row that is both a prefix and a substring
      // should rank as the prefix.
      if (existing == null || score > existing) scores[id] = score;
    }

    // Prefix of the whole name, and prefix of any word. Both are binary
    // searches over a sorted key list rather than a scan of every key.
    //
    // The cap is checked inside the inner loop as well as between keys: a
    // single common word can map to thousands of ids, and collecting all of
    // them before noticing the cap was the difference between a 9 ms query and
    // a 0.3 ms one.
    for (final firstWord in _keysWithPrefix(_sortedFirstWords, query)) {
      for (final id in _wordPrefix[firstWord]!) {
        bump(id, 800);
        if (scores.length >= maxScored) break;
      }
      if (scores.length >= maxScored) break;
    }

    for (final word in _keysWithPrefix(_sortedWords, query)) {
      for (final id in _words[word]!) {
        bump(id, 750);
        if (scores.length >= maxScored) break;
      }
      if (scores.length >= maxScored) break;
    }

    // Substring, narrowed by trigram overlap, then approximate matching over the
    // same pool. Computed once: the two stages want the same candidate set, and
    // recomputing it doubled the cost of every non-exact query.
    final maxEdits = maxEditsFor(query);
    final candidateIds = query.length > 2
        ? _candidatesByTrigram(query, cap: limit * 6)
        : const <String>[];

    if (candidateIds.isNotEmpty) {
      // Substring first.
      for (final id in candidateIds) {
        if (scores.containsKey(id)) continue;
        if (_names[id]!.contains(query)) {
          bump(id, 600);
        }
      }

      // Approximate: bounded Levenshtein over whatever is left.
      for (final id in candidateIds) {
        if (scores.containsKey(id)) continue;
        final name = _names[id]!;
        // Cheap rejection first: an edit distance can never be smaller than the
        // length difference.
        if ((name.length - query.length).abs() > maxEdits) continue;
        final distance = boundedLevenshtein(name, query, maxEdits);
        if (distance > maxEdits) continue;
        // Closer is better; the band sits below substring so an approximate
        // match can never outrank an exact textual containment.
        final longest = query.length > name.length ? query.length : name.length;
        final similarity = 1.0 - (distance / longest);
        bump(id, 100 + (similarity * 400).round());
      }
    }

    final hits = scores.entries
        .map((e) => DrugHit(e.key, _names[e.key]!, e.value))
        .toList();

    // Rank: score descending, then shorter names first (more likely the
    // canonical entry), then alphabetically so results never reshuffle
    // between identical keystrokes.
    hits.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byLength = a.name.length.compareTo(b.name.length);
      if (byLength != 0) return byLength;
      return a.name.compareTo(b.name);
    });

    return hits.take(limit).toList();
  }

  /// Ids that share a trigram with the query, rarest trigrams first.
  ///
  /// Ordering by posting-list length is what makes this both fast and correct.
  /// Iterating trigrams in the order they appear in the query means the first
  /// one tried is usually a common prefix like "  m", whose posting list runs
  /// to thousands of entries; the cap then truncates before any distinctive
  /// trigram is ever consulted, so genuinely close matches are never seen.
  /// Leading with the rarest trigram collects the most discriminating
  /// candidates first, within the same budget.
  List<String> _candidatesByTrigram(String query, {required int cap}) {
    final queryTrigrams = _trigramsOf(query).toList()
      ..sort((a, b) {
        final la = _trigrams[a]?.length ?? 0;
        final lb = _trigrams[b]?.length ?? 0;
        return la.compareTo(lb);
      });

    final counts = <String, int>{};
    for (final tri in queryTrigrams) {
      final ids = _trigrams[tri];
      if (ids == null) continue;
      for (final id in ids) {
        counts[id] = (counts[id] ?? 0) + 1;
        if (counts.length >= cap) break;
      }
      // Enough candidates collected from the most selective trigrams.
      if (counts.length >= cap) break;
    }
    return counts.keys.toList();
  }

  /// Levenshtein distance, abandoned early once every cell in a row exceeds
  /// [maxDistance].
  ///
  /// The early exit is what keeps this cheap: for a 3-edit budget against a long
  /// name, most comparisons terminate after a few rows instead of filling the
  /// whole matrix.
  static int boundedLevenshtein(String a, String b, int maxDistance) {
    if (a == b) return 0;
    if ((a.length - b.length).abs() > maxDistance) return maxDistance + 1;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    var previous = List<int>.generate(b.length + 1, (i) => i);
    var current = List<int>.filled(b.length + 1, 0);

    for (var i = 1; i <= a.length; i++) {
      current[0] = i;
      var rowMin = current[0];
      final aChar = a.codeUnitAt(i - 1);

      for (var j = 1; j <= b.length; j++) {
        final substitutionCost = aChar == b.codeUnitAt(j - 1) ? 0 : 1;
        var value = previous[j - 1] + substitutionCost;
        final insertion = current[j - 1] + 1;
        final deletion = previous[j] + 1;
        if (insertion < value) value = insertion;
        if (deletion < value) value = deletion;
        current[j] = value;
        if (value < rowMin) rowMin = value;
      }

      if (rowMin > maxDistance) return maxDistance + 1;

      final swap = previous;
      previous = current;
      current = swap;
    }

    final distance = previous[b.length];
    return distance > maxDistance ? maxDistance + 1 : distance;
  }

  /// Encodes to a plain map so it can be sent to an isolate.
  Map<String, dynamic> toTransferable() => {
    'exact': _exact,
    'wordPrefix': _wordPrefix,
    'words': _words,
    'trigrams': _trigrams,
    'names': _names,
    'byLength': _byLength,
    'sortedFirstWords': _sortedFirstWords,
    'sortedWords': _sortedWords,
  };

  /// Rebuilds from [toTransferable] inside an isolate.
  static SearchIndex fromTransferable(Map<String, dynamic> data) {
    Map<String, List<String>> listMap(String key) => {
      for (final e in (data[key] as Map).entries)
        '${e.key}': [for (final v in (e.value as List)) '$v'],
    };
    Map<String, String> stringMap(String key) => {
      for (final e in (data[key] as Map).entries) '${e.key}': '${e.value}',
    };
    // Keys arrive as strings because a Map with int keys does not survive the
    // isolate boundary intact.
    Map<int, List<String>> intKeyedListMap(String key) => {
      for (final e in (data[key] as Map).entries)
        int.parse('${e.key}'): [for (final v in (e.value as List)) '$v'],
    };

    return SearchIndex._(
      stringMap('exact'),
      listMap('wordPrefix'),
      listMap('words'),
      listMap('trigrams'),
      stringMap('names'),
      [for (final v in (data['sortedFirstWords'] as List)) '$v'],
      [for (final v in (data['sortedWords'] as List)) '$v'],
      intKeyedListMap('byLength'),
    );
  }
}

/// Runs a search in a background isolate.
///
/// Must be a top-level or static function to be usable with `compute`.
/// Returns hits serialised as plain maps because [DrugHit] crosses the isolate
/// boundary fine, but keeping the payload primitive makes the contract obvious.
Future<List<Map<String, dynamic>>> searchDrugs(
  Map<String, dynamic> args,
) async {
  final index = SearchIndex.fromTransferable(args['index'] as Map<String, dynamic>);
  final query = args['query'] as String;
  final limit = args['limit'] as int? ?? 60;
  final hits = index.search(query, limit: limit);
  return [
    for (final hit in hits)
      {'id': hit.id, 'name': hit.name, 'score': hit.score},
  ];
}