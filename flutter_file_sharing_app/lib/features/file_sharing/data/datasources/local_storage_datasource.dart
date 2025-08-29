import '../../domain/entities/shared_folder.dart';
import '../../domain/entities/file_request.dart';

class LocalStorageDataSource {
  final List<SharedFolder> _sharedFolders = [];
  final List<FileRequest> _fileRequests = [];

  Future<bool> addSharedFolder(SharedFolder folder) async {
    _sharedFolders.removeWhere((f) => f.id == folder.id);
    _sharedFolders.add(folder);
    return true;
  }

  Future<List<SharedFolder>> getSharedFolders() async =>
      List.unmodifiable(_sharedFolders);

  Future<bool> addFileRequest(FileRequest request) async {
    _fileRequests.add(request);
    return true;
  }

  Future<List<FileRequest>> getFileRequests() async =>
      List.unmodifiable(_fileRequests);

  Future<void> updateFileRequestStatus(
      String id, FileRequestStatus status) async {
    for (var i = 0; i < _fileRequests.length; i++) {
      final fr = _fileRequests[i];
      if (fr.id == id) {
        _fileRequests[i] = fr.copyWith(status: status);
        break;
      }
    }
  }
}
