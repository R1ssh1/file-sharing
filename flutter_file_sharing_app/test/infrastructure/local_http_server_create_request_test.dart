import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/local_http_server.dart';
import 'package:http/http.dart' as http;

void main() {
  test('POST /requests creates request', () async {
    final stored = <Map<String, dynamic>>[];
    final server = LocalHttpServer(
      port: 7370,
      sharedFoldersProvider: () async => [
        {'id': 'f1', 'name': 'Folder', 'path': '/f1', 'isShared': true},
      ],
      fileRequestsProvider: () async => stored,
      updateRequestStatus: (id, status) async => true,
      createRequest: (data) async {
        final map = {
          'id': 'new1',
          'folderId': data['folderId'],
          'peerId': data['peerId'] ?? 'ext-peer',
          'filePath': data['filePath'],
          'status': 'pending',
          'createdAt': DateTime.now().toIso8601String(),
        };
        stored.add(map);
        return map;
      },
    );
    await server.start();
    final base = 'http://localhost:${server.boundPort}';

    final res = await http.post(Uri.parse('$base/requests'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'folderId': 'f1', 'filePath': '/f1/file.txt'}));
    expect(res.statusCode, 201);
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    expect(decoded['folderId'], 'f1');

    final listRes = await http.get(Uri.parse('$base/requests'));
    final listDecoded = jsonDecode(listRes.body) as Map<String, dynamic>;
    expect((listDecoded['requests'] as List).length, 1);

    await server.stop();
  });
}
