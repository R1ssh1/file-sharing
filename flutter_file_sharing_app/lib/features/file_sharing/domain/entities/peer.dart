class Peer {
  final String id; // device identifier
  final String name;
  final String? address; // IP:port or similar
  final DateTime? lastSeen;
  final String? encryption; // e.g., aes-gcm-chunked
  final String? version; // protocol/service version
  final String? fingerprint; // certificate fingerprint prefix

  const Peer({
    required this.id,
    required this.name,
    this.address,
    this.lastSeen,
    this.encryption,
    this.version,
    this.fingerprint,
  });
}
