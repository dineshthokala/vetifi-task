/// Settings and diagnostics.
///
/// Exists because a silent sync failure is indistinguishable from "nothing to
/// do". An operator debugging a clinic that never updates needs to see the
/// dataset version, when it arrived, how many logs are waiting, and the server
/// URL, without attaching a debugger to a phone in a rural clinic.
library;

import 'package:flutter/material.dart';

import '../services/database_service.dart';
import '../services/sync_service.dart';
import '../services/update_service.dart';
import '../theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  DatasetInfo _info = DatasetInfo.unknown;
  int _pendingLogs = 0;
  int _drugCount = 0;
  String _syncMessage = '';
  bool _busy = false;

  late final TextEditingController _serverController =
      TextEditingController(text: UpdateService.serverUrl);

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _serverController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final info = await DatabaseService.getDatasetInfo();
    final pending = await DatabaseService.pendingLogCount();
    final entries = await DatabaseService.getSearchIndexEntries();
    if (!mounted) return;
    setState(() {
      _info = info;
      _pendingLogs = pending;
      _drugCount = entries.length;
    });
  }

  Future<void> _syncNow() async {
    setState(() {
      _busy = true;
      _syncMessage = '';
    });
    // force: the operator asked explicitly, so do not short-circuit on the
    // connectivity check the background sync uses.
    final outcome = await SyncService.syncNow(force: true);
    await _refresh();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _syncMessage = outcome.datasetMessage;
    });
  }

  void _saveServerUrl() {
    final url = _serverController.text.trim();
    if (url.isEmpty) {
      UpdateService.resetServerUrl();
    } else {
      UpdateService.setServerUrl(url);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Server set to ${UpdateService.serverUrl}')),
    );
  }

  @override
  Widget build(BuildContext context) {
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
        title: const Text(
          'Settings and sync',
          softWrap: false,
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Section(
            title: 'Dataset',
            children: [
              _Row(label: 'Installed version', value: _info.version),
              _Row(
                label: 'Schema version',
                value: _info.schemaVersion == 0
                    ? 'unknown'
                    : '${_info.schemaVersion}',
              ),
              _Row(
                label: 'Last checked',
                value: _info.fetchedAt == null
                    ? 'unknown'
                    : _formatTimestamp(_info.fetchedAt!),
              ),
              _Row(
                label: 'Dataset age',
                value: _info.age == null
                    ? 'unknown'
                    : '${_info.age!.inDays} days',
              ),
              _Row(label: 'Searchable drugs', value: '$_drugCount'),
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Calculation log',
            children: [
              _Row(
                label: 'Records waiting to upload',
                value: '$_pendingLogs',
              ),
              const SizedBox(height: 8),
              _NoWrapText(
                'Records are held on the device until a connection is '
                'available, then uploaded in batches. Uploading twice is '
                'harmless: the server deduplicates on the record ID.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: VetifiTheme.textMuted,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Dataset server',
            children: [
              TextField(
                controller: _serverController,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Base URL',
                  helper: _NoWrapText(
                    'The default 10.0.2.2 is the host machine as seen from an Android emulator.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: VetifiTheme.textMuted,
                        ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _syncNow,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.sync),
                      label: const Text('Sync now', softWrap: false),
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: _saveServerUrl,
                    child: const Text('Save', softWrap: false),
                  ),
                ],
              ),
              if (_syncMessage.isNotEmpty) ...[
                const SizedBox(height: 12),
                _NoWrapText(
                  _syncMessage,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: VetifiTheme.textSecondary,
                      ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          _Section(
            title: 'Trust',
            children: [
              _NoWrapText(
                'Every dataset is verified against the Ed25519 public key '
                'compiled into this build before a single row is written. An '
                'update that fails verification is discarded, and the '
                'previously installed dataset is kept.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: VetifiTheme.textSecondary,
                      height: 1.4,
                    ),
              ),
              const SizedBox(height: 10),
              _Row(
                label: 'Public key',
                value: UpdateService.serverPublicKeyHex,
              ),
            ],
          ),
          const SizedBox(height: 24),
          Center(
            child: _NoWrapText(
              'Vetifi 1.0.0 - fictional drugs, not for clinical use',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: VetifiTheme.textMuted,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTimestamp(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: VetifiTheme.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _NoWrapText(
            title.toUpperCase(),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
              color: VetifiTheme.textMuted,
            ),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;
  const _Row({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    label,
                    softWrap: false,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(width: 16),
                  Text(
                    value,
                    softWrap: false,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: VetifiTheme.textPrimary,
                        ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _NoWrapText extends StatelessWidget {
  final String text;
  final TextStyle? style;

  const _NoWrapText(this.text, {this.style});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Text(
        text,
        softWrap: false,
        style: style,
      ),
    );
  }
}