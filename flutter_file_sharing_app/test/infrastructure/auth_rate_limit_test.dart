import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/local_http_server.dart';
import 'package:http/http.dart' as http;

void main() {
  test('auth brute force triggers rate limiting', () async {
    String? token = 'correct';
    final server = LocalHttpServer(
      port: 7425,
      sharedFoldersProvider: () async => [],
      fileRequestsProvider: () async => [],
      authToken: token,
    );
    await server.start();
    final base = 'http://localhost:${server.boundPort}';
    // Perform 6 failed attempts with wrong token
    for (int i = 0; i < 5; i++) {
      final r = await http
          .get(Uri.parse('$base/requests'), headers: {'X-Auth-Token': 'wrong'});
      expect(r.statusCode, anyOf(401, 429));
      if (r.statusCode == 429) break; // already limited earlier
    }
    final sixth = await http
        .get(Uri.parse('$base/requests'), headers: {'X-Auth-Token': 'wrong'});
    // Expect rate limit (429) by or before 6th
    expect(sixth.statusCode, 429);
    final body = jsonDecode(sixth.body) as Map<String, dynamic>;
    expect(body['error'], anyOf('auth_rate_limited', 'unauthorized'));
    await server.stop();
  });
}
