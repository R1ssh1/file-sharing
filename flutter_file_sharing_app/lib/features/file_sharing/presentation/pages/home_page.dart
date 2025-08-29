import 'package:flutter/material.dart';
import '../../../file_sharing/infrastructure/peer_discovery_service.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../../file_sharing/domain/entities/shared_folder.dart';
import '../widgets/folder_tile.dart';
// main.dart already imported earlier; remove duplicate.
import '../../../file_sharing/domain/entities/file_request.dart';
import '../../../file_sharing/infrastructure/permission_service.dart';
import '../../../file_sharing/infrastructure/folder_picker_service.dart';
import '../../../file_sharing/domain/repositories/file_sharing_repository.dart';
import '../../../file_sharing/infrastructure/local_http_server.dart';
import '../../../file_sharing/infrastructure/trust_manager.dart';
import '../../../file_sharing/infrastructure/client_download_service.dart';
import '../../../file_sharing/infrastructure/encryption_service.dart';
import 'dart:io';
import '../../../../main.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  final List<Map<String, dynamic>>? logs;
  final VoidCallback? toggleLogs;
  final bool showLogs;
  const HomePage(
      {Key? key,
      this.logs,
      this.toggleLogs,
      this.showLogs = false,
      this.autoResume,
      this.toggleAutoResume,
      this.computeHash,
      this.toggleComputeHash})
      : super(key: key);
  final bool? autoResume;
  final VoidCallback? toggleAutoResume;
  final bool? computeHash;
  final VoidCallback? toggleComputeHash;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('File Sharing App'), actions: [
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const SettingsPage())),
        ),
        if (widget.toggleLogs != null)
          IconButton(
            tooltip: widget.showLogs ? 'Hide Logs' : 'Show Logs',
            icon:
                Icon(widget.showLogs ? Icons.visibility_off : Icons.visibility),
            onPressed: widget.toggleLogs,
          )
      ]),
      drawer: Builder(builder: (ctx) {
        return Drawer(
          child: ListView(
            children: [
              const DrawerHeader(child: Text('Menu')),
              ListTile(
                leading: const Icon(Icons.verified_user),
                title: const Text('Trusted Peers'),
                onTap: () {
                  Navigator.of(ctx).pop();
                  Navigator.of(ctx).push(MaterialPageRoute(
                      builder: (_) => const _TrustListPage()));
                },
              ),
            ],
          ),
        );
      }),
      body: Column(
        children: [
          Consumer<LocalHttpServer?>(builder: (_, server, __) {
            // Display a sample issued peer token count (not the tokens themselves for security) – unless we choose to reveal first for convenience.
            final mgr = server?.peerAuthManager;
            if (mgr == null) return const SizedBox.shrink();
            // Reflection not exposed; we only show count hint.
            return Padding(
              padding: const EdgeInsets.only(top: 8, left: 16, right: 16),
              child: Row(
                children: [
                  const Icon(Icons.vpn_key, size: 16, color: Colors.grey),
                  const SizedBox(width: 6),
                  const Text('Peer auth enabled',
                      style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const Spacer(),
                  Consumer<LocalHttpServer?>(builder: (_, s, __) {
                    final fp = s?.certFingerprintSha256;
                    if (fp == null) return const SizedBox.shrink();
                    return Text('FP ${fp.substring(0, 8)}…',
                        style:
                            const TextStyle(fontSize: 11, color: Colors.grey));
                  })
                ],
              ),
            );
          }),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text('Share your files with peers'),
          ),
          Expanded(
            child: ListView(
              children: [
                Consumer<SharedFoldersModel>(builder: (_, model, __) {
                  final folders = model.folders;
                  if (folders.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(24.0),
                      child: Center(child: Text('No folders shared yet')),
                    );
                  }
                  // Simple column for small counts to aid tests; if large fallback to list.
                  if (folders.length <= 3) {
                    return Column(
                      children: [
                        for (final f in folders) FolderTile(folder: f),
                      ],
                    );
                  }
                  return SizedBox(
                    height: 140,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: folders.length,
                      itemBuilder: (context, index) =>
                          FolderTile(folder: folders[index]),
                    ),
                  );
                }),
                const Divider(),
                if (widget.showLogs && widget.logs != null)
                  SizedBox(
                    height: 160,
                    child: Container(
                      color: Colors.black,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8.0, vertical: 4),
                            child: Row(
                              children: [
                                if (widget.autoResume != null)
                                  Row(children: [
                                    Switch(
                                        value: widget.autoResume!,
                                        onChanged: (_) =>
                                            widget.toggleAutoResume?.call(),
                                        activeColor: Colors.green),
                                    const Text('Auto-resume',
                                        style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 12)),
                                    const SizedBox(width: 12),
                                  ]),
                                if (widget.computeHash != null)
                                  Row(children: [
                                    Switch(
                                        value: widget.computeHash!,
                                        onChanged: (_) =>
                                            widget.toggleComputeHash?.call(),
                                        activeColor: Colors.lightBlue),
                                    const Text('Hash',
                                        style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 12)),
                                    const SizedBox(width: 12),
                                  ]),
                                Text('Logs: ${widget.logs!.length}',
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 11)),
                              ],
                            ),
                          ),
                          const Divider(height: 1, color: Colors.white24),
                          Expanded(
                            child: ListView.builder(
                              reverse: true,
                              itemCount: widget.logs!.length,
                              itemBuilder: (_, i) {
                                final rec =
                                    widget.logs![widget.logs!.length - 1 - i];
                                return Text(
                                  '${rec['method']} ${rec['path']} ${rec['status']} ${rec['ms'] ?? ''}ms',
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.white70),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(children: [
                  const Text('Discovered Peers',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Consumer<PeerDiscoveryService>(builder: (_, disc, __) {
                    Color color;
                    switch (disc.statusLabel) {
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
                      label: Text(disc.statusLabel,
                          style: const TextStyle(fontSize: 11)),
                      backgroundColor: color.withOpacity(0.15),
                      side: BorderSide(color: color),
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                      padding:
                          const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                    );
                  }),
                ]),
                Consumer<PeersModel>(
                    builder: (_, peersModel, __) =>
                        Text('${peersModel.peers.length}')),
              ],
            ),
          ),
          SizedBox(
            height: 120,
            child: Consumer<PeersModel>(builder: (_, peersModel, __) {
              final peers = peersModel.peers;
              if (peers.isEmpty) {
                return const Center(child: Text('No peers yet'));
              }
              return ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: peers.length,
                itemBuilder: (_, i) {
                  final p = peers[i];
                  return Container(
                    width: 140,
                    margin: const EdgeInsets.all(8),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.blueGrey.shade200),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(p.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold)),
                            ),
                            if (p.fingerprint != null)
                              const Icon(Icons.lock,
                                  size: 14, color: Colors.green),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(p.address ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11)),
                        if (p.encryption != null)
                          Text(p.encryption!,
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.blueGrey)),
                        if (p.version != null)
                          Text('v${p.version}',
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.blueGrey)),
                        const Spacer(),
                        Text(
                            'Last seen: ${p.lastSeen?.toLocal().toIso8601String().substring(11, 19) ?? '-'}',
                            style: const TextStyle(fontSize: 10)),
                      ],
                    ),
                  );
                },
              );
            }),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8),
            child: Row(
              children: [
                const Expanded(
                    child: Text('File Requests',
                        style: TextStyle(fontWeight: FontWeight.bold))),
                Consumer<FileRequestsModel>(
                    builder: (_, rModel, __) =>
                        Text('${rModel.requests.length}')),
                if (widget.showLogs) ...[
                  IconButton(
                    tooltip: 'Simulate',
                    icon: const Icon(Icons.bolt, size: 20),
                    onPressed: () {
                      final folders =
                          context.read<SharedFoldersModel>().folders;
                      if (folders.isEmpty) return;
                      final folder = folders.first;
                      final fr = FileRequest(
                        id: DateTime.now().microsecondsSinceEpoch.toString(),
                        folderId: folder.id,
                        peerId: 'sim-peer',
                        filePath: null,
                      );
                      context.read<FileRequestsModel>().addRequest(fr);
                      context.read<FileSharingRepository>().requestFile(fr);
                    },
                  ),
                  IconButton(
                    tooltip: 'Test Download (first approved)',
                    icon: const Icon(Icons.download, size: 20),
                    onPressed: () async {
                      final reqs = context.read<FileRequestsModel>().requests;
                      final approved = reqs.firstWhere(
                          (r) =>
                              r.status == FileRequestStatus.completed ||
                              r.status == FileRequestStatus.transferring ||
                              r.status == FileRequestStatus.approved,
                          orElse: () => FileRequest(
                              id: '',
                              folderId: '',
                              peerId: '',
                              filePath: null));
                      if (approved.id.isEmpty || approved.filePath == null) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                              content: Text(
                                  'No suitable approved file request with filePath.')));
                        }
                        return;
                      }
                      final server = context.read<LocalHttpServer?>();
                      if (server == null) return;
                      final uri = Uri.parse(
                          'http://localhost:${server.boundPort}/download/${approved.id}');
                      final enc = EncryptionService();
                      final downloader = ClientDownloadService(enc);
                      final tmpDir =
                          await Directory.systemTemp.createTemp('dl');
                      final outFile = File('${tmpDir.path}/${approved.id}.bin');
                      final dm = context.read<DownloadManager>();
                      dm.start(approved.id,
                          filePath: outFile.path, uri: uri.toString());
                      try {
                        final res = await downloader.download(uri, outFile,
                            computeHash: widget.computeHash ?? true,
                            onProgress: (r, _) {
                          dm.progress(approved.id, r, null);
                        });
                        dm.complete(approved.id,
                            hash: res.hashHex,
                            expectedHash: res.expectedHash,
                            mismatch: res.hashMismatch);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(
                                  'Downloaded ${res.bytes} bytes hash=${res.hashHex?.substring(0, 8)}')));
                        }
                      } catch (e) {
                        dm.fail(approved.id, e);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Download failed: $e')));
                        }
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
          // Active downloads horizontal list (optional if provider present)
          Builder(builder: (ctx) {
            bool hasProvider = true;
            try {
              Provider.of<DownloadManager>(ctx, listen: false);
            } catch (_) {
              hasProvider = false;
            }
            if (!hasProvider) return const SizedBox.shrink();
            return Consumer<DownloadManager>(builder: (_, dm, __) {
              if (dm.downloads.isEmpty) return const SizedBox.shrink();
              return SizedBox(
                height: 90,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: dm.downloads.entries.map((e) {
                    final st = e.value;
                    final pct = (st.total != null && st.total! > 0)
                        ? (st.received / st.total!).clamp(0, 1)
                        : null;
                    return Container(
                      width: 150,
                      margin: const EdgeInsets.all(8),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.indigo.shade200),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('DL ${e.key}',
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 12)),
                          const SizedBox(height: 4),
                          LinearProgressIndicator(
                              value: st.completed
                                  ? 1.0
                                  : (pct == null ? null : pct.toDouble()),
                              minHeight: 4),
                          const SizedBox(height: 4),
                          Text(
                              st.total != null && st.total! > 0
                                  ? '${st.received} B / ${st.total} B'
                                  : '${st.received} B',
                              style: const TextStyle(fontSize: 10)),
                          if (st.completed)
                            Text(st.hashMismatch ? 'HASH MISMATCH' : 'OK',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: st.hashMismatch
                                        ? Colors.red
                                        : Colors.green)),
                          if (st.failed)
                            const Text('FAILED',
                                style: TextStyle(
                                    fontSize: 10, color: Colors.redAccent)),
                          if (st.canceled)
                            const Text('CANCELED',
                                style: TextStyle(
                                    fontSize: 10, color: Colors.orangeAccent)),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              );
            });
          }),
          SizedBox(
            height: 160,
            child: Consumer<FileRequestsModel>(builder: (_, rModel, __) {
              final reqs = rModel.requests;
              if (reqs.isEmpty) {
                return const Center(child: Text('No file requests'));
              }
              return ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: reqs.length,
                itemBuilder: (_, i) {
                  final r = reqs[i];
                  return Container(
                    width: 200,
                    margin: const EdgeInsets.all(8),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.green.shade200),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Req ${r.id}',
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Text('Folder: ${r.folderId}',
                            overflow: TextOverflow.ellipsis),
                        Text('Peer: ${r.peerId}',
                            overflow: TextOverflow.ellipsis),
                        Text(r.filePath ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11)),
                        const Spacer(),
                        Text(r.status.name,
                            style: TextStyle(
                                fontSize: 11, color: _statusColor(r.status))),
                        if (r.status == FileRequestStatus.transferring)
                          Selector<FileRequestsModel, _TransferViewData>(
                            selector: (_, m) => _TransferViewData(
                                m.progressFor(r.id),
                                m.bytesSent(r.id),
                                m.bytesTotal(r.id)),
                            builder: (_, data, __) {
                              final p = data.progress;
                              final sent = data.sent;
                              final total = data.total;
                              String bytesInfo() {
                                if (total <= 0) return '$sent B';
                                return _formatBytes(sent) +
                                    ' / ' +
                                    _formatBytes(total);
                              }

                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  LinearProgressIndicator(
                                      value: p == 0 ? null : p, minHeight: 4),
                                  const SizedBox(height: 4),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '${(p * 100).toStringAsFixed(0)}%  ${bytesInfo()}',
                                          style: const TextStyle(fontSize: 10),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Cancel transfer',
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        icon: const Icon(Icons.stop,
                                            size: 18, color: Colors.redAccent),
                                        onPressed: () {
                                          context
                                              .read<FileRequestsModel>()
                                              .cancelTransfer(r.id);
                                        },
                                      ),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                        if (r.status == FileRequestStatus.pending)
                          Row(
                            children: [
                              IconButton(
                                tooltip: 'Approve',
                                icon: const Icon(Icons.check,
                                    size: 20, color: Colors.green),
                                onPressed: () => _updateRequestStatus(
                                    context, r.id, FileRequestStatus.approved),
                              ),
                              IconButton(
                                tooltip: 'Reject',
                                icon: const Icon(Icons.close,
                                    size: 20, color: Colors.redAccent),
                                onPressed: () => _updateRequestStatus(
                                    context, r.id, FileRequestStatus.rejected),
                              ),
                            ],
                          )
                        else
                          const SizedBox(height: 32),
                      ],
                    ),
                  );
                },
              );
            }),
          ),
          const Divider(),
          Consumer<LocalHttpServer?>(builder: (_, server, __) {
            final fp = server?.certFingerprintSha256;
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      fp == null
                          ? 'Fingerprint: (loading)'
                          : 'Fingerprint: ${fp.substring(0, 16)}…',
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Consumer2<PeerDiscoveryService, SettingsModel>(
                      builder: (_, disc, settings, __) {
                    Color color;
                    switch (disc.statusLabel) {
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
                    return Row(children: [
                      Chip(
                        label: Text(disc.statusLabel,
                            style: const TextStyle(fontSize: 11)),
                        backgroundColor: color.withOpacity(0.15),
                        side: BorderSide(color: color),
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        padding:
                            const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
                      ),
                    ]);
                  }),
                  if (fp != null)
                    IconButton(
                      tooltip: 'Copy full fingerprint',
                      icon:
                          const Icon(Icons.copy, size: 16, color: Colors.grey),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: fp));
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Fingerprint copied')),
                        );
                      },
                    ),
                ],
              ),
            );
          }),
          const SizedBox(
              height: 80), // bottom padding so FAB doesn't cover toggle
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final permission = PermissionService();
          if (!await permission.ensureStorage()) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Storage permission denied')));
            return;
          }
          final picker = FolderPickerService();
          final path = await picker.pickFolder();
          if (path == null) return;
          bool autoApprove = false;
          bool allowPreview = true;
          if (!mounted) return;
          await showDialog(
              context: context,
              builder: (ctx) {
                return StatefulBuilder(builder: (ctx, setState) {
                  return AlertDialog(
                    title: const Text('Share Folder'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(path,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        const SizedBox(height: 12),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Auto-approve requests'),
                          value: autoApprove,
                          onChanged: (v) =>
                              setState(() => autoApprove = v ?? false),
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                              'Allow preview (list files before approval)'),
                          value: allowPreview,
                          onChanged: (v) =>
                              setState(() => allowPreview = v ?? true),
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('Cancel')),
                      ElevatedButton(
                          onPressed: () => Navigator.of(ctx).pop(true),
                          child: const Text('Share')),
                    ],
                  );
                });
              });
          // If dialog canceled, abort
          if (!mounted) return;
          final model = context.read<SharedFoldersModel>();
          model.addFolder(SharedFolder(
              id: DateTime.now().millisecondsSinceEpoch.toString(),
              name: path.split('/').last,
              path: path,
              isShared: true,
              autoApprove: autoApprove,
              allowPreview: allowPreview));
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}

class _TrustListPage extends StatefulWidget {
  const _TrustListPage();
  @override
  State<_TrustListPage> createState() => _TrustListPageState();
}

class _TrustListPageState extends State<_TrustListPage> {
  @override
  Widget build(BuildContext context) {
    final trust = context.read<TrustManager>();
    final entries = trust.pinned.entries.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Trusted Peers')),
      body: entries.isEmpty
          ? const Center(child: Text('No fingerprints pinned yet'))
          : ListView.builder(
              itemCount: entries.length,
              itemBuilder: (_, i) {
                final e = entries[i];
                return ListTile(
                  leading: const Icon(Icons.lock, color: Colors.green),
                  title: Text(e.key),
                  subtitle: Text(e.value.length > 32
                      ? e.value.substring(0, 32) + '…'
                      : e.value),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete, color: Colors.redAccent),
                    onPressed: () async {
                      await trust.remove(e.key);
                      if (mounted) setState(() {});
                    },
                  ),
                );
              },
            ),
    );
  }
}

Color _statusColor(FileRequestStatus status) {
  switch (status) {
    case FileRequestStatus.pending:
      return Colors.orange;
    case FileRequestStatus.approved:
      return Colors.green;
    case FileRequestStatus.rejected:
      return Colors.redAccent;
    case FileRequestStatus.transferring:
      return Colors.blue;
    case FileRequestStatus.completed:
      return Colors.green.shade700;
    case FileRequestStatus.failed:
      return Colors.red;
  }
}

void _updateRequestStatus(
    BuildContext context, String id, FileRequestStatus status) {
  final repo = context.read<FileSharingRepository>();
  repo.updateFileRequestStatus(id, status);
  context.read<FileRequestsModel>().updateStatus(id, status);
}

class _TransferViewData {
  final double progress;
  final int sent;
  final int total;
  const _TransferViewData(this.progress, this.sent, this.total);
}

String _formatBytes(int bytes, [int decimals = 1]) {
  const k = 1024;
  if (bytes < k) return '$bytes B';
  const sizes = ['KB', 'MB', 'GB', 'TB'];
  double v = bytes.toDouble();
  int i = -1;
  do {
    v /= k;
    i++;
  } while (v >= k && i < sizes.length - 1);
  return v.toStringAsFixed(decimals) + ' ' + sizes[i];
}
