import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/local_http_server.dart';
import 'package:http/http.dart' as http;

void main() {
  test('GET /requests returns list and PATCH updates status', () async {
    final requests = [
      {
        'id': 'r1',
        'folderId': 'f1',
        'peerId': 'p1',
        'filePath': '/f1/file.txt',
        'status': 'pending',
        'createdAt': DateTime.now().toIso8601String(),
      }
    ];
    String currentStatus = 'pending';
    final server = LocalHttpServer(
      port: 7360,
      sharedFoldersProvider: () async => [
        {'id': 'f1', 'name': 'Folder', 'path': '/f1', 'isShared': true},
      ],
      fileRequestsProvider: () async =>
          requests.map((r) => {...r, 'status': currentStatus}).toList(),
      updateRequestStatus: (id, status) async {
        if (id != 'r1') return false;
        currentStatus = status;
        return true;
      },
    );

    await server.start();
    final base = 'http://localhost:${server.boundPort}';

    // GET list
    final getRes = await http.get(Uri.parse('$base/requests'));
    expect(getRes.statusCode, 200);
    final listDecoded = jsonDecode(getRes.body) as Map<String, dynamic>;
    expect(listDecoded['requests'], isA<List>());
    expect((listDecoded['requests'] as List).first['status'], 'pending');

    // PATCH update
    final patchRes = await http.patch(Uri.parse('$base/requests/r1'),
        body: jsonEncode({'status': 'approved'}),
        headers: {'Content-Type': 'application/json'});
    expect(patchRes.statusCode, 200);
    final patchDecoded = jsonDecode(patchRes.body) as Map<String, dynamic>;
    expect(patchDecoded['status'], 'approved');

    // GET again reflects change
    final getRes2 = await http.get(Uri.parse('$base/requests'));
    final listDecoded2 = jsonDecode(getRes2.body) as Map<String, dynamic>;
    expect((listDecoded2['requests'] as List).first['status'], 'approved');

    await server.stop();
  });
}
