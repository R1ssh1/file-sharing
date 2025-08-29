import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/data/repositories/file_sharing_repository_impl.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/data/datasources/local_storage_datasource.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/data/datasources/peer_connection_datasource.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/domain/entities/shared_folder.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/domain/entities/peer.dart';
import 'package:flutter_file_sharing_app/features/file_sharing/domain/entities/file_request.dart';

void main() {
  late FileSharingRepositoryImpl repository;
  late LocalStorageDataSource localStorageDataSource;
  late PeerConnectionDataSource peerConnectionDataSource;

  setUp(() {
    localStorageDataSource = LocalStorageDataSource();
    peerConnectionDataSource = PeerConnectionDataSource();
    repository = FileSharingRepositoryImpl(
      localStorageDataSource: localStorageDataSource,
      peerConnectionDataSource: peerConnectionDataSource,
    );
  });

  group('FileSharingRepositoryImpl', () {
    test('should share a folder', () async {
      final folder = SharedFolder(id: '1', name: 'Test Folder');
      final result = await repository.shareFolder(folder);
      expect(result, true);
    });

    test('should request a file', () async {
      final request = FileRequest(id: '1', folderId: '1', peerId: 'peer1');
      final result = await repository.requestFile(request);
      expect(result, true);
    });

    test('should get shared folders', () async {
      final folders = await repository.getSharedFolders();
      expect(folders, isA<List<SharedFolder>>());
    });

    test('should get peers', () async {
      final peers = await repository.getPeers();
      expect(peers, isA<List<Peer>>());
    });
  });
}