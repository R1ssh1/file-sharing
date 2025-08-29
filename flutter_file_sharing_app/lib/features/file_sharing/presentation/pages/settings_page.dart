import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:provider/provider.dart';
import '../../../../main.dart';
import '../../../file_sharing/infrastructure/peer_discovery_service.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          _AppearanceSection(),
          SizedBox(height: 16),
          _CoreSettingsSection(),
          SizedBox(height: 16),
          _DiagnosticsSection(),
        ],
      ),
    );
  }
}

class _AppearanceSection extends StatefulWidget {
  const _AppearanceSection({Key? key}) : super(key: key);

  @override
  State<_AppearanceSection> createState() => _AppearanceSectionState();
}

class _AppearanceSectionState extends State<_AppearanceSection> {
  late int _seed;
  late String _mode;

  @override
  void initState() {
    super.initState();
    final s = context.read<SettingsModel>();
    _seed = s.colorSeed;
    _mode = s.themeMode;
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsModel>();
    final seeds = <int>[
      0xFF6750A4, // purple
      0xFF006874, // teal
      0xFF386A20, // green
      0xFFB3261E, // red
      0xFF1F1F1F, // near-black
      0xFF0B57D0, // blue
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Appearance',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            const Text('Theme'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('System'),
                  selected: _mode == 'system',
                  onSelected: (_) => setState(() => _mode = 'system'),
                ),
                ChoiceChip(
                  label: const Text('Light'),
                  selected: _mode == 'light',
                  onSelected: (_) => setState(() => _mode = 'light'),
                ),
                ChoiceChip(
                  label: const Text('Dark'),
                  selected: _mode == 'dark',
                  onSelected: (_) => setState(() => _mode = 'dark'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('Color'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in seeds)
                  GestureDetector(
                    onTap: () => setState(() => _seed = c),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Color(c),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: _seed == c ? Colors.white : Colors.black12,
                            width: _seed == c ? 2 : 1),
                        boxShadow: const [
                          BoxShadow(
                              color: Colors.black12,
                              blurRadius: 3,
                              offset: Offset(0, 1))
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () {
                  settings.setThemeMode(_mode);
                  settings.setColorSeed(_seed);
                },
                icon: const Icon(Icons.check),
                label: const Text('Apply'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CoreSettingsSection extends StatelessWidget {
  const _CoreSettingsSection({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsModel>();
    final discovery = context.watch<PeerDiscoveryService>();
    final verbose = settings.discoveryVerbose;
    final heartbeat = settings.fallbackHeartbeat;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Core',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            SwitchListTile(
              title: const Text('LAN Discovery'),
              subtitle: Text(discovery.isDisabled
                  ? 'Disabled by OS/device'
                  : (discovery.isRunning ? 'Running' : 'Stopped')),
              value: settings.discoveryEnabled && !discovery.isDisabled,
              onChanged: (v) async {
                settings.setDiscoveryEnabled(v);
                if (v) {
                  if (!discovery.isRunning && !discovery.isDisabled) {
                    unawaited(discovery.start(
                        port: 7345, heartbeat: settings.fallbackHeartbeat));
                  }
                } else {
                  await discovery.stop();
                }
              },
            ),
            SwitchListTile(
              title: const Text('Verbose discovery logs'),
              subtitle: const Text('Extra console output for troubleshooting'),
              value: verbose,
              onChanged: (v) {
                settings.setDiscoveryVerbose(v);
                discovery.setVerbose(v);
              },
            ),
            SwitchListTile(
              title: const Text('UDP heartbeat fallback'),
              subtitle: const Text('Peer liveness if mDNS blocked'),
              value: heartbeat,
              onChanged: (v) {
                settings.setFallbackHeartbeat(v);
                if (settings.discoveryEnabled && discovery.isRunning) {
                  discovery.restart(heartbeat: v);
                }
              },
            ),
            const Divider(),
            SwitchListTile(
              title: const Text('Logging'),
              value: settings.loggingEnabled,
              onChanged: (_) => settings.toggleLogging(),
            ),
            SwitchListTile(
              title: const Text('Auto-resume downloads'),
              value: settings.autoResume,
              onChanged: (_) => settings.toggleAutoResume(),
            ),
            SwitchListTile(
              title: const Text('Compute hash after download'),
              value: settings.computeHashOnDownload,
              onChanged: (_) => settings.toggleComputeHash(),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiagnosticsSection extends StatefulWidget {
  const _DiagnosticsSection({Key? key}) : super(key: key);

  @override
  State<_DiagnosticsSection> createState() => _DiagnosticsSectionState();
}

class _DiagnosticsSectionState extends State<_DiagnosticsSection> {
  Map<String, dynamic>? _data;
  bool _loading = false;
  bool _showLogs = false;

  Future<void> _run() async {
    setState(() {
      _loading = true;
    });
    try {
      final d = await context.read<PeerDiscoveryService>().diagnostics();
      setState(() {
        _data = d;
      });
    } catch (e) {
      setState(() {
        _data = {'error': e.toString()};
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Diagnostics',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                Consumer<PeerDiscoveryService>(builder: (_, svc, __) {
                  Color color;
                  switch (svc.statusLabel) {
                    case 'mDNS+HB':
                      color = Colors.blue;
                      break;
                    case 'mDNS':
                      color = Colors.green;
                      break;
                    case 'Heartbeat':
                      color = Colors.orange;
                      break;
                    case 'Disabled':
                      color = Colors.redAccent;
                      break;
                    case 'Starting':
                      color = Colors.amber;
                      break;
                    default:
                      color = Colors.grey;
                  }
                  return Chip(
                    label: Text(svc.statusLabel,
                        style: const TextStyle(fontSize: 11)),
                    backgroundColor: color.withOpacity(0.15),
                    side: BorderSide(color: color),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  );
                }),
                const Spacer(),
                IconButton(
                    tooltip: _showLogs ? 'Hide recent logs' : 'Show recent logs',
                    onPressed: () => setState(() => _showLogs = !_showLogs),
                    icon: Icon(_showLogs ? Icons.receipt_long : Icons.list_alt)),
        Consumer<PeerDiscoveryService>(builder: (_, svc, __) {
          return IconButton(
            tooltip: 'Restart discovery',
            onPressed: () => svc.restart(),
            icon: const Icon(Icons.refresh));
        }),
        Consumer<PeerDiscoveryService>(builder: (_, svc, __) {
          return IconButton(
            tooltip: 'Copy logs',
            onPressed: svc.recentLogs.isEmpty
              ? null
              : () async {
                final joined = svc.recentLogs.join('\n');
                await Clipboard.setData(
                  ClipboardData(text: joined));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Logs copied')));
              },
            icon: const Icon(Icons.copy_all));
        }),
                FilledButton.icon(
                  onPressed: _loading ? null : _run,
                  icon: _loading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.play_arrow),
                  label: const Text('Run'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_data != null)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  _pretty(_data!),
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              )
            else
              const Text('Tap Run to collect discovery diagnostics',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            if (_showLogs) ...[
              const Divider(),
              const Text('Recent Discovery Logs',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              SizedBox(
                height: 140,
                child: Consumer<PeerDiscoveryService>(
                    builder: (_, svc, __) => ListView.builder(
                          itemCount: svc.recentLogs.length,
                          itemBuilder: (_, i) {
                            final line = svc.recentLogs[svc.recentLogs.length - 1 - i];
                            return Text(line,
                                style: const TextStyle(
                                    fontSize: 11, fontFamily: 'monospace'));
                          },
                        )),
              )
            ]
          ],
        ),
      ),
    );
  }

  String _pretty(Map<String, dynamic> map) {
    String buf = '';
    void write(String k, dynamic v, [int indent = 0]) {
      final pad = '  ' * indent;
      if (v is Map) {
        buf += '$pad$k:\n';
        v.forEach((kk, vv) => write(kk, vv, indent + 1));
      } else if (v is List) {
        buf += '$pad$k: [${v.join(', ')}]\n';
      } else {
        buf += '$pad$k: $v\n';
      }
    }

    map.forEach((k, v) => write(k, v));
    return buf.trimRight();
  }
}
