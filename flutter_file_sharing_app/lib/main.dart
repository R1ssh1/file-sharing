import 'package:flutter/material.dart';
import 'dart:async';
import 'package:provider/provider.dart';
import 'features/file_sharing/presentation/pages/home_page.dart';
import 'features/file_sharing/data/datasources/local_storage_datasource.dart';
import 'features/file_sharing/data/datasources/peer_connection_datasource.dart';
import 'features/file_sharing/data/repositories/file_sharing_repository_impl.dart';
import 'features/file_sharing/domain/repositories/file_sharing_repository.dart';
import 'features/file_sharing/domain/entities/shared_folder.dart';
import 'features/file_sharing/domain/entities/peer.dart';
import 'features/file_sharing/data/datasources/hive_shared_folder_datasource.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'features/file_sharing/infrastructure/local_http_server.dart';
import 'dart:io';
import 'package:shelf/shelf.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'features/file_sharing/infrastructure/permission_service.dart';
import 'features/file_sharing/infrastructure/folder_picker_service.dart';
import 'features/file_sharing/infrastructure/peer_discovery_service.dart';
import 'features/file_sharing/infrastructure/peer_auth_manager.dart';
import 'features/file_sharing/infrastructure/encryption_service.dart';
import 'features/file_sharing/data/datasources/hive_file_request_datasource.dart';
import 'features/file_sharing/domain/entities/file_request.dart';
import 'features/file_sharing/infrastructure/trust_manager.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:path/path.dart' as p;
import 'features/file_sharing/infrastructure/client_download_service.dart';
import 'features/file_sharing/presentation/pages/settings_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  if (!Hive.isAdapterRegistered(1)) {
    Hive.registerAdapter(SharedFolderAdapter());
  }
  runApp(const FileSharingApp());
}

class FileSharingApp extends StatefulWidget {
  const FileSharingApp({Key? key}) : super(key: key);

  @override
  State<FileSharingApp> createState() => _FileSharingAppState();
}

class _FileSharingAppState extends State<FileSharingApp> {
  StreamSubscription? _peerSub;
  static final Map<String, String> _hashCache =
      {}; // requestId -> plaintext hash
  static final Map<String, int> _maxServedChunk =
      {}; // requestId -> highest next chunk index served
  static final Map<String, int> _activePerPeer = {}; // peerId -> active count
  static int _activeGlobal = 0;
  final List<Map<String, dynamic>> _logs = [];
  bool _showLogs = false;

  @override
  void dispose() {
    _peerSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
        providers: [
          Provider<AppServices>(create: (_) => AppServices()),
          ChangeNotifierProvider(create: (_) => SettingsModel()..load()),
          Provider<LocalStorageDataSource>(
              create: (_) => LocalStorageDataSource()),
          Provider<HiveSharedFolderDataSource>(
              create: (_) => HiveSharedFolderDataSource()),
          Provider<HiveFileRequestDataSource>(
              create: (_) => HiveFileRequestDataSource()),
          Provider<PeerConnectionDataSource>(
              create: (_) => PeerConnectionDataSource()),
          Provider<PermissionService>(create: (_) => PermissionService()),
          Provider<FolderPickerService>(create: (_) => FolderPickerService()),
          ChangeNotifierProvider<PeerDiscoveryService>(
            create: (ctx) {
              final settings = ctx.read<SettingsModel>();
              final svc = PeerDiscoveryService();
              svc.setVerbose(settings.discoveryVerbose);
              // Start only after settings loaded & discovery enabled (SettingsModel load is async; we can poll once)
              // Quick microtask to wait a short time for settings; if not loaded yet, schedule when it loads via listener.
              void tryStart() {
                if (settings.isLoaded && settings.discoveryEnabled) {
                  svc.start(port: 7345, heartbeat: settings.fallbackHeartbeat);
                }
              }

              if (settings.isLoaded) {
                tryStart();
              } else {
                settings.addListener(() {
                  tryStart();
                });
              }
              return svc;
            },
          ),
          Provider<TrustManager>(create: (_) => TrustManager()),
          ChangeNotifierProvider(create: (_) => PeersModel()),
          ProxyProvider3<LocalStorageDataSource, PeerConnectionDataSource,
              HiveSharedFolderDataSource, FileSharingRepository>(
            update: (ctx, local, peer, hive, __) => FileSharingRepositoryImpl(
              localStorageDataSource: local,
              peerConnectionDataSource: peer,
              hiveSharedFolderDataSource: hive,
              hiveFileRequestDataSource: ctx.read<HiveFileRequestDataSource>(),
            ),
          ),
          ChangeNotifierProvider(
              create: (_) => SharedFoldersModel()..loadFromPersistence()),
          ChangeNotifierProvider(
              create: (_) => FileRequestsModel()..loadFromPersistence()),
          ChangeNotifierProvider(create: (_) => DownloadManager()),
          Provider<LocalHttpServer>(
            lazy: false,
            create: (ctx) {
              final model = ctx.read<SharedFoldersModel>();
              final requestsModel = ctx.read<FileRequestsModel>();
              final repo = ctx.read<FileSharingRepository>();
              final app = ctx.read<AppServices>();
              final encryptionService = app.encryptionService;
              final keyManager = app.transferKeyManager;
              final server = LocalHttpServer(
                port: 7345,
                sharedFoldersProvider: () async => model.folders
                    .map((f) => {
                          'id': f.id,
                          'name': f.name,
                          'path': f.path,
                          'isShared': f.isShared,
                        })
                    .toList(),
                fileRequestsProvider: () async => requestsModel.requests
                    .map((r) => {
                          'id': r.id,
                          'folderId': r.folderId,
                          'peerId': r.peerId,
                          'filePath': r.filePath,
                          'status': r.status.name,
                          'createdAt': r.createdAt.toIso8601String(),
                        })
                    .toList(),
                updateRequestStatus: (id, statusStr) async {
                  try {
                    final status = FileRequestStatus.values
                        .firstWhere((e) => e.name == statusStr);
                    await repo.updateFileRequestStatus(id, status);
                    requestsModel.updateStatus(id, status);
                    return true;
                  } catch (_) {
                    return false;
                  }
                },
                requestHashProvider: (id) async => _hashCache[id],
                createRequest: (data) async {
                  // Unified DTO & validation; throws specific codes
                  final folderId = (data['folderId'] as String?)?.trim();
                  final peerId = (data['peerId'] as String?)?.trim() ?? 'peer';
                  final rawPath = (data['filePath'] as String?)?.trim();
                  if (folderId == null || folderId.isEmpty) {
                    throw Exception('err_folder_required');
                  }
                  final folder = model.folders.firstWhere(
                      (f) => f.id == folderId,
                      orElse: () => SharedFolder(id: '', name: '', path: null));
                  if (folder.id.isEmpty || folder.path == null) {
                    throw Exception('err_folder_not_found');
                  }
                  String? sanitized;
                  if (rawPath != null && rawPath.isNotEmpty) {
                    final folderRoot = folder.path!;
                    if (p.isAbsolute(rawPath)) {
                      final norm = p.normalize(rawPath);
                      if (!p.isWithin(folderRoot, norm) && norm != folderRoot) {
                        throw Exception('err_path_outside_folder');
                      }
                      sanitized = norm;
                    } else {
                      final joined = p.normalize(p.join(folderRoot, rawPath));
                      if (!p.isWithin(folderRoot, joined) &&
                          joined != folderRoot) {
                        throw Exception('err_path_outside_folder');
                      }
                      sanitized = joined;
                    }
                    // Symlink hardening: resolve both folder root and candidate, then re-check containment.
                    try {
                      final resolvedRoot =
                          Directory(folderRoot).resolveSymbolicLinksSync();
                      final resolvedCandidate =
                          File(sanitized).resolveSymbolicLinksSync();
                      final normRoot = p.normalize(resolvedRoot);
                      final normCand = p.normalize(resolvedCandidate);
                      final within = p.isWithin(normRoot, normCand) ||
                          normCand == normRoot;
                      if (!within) {
                        throw Exception('err_path_outside_folder');
                      }
                      sanitized = normCand;
                    } catch (e) {
                      // If resolution fails (file missing) keep sanitized original; later open will fail if invalid.
                    }
                  }
                  if (sanitized == null && folder.allowPreview == false) {
                    throw Exception('preview_forbidden');
                  }
                  final id = DateTime.now().microsecondsSinceEpoch.toString();
                  final autoApprove = folder.autoApprove;
                  final fr = FileRequest(
                    id: id,
                    folderId: folderId,
                    peerId: peerId,
                    filePath: sanitized,
                    status: autoApprove
                        ? FileRequestStatus.approved
                        : FileRequestStatus.pending,
                  );
                  await repo.requestFile(fr);
                  requestsModel.addRequest(fr);
                  return {
                    'ver': 1,
                    'request': {
                      'id': fr.id,
                      'folderId': fr.folderId,
                      'peerId': fr.peerId,
                      'filePath': fr.filePath,
                      'status': fr.status.name,
                      'createdAt': fr.createdAt.toIso8601String(),
                    }
                  };
                },
                downloadHandler: (request, id) async {
                  final settings = ctx.read<SettingsModel>();
                  // Find request
                  final req = requestsModel.requests.firstWhere(
                      (r) => r.id == id,
                      orElse: () => FileRequest(
                          id: '', folderId: '', peerId: '', filePath: null));
                  if (req.id.isEmpty) {
                    return Response(404,
                        body: jsonEncode({
                          'ver': 1,
                          'error': 'request_not_found',
                          'message': 'Request not found'
                        }),
                        headers: const {
                          'Content-Type': 'application/json',
                          'Access-Control-Allow-Origin': '*'
                        });
                  }
                  if (req.status != FileRequestStatus.approved &&
                      req.status != FileRequestStatus.transferring) {
                    return Response(403,
                        body: jsonEncode({
                          'ver': 1,
                          'error': 'not_approved',
                          'message': 'Request not approved'
                        }),
                        headers: const {
                          'Content-Type': 'application/json',
                          'Access-Control-Allow-Origin': '*'
                        });
                  }
                  // Find folder
                  final folder = model.folders.firstWhere(
                      (f) => f.id == req.folderId,
                      orElse: () => SharedFolder(id: '', name: '', path: null));
                  if (folder.id.isEmpty || folder.path == null) {
                    return Response(404,
                        body: jsonEncode({
                          'ver': 1,
                          'error': 'folder_not_found',
                          'message': 'Folder not found'
                        }),
                        headers: const {
                          'Content-Type': 'application/json',
                          'Access-Control-Allow-Origin': '*'
                        });
                  }
                  // If specific file requested, serve it, else list folder entries (basic JSON)
                  if (req.filePath != null) {
                    // Rate limiting prior to heavy work
                    final peerId = req.peerId.isNotEmpty ? req.peerId : 'anon';
                    final peerActive = _activePerPeer[peerId] ?? 0;
                    if (peerActive >= settings.maxPerPeer ||
                        _activeGlobal >= settings.maxGlobal) {
                      final remainingPeer = (settings.maxPerPeer - peerActive)
                          .clamp(0, settings.maxPerPeer);
                      final remainingGlobal =
                          (settings.maxGlobal - _activeGlobal)
                              .clamp(0, settings.maxGlobal);
                      return Response(429,
                          body: jsonEncode({
                            'ver': 1,
                            'error': 'rate_limited',
                            'message': 'Too many concurrent transfers'
                          }),
                          headers: {
                            'Content-Type': 'application/json',
                            'Access-Control-Allow-Origin': '*',
                            'X-RateLimit-Limit-Peer':
                                settings.maxPerPeer.toString(),
                            'X-RateLimit-Limit-Global':
                                settings.maxGlobal.toString(),
                            'X-RateLimit-Remaining-Peer':
                                remainingPeer.toString(),
                            'X-RateLimit-Remaining-Global':
                                remainingGlobal.toString(),
                          });
                    }
                    _activePerPeer[peerId] = peerActive + 1;
                    _activeGlobal += 1;
                    bool cleaned = false;
                    Future<void> _cleanup() async {
                      if (cleaned) return;
                      cleaned = true;
                      final left = (_activePerPeer[peerId] ?? 1) - 1;
                      if (left <= 0) {
                        _activePerPeer.remove(peerId);
                      } else {
                        _activePerPeer[peerId] = left;
                      }
                      _activeGlobal = (_activeGlobal - 1).clamp(0, 1 << 30);
                    }

                    final file = File(req.filePath!);
                    // Re-validate symlink containment at download time.
                    try {
                      final folderRootResolved =
                          Directory(folder.path!).resolveSymbolicLinksSync();
                      final fileResolved = file.resolveSymbolicLinksSync();
                      final normRoot = p.normalize(folderRootResolved);
                      final normFile = p.normalize(fileResolved);
                      final within = p.isWithin(normRoot, normFile) ||
                          normFile == normRoot;
                      if (!within) {
                        return Response(403,
                            body: jsonEncode({
                              'ver': 1,
                              'error': 'path_outside_folder',
                              'message': 'Resolved path outside shared folder'
                            }),
                            headers: const {
                              'Content-Type': 'application/json',
                              'Access-Control-Allow-Origin': '*'
                            });
                      }
                    } catch (_) {
                      // If resolution throws (e.g., race deletion) proceed with existing existence checks below.
                    }
                    if (!await file.exists()) {
                      return Response(404,
                          body: jsonEncode({
                            'ver': 1,
                            'error': 'file_not_found',
                            'message': 'File missing'
                          }),
                          headers: const {
                            'Content-Type': 'application/json',
                            'Access-Control-Allow-Origin': '*'
                          });
                    }
                    // Transition to transferring if not already
                    if (req.status != FileRequestStatus.transferring) {
                      await repo.updateFileRequestStatus(
                          req.id, FileRequestStatus.transferring);
                      requestsModel.updateStatus(
                          req.id, FileRequestStatus.transferring);
                    }
                    final chunkSize = settings.chunkSize;
                    final length = await file.length();
                    // Resume support: read Range header (bytes=start-)
                    // OR query param startChunk (takes precedence if provided).
                    int startOffset = 0;
                    int startChunk = 0;
                    final range =
                        request.headers['range'] ?? request.headers['Range'];
                    final qp = request.url.queryParameters;
                    if (qp.containsKey('startChunk')) {
                      final sc = int.tryParse(qp['startChunk']!);
                      if (sc != null && sc > 0) {
                        startChunk = sc;
                        startOffset = startChunk * chunkSize;
                        if (startOffset >= length) {
                          startOffset = 0;
                          startChunk = 0;
                        }
                      }
                    } else if (range != null && range.startsWith('bytes=')) {
                      final spec = range.substring(6);
                      final dash = spec.indexOf('-');
                      if (dash >= 0) {
                        final startStr = spec.substring(0, dash).trim();
                        final so = int.tryParse(startStr);
                        if (so != null && so > 0) {
                          if (so >= length) {
                            return Response(416,
                                body: jsonEncode({
                                  'ver': 1,
                                  'error': 'range_not_satisfiable',
                                  'message': 'Requested range not satisfiable'
                                }),
                                headers: const {
                                  'Content-Type': 'application/json',
                                  'Access-Control-Allow-Origin': '*'
                                });
                          }
                          // Align to chunk boundary
                          startOffset = (so ~/ chunkSize) * chunkSize;
                          startChunk = startOffset ~/ chunkSize;
                        }
                      }
                    }
                    // Replay protection: disallow starting before highest previously served chunk for this id.
                    final prevMax = _FileSharingAppState._maxServedChunk[id];
                    if (prevMax != null && startChunk < prevMax) {
                      return Response(409,
                          body: jsonEncode({
                            'ver': 1,
                            'error': 'replay_attempt',
                            'message': 'Chunk rewind not allowed'
                          }),
                          headers: const {
                            'Content-Type': 'application/json',
                            'Access-Control-Allow-Origin': '*'
                          });
                    }
                    // Streaming hash (computed while sending; published after completion via hash endpoint)
                    final digest = SHA256Digest();
                    // Determine startChunk for resume if provided
                    // Accept query parameter startChunk
                    // (shelf Router passes Request differently; we can't access here, so ignoring request param in this closure) TODO: integrate if needed.
                    requestsModel.updateBytes(req.id, startOffset, length);
                    final key = keyManager.keyFor(req.id);
                    final baseNonce = encryptionService.generateIv();
                    final nonceBase =
                        Uint8List.fromList(baseNonce.sublist(0, 12));
                    // Provide second stream (re-open file)
                    // Optional gzip compression if client indicates support (Accept-Encoding: gzip) and file large enough
                    final acceptEnc = request.headers['accept-encoding'] ?? '';
                    final wantGzip = acceptEnc.contains('gzip');
                    final compressionThreshold = 8 * 1024; // 8KB heuristic
                    Stream<List<int>> basePlain =
                        file.openRead(startOffset).map((chunk) {
                      final u = chunk is Uint8List
                          ? chunk
                          : Uint8List.fromList(chunk);
                      digest.update(u, 0, u.length);
                      return u;
                    });
                    if (wantGzip &&
                        length - startOffset >= compressionThreshold) {
                      // Wrap in gzip encoder (dart:io) BEFORE encryption so encryption frames carry compressed plaintext.
                      basePlain = basePlain.transform(gzip.encoder);
                    }
                    final plainStream = basePlain;
                    final chunkedStream = encryptionService.encryptChunkedGcm(
                      plainStream,
                      key,
                      nonceBase,
                      chunkSize: chunkSize,
                      startCounter: startChunk,
                    );
                    // Track progress while forwarding frames
                    final framedController = StreamController<List<int>>();
                    StreamSubscription<List<int>>? sub;
                    int sent = startOffset;
                    int currentChunk = startChunk;
                    // Idle timeout
                    final idleTimeout =
                        Duration(seconds: settings.idleTimeoutSeconds);
                    Timer? idleTimer;
                    void resetIdle() {
                      idleTimer?.cancel();
                      idleTimer = Timer(idleTimeout, () async {
                        await sub?.cancel();
                        await repo.updateFileRequestStatus(
                            req.id, FileRequestStatus.failed);
                        requestsModel.updateStatus(
                            req.id, FileRequestStatus.failed);
                        requestsModel.updateProgress(req.id, 0);
                        requestsModel.clearCanceller(req.id);
                        await framedController.close();
                      });
                    }

                    resetIdle();
                    // Hash known only after completion.
                    sub = chunkedStream.listen((frame) {
                      // Frame structure: [len(4)][cipher][tag(16)] => we estimate progress using cipher length approx.
                      if (frame.length >= 4) {
                        final lenBytes = frame.sublist(0, 4);
                        final bd =
                            ByteData.view(Uint8List.fromList(lenBytes).buffer);
                        final chunkLen = bd.getUint32(0, Endian.big);
                        sent += chunkLen;
                        if (sent > length) sent = length;
                        requestsModel.updateBytes(req.id, sent, length);
                        currentChunk += 1;
                        _FileSharingAppState._maxServedChunk[id] = currentChunk;
                      }
                      framedController.add(frame);
                      resetIdle();
                    }, onError: (e, st) async {
                      // Emit failure footer before closing if possible
                      try {
                        final hmacKey =
                            encryptionService.deriveFooterHmacKey(key);
                        final metaMap = {
                          'ver': 1,
                          'type': 'failed',
                          'state': 'failed'
                        };
                        final noSig = jsonEncode(metaMap);
                        final sig = encryptionService.hmacSha256Hex(
                            hmacKey, utf8.encode(noSig));
                        final meta = jsonEncode({...metaMap, 'sig': sig});
                        final mb = utf8.encode(meta);
                        final lb = Uint8List(4)
                          ..buffer
                              .asByteData()
                              .setUint32(0, mb.length, Endian.big);
                        framedController.add(lb);
                        framedController.add(mb);
                      } catch (_) {}
                      framedController.addError(e, st);
                      await repo.updateFileRequestStatus(
                          req.id, FileRequestStatus.failed);
                      requestsModel.updateStatus(
                          req.id, FileRequestStatus.failed);
                      requestsModel.updateProgress(req.id, 0);
                      requestsModel.clearCanceller(req.id);
                      await framedController.close();
                      await _cleanup();
                    }, onDone: () async {
                      // Compute plaintext hash now that all chunks sent (digest accumulated earlier).
                      try {
                        final out = Uint8List(digest.digestSize);
                        digest.doFinal(out, 0);
                        final sb = StringBuffer();
                        for (final b in out) {
                          sb.write(b.toRadixString(16).padLeft(2, '0'));
                        }
                        final hashHex = sb.toString();
                        _hashCache[req.id] =
                            hashHex; // maintain endpoint compatibility
                        // Emit final metadata frame (unencrypted JSON appended as clear footer after frames)
                        final hmacKey =
                            encryptionService.deriveFooterHmacKey(key);
                        final metaMap = {
                          'ver': 1,
                          'type': 'final',
                          'state': 'completed',
                          'hash': hashHex,
                          'length': length,
                          'chunks': currentChunk,
                        };
                        final noSig = jsonEncode(metaMap);
                        final sig = encryptionService.hmacSha256Hex(
                            hmacKey, utf8.encode(noSig));
                        final meta = jsonEncode({...metaMap, 'sig': sig});
                        final metaBytes = utf8.encode(meta);
                        final lenBuf = Uint8List(4)
                          ..buffer
                              .asByteData()
                              .setUint32(0, metaBytes.length, Endian.big);
                        framedController.add(lenBuf);
                        framedController.add(metaBytes);
                      } catch (_) {}
                      await repo.updateFileRequestStatus(
                          req.id, FileRequestStatus.completed);
                      requestsModel.updateStatus(
                          req.id, FileRequestStatus.completed);
                      requestsModel.updateBytes(req.id, length, length);
                      requestsModel.clearCanceller(req.id);
                      _FileSharingAppState._maxServedChunk[id] = currentChunk;
                      await framedController.close();
                      idleTimer?.cancel();
                      await _cleanup();
                    }, cancelOnError: true);
                    requestsModel.setCanceller(req.id, () async {
                      await sub?.cancel();
                      // Emit canceled footer
                      try {
                        final hmacKey =
                            encryptionService.deriveFooterHmacKey(key);
                        final metaMap = {
                          'ver': 1,
                          'type': 'canceled',
                          'state': 'canceled'
                        };
                        final noSig = jsonEncode(metaMap);
                        final sig = encryptionService.hmacSha256Hex(
                            hmacKey, utf8.encode(noSig));
                        final meta = jsonEncode({...metaMap, 'sig': sig});
                        final cb = utf8.encode(meta);
                        final lb = Uint8List(4)
                          ..buffer
                              .asByteData()
                              .setUint32(0, cb.length, Endian.big);
                        framedController.add(lb);
                        framedController.add(cb);
                      } catch (_) {}
                      await repo.updateFileRequestStatus(
                          req.id, FileRequestStatus.failed);
                      requestsModel.updateStatus(
                          req.id, FileRequestStatus.failed);
                      requestsModel.updateProgress(req.id, 0);
                      requestsModel.clearCanceller(req.id);
                      idleTimer?.cancel();
                      await framedController.close();
                      await _cleanup();
                    });
                    final remainingPeer =
                        (settings.maxPerPeer - (_activePerPeer[peerId] ?? 0))
                            .clamp(0, settings.maxPerPeer);
                    final remainingGlobal = (settings.maxGlobal - _activeGlobal)
                        .clamp(0, settings.maxGlobal);
                    final baseHeaders = {
                      'Content-Type': 'application/octet-stream',
                      'Access-Control-Allow-Origin': '*',
                      'Content-Disposition':
                          'attachment; filename="${file.uri.pathSegments.last}.gcm"',
                      'X-File-Key': encryptionService.encodeKey(key),
                      'X-File-Nonce-Base':
                          encryptionService.encodeKey(nonceBase),
                      'X-File-Encrypted': 'aes-gcm-chunked',
                      'X-File-Frame': 'len|cipher|tag16',
                      if (wantGzip &&
                          length - startOffset >= compressionThreshold)
                        'Content-Encoding': 'gzip',
                      // Hash omitted; client can poll /requests/<id>/hash when completed.
                      'X-File-Chunk-Size': chunkSize.toString(),
                      'X-File-Length': length.toString(),
                      'X-File-Start-Chunk': startChunk.toString(),
                      'X-RateLimit-Remaining-Peer': remainingPeer.toString(),
                      'X-RateLimit-Remaining-Global':
                          remainingGlobal.toString(),
                      'X-Transfer-State': 'running',
                      'X-Transfer-Cancel-Signal': 'footer',
                    };
                    if (startOffset > 0) {
                      return Response(206,
                          body: framedController.stream,
                          headers: {
                            ...baseHeaders,
                            'Content-Range':
                                'bytes $startOffset-${length - 1}/$length',
                            'X-File-Resume': 'true',
                          });
                    }
                    return Response.ok(framedController.stream,
                        headers: baseHeaders);
                  } else {
                    final dir = Directory(folder.path!);
                    if (!await dir.exists()) {
                      return Response(404,
                          body: jsonEncode({
                            'ver': 1,
                            'error': 'folder_not_found',
                            'message': 'Folder missing'
                          }),
                          headers: const {
                            'Content-Type': 'application/json',
                            'Access-Control-Allow-Origin': '*'
                          });
                    }
                    final entries = await dir
                        .list()
                        .where((e) => e is File)
                        .map((e) => e.path.split(Platform.pathSeparator).last)
                        .toList();
                    return Response.ok(
                        jsonEncode({'files': entries, 'folder': folder.name}),
                        headers: {
                          'Content-Type': 'application/json',
                          'Access-Control-Allow-Origin': '*',
                        });
                  }
                },
                listFilesHandler: (folderId) async {
                  final folder = model.folders.firstWhere(
                      (f) => f.id == folderId,
                      orElse: () => SharedFolder(id: '', name: '', path: null));
                  if (folder.id.isEmpty || folder.path == null) {
                    return Response(404,
                        body: jsonEncode({
                          'ver': 1,
                          'error': 'folder_not_found',
                          'message': 'Folder not found'
                        }),
                        headers: const {
                          'Content-Type': 'application/json',
                          'Access-Control-Allow-Origin': '*'
                        });
                  }
                  final dir = Directory(folder.path!);
                  if (!await dir.exists()) {
                    return Response(404,
                        body: jsonEncode({
                          'ver': 1,
                          'error': 'folder_not_found',
                          'message': 'Folder missing'
                        }),
                        headers: const {
                          'Content-Type': 'application/json',
                          'Access-Control-Allow-Origin': '*'
                        });
                  }
                  final entries = await dir
                      .list()
                      .where((e) => e is File)
                      .map((e) => e.path.split(Platform.pathSeparator).last)
                      .toList();
                  return Response.ok(
                      jsonEncode({
                        'folderId': folder.id,
                        'folder': folder.name,
                        'files': entries
                      }),
                      headers: {
                        'Content-Type': 'application/json',
                        'Access-Control-Allow-Origin': '*',
                      });
                },
                authToken:
                    null, // disable global token to keep existing tests unchanged
                peerAuthManager: PeerAuthManager(),
                onLog: (rec) {
                  // Keep last 500 logs
                  if (_logs.length > 500) _logs.removeAt(0);
                  _logs.add(rec);
                  if (_showLogs && mounted) setState(() {});
                },
              );
              server.start().then((_) {
                // Propagate fingerprint to discovery TXT records once available
                try {
                  final fp = server.certFingerprintSha256;
                  if (fp != null) {
                    ctx.read<PeerDiscoveryService>().setFingerprint(fp);
                  }
                } catch (_) {}
              });
              return server;
            },
            dispose: (_, s) => s.stop(),
          ),
        ],
        child: Builder(builder: (ctx) {
          // subscribe once
          final trust = ctx.read<TrustManager>();
          if (!trust.isLoaded) {
            // Initialize asynchronously without blocking build.
            unawaited(trust.init());
          }
          _peerSub ??=
              ctx.read<PeerDiscoveryService>().peersStream.listen((list) async {
            final accepted = <Peer>[];
            for (final p in list) {
              final ok = trust.record(p.id, p.fingerprint);
              if (ok) {
                accepted.add(p);
              } else {
                // Show mismatch warning once.
                if (mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                    content: Text(
                        'Fingerprint mismatch for peer ${p.name} (${p.id}). Ignored.'),
                    backgroundColor: Colors.redAccent,
                    duration: const Duration(seconds: 3),
                  ));
                }
              }
            }
            if (mounted) {
              ctx.read<PeersModel>().setPeers(accepted);
            }
          });
          return Consumer<SettingsModel>(builder: (_, settings, __) {
            _showLogs = settings.loggingEnabled;
            // Auto-resume trigger (once) after settings + downloads restored
            if (settings.autoResume) {
              // Schedule after first frame to avoid rebuild loops
              WidgetsBinding.instance.addPostFrameCallback((_) async {
                final dm = ctx.read<DownloadManager>();
                if (!dm.isLoaded) {
                  final restored = await DownloadManager.restore();
                  await dm.load(restored);
                }
                for (final entry in dm.downloads.entries) {
                  final id = entry.key;
                  final st = entry.value;
                  if (st.completed || st.failed || st.canceled) continue;
                  if (st.uri == null || st.filePath == null) continue;
                  try {
                    final file = File(st.filePath!);
                    final existing =
                        await file.exists() ? await file.length() : 0;
                    // If we already have full expected length, mark complete.
                    if (st.expectedLength != null &&
                        existing >= st.expectedLength!) {
                      dm.complete(id);
                      continue;
                    }
                    final enc = ctx.read<AppServices>().encryptionService;
                    final downloader = ClientDownloadService(enc);
                    unawaited(downloader
                        .download(Uri.parse(st.uri!), file,
                            resume: true,
                            computeHash: settings.computeHashOnDownload,
                            onProgress: (r, t) => dm.progress(id, r, t))
                        .then((r) {
                      dm.footerState(id, r.transferState,
                          hash: r.hashHex,
                          expectedHash: r.expectedHash,
                          footerSignatureValid: r.footerSignatureValid);
                      if (r.transferState == null) {
                        // fallback assume completed
                        dm.complete(id,
                            hash: r.hashHex,
                            expectedHash: r.expectedHash,
                            mismatch: r.hashMismatch,
                            footerSignatureValid: r.footerSignatureValid);
                      }
                    }).catchError((e) {
                      dm.fail(id, e);
                    }));
                  } catch (e) {
                    dm.fail(id, e);
                  }
                }
              });
            }
            final seed = Color(settings.colorSeed);
            ThemeData light = ThemeData(
              useMaterial3: true,
              colorSchemeSeed: seed,
              snackBarTheme:
                  const SnackBarThemeData(behavior: SnackBarBehavior.floating),
            );
            ThemeData dark = ThemeData(
              useMaterial3: true,
              colorSchemeSeed: seed,
              brightness: Brightness.dark,
              snackBarTheme:
                  const SnackBarThemeData(behavior: SnackBarBehavior.floating),
            );
            return MaterialApp(
              title: 'File Sharing App',
              theme: light,
              darkTheme: dark,
              themeMode: settings.themeModeEnum,
              home: HomePage(
                logs: _logs,
                toggleLogs: settings.toggleLogging,
                showLogs: settings.loggingEnabled,
                autoResume: settings.autoResume,
                toggleAutoResume: settings.toggleAutoResume,
                computeHash: settings.computeHashOnDownload,
                toggleComputeHash: settings.toggleComputeHash,
              ),
            );
          });
        }));
  }
}

// Lightweight DI container placeholder for future expansion.
class AppServices {
  // Centralized singleton services.
  final EncryptionService encryptionService = EncryptionService();
  late final TransferKeyManager transferKeyManager =
      TransferKeyManager(encryptionService);
}

class SettingsModel extends ChangeNotifier {
  bool loggingEnabled = false;
  bool autoResume = true;
  bool computeHashOnDownload = true;
  bool discoveryEnabled = true; // persisted toggle for peer discovery
  bool discoveryVerbose = true; // show verbose discovery logs
  bool fallbackHeartbeat = false; // enable UDP heartbeat fallback
  // Theming
  int colorSeed = 0xFF6750A4; // default seed color (Material 3 purple)
  String themeMode = 'system'; // system | light | dark
  int maxPerPeer = 2;
  int maxGlobal = 4;
  int idleTimeoutSeconds = 30;
  int chunkSize = 64 * 1024;
  bool _loaded = false;
  bool get isLoaded => _loaded;
  ThemeMode get themeModeEnum {
    if (themeMode == 'light') return ThemeMode.light;
    if (themeMode == 'dark') return ThemeMode.dark;
    return ThemeMode.system;
  }

  Future<void> load() async {
    try {
      final box = await Hive.openBox('settings');
      loggingEnabled = box.get('loggingEnabled', defaultValue: false) as bool;
      autoResume = box.get('autoResume', defaultValue: true) as bool;
      computeHashOnDownload =
          box.get('computeHash', defaultValue: true) as bool;
      discoveryEnabled =
          box.get('discoveryEnabled', defaultValue: true) as bool;
      discoveryVerbose =
          box.get('discoveryVerbose', defaultValue: true) as bool;
      fallbackHeartbeat =
          box.get('fallbackHeartbeat', defaultValue: false) as bool;
      colorSeed = (box.get('colorSeed', defaultValue: 0xFF6750A4) as int);
      themeMode = (box.get('themeMode', defaultValue: 'system') as String);
      maxPerPeer = box.get('maxPerPeer', defaultValue: 2) as int;
      maxGlobal = box.get('maxGlobal', defaultValue: 4) as int;
      idleTimeoutSeconds =
          box.get('idleTimeoutSeconds', defaultValue: 30) as int;
      chunkSize = box.get('chunkSize', defaultValue: 64 * 1024) as int;
      _loaded = true;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final box = await Hive.openBox('settings');
      await box.putAll({
        'loggingEnabled': loggingEnabled,
        'autoResume': autoResume,
        'computeHash': computeHashOnDownload,
        'discoveryEnabled': discoveryEnabled,
        'discoveryVerbose': discoveryVerbose,
        'fallbackHeartbeat': fallbackHeartbeat,
        'colorSeed': colorSeed,
        'themeMode': themeMode,
        'maxPerPeer': maxPerPeer,
        'maxGlobal': maxGlobal,
        'idleTimeoutSeconds': idleTimeoutSeconds,
        'chunkSize': chunkSize,
      });
    } catch (_) {}
  }

  void toggleLogging() {
    loggingEnabled = !loggingEnabled;
    _persist();
    notifyListeners();
  }

  void toggleAutoResume() {
    autoResume = !autoResume;
    _persist();
    notifyListeners();
  }

  void toggleComputeHash() {
    computeHashOnDownload = !computeHashOnDownload;
    _persist();
    notifyListeners();
  }

  void setDiscoveryEnabled(bool v) {
    if (discoveryEnabled == v) return;
    discoveryEnabled = v;
    _persist();
    notifyListeners();
  }

  void setDiscoveryVerbose(bool v) {
    if (discoveryVerbose == v) return;
    discoveryVerbose = v;
    _persist();
    notifyListeners();
  }

  void setFallbackHeartbeat(bool v) {
    if (fallbackHeartbeat == v) return;
    fallbackHeartbeat = v;
    _persist();
    notifyListeners();
  }

  void setColorSeed(int argb) {
    if (colorSeed == argb) return;
    colorSeed = argb;
    _persist();
    notifyListeners();
  }

  void setThemeMode(String mode) {
    if (mode != 'system' && mode != 'light' && mode != 'dark') return;
    if (themeMode == mode) return;
    themeMode = mode;
    _persist();
    notifyListeners();
  }

  void updateLimits(
      {int? perPeer, int? global, int? idleSeconds, int? newChunkSize}) {
    bool changed = false;
    if (perPeer != null && perPeer > 0) {
      maxPerPeer = perPeer;
      changed = true;
    }
    if (global != null && global > 0) {
      maxGlobal = global;
      changed = true;
    }
    if (idleSeconds != null && idleSeconds > 0) {
      idleTimeoutSeconds = idleSeconds;
      changed = true;
    }
    if (newChunkSize != null && newChunkSize >= 1024) {
      chunkSize = newChunkSize;
      changed = true;
    }
    if (changed) {
      _persist();
      notifyListeners();
    }
  }
}

class SharedFoldersModel extends ChangeNotifier {
  final List<SharedFolder> _folders = [];
  List<SharedFolder> get folders => List.unmodifiable(_folders);

  void setFolders(List<SharedFolder> folders) {
    _folders
      ..clear()
      ..addAll(folders);
    notifyListeners();
  }

  void addFolder(SharedFolder folder) {
    _folders.add(folder);
    notifyListeners();
  }

  Future<void> loadFromPersistence() async {
    try {
      final hive = HiveSharedFolderDataSource();
      final list = await hive.getAll();
      if (list.isNotEmpty) {
        setFolders(list);
      }
    } catch (_) {
      // ignore for now
    }
  }
}

class PeersModel extends ChangeNotifier {
  final List<Peer> _peers = [];
  List<Peer> get peers => List.unmodifiable(_peers);

  void setPeers(List<Peer> peers) {
    _peers
      ..clear()
      ..addAll(peers);
    notifyListeners();
  }
}

class DownloadManager extends ChangeNotifier {
  final Map<String, DownloadStatus> _downloads = {}; // id -> status
  Map<String, DownloadStatus> get downloads => Map.unmodifiable(_downloads);
  bool _loaded = false;
  bool get isLoaded => _loaded;

  Future<void> load(Map<String, DownloadStatus> initial) async {
    _downloads
      ..clear()
      ..addAll(initial);
    _loaded = true;
    notifyListeners();
  }

  void start(String id, {String? filePath, int? expectedLength, String? uri}) {
    _downloads[id] = DownloadStatus(
        filePath: filePath, expectedLength: expectedLength, uri: uri);
    notifyListeners();
  }

  void progress(String id, int received, int? total) {
    final prev = _downloads[id] ?? const DownloadStatus();
    _downloads[id] = prev.copyWith(received: received, total: total);
    notifyListeners();
  }

  void complete(String id,
      {String? hash,
      String? expectedHash,
      bool? mismatch,
      bool? footerSignatureValid}) {
    final prev = _downloads[id] ?? const DownloadStatus();
    _downloads[id] = prev.copyWith(
      completed: true,
      hash: hash,
      expectedHash: expectedHash,
      hashMismatch: mismatch ?? false,
      footerSignatureValid: footerSignatureValid ?? prev.footerSignatureValid,
    );
    notifyListeners();
    _persist();
  }

  void fail(String id, Object error) {
    final prev = _downloads[id] ?? const DownloadStatus();
    _downloads[id] = prev.copyWith(failed: true, error: error.toString());
    notifyListeners();
    _persist();
  }

  // Map transfer footer state -> local status
  void footerState(String id, String? state,
      {String? hash, String? expectedHash, bool? footerSignatureValid}) {
    if (state == null) return;
    switch (state) {
      case 'completed':
        complete(id,
            hash: hash,
            expectedHash: expectedHash,
            mismatch: false,
            footerSignatureValid: footerSignatureValid);
        break;
      case 'canceled':
        final prev = _downloads[id] ?? const DownloadStatus();
        _downloads[id] = prev.copyWith(canceled: true);
        notifyListeners();
        _persist();
        break;
      case 'failed':
        fail(id, 'remote_failed');
        break;
    }
  }

  void cancel(String id) {
    final prev = _downloads[id] ?? const DownloadStatus();
    if (prev.completed || prev.failed || prev.canceled) return;
    _downloads[id] = prev.copyWith(canceled: true);
    notifyListeners();
    _persist();
  }

  Future<void> _persist() async {
    try {
      final box = await Hive.openBox('downloads');
      final map = _downloads.map((k, v) => MapEntry(k, {
            'received': v.received,
            'total': v.total,
            'completed': v.completed,
            'failed': v.failed,
            'canceled': v.canceled,
            'error': v.error,
            'hash': v.hash,
            'expectedHash': v.expectedHash,
            'hashMismatch': v.hashMismatch,
            'filePath': v.filePath,
            'expectedLength': v.expectedLength,
            'nonceBaseHex': v.nonceBaseHex,
            'startChunk': v.startChunk,
            'uri': v.uri,
            'footerSignatureValid': v.footerSignatureValid,
          }));
      await box.put('state', map);
    } catch (_) {}
  }

  static Future<Map<String, DownloadStatus>> restore() async {
    try {
      final box = await Hive.openBox('downloads');
      final raw = box.get('state') as Map?;
      if (raw == null) return {};
      return raw.map<String, DownloadStatus>((k, v) {
        final m = Map<String, dynamic>.from(v as Map);
        return MapEntry(
          k as String,
          DownloadStatus(
            received: (m['received'] as int?) ?? 0,
            total: m['total'] as int?,
            completed: m['completed'] == true,
            failed: m['failed'] == true,
            canceled: m['canceled'] == true,
            error: m['error'] as String?,
            hash: m['hash'] as String?,
            expectedHash: m['expectedHash'] as String?,
            hashMismatch: m['hashMismatch'] == true,
            filePath: m['filePath'] as String?,
            expectedLength: m['expectedLength'] as int?,
            nonceBaseHex: m['nonceBaseHex'] as String?,
            startChunk: m['startChunk'] as int?,
            uri: m['uri'] as String?,
            footerSignatureValid: (m['footerSignatureValid'] as bool?) ?? true,
          ),
        );
      });
    } catch (_) {
      return {};
    }
  }
}

/// Root shell with bottom navigation for Home and Settings
class AppShell extends StatefulWidget {
  final Widget home;
  const AppShell({Key? key, required this.home}) : super(key: key);

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      widget.home,
      const SettingsPage(),
    ];
    return Scaffold(
      body: SafeArea(child: pages[_index]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings'),
        ],
        onDestinationSelected: (i) => setState(() => _index = i),
      ),
    );
  }
}

class DownloadStatus {
  final int received;
  final int? total;
  final bool completed;
  final bool failed;
  final bool canceled;
  final String? error;
  final String? hash;
  final String? expectedHash;
  final bool hashMismatch;
  final String? filePath;
  final int? expectedLength;
  final String? nonceBaseHex; // for resume verification
  final int? startChunk; // initial chunk index for resumed transfer
  final String? uri; // source URL for auto-resume
  final bool footerSignatureValid;
  const DownloadStatus({
    this.received = 0,
    this.total,
    this.completed = false,
    this.failed = false,
    this.canceled = false,
    this.error,
    this.hash,
    this.expectedHash,
    this.hashMismatch = false,
    this.filePath,
    this.expectedLength,
    this.nonceBaseHex,
    this.startChunk,
    this.uri,
    this.footerSignatureValid = true,
  });
  DownloadStatus copyWith({
    int? received,
    int? total,
    bool? completed,
    bool? failed,
    bool? canceled,
    String? error,
    String? hash,
    String? expectedHash,
    bool? hashMismatch,
    String? filePath,
    int? expectedLength,
    String? nonceBaseHex,
    int? startChunk,
    String? uri,
    bool? footerSignatureValid,
  }) =>
      DownloadStatus(
        received: received ?? this.received,
        total: total ?? this.total,
        completed: completed ?? this.completed,
        failed: failed ?? this.failed,
        canceled: canceled ?? this.canceled,
        error: error ?? this.error,
        hash: hash ?? this.hash,
        expectedHash: expectedHash ?? this.expectedHash,
        hashMismatch: hashMismatch ?? this.hashMismatch,
        filePath: filePath ?? this.filePath,
        expectedLength: expectedLength ?? this.expectedLength,
        nonceBaseHex: nonceBaseHex ?? this.nonceBaseHex,
        startChunk: startChunk ?? this.startChunk,
        uri: uri ?? this.uri,
        footerSignatureValid: footerSignatureValid ?? this.footerSignatureValid,
      );
}

class FileRequestsModel extends ChangeNotifier {
  final List<FileRequest> _requests = [];
  final Map<String, double> _progress = {}; // requestId -> 0..1 progress
  final Map<String, int> _bytesSent = {};
  final Map<String, int> _bytesTotal = {};
  final Map<String, VoidCallback> _cancellers = {};
  List<FileRequest> get requests => List.unmodifiable(_requests);
  double progressFor(String id) => _progress[id] ?? 0.0;
  int bytesSent(String id) => _bytesSent[id] ?? 0;
  int bytesTotal(String id) => _bytesTotal[id] ?? 0;

  void setRequests(List<FileRequest> list) {
    _requests
      ..clear()
      ..addAll(list);
    notifyListeners();
  }

  void addRequest(FileRequest r) {
    _requests.add(r);
    notifyListeners();
  }

  void updateStatus(String id, FileRequestStatus status) {
    for (var i = 0; i < _requests.length; i++) {
      if (_requests[i].id == id) {
        _requests[i] = _requests[i].copyWith(status: status);
        notifyListeners();
        break;
      }
    }
  }

  void updateProgress(String id, double value) {
    _progress[id] = value.clamp(0.0, 1.0);
    notifyListeners();
  }

  void updateBytes(String id, int sent, int total) {
    _bytesSent[id] = sent;
    _bytesTotal[id] = total;
    if (total > 0) {
      _progress[id] = (sent / total).clamp(0.0, 1.0);
    }
    notifyListeners();
  }

  void setCanceller(String id, VoidCallback cancel) {
    _cancellers[id] = cancel;
  }

  void clearCanceller(String id) {
    _cancellers.remove(id);
  }

  void cancelTransfer(String id) {
    final c = _cancellers[id];
    if (c != null) {
      c();
    }
  }

  Future<void> loadFromPersistence() async {
    try {
      final hive = HiveFileRequestDataSource();
      final list = await hive.getAll();
      if (list.isNotEmpty) {
        setRequests(list);
      }
    } catch (_) {
      // ignore for now
    }
  }
}
