/// Home screen: drug search, sync status, and the entry point to the calculator.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../l10n/app_language.dart';
import '../l10n/strings.dart';
import '../models/drug.dart';
import '../services/database_service.dart';
import '../services/search_index.dart';
import '../services/sync_service.dart';
import '../theme.dart';
// import '../widgets/language_toggle_button.dart';
import '../widgets/version_badge.dart';
import 'calculator_screen.dart';
import 'settings_screen.dart';

/// How long to wait after the last keystroke before searching.
///
/// Long enough to collapse a burst of typing into one query, short enough that
/// results still feel immediate.
const Duration _searchDebounce = Duration(milliseconds: 120);

/// Cap on results per query. Bounds both the work done and what has to be
/// hydrated from SQLite afterwards.
const int _searchResultLimit = 60;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();

  /// Owned here, not created in build: a fresh FocusNode per rebuild drops
  /// keyboard focus every time setState fires (i.e. on every keystroke).
  final FocusNode _searchFocus = FocusNode();

  /// The search index, kept as a transferable map so it can be handed to an
  /// isolate without re-serialising a 50,000-entry object graph per keystroke.
  Map<String, dynamic>? _indexData;

  List<Drug> _results = const [];
  bool _loading = true;
  bool _searching = false;
  String _datasetVersion = '';

  /// Total drugs in the installed dataset. The count line shows this when no
  /// query is active: showing "0 drugs" for an empty query reads as an empty
  /// dataset, which is exactly the confusion it caused.
  int _totalDrugs = 0;
  String? _stalenessWarning;
  String? _syncMessage;
  bool _syncFailed = false;
  bool _isOffline = false;

  Timer? _debounce;

  /// Monotonic counter. Each search takes a ticket; results are applied only if
  /// they still hold the newest one. This is what guarantees a slow query for
  /// "mel" cannot land after a fast query for "meloquin" and replace it with
  /// worse results.
  int _searchTicket = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  /// Load the local dataset first, then sync against it. The sync decision
  /// ("did the dataset change?") is only meaningful against a displayed
  /// version that is already current: firing load and sync concurrently lets
  /// the initial load land after the sync and show a stale version with no
  /// further correction until the next sync.
  Future<void> _init() async {
    await _loadDrugs();
    await _backgroundSync();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _loadDrugs() async {
    await DatabaseService.ensureBaseDataset();
    final entries = await DatabaseService.getSearchIndexEntries();
    final index = SearchIndex.fromEntries(entries);
    final info = await DatabaseService.getDatasetInfo();
    // Small datasets (a fresh seed, a test server) are browsable: show them
    // up front instead of an empty screen that reads as "no data". Large
    // datasets still require a query -- hydrating tens of thousands of rows
    // into a ListView is exactly what the result cap exists to avoid.
    final List<Drug> initial = entries.length <= _searchResultLimit
        ? await DatabaseService.getAllDrugs()
        : const <Drug>[];
    if (!mounted) return;
    setState(() {
      _indexData = index.toTransferable();
      _results = initial;
      _totalDrugs = entries.length;
      _datasetVersion = info.version;
      _stalenessWarning = _stalenessMessage(info.age, info.version);
      _loading = false;
    });
  }

  /// Builds the staleness advisory described in DECISIONS.md question 4.
  ///
  /// The app cannot force a user who has been offline to update. It can be
  /// honest about how old its data is, which is the part that is actually
  /// within its control.
  String? _stalenessMessage(Duration? age, String version) {
    if (age == null) return null;
    final days = age.inDays;
    if (days >= 180) {
      return 'Formulary $version is $days days old. This dataset may contain '
          'concentrations that have since been corrected.';
    }
    if (days >= 60) {
      return 'Formulary $version is $days days old. Check for safety '
          'revisions when a connection is available.';
    }
    return null;
  }

  Future<void> _backgroundSync() async {
    final outcome = await SyncService.syncNow();
    if (!mounted) return;

    // The dataset can change without this sync doing it: the user may have
    // pressed "Sync now" in Settings, which returns with the database already
    // updated. Then before == after, datasetChanged is false, but this screen
    // is still showing the old version with a stale index. Reload whenever the
    // installed version differs from what is displayed, not just when this
    // sync performed the replacement.
    final installed = await DatabaseService.getDatasetVersion();
    if (outcome.datasetChanged ||
        (_datasetVersion.isNotEmpty && installed != _datasetVersion)) {
      await _loadDrugs();
      if (!mounted) return;
    }
    setState(() {
      _syncMessage = outcome.datasetMessage;
      _syncFailed = outcome.datasetFailed;
      _isOffline = outcome.isOffline;
    });
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();

    final trimmed = query.trim().toLowerCase();
    if (trimmed.isEmpty) {
      // Invalidate any in-flight query so it cannot repopulate the list.
      _searchTicket++;
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }

    if (!_searching) setState(() => _searching = true);
    _debounce = Timer(_searchDebounce, () => _runSearch(trimmed));
  }

  Future<void> _runSearch(String query) async {
    final indexData = _indexData;
    if (indexData == null) return;

    // Debug-only keystroke-to-results timer for the Part B on-device
    // measurement (see RUNBOOK). Compiled out of release builds, so it
    // cannot affect shipped behaviour or performance.
    final sw = Stopwatch()..start();
    final ticket = ++_searchTicket;

    List<Map<String, dynamic>> rawHits;
    try {
      rawHits = await compute(searchDrugs, {
        'index': indexData,
        'query': query,
        'limit': _searchResultLimit,
      });
    } catch (_) {
      // An isolate failure must not leave the spinner running forever.
      if (mounted && ticket == _searchTicket) {
        setState(() => _searching = false);
      }
      return;
    }

    if (!mounted || ticket != _searchTicket) return;

    final ids = [for (final hit in rawHits) hit['id'] as String];
    final drugs = await DatabaseService.getDrugsByIds(ids);

    if (!mounted || ticket != _searchTicket) return;
    setState(() {
      _results = drugs;
      _searching = false;
    });
    if (kDebugMode) {
      debugPrint(
        'vetifi_search ms=${(sw.elapsedMicroseconds / 1000).toStringAsFixed(2)} '
        'query="$query" hits=${drugs.length}',
      );
    }
  }

  void _openCalculator(Drug drug) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            CalculatorScreen(drug: drug, datasetVersion: _datasetVersion),
      ),
    );
  }

  void _openSettings() {
    unawaited(
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const SettingsScreen()))
          .then((_) => _backgroundSync()),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Multi-language toggle commented out for now (defaults to English):
    // return ValueListenableBuilder<AppLanguage>(
    //   valueListenable: LanguageController.instance.currentLanguage,
    //   builder: (context, currentLang, _) {
    const strings = AppStrings(AppLanguage.en);

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: VetifiTheme.primaryGradient,
          ),
        ),
        title: Row(
          children: [
            const Icon(Icons.pets, size: 24, color: Colors.white),
            const SizedBox(width: 10),
            Text(
              strings.appTitle,
              style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
        actions: [
          // const LanguageToggleButton(),
          if (_datasetVersion.isNotEmpty)
            VersionBadge(
              version: _datasetVersion,
              onTap: _openSettings,
            ),
          IconButton(
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined, color: Colors.white),
            tooltip: 'Settings and sync',
          ),
          const SizedBox(width: 4),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(66),
          child: _SearchBar(
            controller: _searchController,
            focusNode: _searchFocus,
            hintText: strings.searchHint,
            onChanged: _onSearchChanged,
            onClear: () {
              _searchController.clear();
              _onSearchChanged('');
            },
          ),
        ),
      ),
      body: Column(
        children: [
          if (_stalenessWarning != null)
            _AdvisoryBanner(
              icon: Icons.schedule,
              color: VetifiTheme.warning,
              background: VetifiTheme.warningBg,
              message: _stalenessWarning!,
            ),
          if (_syncMessage != null && !_searching)
            _AdvisoryBanner(
              icon: _isOffline
                  ? Icons.cloud_off_outlined
                  : (_syncFailed
                      ? Icons.error_outline
                      : Icons.cloud_done_outlined),
              color: _isOffline
                  ? VetifiTheme.offline
                  : (_syncFailed ? VetifiTheme.error : VetifiTheme.info),
              background: _isOffline
                  ? VetifiTheme.offlineBg
                  : (_syncFailed ? VetifiTheme.errorBg : VetifiTheme.infoBg),
              message: _syncMessage!,
            ),
          _ResultCount(
            count: _results.length,
            total: _totalDrugs,
            searching: _searching,
            hasQuery: _searchController.text.trim().isNotEmpty,
            version: _datasetVersion,
          ),
          Expanded(child: _buildBody(strings)),
        ],
      ),
    );
    //   },
    // );
  }

  Widget _buildBody(AppStrings strings) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: VetifiTheme.primary),
      );
    }
    if (_results.isEmpty) {
      return _EmptyState(hasQuery: _searchController.text.trim().isNotEmpty);
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 16),
      itemCount: _results.length,
      itemBuilder: (context, index) => _DrugListItem(
        drug: _results[index],
        datasetVersion: _datasetVersion,
        strings: strings,
        onTap: () => _openCalculator(_results[index]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Supporting widgets
// ---------------------------------------------------------------------------

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hintText;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.hintText,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onChanged: onChanged,
        // Searching already ran via onChanged; the action key just puts the
        // keyboard away so the results are visible.
        onSubmitted: (_) => focusNode.unfocus(),
        textInputAction: TextInputAction.search,
        autocorrect: false,
        enableSuggestions: false,
        style: const TextStyle(color: VetifiTheme.textPrimary),
        decoration: InputDecoration(
          hintText: hintText,
          prefixIcon: const Icon(Icons.search, color: VetifiTheme.textMuted),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    icon: const Icon(Icons.clear, color: VetifiTheme.textMuted),
                    tooltip: 'Clear',
                    onPressed: onClear,
                  ),
          ),
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

class _AdvisoryBanner extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color background;
  final String message;

  const _AdvisoryBanner({
    required this.icon,
    required this.color,
    required this.background,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: background,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: GoogleFonts.plusJakartaSans(
                fontSize: 12.5,
                color: color,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultCount extends StatelessWidget {
  final int count;
  final int total;
  final bool searching;
  final bool hasQuery;
  final String version;

  const _ResultCount({
    required this.count,
    required this.total,
    required this.searching,
    required this.hasQuery,
    required this.version,
  });

  @override
  Widget build(BuildContext context) {
    // With no query there are no "results" yet, so the count names the whole
    // installed dataset instead of reading "0 drugs" for a full database.
    final label = searching
        ? 'Searching...'
        : hasQuery
        ? '$count drug${count == 1 ? '' : 's'}'
        : '$total drug${total == 1 ? '' : 's'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(width: 8),
          if (searching)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: VetifiTheme.primary,
              ),
            ),
          const Spacer(),
          if (version.isNotEmpty)
            Text(
              'Dataset $version',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: VetifiTheme.textMuted,
                fontSize: 12,
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool hasQuery;
  const _EmptyState({required this.hasQuery});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasQuery ? Icons.search_off : Icons.medication_outlined,
              size: 64,
              color: VetifiTheme.textMuted.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              hasQuery ? 'No matching drugs' : 'Search for a drug',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(color: VetifiTheme.textMuted),
            ),
            const SizedBox(height: 6),
            Text(
              hasQuery
                  ? 'Check the spelling, or try a shorter fragment of the name.'
                  : 'Type at least two letters to search.',
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: VetifiTheme.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrugListItem extends StatelessWidget {
  final Drug drug;
  final String datasetVersion;
  final AppStrings strings;
  final VoidCallback onTap;

  const _DrugListItem({
    required this.drug,
    required this.datasetVersion,
    required this.strings,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hasIssue = drug.hasGlobalError || drug.isWithdrawn;
    final species = drug.availableSpecies.toList()..sort();

    final accent = drug.isWithdrawn
        ? VetifiTheme.error
        : hasIssue
        ? VetifiTheme.warning
        : VetifiTheme.primary;

    return Card(
      color: drug.isWithdrawn
          ? VetifiTheme.withdrawnBg
          : hasIssue
          ? VetifiTheme.warningBg
          : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  drug.isWithdrawn
                      ? Icons.block
                      : hasIssue
                      ? Icons.warning_amber_rounded
                      : Icons.medication,
                  color: accent,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      drug.name,
                      style: GoogleFonts.plusJakartaSans(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: VetifiTheme.textPrimary,
                        decoration: drug.isWithdrawn
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _InfoChip(
                          label: drug.route,
                          color: VetifiTheme.secondary,
                        ),
                        _InfoChip(
                          label: drug.concentrationRaw,
                          color: drug.concentration == null
                              ? VetifiTheme.error
                              : VetifiTheme.textSecondary,
                        ),
                        for (final s in species) _SpeciesTag(species: s),
                      ],
                    ),
                    if (drug.isWithdrawn && drug.withdrawnReason != null)
                      _Note(
                        text: 'Withdrawn: ${drug.withdrawnReason}',
                        color: VetifiTheme.error,
                      ),
                    if (hasIssue && !drug.isWithdrawn)
                      _Note(
                        text: drug.validationErrors.isNotEmpty
                            ? drug.validationErrors.first
                            : drug.concentration == null
                            ? 'Invalid concentration: ${drug.concentrationRaw}'
                            : 'Data issue detected',
                        color: VetifiTheme.warning,
                      ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Icon(Icons.chevron_right, color: VetifiTheme.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  final Color color;
  const _Note({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        text,
        style: GoogleFonts.plusJakartaSans(fontSize: 11.5, color: color, height: 1.3),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final Color color;
  const _InfoChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: GoogleFonts.plusJakartaSans(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: color,
        ),
      ),
    );
  }
}

class _SpeciesTag extends StatelessWidget {
  final String species;
  const _SpeciesTag({required this.species});

  @override
  Widget build(BuildContext context) {
    final lower = species.toLowerCase();
    final (icon, label) = switch (lower) {
      'dog' || 'canine' => ('\u{1F415}', 'Dog'),
      'cat' || 'feline' => ('\u{1F408}', 'Cat'),
      _ => ('\u{1F43E}', species),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(icon, style: const TextStyle(fontSize: 12)),
        const SizedBox(width: 3),
        Text(
          label,
          style: GoogleFonts.plusJakartaSans(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: VetifiTheme.textSecondary,
          ),
        ),
      ],
    );
  }
}
