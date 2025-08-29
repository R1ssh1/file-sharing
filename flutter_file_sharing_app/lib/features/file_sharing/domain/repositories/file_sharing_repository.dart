import '../entities/shared_folder.dart';
import '../entities/peer.dart';
import '../entities/file_request.dart';

abstract class FileSharingRepository {
  Future<bool> shareFolder(SharedFolder folder);
  Future<bool> requestFile(FileRequest request);
  Future<List<SharedFolder>> getSharedFolders();
  Future<List<Peer>> getPeers();
  Future<List<FileRequest>> getFileRequests();
  Future<void> updateFileRequestStatus(String id, FileRequestStatus status);
  Future<void> updateSharedFolder(SharedFolder folder);
}
