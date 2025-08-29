enum FileRequestStatus {
  pending,
  approved,
  rejected,
  transferring,
  completed,
  failed
}

class FileRequest {
  final String id;
  final String folderId;
  final String peerId;
  final String? filePath;
  final FileRequestStatus status;
  final DateTime createdAt;

  FileRequest({
    required this.id,
    required this.folderId,
    required this.peerId,
    this.filePath,
    this.status = FileRequestStatus.pending,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  FileRequest copyWith({
    FileRequestStatus? status,
  }) =>
      FileRequest(
        id: id,
        folderId: folderId,
        peerId: peerId,
        filePath: filePath,
        status: status ?? this.status,
        createdAt: createdAt,
      );
}
