import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/trust_manager.dart';

void main() {
  test('TrustManager pins first fingerprint and rejects mismatch', () {
    final tm = TrustManager();
    expect(tm.record('peer1', 'abc'), isTrue);
    expect(tm.fingerprintFor('peer1'), 'abc');
    // Same again
    expect(tm.record('peer1', 'abc'), isTrue);
    // Different fingerprint => reject
    expect(tm.record('peer1', 'def'), isFalse);
  });
}
