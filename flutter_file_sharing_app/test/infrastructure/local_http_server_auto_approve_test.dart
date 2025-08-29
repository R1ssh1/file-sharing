import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/local_http_server.dart';
import 'package:http/http.dart' as http;

void main() {
  test('POST /requests auto-approves when folder.autoApprove=true', () async {
    final stored = <Map<String, dynamic>>[];
    final server = LocalHttpServer(
      port: 7410,
      sharedFoldersProvider: () async => [
        {
          'id': 'f1',
          'name': 'Folder',
          'path': '/f1',
          'isShared': true,
          'autoApprove': true,
          'allowPreview': true
        },
      ],
      fileRequestsProvider: () async => stored,
      createRequest: (data) async {
        final map = {
          'id': 'r1',
          'folderId': data['folderId'],
          'peerId': data['peerId'] ?? 'p',
          'filePath': data['filePath'],
          'status': 'approved',
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
        body: jsonEncode({'folderId': 'f1'}));
    expect(res.statusCode, 201);
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    expect(decoded['status'], 'approved');

    await server.stop();
  });
}
