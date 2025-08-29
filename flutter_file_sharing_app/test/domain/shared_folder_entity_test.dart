import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/domain/entities/shared_folder.dart';

void main() {
  group('SharedFolder', () {
    test('should create a SharedFolder with given properties', () {
      final sharedFolder = SharedFolder(
        id: '1',
        name: 'Documents',
        path: '/user/documents',
        isShared: true,
      );

      expect(sharedFolder.id, '1');
      expect(sharedFolder.name, 'Documents');
      expect(sharedFolder.path, '/user/documents');
      expect(sharedFolder.isShared, true);
    });

    test('should return correct string representation', () {
      final sharedFolder = SharedFolder(
        id: '1',
        name: 'Documents',
        path: '/user/documents',
        isShared: true,
      );

      expect(sharedFolder.toString(),
          'SharedFolder(id: 1, name: Documents, path: /user/documents, isShared: true, autoApprove: false, allowPreview: true, allowed: null, denied: null)');
    });
  });
}
