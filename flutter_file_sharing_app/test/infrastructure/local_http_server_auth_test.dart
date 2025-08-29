import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/local_http_server.dart';
import 'package:http/http.dart' as http;

void main() {
  test('Protected endpoints require auth token', () async {
    final stored = <Map<String, dynamic>>[];
    final token = 'secret-token';
    final server = LocalHttpServer(
      port: 7400,
      sharedFoldersProvider: () async => [
        {'id': 'f1', 'name': 'F', 'path': '/f1', 'isShared': true},
      ],
      fileRequestsProvider: () async => stored,
      createRequest: (data) async {
        final map = {
          'id': 'r1',
          'folderId': data['folderId'],
          'peerId': data['peerId'] ?? 'p',
          'filePath': data['filePath'],
          'status': 'pending',
          'createdAt': DateTime.now().toIso8601String(),
        };
        stored.add(map);
        return map;
      },
      updateRequestStatus: (id, status) async => true,
      authToken: token,
    );
    await server.start();
    final base = 'http://localhost:${server.boundPort}';

    // Missing token -> 401
    final resNoAuth = await http.post(Uri.parse('$base/requests'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'folderId': 'f1'}));
    expect(resNoAuth.statusCode, 401);

    // With token -> 201
    final resAuth = await http.post(Uri.parse('$base/requests'),
        headers: {'Content-Type': 'application/json', 'X-Auth-Token': token},
        body: jsonEncode({'folderId': 'f1'}));
    expect(resAuth.statusCode, 201);

    // PATCH without token
    final patchNoAuth = await http.patch(Uri.parse('$base/requests/r1'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'status': 'approved'}));
    expect(patchNoAuth.statusCode, 401);

    // PATCH with token
    final patchAuth = await http.patch(Uri.parse('$base/requests/r1'),
        headers: {'Content-Type': 'application/json', 'X-Auth-Token': token},
        body: jsonEncode({'status': 'approved'}));
    expect(patchAuth.statusCode, 200);

    await server.stop();
  });
}
