import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/local_http_server.dart';
import 'package:http/http.dart' as http;

void main() {
  test('LocalHttpServer returns folders JSON', () async {
    final server = LocalHttpServer(
      port: 7350,
      sharedFoldersProvider: () async => [
        {'id': '1', 'name': 'Docs', 'path': '/docs', 'isShared': true},
      ],
    );
    await server.start();
    final uri = Uri.parse('http://localhost:${server.boundPort}/folders');
    final res = await http.get(uri);
    expect(res.statusCode, 200);
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    expect(decoded['folders'], isA<List>());
    await server.stop();
  });
}
