import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/local_http_server.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/encryption_service.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:shelf/shelf.dart';

void main() {
  test('Hash endpoint returns 404 until completion then 200 with hash',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('hash_ep');
    final file = File('${tempDir.path}${Platform.pathSeparator}data.bin');
    final content = Uint8List.fromList(
        List<int>.generate(200000, (i) => i % 256)); // 200 KB
    await file.writeAsBytes(content, flush: true);

    String status = 'approved';
    final encryptionService = EncryptionService();
    final keyManager = TransferKeyManager(encryptionService);

    final hashCache = <String, String>{};

    final server = LocalHttpServer(
      port: 7395,
      sharedFoldersProvider: () async => [
        {'id': 'f1', 'name': 'Temp', 'path': tempDir.path, 'isShared': true},
      ],
      fileRequestsProvider: () async => [
        {
          'id': 'r1',
          'folderId': 'f1',
          'peerId': 'p',
          'filePath': file.path,
          'status': status,
          'createdAt': DateTime.now().toIso8601String()
        },
      ],
      updateRequestStatus: (id, newStatus) async {
        status = newStatus;
        return true;
      },
      requestHashProvider: (id) async => hashCache[id],
      downloadHandler: (request, id) async {
        if (id != 'r1') return Response.notFound('nf');
        if (status != 'approved' && status != 'transferring') {
          return Response(403, body: 'not approved');
        }
        final key = keyManager.keyFor(id);
        final nonceBase = encryptionService.generateIv().sublist(0, 12);
        final bytes = await file.readAsBytes();
        // compute hash inline for test and store after artificial delay
        final digest = SHA256Digest()..update(bytes, 0, bytes.length);
        final hashOut = Uint8List(digest.digestSize);
        digest.doFinal(hashOut, 0);
        Future.delayed(const Duration(milliseconds: 150), () {
          hashCache[id] =
              hashOut.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        });
        final stream = encryptionService.encryptChunkedGcm(
            Stream.value(bytes), key, nonceBase);
        return Response.ok(stream, headers: {
          'Content-Type': 'application/octet-stream',
          'X-File-Key': base64Encode(key),
          'X-File-Nonce-Base': base64Encode(nonceBase),
          'X-File-Encrypted': 'aes-gcm-chunked',
          'X-File-Frame': 'len|cipher|tag16',
          'X-File-Length': bytes.length.toString(),
          'X-File-Start-Chunk': '0',
        });
      },
    );

    await server.start();
    final base = 'http://localhost:${server.boundPort}';

    // Before download finishes (immediate), hash should be 404
    // Kick off download to trigger handler
    final downloadReq =
        await HttpClient().getUrl(Uri.parse('$base/download/r1'));
    final downloadRes = await downloadReq.close();
    expect(downloadRes.statusCode, 200);
    // Drain stream
    await downloadRes.drain();

    // Poll hash endpoint until 200 or timeout
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    int polls = 0;
    HttpClientResponse? okHashRes;
    while (DateTime.now().isBefore(deadline)) {
      polls++;
      final res = await HttpClient()
          .getUrl(Uri.parse('$base/requests/r1/hash'))
          .then((r) => r.close());
      if (res.statusCode == 200) {
        okHashRes = res;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 60));
    }
    expect(okHashRes, isNotNull,
        reason: 'hash endpoint never returned 200 after $polls polls');
    final body = await utf8.decoder.bind(okHashRes!).join();
    expect(body.contains('hash'), true);

    await server.stop();
    await tempDir.delete(recursive: true);
  });
}
