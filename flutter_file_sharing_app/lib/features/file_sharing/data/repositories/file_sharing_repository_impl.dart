import '../../domain/entities/shared_folder.dart';
import '../../domain/entities/file_request.dart';
import '../../domain/entities/peer.dart';
import '../../domain/repositories/file_sharing_repository.dart';
import '../datasources/local_storage_datasource.dart';
import '../datasources/peer_connection_datasource.dart';
import '../datasources/hive_shared_folder_datasource.dart';
import '../datasources/hive_file_request_datasource.dart';

class FileSharingRepositoryImpl implements FileSharingRepository {
  final LocalStorageDataSource localStorageDataSource;
  final PeerConnectionDataSource peerConnectionDataSource;
  final HiveSharedFolderDataSource? hiveSharedFolderDataSource;
  final HiveFileRequestDataSource? hiveFileRequestDataSource;

  FileSharingRepositoryImpl({
    required this.localStorageDataSource,
    required this.peerConnectionDataSource,
    this.hiveSharedFolderDataSource,
    this.hiveFileRequestDataSource,
  });

  @override
  Future<bool> shareFolder(SharedFolder folder) async {
    final updated = folder.copyWith(isShared: true);
    if (hiveSharedFolderDataSource != null) {
      await hiveSharedFolderDataSource!.put(updated);
    }
    return localStorageDataSource.addSharedFolder(updated);
  }

  @override
  Future<bool> requestFile(FileRequest request) {
    if (hiveFileRequestDataSource != null) {
      hiveFileRequestDataSource!.put(request);
    }
    return localStorageDataSource.addFileRequest(request);
  }

  @override
  Future<List<SharedFolder>> getSharedFolders() {
    return localStorageDataSource.getSharedFolders();
  }

  @override
  Future<List<Peer>> getPeers() {
    return peerConnectionDataSource.getPeers();
  }

  @override
  Future<List<FileRequest>> getFileRequests() async {
    final inMemory = await localStorageDataSource.getFileRequests();
    if (hiveFileRequestDataSource != null) {
      final persisted = await hiveFileRequestDataSource!.getAll();
      // merge unique by id (persisted source of truth first)
      final map = {for (var fr in persisted) fr.id: fr};
      for (final fr in inMemory) {
        map.putIfAbsent(fr.id, () => fr);
      }
      return map.values.toList();
    }
    return inMemory;
  }

  @override
  Future<void> updateFileRequestStatus(
      String id, FileRequestStatus status) async {
    if (hiveFileRequestDataSource != null) {
      await hiveFileRequestDataSource!.updateStatus(id, status);
    }
    await localStorageDataSource.updateFileRequestStatus(id, status);
  }

  @override
  Future<void> updateSharedFolder(SharedFolder folder) async {
    if (hiveSharedFolderDataSource != null) {
      await hiveSharedFolderDataSource!.put(folder);
    }
    await localStorageDataSource.addSharedFolder(folder);
  }
}
