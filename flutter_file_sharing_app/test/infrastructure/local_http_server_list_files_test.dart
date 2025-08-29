import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/local_http_server.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

void main() {
  test('GET /folders/<id>/files lists files in shared folder', () async {
    final tempDir = await Directory.systemTemp.createTemp('list_test');
    final fileA = File('${tempDir.path}${Platform.pathSeparator}a.txt');
    final fileB = File('${tempDir.path}${Platform.pathSeparator}b.log');
    await fileA.writeAsString('A');
    await fileB.writeAsString('B');

    final server = LocalHttpServer(
      port: 7390,
      sharedFoldersProvider: () async => [
        {'id': 'f1', 'name': 'Temp', 'path': tempDir.path, 'isShared': true},
      ],
      listFilesHandler: (id) async {
        if (id != 'f1') return Response.notFound('folder not found');
        final dir = Directory(tempDir.path);
        final entries = await dir
            .list()
            .where((e) => e is File)
            .map((e) => e.path.split(Platform.pathSeparator).last)
            .toList();
        return Response.ok(
            jsonEncode({'folderId': 'f1', 'folder': 'Temp', 'files': entries}),
            headers: {'Content-Type': 'application/json'});
      },
      updateRequestStatus: (id, status) async => true,
      fileRequestsProvider: () async => [],
    );

    await server.start();
    final base = 'http://localhost:${server.boundPort}';

    final res = await http.get(Uri.parse('$base/folders/f1/files'));
    expect(res.statusCode, 200);
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final files = (decoded['files'] as List).cast<String>();
    expect(files.contains('a.txt'), isTrue);
    expect(files.contains('b.log'), isTrue);

    await server.stop();
    await tempDir.delete(recursive: true);
  });
}
