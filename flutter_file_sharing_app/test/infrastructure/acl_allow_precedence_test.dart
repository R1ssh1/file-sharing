import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/local_http_server.dart';
import 'package:shelf/shelf.dart';
import 'package:http/http.dart' as http;

void main() {
  test('Allow list permits peer and deny list blocks peer appropriately',
      () async {
    final tempDir = await Directory.systemTemp.createTemp('acl_allow');
    final sample = File('${tempDir.path}${Platform.pathSeparator}f.txt');
    await sample.writeAsString('hello');
    String status = 'approved';
    final server = LocalHttpServer(
      port: 7441,
      sharedFoldersProvider: () async => [
        {
          'id': 'f1',
          'name': 'Temp',
          'path': tempDir.path,
          'isShared': true,
          'allowedPeerIds': ['peer-ok'],
          'deniedPeerIds': ['peer-bad']
        },
      ],
      fileRequestsProvider: () async => [
        {
          'id': 'r1',
          'folderId': 'f1',
          'peerId': 'peer-ok',
          'filePath': sample.path,
          'status': status,
          'createdAt': DateTime.now().toIso8601String(),
        },
        {
          'id': 'r2',
          'folderId': 'f1',
          'peerId': 'peer-bad',
          'filePath': sample.path,
          'status': status,
          'createdAt': DateTime.now().toIso8601String(),
        }
      ],
      updateRequestStatus: (id, newStatus) async {
        status = newStatus;
        return true;
      },
      downloadHandler: (request, id) async => Response.ok('ok'),
    );
    await server.start();
    final base = 'http://localhost:${server.boundPort}';
    final okRes = await http.get(Uri.parse('$base/download/r1'));
    expect(okRes.statusCode, 200);
    final deniedRes = await http.get(Uri.parse('$base/download/r2'));
    expect(deniedRes.statusCode, 403);
    await server.stop();
    await tempDir.delete(recursive: true);
  });
}
