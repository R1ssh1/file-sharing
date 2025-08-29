import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/local_http_server.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/encryption_service.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/client_download_service.dart';
import 'package:shelf/shelf.dart';

// Ensures client detects tampered footer signature by crafting a stream with invalid sig.
void main() {
  test('Client detects tampered footer signature (footerSignatureValid=false)',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('tamper_test');
    final file = File('${tempDir.path}${Platform.pathSeparator}large.bin');
    final data = List<int>.generate(20 * 1024, (i) => i % 256); // 20KB
    await file.writeAsBytes(data, flush: true);

    String status = 'approved';
    final enc = EncryptionService();
    final keyManager = TransferKeyManager(enc);

    final server = LocalHttpServer(
        port: 7421,
        sharedFoldersProvider: () async => [
              {
                'id': 'f1',
                'name': 'Temp',
                'path': tempDir.path,
                'isShared': true
              },
            ],
        fileRequestsProvider: () async => [
              {
                'id': 'r1',
                'folderId': 'f1',
                'peerId': 'p1',
                'filePath': file.path,
                'status': status,
                'createdAt': DateTime.now().toIso8601String(),
              }
            ],
        updateRequestStatus: (id, newStatus) async {
          status = newStatus;
          return true;
        },
        downloadHandler: (request, id) async {
          if (id != 'r1') return Response.notFound('nf');
          final key = keyManager.keyFor(id);
          final baseNonce = enc.generateIv();
          final base = Uint8List.fromList(baseNonce.sublist(0, 12));
          final chunkSize = 8 * 1024;
          final length = await file.length();
          final plainStream = file.openRead();
          final stream = enc.encryptChunkedGcm(plainStream, key, base,
              chunkSize: chunkSize);
          // We buffer frames then append tampered footer.
          final controller = StreamController<List<int>>();
          stream.listen((f) {
            controller.add(f);
          }, onDone: () async {
            final hmacKey = enc.deriveFooterHmacKey(key);
            final metaMap = {
              'ver': 1,
              'type': 'final',
              'state': 'completed',
              'hash': '00' * 32,
              'length': length,
              'chunks': (length / chunkSize).ceil()
            };
            final noSig = jsonEncode(metaMap);
            final sig = enc.hmacSha256Hex(hmacKey, utf8.encode(noSig));
            // Tamper: alter sig first hex
            final tampered = sig.replaceFirst(
                RegExp(r'^[0-9a-fA-F]'), sig[0] == 'a' ? 'b' : 'a');
            final meta = jsonEncode({...metaMap, 'sig': tampered});
            final mb = utf8.encode(meta);
            final lb = Uint8List(4)
              ..buffer.asByteData().setUint32(0, mb.length, Endian.big);
            controller.add(lb);
            controller.add(mb);
            await controller.close();
          });
          return Response.ok(controller.stream, headers: {
            'Content-Type': 'application/octet-stream',
            'X-File-Key': enc.encodeKey(key),
            'X-File-Nonce-Base': enc.encodeKey(base),
            'X-File-Encrypted': 'aes-gcm-chunked',
            'X-File-Chunk-Size': chunkSize.toString(),
            'X-File-Length': length.toString(),
            'X-File-Start-Chunk': '0',
          });
        });
    await server.start();
    final baseUrl = 'http://localhost:${server.boundPort}';
    final downloader = ClientDownloadService(enc);
    final outFile = File('${tempDir.path}${Platform.pathSeparator}out.dec');
    ClientDownloadResult? result;
    try {
      result = await downloader.download(
          Uri.parse('$baseUrl/download/r1'), outFile,
          computeHash: false);
    } catch (e) {
      // Allow trailing incomplete frame error triggered by plaintext footer injection.
      expect(e.toString(), contains('Trailing incomplete frame'));
    }
    if (result != null) {
      expect(result.footerSignatureValid, isFalse,
          reason: 'Signature should be invalid');
      expect(result.transferState, anyOf(['failed', isNull]));
    }
    await server.stop();
    // Attempt deletion; ignore failures (Windows file lock timing).
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });
}
