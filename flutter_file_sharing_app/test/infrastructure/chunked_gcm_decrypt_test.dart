import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/encryption_service.dart';

void main() {
  test('encryptChunkedGcm + decryptChunkedGcm round trip', () async {
    final svc = EncryptionService();
    final key = svc.generateKey();
    final baseNonce = svc.generateIv().sublist(0, 12); // ensure 12 bytes
    final plain =
        List<int>.generate(200000, (i) => i % 256); // > 3 chunks (64k)
    final stream = Stream<List<int>>.fromIterable([
      plain.sublist(0, 50000),
      plain.sublist(50000, 120000),
      plain.sublist(120000),
    ]);
    final encrypted =
        svc.encryptChunkedGcm(stream, key, Uint8List.fromList(baseNonce));
    final collectedFrames = await encrypted.toList();
    // Flatten frames to simulate transport fragmentation then feed in arbitrary splits
    final concatenated = collectedFrames.expand((f) => f).toList();
    // Split into irregular chunks
    final splits = <List<int>>[];
    int idx = 0;
    while (idx < concatenated.length) {
      final remain = concatenated.length - idx;
      final take = remain < 7000 ? remain : 3000 + (idx % 4000);
      splits.add(concatenated.sublist(idx, idx + take));
      idx += take;
    }
    final decryptedStream = svc.decryptChunkedGcm(
        Stream.fromIterable(splits), key, Uint8List.fromList(baseNonce));
    final recovered =
        (await decryptedStream.fold<BytesBuilder>(BytesBuilder(), (b, chunk) {
      b.add(chunk);
      return b;
    }))
            .takeBytes();
    expect(recovered.length, plain.length);
    for (var i = 0; i < plain.length; i++) {
      if (recovered[i] != plain[i]) {
        fail('Byte mismatch at $i');
      }
    }
  });
}
