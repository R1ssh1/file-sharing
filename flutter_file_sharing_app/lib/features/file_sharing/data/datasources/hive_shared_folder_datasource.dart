import 'package:hive/hive.dart';
import '../../domain/entities/shared_folder.dart';

class HiveSharedFolderDataSource {
  static const boxName = 'shared_folders';
  Box<SharedFolder>? _box;

  Future<void> init() async {
    _box ??= await Hive.openBox<SharedFolder>(boxName);
  }

  Future<List<SharedFolder>> getAll() async {
    await init();
    return _box!.values.toList(growable: false);
  }

  Future<void> put(SharedFolder folder) async {
    await init();
    await _box!.put(folder.id, folder);
  }
}
