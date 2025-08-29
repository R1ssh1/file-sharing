import '../entities/shared_folder.dart';
import '../repositories/file_sharing_repository.dart';

class GetSharedFolders {
  final FileSharingRepository repository;
  GetSharedFolders(this.repository);

  Future<List<SharedFolder>> call() => repository.getSharedFolders();
}
