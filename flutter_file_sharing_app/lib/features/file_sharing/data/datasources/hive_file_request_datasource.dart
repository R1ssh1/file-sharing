import 'package:hive_flutter/hive_flutter.dart';
import '../../domain/entities/file_request.dart';

class HiveFileRequestDataSource {
  static const boxName = 'file_requests';
  Box? _box;

  Future<void> open() async {
    _box ??= await Hive.openBox(boxName);
  }

  Future<void> put(FileRequest request) async {
    await open();
    await _box!.put(request.id, {
      'id': request.id,
      'folderId': request.folderId,
      'peerId': request.peerId,
      'filePath': request.filePath,
      'status': request.status.index,
      'createdAt': request.createdAt.toIso8601String(),
    });
  }

  Future<List<FileRequest>> getAll() async {
    await open();
    return _box!.values.map((e) {
      final map = Map<String, dynamic>.from(e as Map);
      return FileRequest(
        id: map['id'] as String,
        folderId: map['folderId'] as String,
        peerId: map['peerId'] as String,
        filePath: map['filePath'] as String?,
        status: FileRequestStatus.values[map['status'] as int],
        createdAt: DateTime.parse(map['createdAt'] as String),
      );
    }).toList();
  }

  Future<void> updateStatus(String id, FileRequestStatus status) async {
    await open();
    final data = _box!.get(id);
    if (data != null) {
      final map = Map<String, dynamic>.from(data as Map);
      map['status'] = status.index;
      await _box!.put(id, map);
    }
  }
}
