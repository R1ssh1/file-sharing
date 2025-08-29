import '../entities/shared_folder.dart';
import '../repositories/file_sharing_repository.dart';

class ShareFolder {
  final FileSharingRepository repository;
  ShareFolder(this.repository);

  Future<bool> call(SharedFolder folder) => repository.shareFolder(folder);
}
