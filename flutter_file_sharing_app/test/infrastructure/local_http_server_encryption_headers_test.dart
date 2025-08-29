import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/local_http_server.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/encryption_service.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';
import 'package:shelf/shelf.dart';

void main() {
  test('Download provides AES-GCM headers and ciphertext decrypts correctly',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('enc_test');
    final file = File('${tempDir.path}${Platform.pathSeparator}greet.txt');
    const original = 'sample greeting text';
    await file.writeAsString(original);

    // Request state
    String status = 'approved';

    final encryptionService = EncryptionService();
    final keyManager = TransferKeyManager(encryptionService);

    final server = LocalHttpServer(
      port: 7391,
      sharedFoldersProvider: () async => [
        {'id': 'f1', 'name': 'Temp', 'path': tempDir.path, 'isShared': true},
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
        if (id != 'r1') return false;
        status = newStatus;
        return true;
      },
      downloadHandler: (request, id) async {
        if (id != 'r1') return Response.notFound('not found');
        if (status != 'approved' && status != 'transferring') {
          return Response(403, body: 'not approved');
        }
        final key = keyManager.keyFor(id);
        final iv = encryptionService.generateIv();
        final bytes = await file.readAsBytes();
        final gcmRes = encryptionService.encryptBytesGcm(bytes, key, iv);
        return Response.ok(gcmRes.cipherText, headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Length': gcmRes.cipherText.length.toString(),
          'X-File-Key': base64Encode(key),
          'X-File-IV': base64Encode(iv),
          'X-File-Encrypted': 'aes-gcm',
          'X-File-Tag': base64Encode(gcmRes.tag),
        });
      },
    );

    await server.start();
    final base = 'http://localhost:${server.boundPort}';
    final res = await http.get(Uri.parse('$base/download/r1'));
    expect(res.statusCode, 200);
    expect(res.headers['x-file-encrypted'], 'aes-gcm');
    final keyB64 = res.headers['x-file-key'];
    final ivB64 = res.headers['x-file-iv'];
    final tagB64 = res.headers['x-file-tag'];
    expect(keyB64, isNotNull);
    expect(ivB64, isNotNull);
    expect(tagB64, isNotNull);

    final key = base64Decode(keyB64!);
    final iv = base64Decode(ivB64!);
    final tag = base64Decode(tagB64!);
    final cipherText = res.bodyBytes; // detached tag

    // Decrypt: supply ciphertext+tag to GCM in one shot
    final combined = Uint8List(cipherText.length + tag.length);
    combined.setRange(0, cipherText.length, cipherText);
    combined.setRange(cipherText.length, combined.length, tag);
    final gcm = GCMBlockCipher(AESEngine());
    gcm.init(false, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
    final out = Uint8List(gcm.getOutputSize(combined.length));
    var off = gcm.processBytes(combined, 0, combined.length, out, 0);
    off += gcm.doFinal(out, off);
    final plain = utf8.decode(out.sublist(0, off));
    expect(plain, original);

    await server.stop();
    await tempDir.delete(recursive: true);
  });
}
