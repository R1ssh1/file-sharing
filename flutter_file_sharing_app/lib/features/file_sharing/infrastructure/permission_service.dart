import 'dart:io' show Platform;
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

class PermissionService {
  Future<bool> ensureStorage() async {
    // Basic approach: try requesting storage; on Android 13+ also request media permissions individually.
    final requests = <Permission>[Permission.storage];
    if (Platform.isAndroid) {
      // Only add Android 13+ granular media permissions if running on that SDK (avoid "No permissions in manifest" noise)
      final sdk = (await DeviceInfoPlugin().androidInfo).version.sdkInt;
      if (sdk >= 33) {
        requests.addAll([
          Permission.photos,
          Permission.videos,
          Permission.audio,
        ]);
      }
    }
    final statuses = await requests.request();
    // Success if any permission granted.
    return statuses.entries.any((e) => e.value.isGranted);
  }
}
