import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/local_http_server.dart';
import 'package:http/http.dart' as http;
import 'package:shelf/shelf.dart';

void main() {
  test('GET /download/<id> serves file only when approved', () async {
    // Prepare a temp directory and file
    final tempDir = await Directory.systemTemp.createTemp('share_test');
    final file = File('${tempDir.path}${Platform.pathSeparator}hello.txt');
    await file.writeAsString('hello world');

    final requests = <Map<String, dynamic>>[
      {
        'id': 'r1',
        'folderId': 'f1',
        'peerId': 'p1',
        'filePath': file.path,
        'status': 'pending',
        'createdAt': DateTime.now().toIso8601String(),
      }
    ];

    String status = 'pending';

    final server = LocalHttpServer(
      port: 7380,
      sharedFoldersProvider: () async => [
        {'id': 'f1', 'name': 'Temp', 'path': tempDir.path, 'isShared': true},
      ],
      fileRequestsProvider: () async =>
          requests.map((r) => {...r, 'status': status}).toList(),
      updateRequestStatus: (id, newStatus) async {
        if (id != 'r1') return false;
        status = newStatus;
        return true;
      },
      downloadHandler: (request, id) async {
        final req = requests.firstWhere((r) => r['id'] == id, orElse: () => {});
        if (req.isEmpty) {
          return Response.notFound('request not found');
        }
        final current = {...req, 'status': status};
        if (current['status'] != 'approved') {
          return Response(403, body: 'not approved');
        }
        final filePath = current['filePath'] as String?;
        if (filePath == null) return Response.notFound('file missing');
        final f = File(filePath);
        if (!await f.exists()) return Response.notFound('file missing');
        final bytes = await f.readAsBytes();
        return Response.ok(bytes, headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Length': bytes.length.toString(),
          'Content-Disposition': 'attachment; filename="hello.txt"'
        });
      },
    );

    await server.start();
    final base = 'http://localhost:${server.boundPort}';

    // Not approved yet
    final resPending = await http.get(Uri.parse('$base/download/r1'));
    expect(resPending.statusCode, 403);

    // Approve via PATCH
    final patchRes = await http.patch(Uri.parse('$base/requests/r1'),
        body: jsonEncode({'status': 'approved'}),
        headers: {'Content-Type': 'application/json'});
    expect(patchRes.statusCode, 200);

    // Now download
    final resApproved = await http.get(Uri.parse('$base/download/r1'));
    expect(resApproved.statusCode, 200);
    expect(resApproved.bodyBytes, isNotEmpty);
    expect(resApproved.bodyBytes.length, equals(11)); // 'hello world'

    await server.stop();
    await tempDir.delete(recursive: true);
  });
}
