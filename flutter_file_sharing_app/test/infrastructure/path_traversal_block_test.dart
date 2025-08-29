import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/local_http_server.dart';
import 'package:http/http.dart' as http;

void main() {
  test('Server blocks path traversal outside shared folder', () async {
    final tempDir = await Directory.systemTemp.createTemp('trav');
    final shared = Directory('${tempDir.path}/shared');
    await shared.create();
    final outside = File('${tempDir.path}/secret.txt');
    await outside.writeAsString('top secret');
    final requests = <Map<String, dynamic>>[];
    final server = LocalHttpServer(
      port: 7420,
      sharedFoldersProvider: () async => [
        {
          'id': 'f1',
          'name': 'S',
          'path': shared.path,
          'isShared': true,
          'allowPreview': false
        },
      ],
      fileRequestsProvider: () async => requests,
      createRequest: (data) async {
        requests.add(data);
        return data;
      },
      updateRequestStatus: (id, status) async => true,
    );
    await server.start();
    final base = 'http://localhost:${server.boundPort}';
    // Use constructed absolute path outside shared root
    final secretAbs = outside.path;
    final res = await http.post(Uri.parse('$base/requests'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(
            {'folderId': 'f1', 'peerId': 'p', 'filePath': secretAbs}));
    expect(res.statusCode, equals(400));
    expect(res.body.contains('path_outside_folder'), true, reason: res.body);
    await server.stop();
    await tempDir.delete(recursive: true);
  });
}
