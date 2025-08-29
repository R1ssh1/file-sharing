import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/local_http_server.dart';
import 'package:http/http.dart' as http;

void main() {
  test('POST /requests without filePath blocked when allowPreview=false',
      () async {
    final stored = <Map<String, dynamic>>[];
    final server = LocalHttpServer(
      port: 7420,
      sharedFoldersProvider: () async => [
        {
          'id': 'f1',
          'name': 'Folder',
          'path': '/f1',
          'isShared': true,
          'autoApprove': false,
          'allowPreview': false
        },
      ],
      fileRequestsProvider: () async => stored,
      createRequest: (data) async {
        throw Exception('preview_forbidden');
      },
    );

    await server.start();
    final base = 'http://localhost:${server.boundPort}';

    final res = await http.post(Uri.parse('$base/requests'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'folderId': 'f1'}));
    expect(res.statusCode, 403);

    await server.stop();
  });
}
