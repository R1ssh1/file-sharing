import 'package:hive/hive.dart';

@HiveType(typeId: 1)
class SharedFolder extends HiveObject {
  @HiveField(0)
  final String id;
  @HiveField(1)
  final String name;
  @HiveField(2)
  final String? path;
  @HiveField(3)
  final bool isShared;
  @HiveField(4)
  final bool autoApprove;
  @HiveField(5)
  final bool allowPreview;
  // New: optional allow / deny peer lists for ACL enforcement
  @HiveField(6)
  final List<String>? allowedPeerIds; // if non-null, only these peers allowed
  @HiveField(7)
  final List<String>? deniedPeerIds; // if peer in this list -> blocked

  SharedFolder({
    required this.id,
    required this.name,
    this.path,
    this.isShared = false,
    this.autoApprove = false,
    this.allowPreview = true,
    this.allowedPeerIds,
    this.deniedPeerIds,
  });

  SharedFolder copyWith({
    String? id,
    String? name,
    String? path,
    bool? isShared,
    bool? autoApprove,
    bool? allowPreview,
    List<String>? allowedPeerIds,
    List<String>? deniedPeerIds,
  }) =>
      SharedFolder(
        id: id ?? this.id,
        name: name ?? this.name,
        path: path ?? this.path,
        isShared: isShared ?? this.isShared,
        autoApprove: autoApprove ?? this.autoApprove,
        allowPreview: allowPreview ?? this.allowPreview,
        allowedPeerIds: allowedPeerIds ?? this.allowedPeerIds,
        deniedPeerIds: deniedPeerIds ?? this.deniedPeerIds,
      );

  @override
  String toString() =>
      'SharedFolder(id: $id, name: $name, path: ${path ?? ''}, isShared: $isShared, autoApprove: $autoApprove, allowPreview: $allowPreview, allowed: ${allowedPeerIds?.length ?? 'null'}, denied: ${deniedPeerIds?.length ?? 'null'})';
}

// Temporary manual adapter to allow runtime before build_runner generation.
class SharedFolderAdapter extends TypeAdapter<SharedFolder> {
  @override
  final int typeId = 1;

  @override
  SharedFolder read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (var i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }
    return SharedFolder(
      id: fields[0] as String,
      name: fields[1] as String,
      path: fields[2] as String?,
      isShared: fields[3] as bool,
      autoApprove: (fields.containsKey(4) ? fields[4] : false) as bool,
      allowPreview: (fields.containsKey(5) ? fields[5] : true) as bool,
      allowedPeerIds:
          fields.containsKey(6) ? (fields[6] as List?)?.cast<String>() : null,
      deniedPeerIds:
          fields.containsKey(7) ? (fields[7] as List?)?.cast<String>() : null,
    );
  }

  @override
  void write(BinaryWriter writer, SharedFolder obj) {
    final allowList = obj.allowedPeerIds;
    final denyList = obj.deniedPeerIds;
    // dynamic count: base 6 + optional 2
    int fieldCount = 6;
    if (allowList != null) fieldCount++;
    if (denyList != null) fieldCount++;
    writer
      ..writeByte(fieldCount)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.path)
      ..writeByte(3)
      ..write(obj.isShared)
      ..writeByte(4)
      ..write(obj.autoApprove)
      ..writeByte(5)
      ..write(obj.allowPreview);
    if (allowList != null) {
      writer
        ..writeByte(6)
        ..write(allowList);
    }
    if (denyList != null) {
      writer
        ..writeByte(7)
        ..write(denyList);
    }
  }
}
