import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:path_provider/path_provider.dart';
import 'package:shelf_router/shelf_router.dart';
import 'peer_auth_manager.dart';
import 'certificate_generator.dart';
import 'package:path/path.dart' as p;
import 'package:pointycastle/digests/sha256.dart';

/// Simple local HTTP server to expose shared folder listing.
class LocalHttpServer {
  HttpServer? _server;
  final int port;
  final Future<List<Map<String, dynamic>>> Function() sharedFoldersProvider;
  final Future<List<Map<String, dynamic>>> Function()? fileRequestsProvider;
  final Future<bool> Function(String id, String status)? updateRequestStatus;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> input)?
      createRequest;
  final Future<Response> Function(Request request, String id)? downloadHandler;
  final Future<Response> Function(String folderId)? listFilesHandler;
  final Future<String?> Function(String id)? requestHashProvider;
  final String?
      authToken; // if set, protected routes require X-Auth-Token header
  final PeerAuthManager? peerAuthManager; // optional per-peer auth
  final void Function(Map<String, dynamic> log)?
      onLog; // structured log callback

  String? _certFingerprintSha256; // hex string
  String? get certFingerprintSha256 => _certFingerprintSha256;

  LocalHttpServer({
    required this.port,
    required this.sharedFoldersProvider,
    this.fileRequestsProvider,
    this.updateRequestStatus,
    this.createRequest,
    this.downloadHandler,
    this.listFilesHandler,
    this.requestHashProvider,
    this.authToken,
    this.peerAuthManager,
    this.onLog,
  });

  bool get isRunning => _server != null;
  int? get boundPort => _server?.port;

  // In-memory auth failure tracking
  final Map<String, _AuthFailRecord> _authFailLog = {};

  Future<void> start() async {
    if (isRunning) return;
    final router = Router()
      ..get('/health', _healthHandler)
      ..get('/folders', _foldersHandler)
      ..get('/requests', _requestsHandler)
      ..get('/requests/<id>/hash', _requestHashHandler)
      ..get('/fingerprint', _fingerprintHandler)
      ..patch('/requests/<id>', _updateRequestHandler)
      ..post('/requests', _createRequestHandler);
    if (peerAuthManager != null) {
      router.post('/pair', _pairHandler);
    }

    if (downloadHandler != null) {
      router.get('/download/<id>', _downloadRequestHandler);
    }
    if (listFilesHandler != null) {
      router.get('/folders/<id>/files', _listFilesHandler);
    }

    final handler = const Pipeline()
        .addMiddleware(_corsAndOptions())
        .addMiddleware(_structuredLogger(onLog))
        .addHandler(router);

    final ctx = await _loadOrCreateSecurityContext();
    Future<Response> fpWrapper(Request req) async {
      final res = await handler(req);
      if (_certFingerprintSha256 != null) {
        return res.change(headers: {
          ...res.headersAll.map((k, v) => MapEntry(k, v.join(','))),
          'x-cert-fp': _certFingerprintSha256!,
        });
      }
      return res;
    }

    if (ctx != null) {
      _server = await shelf_io.serve(fpWrapper, InternetAddress.anyIPv4, port,
          securityContext: ctx);
    } else {
      _server = await shelf_io.serve(fpWrapper, InternetAddress.anyIPv4, port);
    }
  }

  Future<Response> _healthHandler(Request request) async => Response.ok('OK');

  Future<Response> _fingerprintHandler(Request request) async {
    if (_certFingerprintSha256 == null) {
      return Response.internalServerError(body: 'fingerprint unavailable');
    }
    return Response.ok(jsonEncode({'sha256': _certFingerprintSha256}),
        headers: {
          'Content-Type': 'application/json',
          'Access-Control-Allow-Origin': '*',
        });
  }

  Future<Response> _foldersHandler(Request request) async {
    final list = await sharedFoldersProvider();
    return _jsonOk({'folders': list});
  }

  Future<Response> _requestsHandler(Request request) async {
    if (fileRequestsProvider == null) {
      return _jsonError(404, 'not_found', 'Requests not enabled');
    }
    // Apply auth (and rate limiting) just like create/update endpoints so brute force attempts get tracked.
    final auth = _checkAuth(request);
    if (auth != null) return auth;
    final list = await fileRequestsProvider!();
    return _jsonOk({'requests': list});
  }

  Future<Response> _requestHashHandler(Request request, String id) async {
    if (requestHashProvider == null) {
      return _jsonError(404, 'hash_not_enabled', 'Hash endpoint disabled');
    }
    try {
      final h = await requestHashProvider!(id);
      if (h == null) {
        return _jsonError(404, 'hash_pending', 'Hash not yet available');
      }
      return _jsonOk({'id': id, 'hash': h});
    } catch (e) {
      return _jsonError(500, 'internal_error', 'Failed to fetch hash');
    }
  }

  Future<Response> _updateRequestHandler(Request request, String id) async {
    if (updateRequestStatus == null) {
      return _jsonError(404, 'not_found', 'Update not enabled');
    }
    final auth = _checkAuth(request);
    if (auth != null) return auth;
    final body = await request.readAsString();
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final status = data['status'] as String?;
      if (status == null) {
        return _jsonError(400, 'missing_status', 'Status required');
      }
      final ok = await updateRequestStatus!(id, status);
      if (!ok) return _jsonError(400, 'invalid_status', 'Invalid status value');
      return _jsonOk({'id': id, 'status': status});
    } catch (e) {
      return _jsonError(400, 'bad_request', 'Malformed JSON');
    }
  }

  Future<Response> _createRequestHandler(Request request) async {
    if (createRequest == null) {
      return _jsonError(404, 'not_found', 'Create not enabled');
    }
    final auth = _checkAuth(request);
    if (auth != null) return auth;
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      // Basic path traversal guard: if filePath provided ensure it lies within folder path when folder info resolvable.
      try {
        final filePath = data['filePath'] as String?;
        final folderId = data['folderId'] as String?;
        if (filePath != null && folderId != null) {
          final folders = await sharedFoldersProvider();
          final folder = folders.firstWhere(
            (f) => f['id'] == folderId,
            orElse: () => <String, dynamic>{},
          );
          // Folder-level ACL enforcement (allow list takes precedence then deny list)
          final peerId = data['peerId']
              as String?; // assume peerId supplied in create body
          if (peerId != null && folder.isNotEmpty) {
            final allowed = folder['allowedPeerIds'] as List<dynamic>?;
            final denied = folder['deniedPeerIds'] as List<dynamic>?;
            if (allowed != null &&
                allowed.isNotEmpty &&
                !allowed.contains(peerId)) {
              return _jsonError(
                  403, 'acl_denied', 'Peer not allowed for folder');
            }
            if (denied != null && denied.contains(peerId)) {
              return _jsonError(403, 'acl_denied', 'Peer denied for folder');
            }
          }
          final folderPath = folder['path'] as String?;
          if (folderPath != null) {
            final normFolder = p.normalize(folderPath);
            final normCandidate = p.isAbsolute(filePath)
                ? p.normalize(filePath)
                : p.normalize(p.join(normFolder, filePath));
            final within = p.isWithin(normFolder, normCandidate) ||
                normCandidate == normFolder;
            if (!within) {
              throw Exception('err_path_outside_folder');
            }
          }
        }
      } catch (e) {
        if (e.toString().contains('err_path_outside_folder')) {
          throw Exception('err_path_outside_folder');
        }
      }
      final created = await createRequest!(data);
      return _jsonCreated(created);
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('preview_forbidden')) {
        return _jsonError(
            403, 'preview_forbidden', 'Preview not allowed for this folder');
      }
      if (msg.contains('err_path_outside_folder')) {
        return _jsonError(400, 'path_outside_folder',
            'Requested file path is outside shared folder');
      }
      if (msg.contains('err_folder_not_found')) {
        return _jsonError(404, 'folder_not_found', 'Folder not found');
      }
      if (msg.contains('err_folder_required')) {
        return _jsonError(400, 'folder_required', 'Folder ID required');
      }
      return _jsonError(400, 'bad_request', 'Invalid request');
    }
  }

  Future<Response> _downloadRequestHandler(Request request, String id) async {
    if (downloadHandler == null) {
      return _jsonError(404, 'not_found', 'Download not enabled');
    }
    final auth = _checkAuth(request);
    if (auth != null) return auth;
    // Folder-level ACL enforcement if fileRequestsProvider available
    if (fileRequestsProvider != null) {
      try {
        final reqs = await fileRequestsProvider!();
        final req = reqs.firstWhere((r) => r['id'] == id, orElse: () => {});
        if (req.isNotEmpty) {
          final folderId = req['folderId'] as String?;
          final peerId = req['peerId'] as String?;
          if (folderId != null && peerId != null) {
            final folders = await sharedFoldersProvider();
            final folder = folders.firstWhere((f) => f['id'] == folderId,
                orElse: () => <String, dynamic>{});
            if (folder.isNotEmpty) {
              final allowed = folder['allowedPeerIds'] as List<dynamic>?;
              final denied = folder['deniedPeerIds'] as List<dynamic>?;
              if (allowed != null &&
                  allowed.isNotEmpty &&
                  !allowed.contains(peerId)) {
                return _jsonError(
                    403, 'acl_denied', 'Peer not allowed for folder');
              }
              if (denied != null && denied.contains(peerId)) {
                return _jsonError(403, 'acl_denied', 'Peer denied for folder');
              }
            }
          }
        }
      } catch (_) {}
    }
    try {
      return await downloadHandler!(request, id);
    } catch (e) {
      return _jsonError(500, 'internal_error', 'Download failed');
    }
  }

  Future<Response> _listFilesHandler(Request request, String id) async {
    if (listFilesHandler == null) {
      return _jsonError(404, 'not_found', 'Listing not enabled');
    }
    try {
      return await listFilesHandler!(id);
    } catch (e) {
      return _jsonError(500, 'internal_error', 'Failed to list files');
    }
  }

  Response? _checkAuth(Request request) {
    // Basic brute force limiter (per peerId/token/IP) - in-memory only.
    // Tracks failed attempts and applies simple lockout after threshold within window.
    const window = Duration(seconds: 30);
    const maxFails = 5;
    const lockSeconds = 20;
    _authFailLog.removeWhere(
        (k, v) => DateTime.now().difference(v.lastAttempt) > window);
    final identity = request.headers['X-Peer-Id'] ??
        request.headers['X-Forwarded-For'] ??
        'unknown';
    final rec = _authFailLog[identity];
    if (rec != null &&
        rec.lockedUntil != null &&
        DateTime.now().isBefore(rec.lockedUntil!)) {
      return _jsonError(
          429, 'auth_rate_limited', 'Too many failed auth attempts');
    }
    // Require either global token OR valid per-peer token if a PeerAuthManager is present.
    final globalProvided =
        authToken != null && request.headers['X-Auth-Token'] == authToken;
    bool peerOk = false;
    if (peerAuthManager != null) {
      final peerId = request.headers['X-Peer-Id'];
      final peerToken = request.headers['X-Peer-Token'];
      if (peerId != null && peerToken != null) {
        peerOk = peerAuthManager!.validate(peerId, peerToken);
      }
    }
    if (authToken == null && peerAuthManager == null)
      return null; // auth disabled
    if (globalProvided || peerOk) return null;
    // record failure
    final now = DateTime.now();
    final entry =
        _authFailLog.putIfAbsent(identity, () => _AuthFailRecord(0, now));
    entry.count += 1;
    entry.lastAttempt = now;
    if (entry.count >= maxFails) {
      entry.lockedUntil = now.add(Duration(seconds: lockSeconds));
      entry.count = 0; // reset after lock
      return _jsonError(
          429, 'auth_rate_limited', 'Too many failed auth attempts');
    }
    return _jsonError(
        401, 'unauthorized', 'Valid auth token or peer token required');
  }

  Future<Response> _pairHandler(Request request) async {
    if (peerAuthManager == null) {
      return _jsonError(404, 'not_found', 'Pairing disabled');
    }
    try {
      final body = await request.readAsString();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final peerId = data['peerId'] as String?;
      if (peerId == null || peerId.isEmpty) {
        return _jsonError(400, 'peer_id_required', 'peerId required');
      }
      final token = peerAuthManager!.issueToken(peerId);
      return _jsonCreated({'peerId': peerId, 'token': token});
    } catch (_) {
      return _jsonError(400, 'bad_request', 'Invalid pairing request');
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<SecurityContext?> _loadOrCreateSecurityContext() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final certFile = File(p.join(dir.path, 'server_cert.pem'));
      final keyFile = File(p.join(dir.path, 'server_key.pem'));
      if (!await certFile.exists() || !await keyFile.exists()) {
        final gen = CertificateGenerator();
        final self = await gen.generate();
        await certFile.writeAsString(self.certificatePem, flush: true);
        await keyFile.writeAsString(self.privateKeyPem, flush: true);
      }
      // Compute SHA-256 fingerprint of DER bytes
      try {
        final pem = await certFile.readAsString();
        final der = _pemToDer(pem);
        final digest = SHA256Digest().process(der);
        _certFingerprintSha256 = _toHex(digest);
      } catch (_) {}
      final context = SecurityContext();
      context.useCertificateChain(certFile.path);
      context.usePrivateKey(keyFile.path);
      return context;
    } catch (e) {
      return null; // Fallback to HTTP if HTTPS context fails.
    }
  }

  Uint8List _pemToDer(String pem) {
    final lines = pem.split(RegExp(r'\r?\n'));
    final b64 = lines.where((l) => !l.startsWith('-----')).join('');
    return Uint8List.fromList(base64Decode(b64));
  }

  String _toHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

class _AuthFailRecord {
  int count;
  DateTime lastAttempt;
  DateTime? lockedUntil;
  _AuthFailRecord(this.count, this.lastAttempt);
}

// Structured logging middleware
Middleware _structuredLogger(void Function(Map<String, dynamic>)? onLog) {
  return (Handler inner) {
    return (Request req) async {
      final start = DateTime.now();
      Response res;
      try {
        res = await inner(req);
      } catch (e) {
        res = Response.internalServerError(body: 'internal');
        onLog?.call({
          'ts': start.toIso8601String(),
          'method': req.method,
          'path': req.requestedUri.path,
          'status': 500,
          'error': e.toString(),
        });
        rethrow;
      }
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      onLog?.call({
        'ts': start.toIso8601String(),
        'method': req.method,
        'path': req.requestedUri.path,
        'status': res.statusCode,
        'ms': elapsed,
      });
      return res;
    };
  };
}

Response _jsonOk(Map<String, dynamic> data) => Response.ok(
      jsonEncode({'ver': 1, ...data}),
      headers: const {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*'
      },
    );
Response _jsonCreated(Map<String, dynamic> data) => Response(
      201,
      body: jsonEncode({'ver': 1, ...data}),
      headers: const {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*'
      },
    );
Response _jsonError(int status, String code, String message,
    {Map<String, dynamic>? extra}) {
  final body = {
    'ver': 1,
    'error': code,
    'message': message,
    if (extra != null) ...extra
  };
  return Response(status, body: jsonEncode(body), headers: const {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*'
  });
}

// CORS + OPTIONS preflight middleware
Middleware _corsAndOptions() {
  const allowHeaders =
      'Content-Type, X-Auth-Token, X-Peer-Id, X-Peer-Token, Range';
  const allowMethods = 'GET, POST, PATCH, OPTIONS';
  const base = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': allowHeaders,
    'Access-Control-Allow-Methods': allowMethods,
  };
  return (inner) {
    return (Request req) async {
      if (req.method == 'OPTIONS') {
        return Response(204, headers: base);
      }
      final res = await inner(req);
      return res.change(headers: {
        ...res.headersAll.map((k, v) => MapEntry(k, v.join(','))),
        ...base,
      });
    };
  };
}
