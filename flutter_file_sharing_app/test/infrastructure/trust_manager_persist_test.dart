import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/infrastructure/trust_manager.dart';
import 'package:hive/hive.dart';

void main() {
  test('TrustManager persists fingerprints (Hive local tmp)', () async {
    final dir = await Directory.systemTemp.createTemp('trust_hive');
    Hive.init(dir.path);
    final tm1 = TrustManager();
    await tm1.init();
    expect(tm1.record('peerX', 'ff00'), isTrue);
    final tm2 = TrustManager();
    await tm2.init();
    expect(tm2.fingerprintFor('peerX'), 'ff00');
    await Hive.close();
    await dir.delete(recursive: true);
  });
}
