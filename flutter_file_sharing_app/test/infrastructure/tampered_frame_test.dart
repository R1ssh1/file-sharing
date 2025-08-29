import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/encryption_service.dart';

void main() {
  test('Decrypting tampered frame throws', () async {
    final svc = EncryptionService();
    final key = svc.generateKey();
    final baseNonce = svc.generateIv().sublist(0, 12);
    final plain = Uint8List.fromList(List<int>.generate(1024, (i) => i % 256));
    final encStream = svc.encryptChunkedGcm(Stream.value(plain), key, baseNonce,
        chunkSize: 512);
    final frame = await encStream.first;
    // Corrupt one byte in tag (last 16 bytes of frame)
    final corrupted = Uint8List.fromList(frame);
    corrupted[corrupted.length - 1] ^= 0xFF;
    final frames = Stream<List<int>>.fromIterable([corrupted]);
    final dec = svc.decryptChunkedGcm(frames, key, baseNonce);
    bool threw = false;
    try {
      await dec.drain();
    } catch (_) {
      threw = true;
    }
    expect(threw, true);
  });
}
