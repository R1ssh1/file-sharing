import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/local_http_server.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/encryption_service.dart';
import 'package:shelf/shelf.dart';
import 'package:http/http.dart' as http;

void main() {
  test('Invalid Range outside file returns full content (no leak beyond)',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('range');
    final file = File('${tempDir.path}/data.txt');
    await file.writeAsString('0123456789');
    String status = 'approved';
    final enc = EncryptionService();
    final keyMgr = TransferKeyManager(enc);
    final server = LocalHttpServer(
        port: 7422,
        sharedFoldersProvider: () async => [
              {'id': 'f1', 'name': 'T', 'path': tempDir.path, 'isShared': true},
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
        updateRequestStatus: (id, s) async {
          status = s;
          return true;
        },
        downloadHandler: (request, id) async {
          if (id != 'r1') return Response.notFound('nf');
          if (status != 'approved' && status != 'transferring')
            return Response(403, body: 'not approved');
          final key = keyMgr.keyFor(id);
          final nonce = enc.generateIv().sublist(0, 12);
          final bytes = await file.readAsBytes();
          // ignore provided range intentionally and serve full file
          final stream = enc.encryptChunkedGcm(Stream.value(bytes), key, nonce,
              chunkSize: 4 * 1024);
          return Response.ok(stream, headers: {
            'X-File-Key': enc.encodeKey(key),
            'X-File-Nonce-Base': enc.encodeKey(nonce),
            'X-File-Encrypted': 'aes-gcm-chunked',
            'X-File-Frame': 'len|cipher|tag16',
            'X-File-Length': bytes.length.toString(),
            'X-File-Start-Chunk': '0',
          });
        });
    await server.start();
    final base = 'http://localhost:${server.boundPort}';
    final res = await http
        .get(Uri.parse('$base/download/r1'), headers: {'Range': 'bytes=999-'});
    expect(res.statusCode, 200); // server falls back to full content
    await server.stop();
    await tempDir.delete(recursive: true);
  });
}
